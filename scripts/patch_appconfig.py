#!/usr/bin/env python3
"""
AppConfiguration 补丁：Info.plist 里的自定义键（BasePackageIdentifier / AppGroupIdentifier）
可能被第三方重签工具剥掉，导致 fatalError 启动崩溃。
改成读不到时用默认值兜底，不再断言。
"""
import os
import sys

P = "sing-box-for-apple/Library/Shared/AppConfiguration.swift"

if not os.path.exists(P):
    print("WARN: 找不到 " + P)
    sys.exit(0)

src = open(P, "r", encoding="utf-8").read()

if "YG_DEFAULT_APPGROUP" in src:
    print("已经打过补丁，跳过")
    sys.exit(0)

pairs = [
    # packageName
    ('''public static let packageName: String = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "BasePackageIdentifier") as? String else {
            fatalError("Missing BasePackageIdentifier in Info.plist")
        }
        return value
    }()''',
     '''public static let packageName: String = {
        if let value = Bundle.main.object(forInfoDictionaryKey: "BasePackageIdentifier") as? String, !value.isEmpty {
            return value
        }
        return "com.yglink.app"
    }()'''),

    # appGroupID
    ('''public static let appGroupID: String = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String else {
            fatalError("Missing AppGroupIdentifier in Info.plist")
        }
        return value
    }()''',
     '''public static let appGroupID: String = {
        if let value = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String, !value.isEmpty {
            return value
        }
        return "group.com.yglink.app"
    }()'''),

    # teamID
    ('''public static var teamID: String {
        guard let dotIndex = appGroupID.firstIndex(of: ".") else {
            fatalError("Invalid appGroupID format: \\(appGroupID)")
        }
        return String(appGroupID[..<dotIndex])
    }''',
     '''public static var teamID: String {
        if let dotIndex = appGroupID.firstIndex(of: ".") {
            return String(appGroupID[..<dotIndex])
        }
        return ""
    }'''),
]

ok = 0
for old, new in pairs:
    if old in src:
        src = src.replace(old, new, 1)
        ok += 1
        print("  ✓ 替换成功: " + old.splitlines()[1].strip()[:60])
    else:
        print("  ✗ 未匹配（可能源码有差异）: " + old.splitlines()[0].strip()[:60])

if ok == 0:
    print("ERROR: 一处都没匹配上，AppConfiguration.swift 可能改版了")
    sys.exit(1)

open(P, "w", encoding="utf-8").write(src)
print(f"AppConfiguration 补丁完成，共 {ok} 处")
