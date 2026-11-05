import os
import sys

P = "sing-box-for-apple/Library/Database/Database.swift"
if not os.path.exists(P):
    print("WARN: 找不到 " + P)
    sys.exit(0)

src = open(P, "r", encoding="utf-8").read()
if "YG_FALLBACK_DOCS" in src:
    print("已经打过补丁，跳过")
    sys.exit(0)

start = src.index("private static func makeShared() -> any DatabaseWriter {")
body_start = src.index("{", start) + 1
depth = 1
i = body_start
while depth > 0 and i < len(src):
    if src[i] == "{":
        depth += 1
    elif src[i] == "}":
        depth -= 1
    i += 1
end = i

NEW = '''private static func makeShared() -> any DatabaseWriter {
        let dbURL = FilePath.sharedDirectory.appendingPathComponent("settings.db")
        do {
            return try openDatabase(at: dbURL)
        } catch {
            NSLog("YGLink DB: first open failed: %@", error.localizedDescription)
            // 旧库损坏：删除重试
            try? FileManager.default.removeItem(at: dbURL)
            do {
                return try openDatabase(at: dbURL)
            } catch {
                NSLog("YGLink DB: retry failed: %@", error.localizedDescription)
                // 换 Documents 目录再试（更可写，且能持久化）
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                let alt = docs.appendingPathComponent("settings.db")
                do {
                    return try openDatabase(at: alt)
                } catch {
                    // 最后兜底：内存库，保证 App 不闪退（配置当次会话有效）
                    NSLog("YGLink DB: using in-memory after all failed: %@", error.localizedDescription)
                    do {
                        let db = try DatabaseQueue()
                        try migrate(db)
                        return db
                    } catch {
                        fatalError(error.localizedDescription)
                    }
                }
            }
        }
    }

    private static func openDatabase(at url: URL) throws -> any DatabaseWriter {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let database = try DatabasePool(path: url.relativePath)
        try migrate(database)
        return database
    }

    private static func migrate(_ database: any DatabaseWriter) throws {
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
    }'''

src = src[:start] + NEW + src[end:]
open(P, "w", encoding="utf-8").write(src)
print("Database 补丁完成：四级兜底（正常/删库/Documents/内存）")
print("花括号:", src.count("{"), src.count("}"))
