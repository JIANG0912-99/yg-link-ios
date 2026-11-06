#!/usr/bin/env python3
"""
FilePath 补丁：App Group 容器拿不到时退回 App 自己的目录。

背景：
  FilePath.sharedDirectory = defaultSharedDirectory!    // 强制解包
  当签名商的描述文件里没有 group.com.yglink.app 时，
  containerURL(forSecurityApplicationGroupIdentifier:) 返回 nil，
  这行直接触发 fatalError（EXC_BREAKPOINT / SIGTRAP），App 启动即崩。

  扩展实际是通过 providerConfiguration 的 configContent 拿配置的，
  不依赖共享目录，所以退回本地目录不影响连接。
"""
import os
import sys

P = "sing-box-for-apple/Library/Shared/FilePath.swift"

OLD_DECL = "    private static let defaultSharedDirectory: URL! = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupName)"
NEW_DECL = """    private static let defaultSharedDirectory: URL? = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupName)

    /// App Group 不可用时的兜底目录。
    /// 要求：① 一定可写  ② 路径足够短（unix socket 的 sun_path 上限 104 字节）
    /// 做法：从 Documents 反推容器根目录 —— Documents 由系统保证存在且可写，
    ///       比 NSHomeDirectory() 可靠（后者在重签 App 里可能返回只读的包目录）。
    private static let fallbackDirectory: URL = {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let container = docs.deletingLastPathComponent()
        let dir = container.appendingPathComponent("y", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            NSLog("YGLink FilePath: create fallback dir failed: %@", error.localizedDescription)
        }
        return dir
    }()"""

PAIRS = [
    (OLD_DECL, NEW_DECL),
    ("        public static let sharedDirectory = defaultSharedDirectory!",
     "        public static let sharedDirectory = defaultSharedDirectory ?? fallbackDirectory"),
    ("        public static var sharedDirectory: URL! = defaultSharedDirectory",
     "        public static var sharedDirectory: URL! = defaultSharedDirectory ?? fallbackDirectory"),
]

if not os.path.exists(P):
    print("WARN: 找不到 " + P)
    sys.exit(0)

src = open(P, "r", encoding="utf-8").read()

if "fallbackDirectory" in src:
    print("已经打过补丁，跳过")
    sys.exit(0)

ok = 0
for old, new in PAIRS:
    if old in src:
        src = src.replace(old, new, 1)
        ok += 1
        print("  ✓ 替换成功: " + old.strip()[:70])
    else:
        print("  ✗ 未匹配: " + old.strip()[:70])

if ok == 0:
    print("ERROR: 一处都没匹配上，FilePath.swift 可能改版了，终止以免打包出崩溃包")
    sys.exit(1)

open(P, "w", encoding="utf-8").write(src)
print(f"FilePath 补丁完成，共 {ok} 处")
