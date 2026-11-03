#!/usr/bin/env python3
"""
把上游用到的 iOS 26 专有 API 替换成本地等价写法。
原因：GitHub 的 macos-14 runner 只有 Xcode 16（iOS 18 SDK），
      即使代码写了 if #available(iOS 26, *)，编译器也不认识那个符号。

替换规则：
  tabViewBottomAccessory { ... }            -> Group { ... }
  glassEffect(...) / .glassEffect(...)      -> background(Color.secondary.opacity(0.08))
"""
import os
import re
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "sing-box-for-apple"

def replace_call(src, name, replacement, keep_dot):
    """把 name(...) 连同括号内容整体替换，支持嵌套括号。"""
    out = []
    i = 0
    changed = 0
    n = len(src)
    while True:
        j = src.find(name + "(", i)
        if j == -1:
            out.append(src[i:])
            break
        # 前面紧邻的字符，判断是不是 .name(
        k = j - 1
        has_dot = k >= 0 and src[k] == "."
        out.append(src[i:j - 1] if (has_dot and keep_dot) else src[i:j])
        # 找配对括号
        p = j + len(name)
        depth = 0
        end = -1
        while p < n:
            c = src[p]
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    end = p
                    break
            p += 1
        if end == -1:
            out.append(src[j:])
            break
        prefix = "." if (has_dot and keep_dot) else ""
        out.append(prefix + replacement)
        changed += 1
        i = end + 1
    return "".join(out), changed

def process(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        src = f.read()
    orig = src

    src, n1 = replace_call(src, "glassEffect", "background(Color.secondary.opacity(0.08))", True)
    src = src.replace("tabViewBottomAccessory {", "Group {")
    n2 = orig.count("tabViewBottomAccessory {")

    if src != orig:
        with open(path, "w", encoding="utf-8") as f:
            f.write(src)
        return n1, n2
    return 0, 0

total_glass = total_tab = touched = 0
for dirpath, _, files in os.walk(ROOT):
    for fn in files:
        if not fn.endswith(".swift"):
            continue
        p = os.path.join(dirpath, fn)
        a, b = process(p)
        if a or b:
            touched += 1
            total_glass += a
            total_tab += b
            print(f"  patched {p}  glassEffect={a} tabViewBottomAccessory={b}")

print(f"补丁完成：文件 {touched} 个，glassEffect {total_glass} 处，tabViewBottomAccessory {total_tab} 处")
