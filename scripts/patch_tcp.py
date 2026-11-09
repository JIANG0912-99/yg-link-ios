#!/usr/bin/env python3
"""
TCP 命令服务器补丁：
iOS 的容器根目录只读 + 容器路径太长（unix socket 上限 104 字节），
unix socket 方案在重签 App 上必然失败。改用 libbox 内置的 TCP 命令服务器
（原本给 tvOS 用），监听 127.0.0.1:12888 —— 与文件系统路径无关，彻底绕开。

需同时改两处（App 与扩展各自调用一次 LibboxSetup）：
  1) Library/Network/ExtensionProvider.swift —— 服务端监听
  2) SFI/ApplicationDelegate.swift           —— 客户端连接
"""
import os
import sys

PORT = 12888

def patch(path, anchors, label):
    if not os.path.exists(path):
        print(f"  WARN: 找不到 {path}")
        return False
    src = open(path, "r", encoding="utf-8").read()
    if "commandServerListenPort = %d" % PORT in src:
        print(f"  {label}: 已打过补丁，跳过")
        return True
    ok = 0
    for old, new in anchors:
        if old in src:
            src = src.replace(old, new, 1)
            ok += 1
    if ok == 0:
        print(f"  {label}: 未匹配到锚点！")
        return False
    open(path, "w", encoding="utf-8").write(src)
    print(f"  {label}: 已设置 TCP 端口 {PORT}（{ok} 处）")
    return True

# 1) 扩展侧：LibboxSetupOptions 里加监听端口
patch(
    "sing-box-for-apple/Library/Network/ExtensionProvider.swift",
    [("        options.logMaxLines = 3000\n",
      "        options.logMaxLines = 3000\n        options.commandServerListenPort = %d\n" % PORT)],
    "ExtensionProvider",
)

# 2) App 侧：LibboxSetupOptions 里加同样端口（客户端据此连 TCP）
patch(
    "sing-box-for-apple/SFI/ApplicationDelegate.swift",
    [("        options.tempPath = FilePath.cacheDirectory.relativePath\n",
      "        options.tempPath = FilePath.cacheDirectory.relativePath\n        options.commandServerListenPort = %d\n" % PORT)],
    "ApplicationDelegate",
)

print("TCP 命令服务器补丁完成")
