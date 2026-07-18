#!/bin/bash
# zigfoundation iOS 示例构建脚本
#
# 用法:
#   ./build.sh                    # 构建静态库 + 打开 Xcode 指引
#   ./build.sh run                # 构建后在模拟器中运行（需要 Xcode）
#
# 依赖:
#   - Zig 0.16.0+
#   - Xcode 16+ (with iOS Simulator)
#   - macOS
#
# 环境变量 (在 ~/.bash_profile 中设置):
#   IOS_SDK_HOME — iOS SDK 路径 (xcrun --sdk iphonesimulator --show-sdk-path)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== zigfoundation iOS 示例构建 ==="
echo ""

# 检查环境变量
if [ -z "${IOS_SDK_HOME:-}" ]; then
    export IOS_SDK_HOME=$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null)
fi
if [ -z "${IOS_SDK_HOME:-}" ]; then
    echo "Error: IOS_SDK_HOME 未设置且 xcrun 不可用。请安装 Xcode。"
    exit 1
fi
echo "IOS_SDK_HOME=${IOS_SDK_HOME}"

# 检测架构
ARCH="${ARCH:-aarch64}"
TARGET="${ARCH}-ios-simulator"

echo ""
echo "[1/2] 编译 Zig 静态库 (target: ${TARGET})..."
cd "$PROJECT_DIR"
zig build example-ios -Dtarget="${TARGET}" -Doptimize=ReleaseSafe -Dsysroot="${IOS_SDK_HOME}" 2>&1

LIB_PATH="${PROJECT_DIR}/zig-out/lib/libzigfoundation-example-ios.a"
if [ ! -f "$LIB_PATH" ]; then
    echo "Error: 静态库未生成: $LIB_PATH"
    exit 1
fi
echo "  → ${LIB_PATH}"

echo ""
echo "[2/2] Xcode 项目集成指引"
echo ""
echo "在 Xcode 中使用此静态库："
echo ""
echo "方法 A — 新建 Swift 项目:"
echo "  1. Xcode → New Project → iOS → App (Swift)"
echo "  2. 将以下文件添加到项目:"
echo "     - ${SCRIPT_DIR}/AppDelegate.swift"
echo "     - ${SCRIPT_DIR}/Info.plist"
echo "  3. Build Phases → Link Binary With Libraries → 添加:"
echo "     ${LIB_PATH}"
echo "  4. Build Settings → Library Search Paths → 添加:"
echo "     ${PROJECT_DIR}/zig-out/lib"
echo "  5. Build Settings → Swift Compiler → Other Linker Flags → 添加:"
echo "     -lzigfoundation-example-ios"
echo "  6. 选择 iOS Simulator 目标，Cmd+R 运行"
echo ""
echo "方法 B — Run Script 构建阶段:"
echo "  Build Phases → + → New Run Script Phase:"
echo "    cd ${PROJECT_DIR}"
echo "    zig build example-ios -Dtarget=\${ARCH}-ios-simulator -Dsysroot=\${IOS_SDK_HOME}"
echo ""
echo "运行后在模拟器中查看结果（绿色 PASS 或红色 FAIL）。"
echo "详细日志可通过 Console.app 或 'xcrun simctl spawn booted log stream' 查看。"

if [ "${1:-}" = "run" ]; then
    echo ""
    echo "提示: 请在 Xcode 中打开项目后选择 iOS Simulator 并运行。"
fi
