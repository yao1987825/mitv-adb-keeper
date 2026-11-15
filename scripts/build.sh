#!/bin/bash
# 构建 AdbKeeper APK
# 需要：Android SDK build-tools (aapt2/d8/zipalign/apksigner)、android-6.0 平台库、JDK 17
set -e
cd "$(dirname "$0")/.."

SDK="${ANDROID_SDK:-$HOME/rikkahub_file/android_sdk}"
BT="${SDK}/android-14"
PLATFORM="${SDK}/android-6.0/android.jar"
JAVAC="${JAVA_HOME:+$JAVA_HOME/bin/}javac"
KEYSTORE="dist/adbkeeper.keystore"

echo "==> 编译资源"
"$BT/aapt2" compile --dir app/res -o app/res.zip
"$BT/aapt2" link -o app/unsigned.apk -I "$PLATFORM" \
    --manifest app/AndroidManifest.xml --java app/gen app/res.zip

echo "==> 编译 Java"
rm -rf app/classes app/dexout
mkdir -p app/classes app/dexout
"$JAVAC" -source 1.8 -target 1.8 -bootclasspath "$PLATFORM" -d app/classes \
    app/gen/com/example/adbkeeper/R.java app/src/com/example/adbkeeper/*.java

echo "==> 生成 dex"
"$BT/d8" --release --lib "$PLATFORM" --output app/dexout app/classes/com/example/adbkeeper/*.class

echo "==> 打包并签名"
python3 - <<'PY'
import zipfile, shutil
shutil.copy('app/unsigned.apk', 'app/withdex.apk')
with zipfile.ZipFile('app/withdex.apk', 'a') as z:
    z.write('app/dexout/classes.dex', 'classes.dex')
PY
"$BT/zipalign" -f 4 app/withdex.apk app/aligned.apk
"$BT/apksigner" sign --ks "$KEYSTORE" --ks-key-alias adbkeeper \
    --ks-pass pass:adbkeeper123 --key-pass pass:adbkeeper123 \
    --out dist/adbkeeper.apk app/aligned.apk
"$BT/apksigner" verify dist/adbkeeper.apk
echo "==> 完成: dist/adbkeeper.apk"
