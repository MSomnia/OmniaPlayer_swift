import Foundation
import GRDB

public final class AppDatabase {
    public static let shared = AppDatabase()

    public let databaseURL: URL
    private var dbQueue: DatabaseQueue?

    public init(databaseURL: URL? = nil) {
        self.databaseURL = databaseURL ?? Self.defaultDatabaseURL()
    }

    public func setupSync() throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let queue = try DatabaseQueue(path: databaseURL.path)
        try migrate(queue)
        try seedDefaults(queue)
        dbQueue = queue
    }

    public func setup() async throws {
        try setupSync()
    }

    public var queue: DatabaseQueue {
        get throws {
            guard let dbQueue else {
                throw AppDatabaseError.notSetup
            }
            return dbQueue
        }
    }

    private static func defaultDatabaseURL() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Omnia", isDirectory: true)
            .appendingPathComponent("omnia.db")
    }

    private func migrate(_ dbQueue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS credentials (
                    platform    TEXT PRIMARY KEY,
                    data        BLOB NOT NULL,
                    updated_at  INTEGER NOT NULL
                );

                CREATE TABLE IF NOT EXISTS play_history (
                    id          INTEGER PRIMARY KEY AUTOINCREMENT,
                    platform    TEXT NOT NULL,
                    track_id    TEXT NOT NULL,
                    title       TEXT NOT NULL,
                    artist      TEXT NOT NULL,
                    cover_url   TEXT,
                    played_at   INTEGER NOT NULL
                );

                CREATE TABLE IF NOT EXISTS settings (
                    key         TEXT PRIMARY KEY,
                    value       TEXT NOT NULL
                );
                """)
        }

        try migrator.migrate(dbQueue)
    }

    private func seedDefaults(_ dbQueue: DatabaseQueue) throws {
        let defaults = [
            "volume": "70",
            "repeat_mode": "none",
            "shuffle": "false",
            "display_name": "Omnia",
            "background_image_path": "",
            "background_pure_black": "false"
        ]

        try dbQueue.write { db in
            for (key, value) in defaults {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO settings (key, value) VALUES (?, ?)",
                    arguments: [key, value]
                )
            }
        }
    }
}

public enum AppDatabaseError: Error, Equatable {
    case notSetup
}
