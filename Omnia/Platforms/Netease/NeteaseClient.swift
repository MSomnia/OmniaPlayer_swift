import Foundation
import Network

private let baseURL = "https://music.163.com"
private let neteaseProxyBaseURL = "http://127.0.0.1:3000"

/// URLSession configured to look like a real browser to Netease's WAF.
/// - Adds browser-standard headers (Accept, Accept-Language, Connection)
///   that Python httpx sends automatically but URLSession.shared omits.
/// - Disables HTTP/2 via requestCachePolicy tweak isn't possible directly;
///   we rely on the headers to satisfy the WAF check.
// Delegate that logs protocol version, redirects, and preserves POST + Cookie headers.
private final class NeteaseSessionDelegate: NSObject, URLSessionTaskDelegate {
    static let shared = NeteaseSessionDelegate()

    // Log the actual protocol (h2 vs http/1.1) used for each transaction.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didFinishCollecting metrics: URLSessionTaskMetrics) {
        for tx in metrics.transactionMetrics {
            let proto = tx.networkProtocolName ?? "unknown"
            NSLog("[NeteaseClient] ← protocol: \(proto)  reused=\(tx.isReusedConnection)")
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        NSLog("[NeteaseClient] REDIRECT \(response.statusCode) → \(request.url?.absoluteString ?? "?")")
        var fixed = request
        fixed.httpMethod = task.originalRequest?.httpMethod ?? "POST"
        fixed.httpBody   = task.originalRequest?.httpBody
        if let cookie = task.originalRequest?.value(forHTTPHeaderField: "Cookie") {
            fixed.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        completionHandler(fixed)
    }
}

internal let neteaseSession: URLSession = {
    let config = URLSessionConfiguration.default
    config.httpAdditionalHeaders = [
        "Accept":          "*/*",
        "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
        "Connection":      "keep-alive",
    ]
    config.timeoutIntervalForRequest  = 15
    config.timeoutIntervalForResource = 30
    return URLSession(configuration: config, delegate: NeteaseSessionDelegate.shared, delegateQueue: nil)
}()

public actor NeteaseClient: PlatformProtocol {
    public let id          = "netease"
    public let displayName = "网易云音乐"

    private let cookies: [String: String]
    private let session: URLSession
    private var proxyProcess: Process?

    public init(cookies: [String: String], session: URLSession? = nil) {
        self.cookies = cookies
        self.session = session ?? neteaseSession
    }

    // MARK: - Search

    public func search(query: String, limit: Int = 30) async throws -> [Track] {
        let data = try await postWithFallback(
            path: "/weapi/cloudsearch/pc",
            params: cloudSearchParams(query: query, type: 1, limit: limit),
            proxyPath: "/cloudsearch",
            proxyParams: ["keywords": query, "type": 1, "limit": limit]
        )
        let songs = (data["result"] as? [String: Any])?["songs"] as? [[String: Any]] ?? []
        return songs.map(songToTrack)
    }

    public func searchAlbums(query: String, limit: Int = 20) async throws -> [Album] {
        let data = try await postWithFallback(
            path: "/weapi/search/get",
            params: searchParams(query: query, type: 10, limit: limit),
            proxyPath: "/search",
            proxyParams: ["keywords": query, "type": 10, "limit": limit]
        )
        let albums = (data["result"] as? [String: Any])?["albums"] as? [[String: Any]] ?? []
        return albums.map(albumToAlbum)
    }

    public func getAlbumTracks(albumId: String) async throws -> [Track] {
        let data = try await postWithFallback(
            path: "/weapi/v1/album/\(albumId)",
            params: ["csrf_token": cookies["__csrf"] ?? ""],
            apiPath: "/api/v1/album/\(albumId)",
            apiParams: [:],
            proxyPath: "/album",
            proxyParams: ["id": albumId]
        )
        let songs = data["songs"] as? [[String: Any]] ?? []
        return songs.map(songToTrack)
    }

    // MARK: - Stream URL

    public func getStreamURL(track: Track) async throws -> String {
        guard let songId = Int(track.id) else { throw NeteaseClientError.noStreamURL(track.id) }
        let params: [String: Any] = [
            "ids": [songId],
            "level": "exhigh",
            "encodeType": "flac",
            "csrf_token": cookies["__csrf"] ?? ""
        ]

        // Match the Python implementation: prefer NeteaseCloudMusicApi for
        // playback URLs. Direct /api can return a URL that looks valid but is
        // rejected by the CDN with "auth failed - origin failed".
        if let data = try? await proxyGet(path: "/song/url/v1", params: ["id": track.id, "level": "exhigh"]),
           !data.isEmpty,
           let items = data["data"] as? [[String: Any]],
           let url = items.first?["url"] as? String, !url.isEmpty {
            NSLog("[NeteaseClient] stream URL via local proxy: \(url.prefix(60))")
            return playableStreamURL(url)
        }

        // Fallback 1: NWConnection (HTTP/1.1, bypasses WAF)
        if let data = try? await post(path: "/weapi/song/enhance/player/url/v1", params: params),
           !data.isEmpty,
           let items = data["data"] as? [[String: Any]],
           let url = items.first?["url"] as? String, !url.isEmpty {
            NSLog("[NeteaseClient] stream URL via NWConnection: \(url.prefix(60))")
            return playableStreamURL(url)
        }

        // Fallback 2: URLSession POST (HTTP/2, some CDN paths accept it)
        if let data = try? await urlSessionWeapiPost(path: "/weapi/song/enhance/player/url/v1", params: params),
           !data.isEmpty,
           let items = data["data"] as? [[String: Any]],
           let url = items.first?["url"] as? String, !url.isEmpty {
            NSLog("[NeteaseClient] stream URL via URLSession POST: \(url.prefix(60))")
            return playableStreamURL(url)
        }

        // Last resort: direct /api endpoint. Keep this behind the authenticated
        // paths because its CDN auth token is not reliable for playback.
        if let data = try? await apiGet(
            path: "/api/song/enhance/player/url/v1",
            params: ["ids": "[\(songId)]", "level": "exhigh", "encodeType": "flac"]
        ),
           !data.isEmpty,
           let items = data["data"] as? [[String: Any]],
           let url = items.first?["url"] as? String, !url.isEmpty {
            NSLog("[NeteaseClient] stream URL via direct /api: \(url.prefix(60))")
            return playableStreamURL(url)
        }

        throw NeteaseClientError.noStreamURL(track.id)
    }

    private func playableStreamURL(_ rawURL: String) -> String {
        rawURL
    }

    private func urlSessionWeapiPost(path: String, params: [String: Any]) async throws -> [String: Any] {
        let encrypted = try NeteaseCrypto.weapiEncrypt(params)
        let p = percentEncode(encrypted["params"] ?? "")
        let e = percentEncode(encrypted["encSecKey"] ?? "")
        let bodyData = Data("params=\(p)&encSecKey=\(e)".utf8)
        guard let url = URL(string: baseURL + path) else { throw NeteaseClientError.badURL(path) }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        setCommonHeaders(on: &request)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("\(bodyData.count)", forHTTPHeaderField: "Content-Length")
        NSLog("[NeteaseClient] POST \(path) (URLSession fallback)")
        return try await json(for: request, path: path)
    }

    // MARK: - Lyrics

    public func getLyrics(track: Track) async throws -> [LyricLine] {
        guard let songId = Int(track.id) else { return [] }
        let params: [String: Any] = [
            "id": songId,
            "lv": -1,
            "kv": -1,
            "tv": -1,
            "rv": -1,
            "yv": -1,
            "csrf_token": cookies["__csrf"] ?? ""
        ]

        let data = try await postWithFallback(
            path: "/weapi/song/lyric/v1",
            params: params,
            apiPath: "/api/song/lyric/v1",
            apiParams: [
                "id": songId,
                "lv": -1,
                "kv": -1,
                "tv": -1,
                "rv": -1,
                "yv": -1
            ],
            proxyPath: "/lyric",
            proxyParams: ["id": songId]
        )
        return NeteaseLyrics.parseResponse(data)
    }

    // MARK: - Home / Recommendations

    public func getHome() async throws -> [(String, [Track])] {
        var result: [(String, [Track])] = []

        // 1. 每日推荐（需要账号有足够历史，空 body = 无数据，静默跳过）
        if let dailyData = try? await postWithFallback(
            path: "/weapi/v3/discovery/recommend/songs",
            params: ["csrf_token": cookies["__csrf"] ?? ""],
            apiPath: "/api/v3/discovery/recommend/songs",
            apiParams: [:],
            proxyPath: "/recommend/songs",
            proxyParams: [:]
        ), let daily = (dailyData["data"] as? [String: Any])?["dailySongs"] as? [[String: Any]] {
            let tracks = daily.map(songToTrack)
            if !tracks.isEmpty { result.append(("每日推荐", tracks)) }
        }

        // 2. 个性化推荐新歌（所有登录账号均可用）
        if let newData = try? await postWithFallback(
            path: "/weapi/personalized/newsong",
            params: ["type": 0, "limit": 20, "csrf_token": cookies["__csrf"] ?? ""],
            apiPath: "/api/personalized/newsong",
            apiParams: ["type": 0, "limit": 20],
            proxyPath: "/personalized/newsong",
            proxyParams: ["type": 0, "limit": 20]
        ), let items = newData["result"] as? [[String: Any]] {
            let tracks = items.compactMap { item -> Track? in
                guard let song = item["song"] as? [String: Any] else { return nil }
                return songToTrack(song)
            }
            if !tracks.isEmpty { result.append(("新歌推荐", tracks)) }
        }

        // 3. 个性化推荐歌单中的歌曲（最通用）
        if result.isEmpty {
            if let plData = try? await postWithFallback(
                path: "/weapi/personalized",
                params: ["limit": 3, "csrf_token": cookies["__csrf"] ?? ""],
                apiPath: "/api/personalized/playlist",
                apiParams: ["limit": 3],
                proxyPath: "/personalized",
                proxyParams: ["limit": 3]
            ), let playlists = plData["result"] as? [[String: Any]] {
                for pl in playlists.prefix(2) {
                    if let plId = (pl["id"] as? Int).map({ String($0) }) ?? (pl["id"] as? String) {
                        if let tracks = try? await getPlaylistTracks(playlistId: plId), !tracks.isEmpty {
                            let name = pl["name"] as? String ?? "推荐"
                            result.append((name, Array(tracks.prefix(10))))
                        }
                    }
                }
            }
        }

        return result
    }

    public func getRecommendations(track: Track) async throws -> [Track] {
        // Use artist top tracks as recommendations
        let data = try await postWithFallback(
            path: "/weapi/v1/artist/\(track.id)",
            params: ["csrf_token": cookies["__csrf"] ?? ""],
            apiPath: "/api/v1/artist/\(track.id)",
            apiParams: [:],
            proxyPath: "/artists",
            proxyParams: ["id": track.id]
        )
        // Fallback: search by artist name
        let hot = data["hotSongs"] as? [[String: Any]] ?? []
        if !hot.isEmpty { return hot.map(songToTrack) }
        return try await search(query: track.artist, limit: 20)
    }

    // MARK: - Library / Playlists

    public func getLibraryPlaylists() async throws -> [Playlist] {
        let uid = try await getUID()
        let data = try await postWithFallback(
            path: "/weapi/user/playlist",
            params: ["uid": uid, "limit": 50, "offset": 0, "csrf_token": cookies["__csrf"] ?? ""],
            apiPath: "/api/user/playlist/",
            apiParams: ["uid": uid, "limit": 50, "offset": 0],
            proxyPath: "/user/playlist",
            proxyParams: ["uid": uid, "limit": 50]
        )
        return (data["playlist"] as? [[String: Any]] ?? []).map(playlistToPlaylist)
    }

    public func getPlaylistTracks(playlistId: String) async throws -> [Track] {
        let data = try await postWithFallback(
            path: "/weapi/v3/playlist/detail",
            params: ["id": playlistId, "n": 1000, "csrf_token": cookies["__csrf"] ?? ""],
            apiPath: "/api/v3/playlist/detail",
            apiParams: ["id": playlistId, "n": 1000],
            proxyPath: "/playlist/track/all",
            proxyParams: ["id": playlistId, "limit": 200]
        )
        let songs = (data["playlist"] as? [String: Any])?["tracks"] as? [[String: Any]]
            ?? data["songs"] as? [[String: Any]]
            ?? []
        return songs.map(songToTrack)
    }

    public func getAddablePlaylists() async throws -> [Playlist] {
        let uid = try await getUID()
        let data = try await postWithFallback(
            path: "/weapi/user/playlist",
            params: ["uid": uid, "limit": 100, "offset": 0, "csrf_token": cookies["__csrf"] ?? ""],
            apiPath: "/api/user/playlist/",
            apiParams: ["uid": uid, "limit": 100, "offset": 0],
            proxyPath: "/user/playlist",
            proxyParams: ["uid": uid, "limit": 100]
        )
        return (data["playlist"] as? [[String: Any]] ?? [])
            .filter { ($0["subscribed"] as? Bool) != true }
            .map(playlistToPlaylist)
    }

    public func addTrackToPlaylist(playlistId: String, track: Track) async throws -> Bool {
        let data = try await postWithFallback(
            path: "/weapi/playlist/manipulate/tracks",
            params: [
                "op": "add",
                "pid": playlistId,
                "trackIds": "[\(track.id)]",
                "imme": "true",
                "csrf_token": cookies["__csrf"] ?? ""
            ],
            proxyPath: "/playlist/tracks",
            proxyParams: ["op": "add", "pid": playlistId, "tracks": track.id]
        )
        return playlistOpSucceeded(data)
    }

    public func removeTrackFromPlaylist(playlistId: String, track: Track) async throws -> Bool {
        let data = try await postWithFallback(
            path: "/weapi/playlist/manipulate/tracks",
            params: [
                "op": "del",
                "pid": playlistId,
                "trackIds": "[\(track.id)]",
                "imme": "true",
                "csrf_token": cookies["__csrf"] ?? ""
            ],
            proxyPath: "/playlist/tracks",
            proxyParams: ["op": "del", "pid": playlistId, "tracks": track.id]
        )
        return playlistOpSucceeded(data)
    }

    // MARK: - Artist

    public func searchArtist(name: String) async throws -> Artist? {
        let data = try await postWithFallback(
            path: "/weapi/search/get",
            params: searchParams(query: name, type: 100, limit: 1),
            proxyPath: "/search",
            proxyParams: ["keywords": name, "type": 100, "limit": 1]
        )
        guard let a = ((data["result"] as? [String: Any])?["artists"] as? [[String: Any]])?.first
        else { return nil }
        return Artist(
            id: String(describing: a["id"] ?? ""),
            platform: "netease",
            name: a["name"] as? String ?? "",
            imageURL: httpsURL(a["picUrl"] as? String ?? "")
        )
    }

    public func getArtistTopTracks(artistId: String, limit: Int = 30) async throws -> [Track] {
        let data = try await postWithFallback(
            path: "/weapi/v1/artist/\(artistId)",
            params: ["csrf_token": cookies["__csrf"] ?? ""],
            apiPath: "/api/v1/artist/\(artistId)",
            apiParams: [:],
            proxyPath: "/artists",
            proxyParams: ["id": artistId]
        )
        let songs = data["hotSongs"] as? [[String: Any]] ?? []
        return songs.prefix(limit).map(songToTrack)
    }

    // MARK: - Internal helpers

    private func getUID() async throws -> String {
        let data = try await postWithFallback(
            path: "/weapi/nuser/account/get",
            params: ["csrf_token": cookies["__csrf"] ?? ""],
            apiPath: "/api/nuser/account/get",
            apiParams: [:],
            proxyPath: "/user/account",
            proxyParams: [:]
        )
        let account = data["account"] as? [String: Any]
        let profile = data["profile"] as? [String: Any]
        let id = account?["id"] ?? account?["userId"] ?? profile?["userId"]
        let uid = String(describing: id ?? "")
        guard !uid.isEmpty else { throw NeteaseClientError.emptyResponse("/nuser/account/get") }
        return uid
    }

    private func searchParams(query: String, type: Int, limit: Int) -> [String: Any] {
        ["s": query, "type": type, "limit": limit, "offset": 0, "csrf_token": cookies["__csrf"] ?? ""]
    }

    private func cloudSearchParams(query: String, type: Int, limit: Int) -> [String: Any] {
        [
            "s": query,
            "type": type,
            "limit": limit,
            "offset": 0,
            "total": true,
            "csrf_token": cookies["__csrf"] ?? "",
        ]
    }

    // MARK: - HTTP/1.1 POST via Network.framework
    //
    // URLSession negotiates HTTP/2 with music.163.com; Netease's WAF fingerprints
    // HTTP/2 clients and returns 200 + empty body for non-browser connections.
    // Solution: use NWConnection with ALPN = ["http/1.1"] only, forcing HTTP/1.1
    // which matches Python httpx's default behaviour and bypasses the WAF.

    private func post(path: String, params: [String: Any]) async throws -> [String: Any] {
        let encrypted = try NeteaseCrypto.weapiEncrypt(params)
        let p = percentEncode(encrypted["params"] ?? "")
        let e = percentEncode(encrypted["encSecKey"] ?? "")
        let body = Data("params=\(p)&encSecKey=\(e)".utf8)

        let headers: [(String, String)] = [
            ("Host",            "music.163.com"),
            ("Content-Type",    "application/x-www-form-urlencoded"),
            ("Content-Length",  "\(body.count)"),
            ("User-Agent",      neteaseUserAgent),
            ("Referer",         "https://music.163.com/"),
            ("Origin",          "https://music.163.com"),
            ("Cookie",          cookieHeader(cookies)),
            ("Accept",          "*/*"),
            ("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8"),
            ("Accept-Encoding", "identity"),
            ("Connection",      "close"),
        ]

        NSLog("[NeteaseClient] POST \(path) (HTTP/1.1 via NWConnection)")

        let responseBody = try await http11Post(path: path, headers: headers, body: body)

        NSLog("[NeteaseClient]   body=\(responseBody.count)B: \(String(data: responseBody.prefix(300), encoding: .utf8) ?? "<binary>")")

        guard !responseBody.isEmpty else { throw NeteaseClientError.emptyResponse(path) }
        let json = (try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any]) ?? [:]
        if let code = json["code"] as? Int, code != 200 {
            let msg = json["msg"] as? String ?? json["message"] as? String ?? "code \(code)"
            throw NeteaseClientError.apiError(code, msg)
        }
        return json
    }

