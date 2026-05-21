import CryptoKit
import Foundation
import GRDB
import XCTest
@testable import Omnia

final class AppRepositoryTests: XCTestCase {
    func testSetupCreatesDatabaseAndSchema() throws {
        let database = AppDatabase(databaseURL: makeDatabaseURL())

        try database.setupSync()

        XCTAssertTrue(FileManager.default.fileExists(atPath: database.databaseURL.path))

        let tables = try database.queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table'"
            )
        }

        XCTAssertTrue(tables.contains("credentials"))
        XCTAssertTrue(tables.contains("play_history"))
        XCTAssertTrue(tables.contains("settings"))
    }

    func testSettingsReadAndWrite() async throws {
        let repository = try makeRepository()

        let initialVolume = try await repository.getSetting("volume")
        XCTAssertEqual(initialVolume, "70")

        try await repository.setSetting("volume", value: "35")
        try await repository.setSetting("theme", value: "dark")

        let volume = try await repository.getSetting("volume")
        let theme = try await repository.getSetting("theme")
        let missing = try await repository.getSetting("missing")

        XCTAssertEqual(volume, "35")
        XCTAssertEqual(theme, "dark")
        XCTAssertNil(missing)
    }

    func testCredentialRoundTripAndDelete() async throws {
        let repository = try makeRepository()
        let credential = [
            "cookie": "abc123",
            "token": "secret"
        ]

        try await repository.saveCredential("spotify", data: credential)

        let loaded = try await repository.loadCredential("spotify")
        XCTAssertEqual(loaded, credential)

        try await repository.deleteCredential("spotify")

        let deleted = try await repository.loadCredential("spotify")
        XCTAssertNil(deleted)
    }

    func testPlayHistoryReturnsNewestTracksFirst() async throws {
        let repository = try makeRepository()
        let first = Track(
            id: "1",
            platform: "netease",
            title: "First",
            artist: "Artist A",
            artists: ["Artist A"],
            album: "Album A",
            albumCoverURL: "https://example.com/a.jpg",
            durationMs: 180_000
        )
        let second = Track(
            id: "2",
            platform: "spotify",
            title: "Second",
            artist: "Artist B",
            artists: ["Artist B"],
            album: "Album B",
            albumCoverURL: "https://example.com/b.jpg",
            durationMs: 220_000
        )

        try await repository.addPlayHistory(track: first)
        try await repository.addPlayHistory(track: second)

        let history = try await repository.getPlayHistory(limit: 1)

        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].id, "2")
        XCTAssertEqual(history[0].platform, "spotify")
        XCTAssertEqual(history[0].title, "Second")
        XCTAssertEqual(history[0].artist, "Artist B")
        XCTAssertEqual(history[0].artists, ["Artist B"])
        XCTAssertEqual(history[0].albumCoverURL, "https://example.com/b.jpg")
        XCTAssertEqual(history[0].durationMs, 0)
    }

    private func makeRepository() throws -> AppRepository {
        let database = AppDatabase(databaseURL: makeDatabaseURL())
        try database.setupSync()
        return AppRepository(database: database, keyStore: InMemoryCredentialKeyStore())
    }

    private func makeDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("omnia.db")
    }
}

private final class InMemoryCredentialKeyStore: CredentialKeyStore {
    private var key: SymmetricKey?

    func loadKey() throws -> SymmetricKey? {
        key
    }

    func saveKey(_ key: SymmetricKey) throws {
        self.key = key
    }
}
