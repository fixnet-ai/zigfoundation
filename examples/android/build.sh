#!/bin/bash
# zigfoundation Android 示例构建脚本
#
# 用法:
#   ./build.sh                                 # 构建 .so
#   ./build.sh all                             # 构建 .so + APK 打包指引
#
# 依赖:
#   - Zig 0.16.0+
#   - Android NDK (r25+) — 交叉编译必需
#   - Android SDK (build-tools, platform-tools) — APK 打包必需 (仅 all 模式)
#
# 环境变量 (在 ~/.bash_profile 中设置):
#   ANDROID_NDK_HOME  — NDK 安装路径
#   ANDROID_HOME      — SDK 安装路径

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== zigfoundation Android 示例构建 ==="
echo ""

# 检查环境变量
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    echo "Error: ANDROID_NDK_HOME 未设置。"
    echo "请在 ~/.bash_profile 中添加:"
    echo "  export ANDROID_NDK_HOME=\$HOME/Library/Android/sdk/ndk/<version>"
    exit 1
fi
echo "ANDROID_NDK_HOME=${ANDROID_NDK_HOME}"

# NDK sysroot
NDK_SYSROOT="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/darwin-x86_64/sysroot"
if [ ! -d "$NDK_SYSROOT" ]; then
    echo "Error: NDK sysroot 未找到: $NDK_SYSROOT"
    exit 1
fi

# 检测架构 (Android 模拟器常用 x86_64, 真机用 aarch64)
ARCH="${ARCH:-aarch64}"
TARGET="${ARCH}-linux-android"

echo "[1/2] 编译 Zig 共享库 (target: ${TARGET})..."
cd "$PROJECT_DIR"

# 生成 libc 配置文件 (Zig 0.16.0 不捆绑 Android Bionic，需指向 NDK)
LIBC_CONF="${PROJECT_DIR}/.zig-cache/android_libc.conf"
cat > "${LIBC_CONF}" << LIBCEOF
include_dir=${NDK_SYSROOT}/usr/include
sys_include_dir=${NDK_SYSROOT}/usr/include
crt_dir=${NDK_SYSROOT}/usr/lib/${TARGET}/35
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=
LIBCEOF

zig build example-android \
    -Dtarget="${TARGET}" \
    -Doptimize=ReleaseSafe \
    -Dsysroot="${NDK_SYSROOT}" \
    -Dlibc-file="${LIBC_CONF}" 2>&1

SO_PATH="${PROJECT_DIR}/zig-out/lib/libzigfoundation-example-android.so"
if [ ! -f "$SO_PATH" ]; then
    echo "Error: .so 未生成: $SO_PATH"
    exit 1
fi
echo "  → ${SO_PATH}"

echo ""
echo "[2/2] APK 打包与部署"
echo ""
echo "将 .so 集成到 Android 项目中的方法:"
echo ""
echo "方法 A — Android Studio 项目:"
echo "  1. 创建新项目: Android Studio → New Project → Empty Activity"
echo "  2. 复制以下文件到项目中:"
echo "     - ${SCRIPT_DIR}/MainActivity.java → app/src/main/java/com/example/zigfoundation/"
echo "     - ${SCRIPT_DIR}/AndroidManifest.xml → app/src/main/"
echo "  3. 将 .so 放入 jniLibs:"
echo "     mkdir -p app/src/main/jniLibs/arm64-v8a"
echo "     cp ${SO_PATH} app/src/main/jniLibs/arm64-v8a/"
echo "  4. 运行: Android Studio → Run (选择模拟器)"
echo ""
echo "方法 B — 命令行手动打包:"
echo "  # 编译 Java"
echo "  javac -d obj -bootclasspath \${ANDROID_HOME}/platforms/android-35/android.jar \\"
echo "    ${SCRIPT_DIR}/MainActivity.java"
echo "  # 转换为 dex"
echo "  \${ANDROID_HOME}/build-tools/35.0.0/d8 --output . \\"
echo "    --lib \${ANDROID_HOME}/platforms/android-35/android.jar obj/com/example/zigfoundation/*.class"
echo "  # 打包 APK"
echo "  \${ANDROID_HOME}/build-tools/35.0.0/aapt package -f -M ${SCRIPT_DIR}/AndroidManifest.xml \\"
echo "    -I \${ANDROID_HOME}/platforms/android-35/android.jar -F app-unsigned.apk"
echo "  # 添加 .so"
echo "  mkdir -p lib/arm64-v8a && cp ${SO_PATH} lib/arm64-v8a/"
echo "  \${ANDROID_HOME}/build-tools/35.0.0/aapt add app-unsigned.apk lib/arm64-v8a/libzigfoundation-example-android.so"
echo "  # 签名 + 安装"
echo "  apksigner sign --ks debug.keystore app-unsigned.apk"
echo "  adb install app-unsigned.apk"
echo ""
echo "运行后查看结果:"
echo "  adb logcat -s zigfoundation:V  # 查看测试日志"
echo "  # 屏幕显示绿色 PASS 或红色 FAIL"

if [ "${1:-}" = "all" ]; then
    echo ""
    echo "提示: 完整 APK 打包需要 Android SDK。"
    echo "请确保 ANDROID_HOME 已设置，推荐使用 Android Studio 打开项目（方法 A）。"
fi