    private func postWithFallback(
        path: String,
        params: [String: Any],
        apiPath: String? = nil,
        apiParams: [String: Any]? = nil,
        proxyPath: String? = nil,
        proxyParams: [String: Any]? = nil
    ) async throws -> [String: Any] {
        do {
            let data = try await post(path: path, params: params)
            if !data.isEmpty { return data }
        } catch {
            NSLog("[NeteaseClient] weapi failed for \(path): \(error)")
        }

        if let apiPath {
            do {
                let data = try await apiGet(path: apiPath, params: apiParams ?? params)
                if !data.isEmpty { return data }
            } catch {
                NSLog("[NeteaseClient] api fallback failed for \(apiPath): \(error)")
            }
        }

        if let proxyPath {
            let data = try await proxyGet(path: proxyPath, params: proxyParams ?? params)
            if !data.isEmpty { return data }
        }

        throw NeteaseClientError.emptyResponse(path)
    }

    private func apiGet(path: String, params: [String: Any]) async throws -> [String: Any] {
        var query = params
        if !cookieHeader(cookies).isEmpty {
            query["cookie"] = cookieHeader(cookies)
        }
        guard var comps = URLComponents(string: baseURL + path) else {
            throw NeteaseClientError.badURL(path)
        }
        comps.queryItems = query.map {
            URLQueryItem(name: $0.key, value: String(describing: $0.value))
        }
        guard let url = comps.url else { throw NeteaseClientError.badURL(path) }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "GET"
        setCommonHeaders(on: &request)
        NSLog("[NeteaseClient] GET \(path) (/api fallback)")
        return try await json(for: request, path: path)
    }

