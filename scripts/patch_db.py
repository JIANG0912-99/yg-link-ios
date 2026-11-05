#!/usr/bin/env python3
"""
Database 补丁：启动时 settings.db 迁移失败会导致 fatalError 闪退。
改成"迁移失败就删除旧库重来一次"，鲁棒处理损坏/不兼容的旧库。
"""
import os
import sys

P = "sing-box-for-apple/Library/Database/Database.swift"

if not os.path.exists(P):
    print("WARN: 找不到 " + P)
    sys.exit(0)

src = open(P, "r", encoding="utf-8").read()

if "openDatabase(at:" in src:
    print("已经打过补丁，跳过")
    sys.exit(0)

start = src.index("private static func makeShared() -> any DatabaseWriter {")
# 从函数体开始做花括号配平，找到该函数的结束花括号
body_start = src.index("{", start) + 1
depth = 1
i = body_start
while depth > 0 and i < len(src):
    if src[i] == "{":
        depth += 1
    elif src[i] == "}":
        depth -= 1
    i += 1
end = i  # makeShared 函数结束后的位置

NEW = '''private static func makeShared() -> any DatabaseWriter {
        let dbURL = FilePath.sharedDirectory.appendingPathComponent("settings.db")
        do {
            return try openDatabase(at: dbURL)
        } catch {
            // 旧库损坏/不兼容：删除后重来一次，避免启动闪退
            try? FileManager.default.removeItem(at: dbURL)
            do {
                return try openDatabase(at: dbURL)
            } catch {
                fatalError(error.localizedDescription)
            }
        }
    }

    private static func openDatabase(at url: URL) throws -> any DatabaseWriter {
        try FileManager.default.createDirectory(at: FilePath.sharedDirectory, withIntermediateDirectories: true)
        let database = try DatabasePool(path: url.relativePath)
        var migrator = DatabaseMigrator().disablingDeferredForeignKeyChecks()
        migrator.registerMigration("initialize") { db in
            try db.create(table: "profiles") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("order", .integer).notNull()
                t.column("type", .integer).notNull().defaults(to: ProfileType.local.rawValue)
                t.column("path", .text).notNull()
                t.column("remoteURL", .text)
                t.column("autoUpdate", .boolean).notNull().defaults(to: false)
                t.column("lastUpdated", .datetime)
            }
            try db.create(table: "preferences") { t in
                t.primaryKey("name", .text, onConflict: .replace).notNull()
                t.column("data", .blob)
            }
        }
        migrator.registerMigration("add_auto_update_interval") { db in
            try db.alter(table: "profiles") { t in
                t.add(column: "autoUpdateInterval", .integer).notNull().defaults(to: 0)
            }
        }
        migrator.registerMigration("fix_cellular_typo") { db in
            try db.execute(sql: "UPDATE preferences SET name = 'exclude_cellular_services' WHERE name = 'exclude_celluar_services'")
        }
        try migrator.migrate(database)
        return database
    }'''

src = src[:start] + NEW + src[end:]
open(P, "w", encoding="utf-8").write(src)
print("Database 补丁完成：迁移失败自动删库重试")
print("openDatabase 出现次数:", src.count("openDatabase(at:"))
print("fatalError 出现次数:", src.count("fatalError"))
