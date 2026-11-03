#!/usr/bin/env python3
"""把登录门注入 SFI 入口：MainView() 外面包一层 YGGate。"""
import sys

P = "sing-box-for-apple/SFI/Application.swift"
OLD = """            MainView()
                .environmentObject(environments)"""
NEW = """            YGGate {
                MainView()
            }
            .environmentObject(environments)"""

try:
    src = open(P, "r", encoding="utf-8").read()
except FileNotFoundError:
    print("WARN: 找不到 " + P)
    sys.exit(0)

if "YGGate" in src:
    print("已经注入过，跳过")
    sys.exit(0)

if OLD in src:
    src = src.replace(OLD, NEW, 1)
    open(P, "w", encoding="utf-8").write(src)
    print("OK: 已注入 YGGate -> " + P)
else:
    print("WARN: 未匹配到入口代码，Application.swift 内容如下：")
    print(src)
