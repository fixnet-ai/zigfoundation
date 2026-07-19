//! YAML 解析封装 — 基于 libyaml C 库的薄封装
//!
//! 通过 vendor/yaml 独立 Zig 包（`b.dependency("yaml")`）编译和链接 libyaml。
//! 本模块提供 `Document` 类型，封装 `yaml_document_t` 并提供 Zig 友好的节点导航 API。
//!
//! 不包含任何业务配置结构（如代理、TUN、DNS 配置），仅提供通用的 YAML 解析能力。
//!
//! ## 使用示例
//!
//! ```
//! const yaml = @import("zigfoundation").yaml;
//!
//! var doc = try yaml.Document.parse(
//!     \\server:
//!     \\  port: 8080
//!     \\  hosts:
//!     \\    - example.com
//!     \\    - test.com
//! );
//! defer doc.deinit();
//!
//! const root = doc.root();
//! const server = root.mappingGet("server").?;
//! const port = server.mappingGet("port").?.asInt(u16).?;
//! ```

const std = @import("std");
const yaml_c = @import("yaml_c");

/// 文档解析错误。
pub const Error = error{
    ParseFailed,
    OutOfMemory,
    InvalidNodeType,
    EmptyDocument,
};

/// 已解析的 YAML 文档。
///
/// 包装 libyaml 的 `yaml_document_t`，提供树形导航方法。
/// 所有节点引用在 `deinit()` 之前有效。
pub const Document = struct {
    doc: yaml_c.yaml_document_t,

    /// 从 YAML 字符串解析文档。
    /// 空流或纯注释文件返回 `error.EmptyDocument`（不产出无根文档）。
    pub fn parse(content: []const u8) !Document {
        var parser: yaml_c.yaml_parser_t = undefined;
        if (yaml_c.yaml_parser_initialize(&parser) == 0) {
            return error.OutOfMemory;
        }
        defer yaml_c.yaml_parser_delete(&parser);

        yaml_c.yaml_parser_set_input_string(&parser, content.ptr, content.len);

        var doc: yaml_c.yaml_document_t = undefined;
        if (yaml_c.yaml_parser_load(&parser, &doc) == 0) {
            return error.ParseFailed;
        }

        // 空流/纯注释：load 返回成功但文档无根节点。在此拒绝并释放，
        // 保证 root() 永远有根可取（曾经 root() 对空文档 @panic 使进程 abort）。
        if (yaml_c.yaml_document_get_root_node(&doc) == null) {
            yaml_c.yaml_document_delete(&doc);
            return error.EmptyDocument;
        }

        return Document{ .doc = doc };
    }

    /// 释放文档占用的所有资源。
    pub fn deinit(self: *Document) void {
        yaml_c.yaml_document_delete(&self.doc);
        self.* = undefined;
    }

    /// 获取文档根节点。
    /// `parse()` 已拒绝空文档，此处根节点必然存在。
    pub fn root(self: *Document) Node {
        const node_ptr = yaml_c.yaml_document_get_root_node(&self.doc) orelse
            unreachable; // parse() 保证非空文档
        return Node{
            .doc = &self.doc,
            .ptr = node_ptr,
        };
    }

    /// 文档树中的一个节点。
    pub const Node = struct {
        doc: *yaml_c.yaml_document_t,
        ptr: *yaml_c.yaml_node_t,

        /// 节点类型。
        pub const Kind = enum {
            scalar,
            sequence,
            mapping,
        };

        /// 获取节点类型。
        pub fn kind(self: Node) Kind {
            return switch (self.ptr.*.type) {
                yaml_c.YAML_SCALAR_NODE => .scalar,
                yaml_c.YAML_SEQUENCE_NODE => .sequence,
                yaml_c.YAML_MAPPING_NODE => .mapping,
                else => .scalar,
            };
        }

        /// 将标量节点解释为字符串。
        /// 非标量节点返回 null。
        pub fn asString(self: Node) ?[]const u8 {
            if (self.ptr.*.type != yaml_c.YAML_SCALAR_NODE) return null;
            const data = self.ptr.*.data.scalar;
            const len: usize = @intCast(data.length);
            return data.value[0..len];
        }

        /// 将标量节点解释为整数。
        /// 非标量节点或非整数标量返回 null。
        pub fn asInt(self: Node, comptime T: type) ?T {
            const s = self.asString() orelse return null;
            return std.fmt.parseInt(T, s, 10) catch null;
        }

        /// 将标量节点解释为布尔值。
        pub fn asBool(self: Node) ?bool {
            const s = self.asString() orelse return null;
            if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "yes")) return true;
            if (std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "no")) return false;
            return null;
        }

        /// 获取序列节点的长度。非序列节点返回 0。
        pub fn seqLen(self: Node) usize {
            if (self.ptr.*.type != yaml_c.YAML_SEQUENCE_NODE) return 0;
            const items = self.ptr.*.data.sequence.items;
            return items.top - items.start;
        }

        /// 获取序列节点的第 `index` 个子节点。越界或无子节点返回 null。
        pub fn seqGet(self: Node, index: usize) ?Node {
            if (self.ptr.*.type != yaml_c.YAML_SEQUENCE_NODE) return null;
            const items = self.ptr.*.data.sequence.items;
            const len = items.top - items.start;
            if (index >= len) return null;
            const item_idx: c_int = items.start[index];
            const node_ptr = yaml_c.yaml_document_get_node(self.doc, item_idx) orelse return null;
            return Node{ .doc = self.doc, .ptr = node_ptr };
        }

        /// 遍历序列节点的迭代器。非序列节点返回空迭代器。
        pub fn seqIter(self: Node) SeqIterator {
            const len = self.seqLen();
            return SeqIterator{ .node = self, .index = 0, .len = len };
        }

        /// 获取映射节点中指定键的值节点。键不存在或非映射节点返回 null。
        pub fn mappingGet(self: Node, key: []const u8) ?Node {
            if (self.ptr.*.type != yaml_c.YAML_MAPPING_NODE) return null;
            const pairs = self.ptr.*.data.mapping.pairs;
            const count = pairs.top - pairs.start;
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const pair = &pairs.start[i];
                const key_node = yaml_c.yaml_document_get_node(self.doc, pair.*.key) orelse continue;
                if (key_node.*.type != yaml_c.YAML_SCALAR_NODE) continue;
                const kd = key_node.*.data.scalar;
                const klen: usize = @intCast(kd.length);
                if (klen != key.len) continue;
                if (!std.mem.eql(u8, kd.value[0..klen], key)) continue;
                const val_node = yaml_c.yaml_document_get_node(self.doc, pair.*.value) orelse return null;
                return Node{ .doc = self.doc, .ptr = val_node };
            }
            return null;
        }

        /// 映射节点遍历迭代器。非映射节点返回空迭代器。
        pub fn mappingIter(self: Node) MappingIterator {
            const count: usize = if (self.ptr.*.type == yaml_c.YAML_MAPPING_NODE)
                self.ptr.*.data.mapping.pairs.top - self.ptr.*.data.mapping.pairs.start
            else
                0;
            return MappingIterator{ .node = self, .index = 0, .count = count };
        }
    };

    /// 序列节点迭代器。
    pub const SeqIterator = struct {
        node: Node,
        index: usize,
        len: usize,

        pub fn next(self: *SeqIterator) ?Node {
            if (self.index >= self.len) return null;
            const result = self.node.seqGet(self.index);
            self.index += 1;
            return result;
        }
    };

    /// 映射节点迭代器。
    pub const MappingIterator = struct {
        node: Node,
        index: usize,
        count: usize,

        pub fn next(self: *MappingIterator) ?MappingEntry {
            if (self.index >= self.count) return null;
            defer self.index += 1;

            const pairs = self.node.ptr.*.data.mapping.pairs;
            const pair = &pairs.start[self.index];

            const key_node = yaml_c.yaml_document_get_node(self.node.doc, pair.*.key) orelse return null;
            const val_node = yaml_c.yaml_document_get_node(self.node.doc, pair.*.value) orelse return null;

            return MappingEntry{
                .key = Node{ .doc = self.node.doc, .ptr = key_node },
                .value = Node{ .doc = self.node.doc, .ptr = val_node },
            };
        }
    };

    /// 映射条目（键值对）。
    pub const MappingEntry = struct {
        key: Node,
        value: Node,
    };
};

