import Foundation
import CryptoKit
import GRDB
@preconcurrency import KeychainAccess

public protocol CredentialKeyStore {
    func loadKey() throws -> SymmetricKey?
    func saveKey(_ key: SymmetricKey) throws
}

public struct KeychainCredentialKeyStore: CredentialKeyStore {
    private let keychain: Keychain
    private let keyName: String

    public init(service: String = "com.omnia.player", keyName: String = "credential-aes-gcm-key") {
        self.keychain = Keychain(service: service)
        self.keyName = keyName
    }

    public func loadKey() throws -> SymmetricKey? {
        guard let data = try keychain.getData(keyName) else {
            return nil
        }
        return SymmetricKey(data: data)
    }

    public func saveKey(_ key: SymmetricKey) throws {
        try keychain.set(key.dataRepresentation, key: keyName)
    }
}

public actor AppRepository {
    private let database: AppDatabase
    private let keyStore: CredentialKeyStore

    public init(
        database: AppDatabase = .shared,
        keyStore: CredentialKeyStore = KeychainCredentialKeyStore()
    ) {
        self.database = database
        self.keyStore = keyStore
    }

    public func saveCredential(_ platform: String, data: [String: String]) async throws {
        let plaintext = try JSONEncoder().encode(data)
        let encrypted = try AES.GCM.seal(plaintext, using: credentialKey())

        guard let blob = encrypted.combined else {
            throw AppRepositoryError.encryptionFailed
        }

        try await database.queue.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO credentials (platform, data, updated_at)
                    VALUES (?, ?, ?)
                    """,
                arguments: [platform, blob, Self.unixTimestamp()]
            )
        }
    }

    public func loadCredential(_ platform: String) async throws -> [String: String]? {
        let blob: Data? = try await database.queue.read { db in
            try Data.fetchOne(
                db,
                sql: "SELECT data FROM credentials WHERE platform = ?",
                arguments: [platform]
            )
        }

        guard let blob else {
            return nil
        }

        let sealedBox = try AES.GCM.SealedBox(combined: blob)
        let plaintext = try AES.GCM.open(sealedBox, using: credentialKey())
        return try JSONDecoder().decode([String: String].self, from: plaintext)
    }

    public func deleteCredential(_ platform: String) async throws {
        try await database.queue.write { db in
            try db.execute(
                sql: "DELETE FROM credentials WHERE platform = ?",
                arguments: [platform]
            )
        }
    }

    public func getSetting(_ key: String) async throws -> String? {
        try await database.queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM settings WHERE key = ?",
                arguments: [key]
            )
        }
    }

    public func setSetting(_ key: String, value: String) async throws {
        try await database.queue.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
                arguments: [key, value]
            )
        }
    }

    public func addPlayHistory(track: Track) async throws {
        try await database.queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO play_history (platform, track_id, title, artist, cover_url, played_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    track.platform,
                    track.id,
                    track.title,
                    track.artist,
                    track.albumCoverURL,
                    Self.unixTimestamp()
                ]
            )
        }
    }

    public func getPlayHistory(limit: Int) async throws -> [Track] {
        let rows = try await database.queue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT platform, track_id, title, artist, cover_url
                    FROM play_history
                    ORDER BY played_at DESC, id DESC
                    LIMIT ?
                    """,
                arguments: [limit]
            )
        }

        return rows.map { row in
            let artist: String = row["artist"]
            let coverURL: String? = row["cover_url"]
            return Track(
                id: row["track_id"],
                platform: row["platform"],
                title: row["title"],
                artist: artist,
                artists: artist.isEmpty ? [] : [artist],
                album: "",
                albumCoverURL: coverURL ?? "",
                durationMs: 0
            )
        }
    }

    public func keychain(service: String = "com.omnia.player") -> Keychain {
        Keychain(service: service)
    }

    private func credentialKey() throws -> SymmetricKey {
        if let key = try keyStore.loadKey() {
            return key
        }

        let key = SymmetricKey(size: .bits256)
        try keyStore.saveKey(key)
        return key
    }

    private static func unixTimestamp() -> Int {
        Int(Date().timeIntervalSince1970)
    }
}

public enum AppRepositoryError: Error, Equatable {
    case encryptionFailed
}

private extension SymmetricKey {
    var dataRepresentation: Data {
        withUnsafeBytes { Data($0) }
    }
}
