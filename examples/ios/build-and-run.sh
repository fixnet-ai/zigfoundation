#!/bin/bash
# zigfoundation iOS 模拟器一键运行脚本
#
# 用法:
#   ./build-and-run.sh                # 构建 + 在模拟器中运行
#   ./build-and-run.sh build-only     # 仅构建 .app
#
# 不依赖 Xcode — 使用 swiftc + simctl 命令行工具
#
# 技术说明:
#   - ReleaseSmall 避免 __dyld_get_image_header_containing_address (iOS 无此符号)
#   - ar x 提取 .o 再直接链接，避免 Zig .a 静态库的 Mach-O 对齐问题

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
APP_NAME="zigfoundation-test"
BUNDLE_ID="com.fixnet.zigfoundation.test"

# -------------------------------------------------------------------
# Step 0: 检查环境
# -------------------------------------------------------------------
echo "=== [0/7] 检查环境 ==="

command -v swiftc >/dev/null 2>&1 || { echo "错误: swiftc 未找到，请安装 Xcode"; exit 1; }
command -v xcrun >/dev/null 2>&1 || { echo "错误: xcrun 未找到，请安装 Xcode"; exit 1; }

SDK_PATH="$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null)"
if [ -z "$SDK_PATH" ]; then
    echo "错误: 无法找到 iOS Simulator SDK"
    exit 1
fi
echo "  SDK: $SDK_PATH"

# -------------------------------------------------------------------
# Step 1: 选择 / 创建模拟器
# -------------------------------------------------------------------
echo "=== [1/7] 准备模拟器 ==="

DEVICE_NAME="${DEVICE_NAME:-iPhone 17}"
DEVICE_UDID=$(xcrun simctl list devices available | grep "$DEVICE_NAME (" | head -1 | sed -E 's/.*\(([A-F0-9-]+)\).*/\1/')

if [ -z "$DEVICE_UDID" ]; then
    echo "  创建新模拟器: $DEVICE_NAME..."
    RUNTIME=$(xcrun simctl list runtimes ios | grep "iOS" | tail -1 | sed -E 's/.*\((com\.apple\..*)\).*/\1/')
    DEVICE_TYPE=$(xcrun simctl list devicetypes | grep "$DEVICE_NAME " | head -1 | sed -E 's/.*\((com\.apple\..*)\).*/\1/')
    if [ -z "$DEVICE_TYPE" ]; then
        DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17"
    fi
    DEVICE_UDID=$(xcrun simctl create "$DEVICE_NAME" "$DEVICE_TYPE" "$RUNTIME" 2>/dev/null)
    echo "  已创建: $DEVICE_UDID"
else
    echo "  使用已有模拟器: $DEVICE_NAME ($DEVICE_UDID)"
fi

# 启动模拟器（如果未启动）
if ! xcrun simctl list devices booted | grep -q "$DEVICE_UDID"; then
    echo "  启动模拟器..."
    xcrun simctl boot "$DEVICE_UDID" 2>/dev/null || true
    echo "  等待模拟器启动..."
    for i in $(seq 1 30); do
        if xcrun simctl list devices booted | grep -q "$DEVICE_UDID"; then
            STATUS=$(xcrun simctl list devices | grep "$DEVICE_UDID" | grep -o "Booted")
            if [ "$STATUS" = "Booted" ]; then
                break
            fi
        fi
        sleep 2
        echo -n "."
    done
    echo ""
fi

echo "  模拟器已就绪"

# -------------------------------------------------------------------
# Step 2: 编译 Zig 静态库 (ReleaseSmall)
# -------------------------------------------------------------------
echo "=== [2/7] 编译 Zig 静态库 (ReleaseSmall) ==="

cd "$PROJECT_DIR"
zig build example-ios \
    -Dtarget="aarch64-ios-simulator" \
    -Doptimize=ReleaseSmall \
    -Dsysroot="$SDK_PATH" 2>&1 | tail -3

LIB_PATH="$PROJECT_DIR/zig-out/lib/libzigfoundation-example-ios.a"
if [ ! -f "$LIB_PATH" ]; then
    echo "错误: 静态库未生成: $LIB_PATH"
    exit 1
fi
echo "  → $LIB_PATH ($(du -h "$LIB_PATH" | cut -f1))"

# -------------------------------------------------------------------
# Step 3: 提取 .o 文件 (避免 Mach-O 对齐问题)
# -------------------------------------------------------------------
echo "=== [3/7] 提取 .o 文件 ==="