    private func proxyGet(path: String, params: [String: Any]) async throws -> [String: Any] {
        try await ensureProxyReady()
        var query = params
        if !cookieHeader(cookies).isEmpty {
            query["cookie"] = cookieHeader(cookies)
        }
        guard var comps = URLComponents(string: neteaseProxyBaseURL + path) else {
            throw NeteaseClientError.badURL(path)
        }
        comps.queryItems = query.map {
            URLQueryItem(name: $0.key, value: String(describing: $0.value))
        }
        guard let url = comps.url else { throw NeteaseClientError.badURL(path) }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "GET"
        NSLog("[NeteaseClient] GET \(path) (local proxy fallback)")
        return try await json(for: request, path: path)
    }

    private func json(for request: URLRequest, path: String) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NeteaseClientError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        NSLog("[NeteaseClient]   fallback body=\(data.count)B: \(String(data: data.prefix(300), encoding: .utf8) ?? "<binary>")")
        guard !data.isEmpty else { throw NeteaseClientError.emptyResponse(path) }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let code = json["code"] as? Int, code != 200 {
            let msg = json["msg"] as? String ?? json["message"] as? String ?? "code \(code)"
            throw NeteaseClientError.apiError(code, msg)
        }
        return json
    }

    private func setCommonHeaders(on request: inout URLRequest) {
        request.setValue(neteaseUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue("https://music.163.com", forHTTPHeaderField: "Origin")
        request.setValue(cookieHeader(cookies), forHTTPHeaderField: "Cookie")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
    }

    private func ensureProxyReady() async throws {
        if try await proxyIsReady() { return }
        try await startProxyIfPossible()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 350_000_000)
            if try await proxyIsReady() { return }
        }
        throw NeteaseClientError.proxyUnavailable
    }

    private func proxyIsReady() async throws -> Bool {
        guard let url = URL(string: neteaseProxyBaseURL) else { return false }
        var request = URLRequest(url: url, timeoutInterval: 1)
        request.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0) < 500
        } catch {
            return false
        }
    }

    private func startProxyIfPossible() async throws {
        guard proxyProcess == nil else { return }
        guard let npx = ExecutableResolver.findExecutable(named: "npx") else {
            NSLog("[NeteaseClient] cannot start local proxy: npx not found")
            throw NeteaseClientError.proxyUnavailable
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: npx)
        process.arguments = ["-y", "NeteaseCloudMusicApi"]
        process.environment = ExecutableResolver.environmentWithExpandedPATH()
        process.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        process.standardError = errPipe
        process.terminationHandler = { proc in
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            NSLog("[NeteaseClient] local proxy exited status=\(proc.terminationStatus) \(msg)")
        }
        do {
            try process.run()
        } catch {
            NSLog("[NeteaseClient] cannot start local proxy: \(error.localizedDescription)")
            throw NeteaseClientError.proxyUnavailable
        }
        proxyProcess = process
        NSLog("[NeteaseClient] started local NeteaseCloudMusicApi proxy via \(npx)")
    }

    // MARK: - Model mappers

    private func songToTrack(_ song: [String: Any]) -> Track {
        let ar = (song["ar"] as? [[String: Any]])
            ?? (song["artists"] as? [[String: Any]])
            ?? []
        let artistNames = ar.compactMap { $0["name"] as? String }
        let al = (song["al"] as? [String: Any])
            ?? (song["album"] as? [String: Any])
            ?? [:]
        let coverURL = firstString(
            al["picUrl"],
            song["picUrl"],
            song["coverUrl"],
            song["coverImgUrl"]
        )

        return Track(
            id: String(describing: song["id"] ?? ""),
            platform: "netease",
            title: song["name"] as? String ?? "",
            artist: artistNames.first ?? "",
            artists: artistNames,
            album: al["name"] as? String ?? "",
            albumCoverURL: httpsURL(coverURL),
            durationMs: intValue(song["dt"] ?? song["duration"]) ?? 0,
            isExplicit: false
        )
    }

    private func albumToAlbum(_ album: [String: Any]) -> Album {
        let ar = (album["artists"] as? [[String: Any]])?.first
            ?? (album["artist"] as? [String: Any])
            ?? [:]
        return Album(
            id: String(describing: album["id"] ?? ""),
            platform: "netease",
            name: album["name"] as? String ?? "",
            artist: ar["name"] as? String ?? "",
            coverURL: httpsURL(album["picUrl"] as? String ?? ""),
            trackCount: intValue(album["size"]) ?? 0,
            year: publishYear(from: album["publishTime"])
        )
    }

    private func playlistToPlaylist(_ p: [String: Any]) -> Playlist {
        Playlist(
            id: String(describing: p["id"] ?? ""),
            platform: "netease",
            name: p["name"] as? String ?? "",
            coverURL: httpsURL(p["coverImgUrl"] as? String ?? ""),
            trackCount: p["trackCount"] as? Int ?? 0
        )
    }

    private func httpsURL(_ url: String) -> String {
        url.hasPrefix("http://") ? "https://" + url.dropFirst(7) : url
    }

    private func firstString(_ values: Any?...) -> String {
        for value in values {
            if let string = value as? String, !string.isEmpty {
                return string
            }
        }
        return ""
    }

    private func playlistOpSucceeded(_ data: [String: Any]) -> Bool {
        if let body = data["body"] as? [String: Any],
           let code = body["code"].flatMap({ Int(String(describing: $0)) }) {
            return code == 200
        }
        if let code = data["code"].flatMap({ Int(String(describing: $0)) }) {
            return code == 200
        }
        if let status = data["status"].flatMap({ Int(String(describing: $0)) }) {
            return status == 200
        }
        return false
    }

    private func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private func publishYear(from value: Any?) -> String {
        guard let milliseconds = intValue(value), milliseconds > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
        let year = Calendar(identifier: .gregorian).component(.year, from: date)
        return String(year)
    }
}

