#!/usr/bin/env bash
# 构建 休息提醒 APK
# 用法: ./build.sh
set -e
cd "$(dirname "$0")"
# 工具链路径：优先用环境变量，其次用项目上级的目录（可整包搬走）
BASE="$(cd "$(dirname "$0")/../.." && pwd)"
SDK="${ANDROID_SDK:-$BASE/../android_sdk}"
export PATH="${JAVA_HOME:+$JAVA_HOME/bin:}$BASE/../tools/jre/bin:$PATH"
BT="$SDK/android-14"
PLATFORM="$SDK/android-6.0/android.jar"
JAVAC="${JAVA_HOME:+$JAVA_HOME/bin/}javac"
[ -x "$JAVAC" ] || JAVAC="$BASE/../tools/jdk/bin/javac"

rm -rf gen classes dexout res.zip reminder-unsigned.apk reminder-withdex.apk reminder-aligned.apk reminder.apk
mkdir -p classes dexout

echo "== aapt2 compile =="
$BT/aapt2 compile --dir res -o res.zip
echo "== aapt2 link =="
$BT/aapt2 link -o reminder-unsigned.apk -I "$PLATFORM" --manifest AndroidManifest.xml --java gen res.zip
echo "== javac =="
$JAVAC -source 1.8 -target 1.8 -bootclasspath "$PLATFORM" -d classes gen/com/example/reminder/R.java src/com/example/reminder/*.java
echo "== d8 =="
$BT/d8 --release --lib "$PLATFORM" --output dexout classes/com/example/reminder/*.class

python3 - <<'PY'
import zipfile, shutil
shutil.copy('reminder-unsigned.apk', 'reminder-withdex.apk')
z = zipfile.ZipFile('reminder-withdex.apk', 'a')
z.write('dexout/classes.dex', 'classes.dex')
z.close()
PY

echo "== zipalign =="
$BT/zipalign -f 4 reminder-withdex.apk reminder-aligned.apk

KS=reminder.keystore
if [ ! -f "$KS" ]; then
  echo "== 生成签名 =="
  keytool -genkeypair -keystore "$KS" -alias reminder -keyalg RSA -keysize 2048 -validity 10000 \
    -storepass reminder123 -keypass reminder123 -dname "CN=Reminder, OU=TV, O=Home, L=City, ST=State, C=CN"
fi
echo "== 签名 =="
$BT/apksigner sign --ks "$KS" --ks-key-alias reminder --ks-pass pass:reminder123 --key-pass pass:reminder123 --out reminder.apk reminder-aligned.apk
echo "✅ 构建完成: reminder.apk"