// ============================================================================
// 测试
// ============================================================================

const testing = std.testing;

test "yaml: parse simple scalar" {
    const content = "hello world";
    var doc = try Document.parse(content);
    defer doc.deinit();

    const root = doc.root();
    try testing.expectEqual(Document.Node.Kind.scalar, root.kind());
    try testing.expectEqualStrings("hello world", root.asString().?);
}

test "yaml: parse integer" {
    const content = "42";
    var doc = try Document.parse(content);
    defer doc.deinit();

    const root = doc.root();
    try testing.expectEqual(@as(u32, 42), root.asInt(u32).?);
}

test "yaml: parse boolean true" {
    const content = "true";
    var doc = try Document.parse(content);
    defer doc.deinit();

    const root = doc.root();
    try testing.expectEqual(true, root.asBool().?);
}

test "yaml: parse boolean false" {
    const content = "false";
    var doc = try Document.parse(content);
    defer doc.deinit();

    const root = doc.root();
    try testing.expectEqual(false, root.asBool().?);
}

test "yaml: parse sequence" {
    const content =
        \\- apple
        \\- banana
        \\- cherry
    ;
    var doc = try Document.parse(content);
    defer doc.deinit();

    const root = doc.root();
    try testing.expectEqual(Document.Node.Kind.sequence, root.kind());
    try testing.expectEqual(@as(usize, 3), root.seqLen());

    try testing.expectEqualStrings("apple", root.seqGet(0).?.asString().?);
    try testing.expectEqualStrings("banana", root.seqGet(1).?.asString().?);
    try testing.expectEqualStrings("cherry", root.seqGet(2).?.asString().?);
    try testing.expect(root.seqGet(3) == null);
}

