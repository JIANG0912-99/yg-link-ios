#!/usr/bin/env python3
"""
品牌补丁：把 stable 分支里写死的 io.nekohasekai.sfavt 换成我们的 bundle id。
stable 分支不用 BASE_PACKAGE_IDENTIFIER 变量，所以命令行覆盖无效，只能改工程文件。
"""
import sys

APP_ID = sys.argv[1] if len(sys.argv) > 1 else "com.yglink.app"
PBX = "sing-box-for-apple/sing-box.xcodeproj/project.pbxproj"
OLD = "io.nekohasekai.sfavt"

try:
    src = open(PBX, "r", encoding="utf-8").read()
except FileNotFoundError:
    print("WARN: 找不到 " + PBX)
    sys.exit(0)

n = src.count(OLD)
if n == 0:
    print("提示: 未发现 " + OLD + "（可能已改过，或分支使用变量）")
else:
    src = src.replace(OLD, APP_ID)
    open(PBX, "w", encoding="utf-8").write(src)
    print(f"OK: 已把 {n} 处 {OLD} 替换为 {APP_ID}")

# 打印最终的 bundle id 设置，便于在 CI 日志核对
for line in src.splitlines():
    if "PRODUCT_BUNDLE_IDENTIFIER" in line:
        print("  " + line.strip())
