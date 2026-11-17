#!/usr/bin/env bash
# 把技能打包成 RikkaHub / opencode 可导入的 zip
# 用法: bash build_zip.sh [输出路径]
set -e
BASE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$BASE/../../tv-control-rikkahub.zip}"
FILES=(
  "SKILL.md"
  "scripts/appctl.py"
  "scripts/tvctl.py"
  "scripts/keeper_watchdog.sh"
  "adbkeeper/app/AndroidManifest.xml"
  "adbkeeper/app/res/values/strings.xml"
  "adbkeeper/scripts/build.sh"
  "adbkeeper/dist/adbkeeper.apk"
  "adbkeeper/dist/adbkeeper.keystore"
)
cd "$BASE"
python3 - "$OUT" "${FILES[@]}" <<'PY'
import os, sys, zipfile
out = sys.argv[1]; files = sys.argv[2:]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for f in files:
        z.write(f, f)
    for root, dirs, fs in os.walk("adbkeeper/app/src"):
        for f in fs:
            p = os.path.join(root, f)
            z.write(p, os.path.relpath(p, "."))
print("✅ 已生成: %s (%d 字节)" % (out, os.path.getsize(out)))
PY
echo "   导入方式: RikkaHub → 设置 → 扩展管理 → 技能 → + → 从文件导入"