test "yaml: parse mapping" {
    const content =
        \\name: zigfoundation
        \\version: "0.1.0"
        \\active: true
    ;
    var doc = try Document.parse(content);
    defer doc.deinit();

    const root = doc.root();
    try testing.expectEqual(Document.Node.Kind.mapping, root.kind());

    try testing.expectEqualStrings("zigfoundation", root.mappingGet("name").?.asString().?);
    try testing.expectEqualStrings("0.1.0", root.mappingGet("version").?.asString().?);
    try testing.expectEqual(true, root.mappingGet("active").?.asBool().?);
    try testing.expect(root.mappingGet("nonexistent") == null);
}

test "yaml: nested mapping and sequence" {
    const content =
        \\server:
        \\  port: 8080
        \\  hosts:
        \\    - example.com
        \\    - test.com
    ;
    var doc = try Document.parse(content);
    defer doc.deinit();

    const root = doc.root();
    const server = root.mappingGet("server").?;
    try testing.expectEqual(Document.Node.Kind.mapping, server.kind());

    const port = server.mappingGet("port").?;
    try testing.expectEqual(@as(u32, 8080), port.asInt(u32).?);

    const hosts = server.mappingGet("hosts").?;
    try testing.expectEqual(Document.Node.Kind.sequence, hosts.kind());
    try testing.expectEqual(@as(usize, 2), hosts.seqLen());
    try testing.expectEqualStrings("example.com", hosts.seqGet(0).?.asString().?);
    try testing.expectEqualStrings("test.com", hosts.seqGet(1).?.asString().?);
}

test "yaml: sequence iteration" {
    const content =
        \\- red
        \\- green
        \\- blue
    ;
    var doc = try Document.parse(content);
    defer doc.deinit();

    const root = doc.root();
    var it = root.seqIter();
    var count: usize = 0;
    while (it.next()) |_| {
        count += 1;
    }
    try testing.expectEqual(@as(usize, 3), count);
}

test "yaml: mapping iteration" {
    const content =
        \\a: 1
        \\b: 2
    ;
    var doc = try Document.parse(content);
    defer doc.deinit();

    const root = doc.root();
    var it = root.mappingIter();
    var count: usize = 0;
    while (it.next()) |_| {
        count += 1;
    }
    try testing.expectEqual(@as(usize, 2), count);
}

test "yaml: empty or comment-only document returns EmptyDocument (regression)" {
    // 回归 1：空流 load 成功但无根节点，root() 曾 @panic 使进程 abort。
    // 回归 2：旧测试写作 `_ = parse(..) catch |err| { ... }`，parse 实际成功时
    //         断言从不执行，且成功返回的 Document 泄漏 C 堆内存。
    try testing.expectError(error.EmptyDocument, Document.parse(""));
    try testing.expectError(error.EmptyDocument, Document.parse("# 只有注释\n"));
}

test "yaml: malformed document returns ParseFailed" {
    try testing.expectError(error.ParseFailed, Document.parse("[unclosed"));
}

test "yaml: seqGet on non-sequence returns null" {
    const content = "scalar";
    var doc = try Document.parse(content);
    defer doc.deinit();

    const root = doc.root();
    try testing.expect(root.seqGet(0) == null);
}

test "yaml: mappingGet on non-mapping returns null" {
    const content = "scalar";
    var doc = try Document.parse(content);
    defer doc.deinit();

    const root = doc.root();
    try testing.expect(root.mappingGet("any") == null);
}