// MARK: - HTTP/1.1 via Network.framework (forces http/1.1 ALPN, bypasses HTTP/2 WAF block)

/// Send a raw HTTP/1.1 POST to music.163.com:443 using NWConnection.
/// Only advertises "http/1.1" in TLS ALPN, preventing HTTP/2 negotiation.
private func http11Post(path: String, headers: [(String, String)], body: Data) async throws -> Data {
    // TLS options: advertise ONLY http/1.1 in ALPN
    let tls = NWProtocolTLS.Options()
    sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
    let params = NWParameters(tls: tls, tcp: .init())

    let conn = NWConnection(host: "music.163.com", port: 443, using: params)

    // Connect
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        var done = false
        conn.stateUpdateHandler = { state in
            guard !done else { return }
            switch state {
            case .ready:
                done = true; cont.resume()
            case .failed(let err):
                done = true; cont.resume(throwing: err)
            case .cancelled:
                if !done { done = true; cont.resume(throwing: NeteaseClientError.badURL("cancelled")) }
            default: break
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
    }

    // Build raw HTTP/1.1 request
    var req = "POST \(path) HTTP/1.1\r\n"
    for (k, v) in headers { req += "\(k): \(v)\r\n" }
    req += "\r\n"
    var reqData = Data(req.utf8)
    reqData.append(body)

    // Send
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        conn.send(content: reqData, completion: .contentProcessed { err in
            if let err = err { cont.resume(throwing: err) } else { cont.resume() }
        })
    }

    // Receive all (server sends Connection: close so it will close after response)
    var raw = Data()
    loop: while true {
        let (chunk, done) = try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<(Data, Bool), Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 131_072) { data, _, isComplete, err in
                if let err = err {
                    // EOF / reset = server closed → treat as end of response
                    cont.resume(returning: (data ?? Data(), true))
                } else {
                    cont.resume(returning: (data ?? Data(), isComplete))
                }
            }
        }
        raw.append(chunk)
        if done { break loop }
    }
    conn.cancel()

    // Parse HTTP/1.1 response: skip headers, return body
    return extractHTTPBody(from: raw)
}

