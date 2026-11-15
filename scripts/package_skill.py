#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 tv-app-manager 技能打包成 RikkaHub / opencode 可导入的 zip。

用法:
    python3 scripts/package_skill.py            # 生成 skills/tv-app-manager-rikkahub.zip
"""
import os
import zipfile

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKILL_DIR = os.path.join(BASE, "skills", "tv-app-manager")
OUT = os.path.join(BASE, "skills", "tv-app-manager-rikkahub.zip")

FILES = ["SKILL.md", "scripts/appctl.py"]

if __name__ == "__main__":
    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
        for rel in FILES:
            src = os.path.join(SKILL_DIR, rel)
            if not os.path.isfile(src):
                raise SystemExit("缺少文件: " + src)
            z.write(src, rel)
    print("✅ 已生成: %s (%d 字节)" % (OUT, os.path.getsize(OUT)))
    print("   导入方式: RikkaHub → 设置 → 扩展管理 → 技能 → + → 从文件导入")
