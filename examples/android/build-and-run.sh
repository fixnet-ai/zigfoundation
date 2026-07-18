#!/bin/bash
# zigfoundation Android 测试 — 构建并在 ARM64 模拟器中运行
#
# 用法: ./examples/android/build-and-run.sh
#
# 前提:
#   - Android SDK/NDK 已安装（$ANDROID_HOME / $ANDROID_NDK_HOME）
#   - AVD "zigfoundation-test" 已创建（ARM64, API 36+）
#   - zig 0.16.0 在 PATH 中

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ---- 环境检查 ----
: "${ANDROID_HOME:?请设置 ANDROID_HOME 环境变量}"
: "${ANDROID_NDK_HOME:?请设置 ANDROID_NDK_HOME 环境变量}"

ADB="$ANDROID_HOME/platform-tools/adb"
EMULATOR="$ANDROID_HOME/emulator/emulator"
SYSROOT="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/sysroot"
LIBC_FILE="$PROJECT_DIR/ndk-libc.conf"

# ---- 1. 构建测试二进制（动态链接） ----
echo "=== [1/4] 构建 zigfoundation-android-test ==="
cd "$PROJECT_DIR"
zig build android-test \
    -Dtarget="aarch64-linux-android" \
    -Dsysroot="$SYSROOT" \
    -Dlibc-file="$LIBC_FILE"
echo ""

# ---- 2. 启动模拟器（有窗口模式） ----
echo "=== [2/4] 启动 Android 模拟器 ==="
if ! "$ADB" devices 2>/dev/null | grep -q "emulator"; then
    echo "启动 AVD: zigfoundation-test（有窗口模式）..."
    "$EMULATOR" -avd zigfoundation-test -no-boot-anim &
    echo "等待模拟器启动..."
    for i in $(seq 1 90); do
        sleep 2
        if "$ADB" devices 2>/dev/null | grep -q "emulator.*device"; then
            echo "模拟器已连接! ($((i*2))秒)"
            break
        fi
    done
else
    echo "模拟器已在运行"
fi

# 等待 boot 完成
"$ADB" wait-for-device
for i in $(seq 1 30); do
    STATUS=$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
    if [ "$STATUS" = "1" ]; then
        echo "Boot 完成!"
        break
    fi
    sleep 2
done
echo ""

# ---- 3. 推送二进制 ----
echo "=== [3/4] 推送测试到设备 ==="
"$ADB" push zig-out/bin/zigfoundation-android-test /data/local/tmp/zigfoundation-android-test
"$ADB" shell chmod 755 /data/local/tmp/zigfoundation-android-test
echo ""

# ---- 4. 运行测试 ----
echo "=== [4/4] 运行测试 ==="
"$ADB" shell /data/local/tmp/zigfoundation-android-test
echo ""
echo "Done."