BUILD_DIR="$SCRIPT_DIR/.build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

OBJ_DIR="$BUILD_DIR/objects"
rm -rf "$OBJ_DIR"
mkdir -p "$OBJ_DIR"

cd "$OBJ_DIR"
ar x "$LIB_PATH"
chmod 644 ./*.o
OBJ_COUNT=$(ls -1 ./*.o 2>/dev/null | wc -l | tr -d ' ')
echo "  提取了 $OBJ_COUNT 个 .o 文件"

cd "$BUILD_DIR"

# -------------------------------------------------------------------
# Step 4: 编译 Swift → 可执行文件
# -------------------------------------------------------------------
echo "=== [4/7] 编译 Swift 入口 ==="

SWIFT_FILE="$SCRIPT_DIR/AppDelegate.swift"
EXECUTABLE="$BUILD_DIR/$APP_NAME"

ARCH_TRIPLE="arm64-apple-ios16.0-simulator"
swiftc \
    -sdk "$SDK_PATH" \
    -target "$ARCH_TRIPLE" \
    -parse-as-library \
    -O \
    -o "$EXECUTABLE" \
    "$SWIFT_FILE" \
    "$OBJ_DIR"/*.o \
    -framework UIKit \
    -framework Foundation \
    2>&1

if [ ! -f "$EXECUTABLE" ]; then
    echo "错误: Swift 编译失败"
    exit 1
fi
echo "  → $EXECUTABLE ($(du -h "$EXECUTABLE" | cut -f1))"

# -------------------------------------------------------------------
# Step 5: 创建 .app bundle
# -------------------------------------------------------------------
echo "=== [5/7] 创建 .app bundle ==="

BUNDLE_DIR="$BUILD_DIR/${APP_NAME}.app"
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR"

cp "$EXECUTABLE" "$BUNDLE_DIR/$APP_NAME"
chmod +x "$BUNDLE_DIR/$APP_NAME"

# 生成 Info.plist 而非用模板（确保 CFBundleExecutable 一致）
cat > "$BUNDLE_DIR/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSRequiresIPhoneOS</key>
    <true/>
    <key>UIRequiredDeviceCapabilities</key>
    <array>
        <string>arm64</string>
    </array>
    <key>UISupportedInterfaceOrientations</key>
    <array>
        <string>UIInterfaceOrientationPortrait</string>
    </array>
</dict>
</plist>
PLIST

echo "  → $BUNDLE_DIR"

# 如果只需构建，到这里停止
if [ "${1:-}" = "build-only" ]; then
    echo ""
    echo "========================================="
    echo "  .app bundle 已创建: $BUNDLE_DIR"
    echo "  安装运行: xcrun simctl install booted \"$BUNDLE_DIR\" && xcrun simctl launch --console booted $BUNDLE_ID"
    echo "========================================="
    exit 0
fi

# -------------------------------------------------------------------
# Step 6: 安装到模拟器
# -------------------------------------------------------------------
echo "=== [6/7] 安装到模拟器 ==="

xcrun simctl install "$DEVICE_UDID" "$BUNDLE_DIR" 2>&1
echo "  已安装"

# -------------------------------------------------------------------
# Step 7: 启动 + 截图验证
# -------------------------------------------------------------------
echo "=== [7/7] 启动应用 ==="

# 打开模拟器窗口
open -a Simulator 2>/dev/null || true

# 启动应用（后台运行）
xcrun simctl launch "$DEVICE_UDID" "$BUNDLE_ID" &
LAUNCH_PID=$!

# 等待应用启动完成 + 测试执行
sleep 5

# 截图保存
SCREENSHOT="$BUILD_DIR/screenshot.png"
xcrun simctl io "$DEVICE_UDID" screenshot "$SCREENSHOT" 2>/dev/null
echo "  截图: $SCREENSHOT"

kill $LAUNCH_PID 2>/dev/null || true

echo ""
echo "========================================="
echo "  查看截图确认 PASS/FAIL 结果:"
echo "    open $SCREENSHOT"
echo "  详细日志:"
echo "    xcrun simctl spawn booted log stream --predicate 'process == \"$APP_NAME\"'"
echo "========================================="

# 检查应用是否成功安装
if xcrun simctl listapps "$DEVICE_UDID" 2>/dev/null | grep -q "$BUNDLE_ID"; then
    echo "✅ 应用已成功安装到模拟器"
else
    echo "❌ 应用安装失败"
    exit 1
fi
