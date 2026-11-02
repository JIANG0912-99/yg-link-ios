#!/bin/bash
# 上游 sing-box-for-apple 品牌替换（不 fork、不改上游代码，只在构建前打补丁）
# 用法: bash scripts/rebrand.sh <app源码目录> <bundleId前缀> <显示名>
set -euo pipefail

APP_DIR="${1:?缺少 app 源码目录}"
APP_ID="${2:?缺少 bundle id 前缀}"
APP_NAME="${3:?缺少显示名}"

cd "$APP_DIR"
echo "== 改品牌: $APP_ID / $APP_NAME =="

# ---------- 1. 桌面显示名 ----------
PLIST="SFI/Info.plist"
[ -f "$PLIST" ] || { echo "找不到 $PLIST"; exit 1; }
/usr/libexec/PlistBuddy -c "Delete :CFBundleDisplayName" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string \"$APP_NAME\"" "$PLIST"

# 简体中文排第一
/usr/libexec/PlistBuddy -c "Delete :CFBundleDevelopmentRegion" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleDevelopmentRegion string zh_CN" "$PLIST"

# ---------- 2. 图标 ----------
ICON_DIR="SFI/Assets.xcassets/AppIcon.appiconset"
if [ -d "$ICON_DIR" ]; then
  for f in 1024.png 1024-dark.png 1024-tinted.png; do
    SRC="${GITHUB_WORKSPACE:-$(pwd)/..}/assets/icon-1024.png"
    [ -f "$SRC" ] && cp -f "$SRC" "$ICON_DIR/$f"
  done
  echo "   图标已替换"
fi

# ---------- 3. 统计 ----------
echo "   显示名: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$PLIST")"
echo "   bundle: $APP_ID"