/// Strip HTTP/1.1 response headers and return only the body.
private func extractHTTPBody(from raw: Data) -> Data {
    // Find \r\n\r\n (end of headers)
    let sep = Data([0x0d, 0x0a, 0x0d, 0x0a])
    guard let range = raw.range(of: sep) else { return raw }
    let bodyStart = range.upperBound
    guard bodyStart < raw.endIndex else { return Data() }
    var body = raw[bodyStart...]

    // Handle chunked transfer encoding
    let headerSection = String(data: raw[..<range.lowerBound], encoding: .utf8) ?? ""
    if headerSection.lowercased().contains("transfer-encoding: chunked") {
        body = Data(decodeChunked(body) ?? body)
    }
    return Data(body)
}

/// Minimal chunked transfer-encoding decoder.
private func decodeChunked(_ data: Data) -> Data? {
    var result = Data()
    var remaining = data
    while !remaining.isEmpty {
        // Read chunk size line
        guard let crlf = remaining.range(of: Data([0x0d, 0x0a])) else { break }
        let sizeLine = String(data: remaining[..<crlf.lowerBound], encoding: .utf8) ?? ""
        let chunkSize = Int(sizeLine.trimmingCharacters(in: .whitespaces), radix: 16) ?? 0
        if chunkSize == 0 { break }
        remaining = remaining[crlf.upperBound...]
        guard remaining.count >= chunkSize else { break }
        result.append(remaining[..<remaining.index(remaining.startIndex, offsetBy: chunkSize)])
        remaining = remaining[remaining.index(remaining.startIndex, offsetBy: chunkSize)...]
        // Skip trailing \r\n after chunk
        if remaining.prefix(2) == Data([0x0d, 0x0a]) {
            remaining = remaining.dropFirst(2)
        }
    }
    return result.isEmpty ? nil : result
}

private func percentEncode(_ s: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
}

public enum NeteaseClientError: LocalizedError {
    case badURL(String)
    case httpError(Int)
    case apiError(Int, String)   // Netease code + message from JSON body
    case noStreamURL(String)
    case emptyResponse(String)
    case proxyUnavailable
    case downloadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .badURL(let url):
            return "无效 URL：\(url)"
        case .httpError(let code):
            return "HTTP 错误 \(code)"
        case .apiError(let code, let message):
            return "API 错误 \(code)：\(message)"
        case .noStreamURL(let id):
            return "无法获取网易云歌曲流地址（\(id)），可能是版权、会员或地区限制"
        case .emptyResponse(let path):
            return "网易云接口返回空数据：\(path)"
        case .proxyUnavailable:
            return "网易云本地代理不可用，且直连接口未返回可播放地址"
        case .downloadFailed(let message):
            return "网易云音频下载失败：\(message)"
        }
    }
}
