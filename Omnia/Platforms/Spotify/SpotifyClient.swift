import Foundation

// MARK: - Constants

private let partnerURL      = "https://api-partner.spotify.com/pathfinder/v2/query"
private let clientTokenURL  = "https://clienttoken.spotify.com/v1/clienttoken"
private let webAPIURL       = "https://api.spotify.com/v1"
private let webClientID     = "d8a5ed958d274c2e8ee717e6a4b0971d"
private let searchHash      = "556f5a15b2fdd3a7113ffd377ad9805e38a3a27b8bb1ca7d6d76bad54aa8ee12"
private let addToPlaylistFallbackHash = "47b2a1234b17748d332dd0431534f22450e9ecbb3d5ddcdacbd83368636a0990"

// Global operation hash cache — shared across all SpotifyClient instances.
nonisolated(unsafe) private var opHashCache: [String: String] = [:]

// MARK: - SpotifyClient

public actor SpotifyClient: PlatformProtocol {
    public let id          = "spotify"
    public let displayName = "Spotify"

    private let auth: SpotifyAuth
    private var cachedClientToken: String?
    private var cachedClientVersion: String?
    private var deviceId: String = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private var rateLimitedUntil: Date = .distantPast
    private var playlistRateLimitedUntil: Date = .distantPast

    public init(auth: SpotifyAuth) {
        self.auth = auth
    }

    // MARK: - Search

    public func search(query: String, limit: Int = 30) async throws -> [Track] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        guard Date() >= rateLimitedUntil else { return [] }

        let token = try await auth.getAccessToken()
        let clientToken = await getClientToken()
        let resp = try await partnerPost(
            token: token,
            clientToken: clientToken,
            operation: "searchSuggestions",
            hash: searchHash,
            variables: [
                "query": query,
                "limit": min(limit, 30),
                "numberOfTopResults": min(limit, 30),
                "offset": 0,
                "includeAuthors": false,
                "includeAlbumPreReleases": false,
                "includeEpisodeContentRatingsV2": false,
            ]
        )
        return parseSearchSuggestions(resp)
    }

    public func searchAlbums(query: String, limit: Int = 10) async throws -> [Album] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        guard Date() >= rateLimitedUntil else { return [] }

        let token = try await auth.getAccessToken()
        let clientToken = await getClientToken()
        let resp = try await partnerPost(
            token: token,
            clientToken: clientToken,
            operation: "searchSuggestions",
            hash: searchHash,
            variables: [
                "query": query,
                "limit": min(limit * 4, 30),
                "numberOfTopResults": min(limit * 4, 30),
                "offset": 0,
                "includeAuthors": false,
                "includeAlbumPreReleases": false,
                "includeEpisodeContentRatingsV2": false,
            ]
        )
        return Array(parseAlbumsFromSuggestions(resp).prefix(limit))
    }

    // MARK: - Album tracks

    public func getAlbumTracks(albumId: String) async throws -> [Track] {
        let token = try await auth.getAccessToken()
        let clientToken = await getClientToken()
        let albumURI = "spotify:album:\(albumId)"

        // Try album-specific partner operations
        for opName in ["getAlbum", "queryAlbumTracks", "queryAlbum"] {
            if let hash = await getOpHash(opName),
               let result = try? await partnerPost(
                token: token, clientToken: clientToken,
                operation: opName, hash: hash,
                variables: ["uri": albumURI, "locale": "", "offset": 0, "limit": 50]
               ) {
                let tracks = parseAlbumTracksPartner(result)
                if !tracks.isEmpty { return tracks }
            }
        }

        // fetchPlaylist fallback with album URI
        if let hash = await getOpHash("fetchPlaylist"),
           let result = try? await partnerPost(
            token: token, clientToken: clientToken,
            operation: "fetchPlaylist", hash: hash,
            variables: ["uri": albumURI, "offset": 0, "limit": 50, "enableWatchFeedEntrypoint": false]
           ) {
            let tracks = parseFetchPlaylist(result)
            if !tracks.isEmpty { return tracks }
        }

        // Web API fallback
        guard Date() >= rateLimitedUntil else { return [] }
        let data = try await webAPIGet(path: "/albums/\(albumId)", token: token)
        return parseWebAPIAlbum(data)
    }

    // MARK: - Stream URL

    public func getStreamURL(track: Track) async throws -> String {
        return "spotify:track:\(track.id)"
    }

    // MARK: - Lyrics

    public func getLyrics(track: Track) async throws -> [LyricLine] {
        let token = try await auth.getAccessToken()
        return try await SpotifyLyrics.fetch(trackId: track.id, token: token)
    }

    // MARK: - Home

    public func getHome() async throws -> [(String, [Track])] {
        let token = try await auth.getAccessToken()
        let clientToken = await getClientToken()

        guard let homeHash = await getOpHash("home") else { return [] }
        guard let plHash = await getOpHash("fetchPlaylist") else { return [] }

        let homeResp = try await partnerPost(
            token: token, clientToken: clientToken,
            operation: "home", hash: homeHash,
            variables: [
                "timeZone": "UTC",
                "sp_t": "",
                "facet": "",
                "sectionItemsLimit": 8,
                "includeEpisodeContentRatingsV2": false,
                "homeEndUserIntegration": "INTEGRATION_WEB_PLAYER",
            ]
        )

        let sectionPlaylists = extractHomePlaylists(homeResp)
        var result: [(String, [Track])] = []
        for (title, plURI) in sectionPlaylists.prefix(3) {
            if let plResp = try? await partnerPost(
                token: token, clientToken: clientToken,
                operation: "fetchPlaylist", hash: plHash,
                variables: ["uri": plURI, "offset": 0, "limit": 20, "enableWatchFeedEntrypoint": false]
            ) {
                let tracks = parseFetchPlaylist(plResp)
                if !tracks.isEmpty { result.append((title, tracks)) }
            }
        }
        return result
    }

    // MARK: - Library

    public func getLibraryPlaylists() async throws -> [Playlist] {
        let token = try await auth.getAccessToken()
        let clientToken = await getClientToken()
        guard let hash = await getOpHash("libraryV3") else { return [] }
        let resp = try await partnerPost(
            token: token, clientToken: clientToken,
            operation: "libraryV3", hash: hash,
            variables: [
                "filters": ["Playlists"],
                "order": NSNull(),
                "textFilter": "",
                "features": ["LIKED_SONGS", "YOUR_EPISODES"],
                "limit": 50,
                "offset": 0,
                "flatten": false,
                "expandedFolders": [] as [String],
                "folderUri": NSNull(),
                "includeFoldersWhenFlattening": true,
                "withCuration": false,
            ]
        )
        return await playlistsWithWebAPICountsIfNeeded(parseLibraryV3(resp), token: token)
    }

    public func getPlaylistTracks(playlistId: String) async throws -> [Track] {
        let token = try await auth.getAccessToken()
        let clientToken = await getClientToken()
        guard let hash = await getOpHash("fetchPlaylist") else { return [] }
        let plURI = playlistId.hasPrefix("spotify:") ? playlistId : "spotify:playlist:\(playlistId)"
        let resp = try await partnerPost(
            token: token, clientToken: clientToken,
            operation: "fetchPlaylist", hash: hash,
            variables: ["uri": plURI, "offset": 0, "limit": 100, "enableWatchFeedEntrypoint": false]
        )
        return parseFetchPlaylist(resp)
    }

    public func getAddablePlaylists() async throws -> [Playlist] {
        let all = try await getLibraryPlaylists()
        return all.filter { !$0.id.hasPrefix("spotify:") }
    }

    // MARK: - Playlist management

    public func addTrackToPlaylist(playlistId: String, track: Track) async throws -> Bool {
        guard !playlistId.isEmpty, !track.id.isEmpty else { return false }
        guard Date() >= playlistRateLimitedUntil else { return false }

        let token = try await auth.getAccessToken()
        let clientToken = await getClientToken()
        let hash = await getOpHash("addToPlaylist") ?? addToPlaylistFallbackHash
        let plURI = playlistId.hasPrefix("spotify:") ? playlistId : "spotify:playlist:\(playlistId)"

        do {
            let resp = try await partnerPost(
                token: token, clientToken: clientToken,
                operation: "addToPlaylist", hash: hash,
                variables: [
                    "playlistItemUris": ["spotify:track:\(track.id)"],
                    "playlistUri": plURI,
                    "newPosition": ["moveType": "BOTTOM_OF_PLAYLIST", "fromUid": ""],
                ]
            )
            return (resp["errors"] as? [[String: Any]])?.isEmpty ?? true
        } catch SpotifyClientError.rateLimit(let after) {
            playlistRateLimitedUntil = Date().addingTimeInterval(Double(after))
            return false
        }
    }

    public func removeTrackFromPlaylist(playlistId: String, track: Track) async throws -> Bool {
        guard !playlistId.isEmpty, !track.id.isEmpty else { return false }
        guard let uid = track.playlistItemId, !uid.isEmpty else { return false }

        let token = try await auth.getAccessToken()
        let clientToken = await getClientToken()
        guard let hash = await getOpHash("removeFromPlaylist") else { return false }
        let plURI = playlistId.hasPrefix("spotify:") ? playlistId : "spotify:playlist:\(playlistId)"

        let resp = try await partnerPost(
            token: token, clientToken: clientToken,
            operation: "removeFromPlaylist", hash: hash,
            variables: ["playlistUri": plURI, "uids": [uid]]
        )
        let errors = resp["errors"] as? [[String: Any]] ?? []
        return errors.isEmpty
    }

    // MARK: - Recommendations

    public func getRecommendations(track: Track) async throws -> [Track] {
        let token = try await auth.getAccessToken()
        if let data = try? await webAPIGet(
            path: "/recommendations",
            token: token,
            query: ["seed_tracks": track.id, "limit": "12"]
        ) {
            let tracks = (data["tracks"] as? [[String: Any]] ?? [])
                .compactMap { t -> Track? in guard t["id"] is String else { return nil }; return toWebAPITrack(t) }
            if !tracks.isEmpty { return tracks }
        }
        return (try? await search(query: track.artist, limit: 12)) ?? []
    }

    // MARK: - Artist

    public func searchArtist(name: String) async throws -> Artist? {
        guard Date() >= rateLimitedUntil else { return nil }
        let token = try await auth.getAccessToken()
        let clientToken = await getClientToken()
        let resp = try await partnerPost(
            token: token, clientToken: clientToken,
            operation: "searchSuggestions", hash: searchHash,
            variables: [
                "query": name, "limit": 10, "numberOfTopResults": 10,
                "offset": 0, "includeAuthors": false,
                "includeAlbumPreReleases": false, "includeEpisodeContentRatingsV2": false,
            ]
        )
        return parseArtistFromSuggestions(resp, fallbackName: name)
    }

    public func getArtistTopTracks(artistId: String, limit: Int = 30) async throws -> [Track] {
        let token = try await auth.getAccessToken()
        let clientToken = await getClientToken()
        let artistURI = "spotify:artist:\(artistId)"

        for opName in ["queryArtistOverview", "queryArtistTopTracks", "getArtist"] {
            if let hash = await getOpHash(opName),
               let resp = try? await partnerPost(
                token: token, clientToken: clientToken,
                operation: opName, hash: hash,
                variables: ["uri": artistURI, "locale": "", "includePrerelease": false]
               ) {
                let tracks = parseArtistTopTracksPartner(resp, limit: limit)
                if !tracks.isEmpty { return tracks }
            }
        }

        guard Date() >= rateLimitedUntil else { return [] }
        let data = try await webAPIGet(
            path: "/artists/\(artistId)/top-tracks",
            token: token, query: ["market": "US"]
        )
        return (data["tracks"] as? [[String: Any]] ?? []).prefix(limit).compactMap { t in
            guard t["id"] is String else { return nil }
            return toWebAPITrack(t)
        }
    }

    // MARK: - Client token

    private func getClientToken() async -> String? {
        if let token = cachedClientToken { return token }
        let version = await getClientVersion()
        guard let url = URL(string: clientTokenURL) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(spotifyWebUA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://open.spotify.com", forHTTPHeaderField: "Origin")
        request.setValue("https://open.spotify.com/", forHTTPHeaderField: "Referer")

        let payload: [String: Any] = [
            "client_data": [
                "client_version": version,
                "client_id": webClientID,
                "js_sdk_data": [
                    "device_brand": "unknown",
                    "device_model": "desktop",
                    "os": "windows",
                    "os_version": "NT 10.0",
                    "device_id": deviceId,
                    "device_type": "computer",
                ]
            ]
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        request.httpBody = body
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = (json["granted_token"] as? [String: Any])?["token"] as? String
        else { return nil }
        cachedClientToken = token
        return token
    }

    private func getClientVersion() async -> String {
        if let v = cachedClientVersion { return v }
        var request = URLRequest(url: URL(string: "https://open.spotify.com/")!, timeoutInterval: 10)
        request.setValue(spotifyWebUA, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let html = String(data: data, encoding: .utf8) else {
            cachedClientVersion = "1.2.90.356.gc7ecdb13"
            return cachedClientVersion!
        }
        // Try to extract version from appServerConfig
        if let regex = try? NSRegularExpression(pattern: #"<script id="appServerConfig" type="text/plain">([^<]+)</script>"#),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html),
           let decoded = Data(base64Encoded: String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)),
           let configJson = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any],
           let version = configJson["clientVersion"] as? String {
            cachedClientVersion = version
            return version
        }
        cachedClientVersion = "1.2.90.356.gc7ecdb13"
        return cachedClientVersion!
    }

    // MARK: - Operation hash

    private func getOpHash(_ operation: String) async -> String? {
        if let cached = opHashCache[operation] { return cached }
        await loadOpHashes()
        return opHashCache[operation]
    }

    private func loadOpHashes() async {
        guard let url = URL(string: "https://open.spotify.com/") else { return }
        var homeReq = URLRequest(url: url, timeoutInterval: 10)
        homeReq.setValue(spotifyWebUA, forHTTPHeaderField: "User-Agent")
        homeReq.setValue("text/html", forHTTPHeaderField: "Accept")
        guard let (homeData, _) = try? await URLSession.shared.data(for: homeReq),
              let html = String(data: homeData, encoding: .utf8) else { return }

        let regex = try? NSRegularExpression(pattern: #"https://[^"'<>\s]+/web-player\.[^"'<>\s]+\.js"#)
        let htmlNS = html as NSString
        let matches = regex?.matches(in: html, range: NSRange(location: 0, length: htmlNS.length)) ?? []
        var bundleURLs: [String] = []
        var seen = Set<String>()
        for m in matches {
            if let r = Range(m.range, in: html) {
                let u = String(html[r])
                if seen.insert(u).inserted { bundleURLs.append(u) }
            }
        }

        for urlStr in bundleURLs.prefix(8) {
            guard let jsURL = URL(string: urlStr) else { continue }
            var req = URLRequest(url: jsURL, timeoutInterval: 20)
            req.setValue(spotifyWebUA, forHTTPHeaderField: "User-Agent")
            guard let (jsData, _) = try? await URLSession.shared.data(for: req),
                  let js = String(data: jsData, encoding: .utf8) else { continue }
            parsePartnerHashes(js)
            if opHashCache.count > 10 { break }
        }
    }

    private func parsePartnerHashes(_ source: String) {
        guard let regex = try? NSRegularExpression(
            pattern: #"new\s+\w[\w$.]*\s*\(\s*"([^"]{2,60})"\s*,\s*"(?:query|mutation)"\s*,\s*"([0-9a-f]{64})"\s*,\s*null\s*\)"#
        ) else { return }
        let ns = source as NSString
        let range = NSRange(location: 0, length: ns.length)
        for m in regex.matches(in: source, range: range) {
            guard let nameRange = Range(m.range(at: 1), in: source),
                  let hashRange = Range(m.range(at: 2), in: source) else { continue }
            let name = String(source[nameRange])
            let hash = String(source[hashRange])
            opHashCache[name] = hash
        }
    }

    // MARK: - HTTP helpers

    private func partnerPost(
        token: String,
        clientToken: String?,
        operation: String,
        hash: String,
        variables: [String: Any]
    ) async throws -> [String: Any] {
        guard let url = URL(string: partnerURL) else {
            throw SpotifyClientError.badURL(partnerURL)
        }
        var headers: [String: String] = [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json",
            "Content-Type": "application/json;charset=UTF-8",
            "Origin": "https://open.spotify.com",
            "Referer": "https://open.spotify.com/",
            "User-Agent": spotifyWebUA,
            "App-Platform": "WebPlayer",
            "Spotify-App-Version": "1.2.50.248",
        ]
        if let ct = clientToken { headers["client-token"] = ct }

        let body: [String: Any] = [
            "variables": variables,
            "operationName": operation,
            "extensions": ["persistedQuery": ["version": 1, "sha256Hash": hash]],
        ]

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 {
                let retryAfter = Int(http.value(forHTTPHeaderField: "Retry-After") ?? "30") ?? 30
                rateLimitedUntil = Date().addingTimeInterval(Double(max(1, retryAfter)))
                throw SpotifyClientError.rateLimit(retryAfter)
            }
            guard (200..<300).contains(http.statusCode) else {
                throw SpotifyClientError.httpError(http.statusCode)
            }
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func webAPIGet(
        path: String,
        token: String,
        query: [String: String] = [:]
    ) async throws -> [String: Any] {
        var comps = URLComponents(string: webAPIURL + path)!
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { throw SpotifyClientError.badURL(path) }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(spotifyWebUA, forHTTPHeaderField: "User-Agent")
        request.setValue("WebPlayer", forHTTPHeaderField: "App-Platform")
        request.setValue("1.2.50.248", forHTTPHeaderField: "Spotify-App-Version")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 {
                let after = Int(http.value(forHTTPHeaderField: "Retry-After") ?? "30") ?? 30
                rateLimitedUntil = Date().addingTimeInterval(Double(max(1, after)))
                throw SpotifyClientError.rateLimit(after)
            }
            guard (200..<300).contains(http.statusCode) else {
                throw SpotifyClientError.httpError(http.statusCode)
            }
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: - Response parsers

    private func parseSearchSuggestions(_ data: [String: Any]) -> [Track] {
        let items = nestedArray(data, "data", "searchV2", "topResultsV2", "itemsV2")
        return items.compactMap { raw -> Track? in
            let wrapper = (raw["item"] as? [String: Any]) ?? raw
            guard wrapper["__typename"] as? String == "TrackResponseWrapper" else { return nil }
            let td = (wrapper["data"] as? [String: Any]) ?? (wrapper["track"] as? [String: Any]) ?? [:]
            return toSuggestionTrack(td)
        }
    }

    private func parseAlbumsFromSuggestions(_ data: [String: Any]) -> [Album] {
        let items = nestedArray(data, "data", "searchV2", "topResultsV2", "itemsV2")
        return items.compactMap { raw -> Album? in
            let wrapper = (raw["item"] as? [String: Any]) ?? raw
            guard wrapper["__typename"] as? String == "AlbumResponseWrapper" else { return nil }
            let d = wrapper["data"] as? [String: Any] ?? [:]
            let uri = d["uri"] as? String ?? ""
            let albumId = (d["id"] as? String) ?? (uri.components(separatedBy: ":").last ?? "")
            let name = d["name"] as? String ?? ""
            guard !albumId.isEmpty, !name.isEmpty else { return nil }
            let artistItems = (d["artists"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
            let artists = artistItems.compactMap { ($0["profile"] as? [String: Any])?["name"] as? String }
            let sources = (d["coverArt"] as? [String: Any])?["sources"] as? [[String: Any]] ?? []
            let cover = sources.first?["url"] as? String ?? ""
            let year = String(((d["date"] as? [String: Any])?["year"] as? Int) ?? 0)
            let trackCount = ((d["tracks"] as? [String: Any])?["totalCount"] as? Int) ?? 0
            return Album(id: albumId, platform: "spotify", name: name,
                         artist: artists.first ?? "", coverURL: cover,
                         trackCount: trackCount, year: year)
        }
    }

    private func parseFetchPlaylist(_ data: [String: Any]) -> [Track] {
        guard let items = nestedValue(data, "data", "playlistV2", "content", "items") as? [[String: Any]]
        else { return [] }
        return items.compactMap { item -> Track? in
            let uid = item["uid"] as? String ?? ""
            let itemData = ((item["itemV2"] as? [String: Any]) ?? item)["data"] as? [String: Any] ?? [:]
            guard itemData["__typename"] as? String == "Track" else { return nil }
            let uri = itemData["uri"] as? String ?? ""
            let trackId = (itemData["id"] as? String)
                ?? (uri.hasPrefix("spotify:track:") ? String(uri.dropFirst("spotify:track:".count)) : "")
            guard !trackId.isEmpty else { return nil }
            let artistItems = (itemData["artists"] as? [String: Any])?["items"] as? [[String: Any]]
                ?? (itemData["artists"] as? [[String: Any]])
                ?? []
            let artists = artistItems.compactMap { a -> String? in
                (a["profile"] as? [String: Any])?["name"] as? String ?? a["name"] as? String
            }
            let album = itemData["albumOfTrack"] as? [String: Any] ?? [:]
            let sources = (album["coverArt"] as? [String: Any])?["sources"] as? [[String: Any]] ?? []
            let cover = sources.first?["url"] as? String ?? ""
            let dur = (itemData["trackDuration"] as? [String: Any])
                   ?? (itemData["duration"] as? [String: Any])
                   ?? [:]
            var track = Track(
                id: trackId, platform: "spotify",
                title: itemData["name"] as? String ?? "",
                artist: artists.first ?? "",
                artists: artists,
                album: album["name"] as? String ?? "",
                albumCoverURL: cover,
                durationMs: dur["totalMilliseconds"] as? Int ?? 0
            )
            if !uid.isEmpty { track.playlistItemId = uid }
            return track
        }
    }

    private func parseLibraryV3(_ data: [String: Any]) -> [Playlist] {
        guard let items = nestedValue(data, "data", "me", "libraryV3", "items") as? [[String: Any]]
        else { return [] }
        return items.compactMap { entry -> Playlist? in
            let content = ((entry["item"] as? [String: Any]) ?? entry)["data"] as? [String: Any] ?? [:]
            let typename = content["__typename"] as? String ?? ""
            guard typename.lowercased().contains("playlist") else { return nil }
            let uri = content["uri"] as? String ?? ""
            let name = content["name"] as? String ?? ""
            guard !uri.isEmpty, !name.isEmpty else { return nil }
            let plId: String
            if uri.hasPrefix("spotify:playlist:") {
                plId = (content["id"] as? String) ?? String(uri.dropFirst("spotify:playlist:".count))
            } else {
                plId = uri
            }
            let imageItems = (content["images"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
            let sources = imageItems.first?["sources"] as? [[String: Any]] ?? []
            let cover = sources.last?["url"] as? String ?? ""
            let trackCount = spotifyPlaylistTrackCount(from: content)
            return Playlist(id: plId, platform: "spotify", name: name, coverURL: cover, trackCount: trackCount)
        }
    }

    private func spotifyPlaylistTrackCount(from content: [String: Any]) -> Int {
        let candidatePaths: [[String]] = [
            ["tracks"],
            ["tracksV2"],
            ["content", "totalCount"],
            ["content", "total"],
            ["attributes", "trackCount"],
            ["attributes", "totalCount"],
            ["formatListAttributes", "trackCount"],
            ["formatListAttributes", "totalCount"],
        ]

        for path in candidatePaths {
            let value = value(at: path, in: content)

            if let count = path.count == 1
                ? PlaylistTrackCountParser.count(fromTrackMetadata: value)
                : PlaylistTrackCountParser.count(fromTrackMetadata: ["tracks": ["count": value as Any]]) {
                return count
            }
        }

        let visibleTexts = spotifyPlaylistVisibleTexts(from: content)
        return PlaylistTrackCountParser.count(fromTexts: visibleTexts) ?? 0
    }

    private func value(at path: [String], in data: [String: Any]) -> Any? {
        var current: Any = data
        for key in path {
            guard let dict = current as? [String: Any],
                  let next = dict[key] else { return nil }
            current = next
        }
        return current
    }

    private func spotifyPlaylistVisibleTexts(from content: [String: Any]) -> [String] {
        var texts: [String] = []
        for key in ["description", "subtitle", "ownerV2", "owner", "profile"] {
            if let value = content[key] {
                texts.append(contentsOf: visibleTexts(in: value))
            }
        }
        return texts
    }

    private func visibleTexts(in value: Any) -> [String] {
        var result: [String] = []
        func walk(_ node: Any) {
            if let string = node as? String {
                result.append(string)
            } else if let dict = node as? [String: Any] {
                for key in ["text", "name", "transformedLabel"] {
                    if let text = dict[key] as? String {
                        result.append(text)
                    }
                }
                for child in dict.values {
                    walk(child)
                }
            } else if let array = node as? [Any] {
                for child in array {
                    walk(child)
                }
            }
        }
        walk(value)
        return result
    }

    private func playlistsWithWebAPICountsIfNeeded(_ playlists: [Playlist], token: String) async -> [Playlist] {
        guard playlists.contains(where: { $0.trackCount == 0 }) else { return playlists }
        var counts = (try? await webAPIPlaylistCounts(token: token)) ?? [:]
        let missing = playlists.filter { $0.trackCount == 0 && counts[$0.id] == nil }
        if !missing.isEmpty {
            let partnerCounts = await partnerPlaylistCounts(for: missing, token: token)
            counts.merge(partnerCounts) { current, _ in current }
        }
        guard !counts.isEmpty else { return playlists }

        return playlists.map { playlist in
            guard playlist.trackCount == 0 else { return playlist }
            var updated = playlist
            if let count = counts[playlist.id] {
                updated.trackCount = count
            }
            return updated
        }
    }

    private func partnerPlaylistCounts(for playlists: [Playlist], token: String) async -> [String: Int] {
        guard let hash = await getOpHash("fetchPlaylist") else { return [:] }
        let clientToken = await getClientToken()
        var counts: [String: Int] = [:]

        for playlist in playlists.prefix(50) {
            let playlistURI = playlist.id.hasPrefix("spotify:")
                ? playlist.id
                : "spotify:playlist:\(playlist.id)"
            guard let resp = try? await partnerPost(
                token: token,
                clientToken: clientToken,
                operation: "fetchPlaylist",
                hash: hash,
                variables: [
                    "uri": playlistURI,
                    "offset": 0,
                    "limit": 1,
                    "enableWatchFeedEntrypoint": false,
                ]
            ), let count = spotifyFetchPlaylistTrackCount(from: resp)
            else { continue }

            counts[playlist.id] = count
        }

        return counts
    }

    private func spotifyFetchPlaylistTrackCount(from data: [String: Any]) -> Int? {
        let candidates: [Any?] = [
            nestedValue(data, "data", "playlistV2", "content"),
            nestedValue(data, "data", "playlistV2", "content", "pagingInfo"),
            nestedValue(data, "data", "playlistV2", "tracks"),
            nestedValue(data, "data", "playlistV2"),
        ]

        for candidate in candidates {
            if let count = PlaylistTrackCountParser.count(fromTrackMetadata: candidate) {
                return count
            }
        }

        return nil
    }

    private func webAPIPlaylistCounts(token: String) async throws -> [String: Int] {
        var counts: [String: Int] = [:]
        var offset = 0
        let limit = 50

        while true {
            let data = try await webAPIGet(
                path: "/me/playlists",
                token: token,
                query: ["limit": "\(limit)", "offset": "\(offset)"]
            )
            let items = data["items"] as? [[String: Any]] ?? []
            for item in items {
                guard let id = item["id"] as? String else { continue }
                if let total = (item["tracks"] as? [String: Any])?["total"] as? Int {
                    counts[id] = total
                }
            }

            let total = data["total"] as? Int ?? items.count
            offset += items.count
            if items.isEmpty || offset >= total || offset >= 500 {
                break
            }
        }

        if let liked = try? await webAPIGet(
            path: "/me/tracks",
            token: token,
            query: ["limit": "1", "offset": "0"]
        ), let total = liked["total"] as? Int {
            counts["spotify:collection:tracks"] = total
        }

        return counts
    }

    private func parseAlbumTracksPartner(_ data: [String: Any]) -> [Track] {
        let albumNode = (data["data"] as? [String: Any])?["albumUnion"] as? [String: Any]
            ?? (data["data"] as? [String: Any])?["album"] as? [String: Any]
            ?? [:]
        let sources = (albumNode["coverArt"] as? [String: Any])?["sources"] as? [[String: Any]] ?? []
        let cover = sources.first?["url"] as? String ?? ""
        let albumName = albumNode["name"] as? String ?? ""
        let tracksObj = (albumNode["tracks"] as? [String: Any])
            ?? (albumNode["tracksV2"] as? [String: Any])
            ?? [:]
        let items = tracksObj["items"] as? [[String: Any]] ?? []
        return items.compactMap { item -> Track? in
            let td = (item["track"] as? [String: Any]) ?? item
            let uri = td["uri"] as? String ?? ""
            let uid = (td["id"] as? String)
                ?? (uri.hasPrefix("spotify:track:") ? String(uri.dropFirst("spotify:track:".count)) : "")
            guard !uid.isEmpty else { return nil }
            let artistItems = (td["artists"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
            let artists = artistItems.compactMap { ($0["profile"] as? [String: Any])?["name"] as? String }
            let dur = (td["duration"] as? [String: Any]) ?? (td["trackDuration"] as? [String: Any]) ?? [:]
            return Track(
                id: uid, platform: "spotify",
                title: td["name"] as? String ?? "",
                artist: artists.first ?? "", artists: artists,
                album: albumName, albumCoverURL: cover,
                durationMs: dur["totalMilliseconds"] as? Int ?? 0
            )
        }
    }

    private func parseWebAPIAlbum(_ data: [String: Any]) -> [Track] {
        let images = data["images"] as? [[String: Any]] ?? []
        let cover = images.first?["url"] as? String ?? ""
        let albumName = data["name"] as? String ?? ""
        return ((data["tracks"] as? [String: Any])?["items"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let artists = (item["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            return Track(
                id: id, platform: "spotify",
                title: item["name"] as? String ?? "",
                artist: artists.first ?? "", artists: artists,
                album: albumName, albumCoverURL: cover,
                durationMs: item["duration_ms"] as? Int ?? 0,
                isExplicit: item["explicit"] as? Bool ?? false
            )
        }
    }

    private func extractHomePlaylists(_ data: [String: Any]) -> [(String, String)] {
        guard let sections = nestedValue(data, "data", "home", "sectionContainer", "sections", "items") as? [[String: Any]]
        else { return [] }
        var result: [(String, String)] = []
        for sec in sections {
            let secData = sec["data"] as? [String: Any] ?? [:]
            let titleRaw = secData["title"] as? [String: Any] ?? [:]
            let title = (titleRaw["transformedLabel"] as? String)
                ?? (titleRaw["text"] as? String)
                ?? (secData["name"] as? String)
                ?? "推荐"
            let items = (sec["sectionItems"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
            for item in items {
                let content = (item["content"] as? [String: Any])?["data"] as? [String: Any] ?? [:]
                if content["__typename"] as? String == "Playlist",
                   let uri = content["uri"] as? String, !uri.isEmpty {
                    result.append((title, uri))
                    break
                }
            }
        }
        return result
    }

    private func parseArtistFromSuggestions(_ data: [String: Any], fallbackName: String) -> Artist? {
        let items = nestedArray(data, "data", "searchV2", "topResultsV2", "itemsV2")
        for raw in items {
            let wrapper = (raw["item"] as? [String: Any]) ?? raw
            guard wrapper["__typename"] as? String == "ArtistResponseWrapper" else { continue }
            let d = wrapper["data"] as? [String: Any] ?? [:]
            let uri = d["uri"] as? String ?? ""
            let artistId = (d["id"] as? String) ?? (uri.components(separatedBy: ":").last ?? "")
            guard !artistId.isEmpty else { continue }
            let name = (d["profile"] as? [String: Any])?["name"] as? String ?? fallbackName
            let sources = ((d["visuals"] as? [String: Any])?["avatarImage"] as? [String: Any])?["sources"] as? [[String: Any]] ?? []
            let imageURL = sources.first?["url"] as? String ?? ""
            return Artist(id: artistId, platform: "spotify", name: name, imageURL: imageURL)
        }
        return nil
    }

    private func parseArtistTopTracksPartner(_ data: [String: Any], limit: Int) -> [Track] {
        let artistUnion = (data["data"] as? [String: Any])?["artistUnion"] as? [String: Any]
            ?? (data["data"] as? [String: Any])?["artist"] as? [String: Any]
            ?? [:]
        let items = ((artistUnion["discography"] as? [String: Any])?["topTracks"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
        return items.prefix(limit).compactMap { item -> Track? in
            let td = (item["track"] as? [String: Any]) ?? item
            guard td["id"] is String else { return nil }
            return toTrack(td)
        }
    }

    // MARK: - Track conversion

    private func toTrack(_ data: [String: Any]) -> Track {
        let artists = ((data["artists"] as? [String: Any])?["items"] as? [[String: Any]] ?? [])
            .compactMap { ($0["profile"] as? [String: Any])?["name"] as? String }
        let album = data["albumOfTrack"] as? [String: Any] ?? [:]
        let sources = (album["coverArt"] as? [String: Any])?["sources"] as? [[String: Any]] ?? []
        let cover = sources.first?["url"] as? String ?? ""
        let dur = data["duration"] as? [String: Any] ?? [:]
        return Track(
            id: data["id"] as? String ?? "",
            platform: "spotify",
            title: data["name"] as? String ?? "",
            artist: artists.first ?? "",
            artists: artists,
            album: album["name"] as? String ?? "",
            albumCoverURL: cover,
            durationMs: dur["totalMilliseconds"] as? Int ?? 0,
            isExplicit: (data["contentRating"] as? [String: Any])?["label"] as? String == "EXPLICIT"
        )
    }

    private func toWebAPITrack(_ data: [String: Any]) -> Track {
        let artists = (data["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        let album = data["album"] as? [String: Any] ?? [:]
        let images = album["images"] as? [[String: Any]] ?? []
        let cover = images.first?["url"] as? String ?? ""
        return Track(
            id: data["id"] as? String ?? "",
            platform: "spotify",
            title: data["name"] as? String ?? "",
            artist: artists.first ?? "",
            artists: artists,
            album: album["name"] as? String ?? "",
            albumCoverURL: cover,
            durationMs: data["duration_ms"] as? Int ?? 0,
            isExplicit: data["explicit"] as? Bool ?? false
        )
    }

    private func toSuggestionTrack(_ data: [String: Any]) -> Track {
        let uri = data["uri"] as? String ?? ""
        let id = (data["id"] as? String)
            ?? (uri.hasPrefix("spotify:track:") ? String(uri.dropFirst("spotify:track:".count)) : "")
        guard !id.isEmpty else { return Track(id: id, platform: "spotify", title: "", artist: "", artists: [], album: "", albumCoverURL: "", durationMs: 0) }
        let artistItems = (data["artists"] as? [String: Any])?["items"] as? [[String: Any]]
            ?? (data["artists"] as? [[String: Any]])
            ?? []
        let artists = artistItems.compactMap { a -> String? in
            (a["profile"] as? [String: Any])?["name"] as? String ?? a["name"] as? String
        }
        let album = (data["albumOfTrack"] as? [String: Any])
            ?? (data["album"] as? [String: Any])
            ?? [:]
        let sources = (album["coverArt"] as? [String: Any])?["sources"] as? [[String: Any]]
            ?? (album["images"] as? [[String: Any]])
            ?? []
        let cover = sources.first?["url"] as? String ?? ""
        let dur = data["duration"] as? [String: Any] ?? [:]
        return Track(
            id: id, platform: "spotify",
            title: data["name"] as? String ?? "",
            artist: artists.first ?? "",
            artists: artists,
            album: album["name"] as? String ?? "",
            albumCoverURL: cover,
            durationMs: dur["totalMilliseconds"] as? Int ?? data["duration_ms"] as? Int ?? 0,
            isExplicit: (data["contentRating"] as? [String: Any])?["label"] as? String == "EXPLICIT"
        )
    }
}

// MARK: - Nested JSON helpers

private func nestedValue(_ dict: [String: Any], _ keys: String...) -> Any? {
    var current: Any = dict
    for key in keys {
        guard let d = current as? [String: Any], let next = d[key] else { return nil }
        current = next
    }
    return current
}

private func nestedArray(_ dict: [String: Any], _ keys: String...) -> [[String: Any]] {
    var current: Any = dict
    for key in keys {
        guard let d = current as? [String: Any], let next = d[key] else { return [] }
        current = next
    }
    return current as? [[String: Any]] ?? []
}

// MARK: - Error

public enum SpotifyClientError: Error {
    case badURL(String)
    case httpError(Int)
    case rateLimit(Int)
}
