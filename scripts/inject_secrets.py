#!/usr/bin/env python3
"""构建时把 Secrets 注入 Swift 源码（仓库里只保留占位符）。"""
import os
import sys

MAP = {
    "__YG_HOST__": os.environ.get("YG_HOST", ""),
    "__YG_USER__": os.environ.get("YG_USER", ""),
    "__YG_PASS__": os.environ.get("YG_PASS", ""),
}
missing = [k for k, v in MAP.items() if not v]
if missing:
    print("ERROR: 缺少 Secrets: " + ", ".join(missing))
    sys.exit(1)

targets = [
    "swift/YGLogin.swift",
    "config/yg-node.json",
]
for path in targets:
    if not os.path.exists(path):
        continue
    src = open(path, encoding="utf-8").read()
    n = 0
    for k, v in MAP.items():
        if k in src:
            n += src.count(k)
            src = src.replace(k, v)
    if n:
        open(path, "w", encoding="utf-8").write(src)
        print(f"  注入 {path}: {n} 处")

# 注入后不应再残留占位符
for path in targets:
    if os.path.exists(path):
        left = open(path, encoding="utf-8").read()
        for k in MAP:
            if k in left:
                print(f"ERROR: {path} 仍残留 {k}")
                sys.exit(1)
print("Secrets 注入完成")