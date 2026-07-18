//! 重新导出 libyaml C API 绑定供 zigfoundation 的 yaml.zig 使用。
//!
//! translate-c 生成的 yaml.h 绑定通过 yaml_h_internal 导入，
//! 本文件将 zigfoundation 所需的符号显式重新导出，保持 API 稳定。

const yaml_h = @import("yaml_h_internal");

// ---- 类型 ----
pub const yaml_document_t = yaml_h.yaml_document_t;
pub const yaml_parser_t = yaml_h.yaml_parser_t;
pub const yaml_node_t = yaml_h.yaml_node_t;

// ---- 常量 ----
pub const YAML_SCALAR_NODE = yaml_h.YAML_SCALAR_NODE;
pub const YAML_SEQUENCE_NODE = yaml_h.YAML_SEQUENCE_NODE;
pub const YAML_MAPPING_NODE = yaml_h.YAML_MAPPING_NODE;

// ---- 函数 ----
pub const yaml_parser_initialize = yaml_h.yaml_parser_initialize;
pub const yaml_parser_delete = yaml_h.yaml_parser_delete;
pub const yaml_parser_set_input_string = yaml_h.yaml_parser_set_input_string;
pub const yaml_parser_load = yaml_h.yaml_parser_load;
pub const yaml_document_delete = yaml_h.yaml_document_delete;
pub const yaml_document_get_root_node = yaml_h.yaml_document_get_root_node;
pub const yaml_document_get_node = yaml_h.yaml_document_get_node;
