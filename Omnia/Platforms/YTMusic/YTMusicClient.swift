import Foundation

// MARK: - Constants

private let ytmBaseURL    = "https://music.youtube.com/youtubei/v1"
private let ytmOriginStr  = "https://music.youtube.com"

// Windows Chrome UA for API requests (matches Python _YT_UA)
let ytmWindowsChromeUA =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) " +
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

// Search filter params (base64-encoded protobuf)
private let searchParamsSongs     = "EgWKAQIIAWoMEA4QChADEAQQCRAF"
private let searchParamsAlbums    = "EgWKAQIYAWoMEA4QChADEAQQCRAF"
private let searchParamsArtists   = "EgWKAQIgAWoMEA4QChADEAQQCRAF"

// MARK: - YTMusicClient

public actor YTMusicClient: PlatformProtocol {
    public let id          = "ytmusic"
    public let displayName = "YouTube Music"

    private let cookieStr: String
    private let sapisid: String
    private let session: URLSession
    private var cachedYtDlpCommands: [ProcessCommand]?

    private struct ProcessCommand {
        let executable: String
        let argumentsPrefix: [String]
    }

    /// Initialize with the headers dict produced by YTMusicAuth.buildHeaders(from:).
    public init(headers: [String: String], session: URLSession = .shared) {
        let rawCookie = headers["Cookie"] ?? ""
        self.cookieStr = rawCookie.contains("SOCS=") ? rawCookie : [rawCookie, "SOCS=CAI"].filter { !$0.isEmpty }.joined(separator: "; ")
        self.sapisid   = extractCookieValue("__Secure-3PAPISID", from: headers["Cookie"] ?? "")
            ?? extractCookieValue("__Secure-1PAPISID", from: headers["Cookie"] ?? "")
            ?? extractCookieValue("SAPISID", from: headers["Cookie"] ?? "")
            ?? ""
        self.session = session
    }

    // MARK: - Search

    public func search(query: String, limit: Int = 30) async throws -> [Track] {
        let resp = try await innertube("search", body: [
            "query":  query,
            "params": searchParamsSongs,
        ])
        return parseSearchTracks(resp, limit: limit)
    }

    public func searchAlbums(query: String, limit: Int = 10) async throws -> [Album] {
        let resp = try await innertube("search", body: [
            "query":  query,
            "params": searchParamsAlbums,
        ])
        return parseSearchAlbums(resp, limit: limit)
    }

    public func searchArtist(name: String) async throws -> Artist? {
        let resp = try await innertube("search", body: [
            "query":  name,
            "params": searchParamsArtists,
        ])
        return parseFirstArtist(resp)
    }

    // MARK: - Stream URL (yt-dlp subprocess)

    public func getStreamURL(track: Track) async throws -> String {
        guard !track.id.isEmpty else { throw YTMusicClientError.noStreamURL(track.id) }
        return try await extractStreamURLViaYtDlp(videoId: track.id)
    }

    // MARK: - Home

    public func getHome() async throws -> [(String, [Track])] {
        let resp = try await innertube("browse", body: ["browseId": "FEmusic_home"])
        var sections = parseHomeContents(resp)
        if !sections.isEmpty { return sections }

        let playlistFallbacks = parseHomePlaylistFallbacks(resp)
        for (title, playlistId) in playlistFallbacks.prefix(3) {
            let tracks = Array((try await getPlaylistTracks(playlistId: playlistId)).prefix(10))
            if !tracks.isEmpty {
                sections.append((title, tracks))
            }
        }
        return sections
    }

    // MARK: - Library / Playlists

    public func getLibraryPlaylists() async throws -> [Playlist] {
        var playlists: [Playlist] = []
        if let liked = try? await getLikedSongsPlaylistSummary() {
            playlists.append(liked)
        }
        let resp = try await innertube("browse", body: ["browseId": "FEmusic_liked_playlists"])
        playlists.append(contentsOf: parseLibraryPlaylists(resp))
        return uniquedPlaylists(playlists)
    }

    public func getPlaylistTracks(playlistId: String) async throws -> [Track] {
        let browseId = playlistId.hasPrefix("VL") ? playlistId : "VL\(playlistId)"
        let resp = try await innertube("browse", body: ["browseId": browseId])
        return parsePlaylistTracks(resp)
    }

    public func getAddablePlaylists() async throws -> [Playlist] {
        let resp = try await innertube("browse", body: ["browseId": "FEmusic_liked_playlists"])
        return parseLibraryPlaylists(resp).filter { !$0.id.isEmpty && $0.id != "LM" }
    }

    // MARK: - Album tracks

    public func getAlbumTracks(albumId: String) async throws -> [Track] {
        let resp = try await innertube("browse", body: ["browseId": albumId])
        return parseAlbumTracks(resp)
    }

    // MARK: - Artist top tracks

    public func getArtistTopTracks(artistId: String, limit: Int = 30) async throws -> [Track] {
        let resp = try await innertube("browse", body: ["browseId": artistId])
        return parseArtistTopTracks(resp, limit: limit)
    }

    // MARK: - Recommendations (watch playlist)

    public func getRecommendations(track: Track) async throws -> [Track] {
        guard !track.id.isEmpty else { return [] }
        // Match ytmusicapi get_watch_playlist: no params by default, RDAMVM for autoplay mix
        let resp = try await innertube("next", body: [
            "videoId":    track.id,
            "playlistId": "RDAMVM\(track.id)",
        ])
        return parseWatchPlaylistTracks(resp)
    }

    // MARK: - Lyrics

    public func getLyrics(track: Track) async throws -> [LyricLine] {
        try await YTMusicLyrics.fetch(track: track, client: self)
    }

    // MARK: - Playlist management

    public func addTrackToPlaylist(playlistId: String, track: Track) async throws -> Bool {
        guard !playlistId.isEmpty, !track.id.isEmpty else { return false }
        let resp = try await innertube("browse/edit_playlist", body: [
            "playlistId": playlistId,
            "actions": [["addedVideoId": track.id, "action": "ACTION_ADD_VIDEO"]],
        ])
        let status = resp["status"] as? String
        return status == "STATUS_SUCCEEDED" || resp["playlistEditResults"] != nil
    }

    public func removeTrackFromPlaylist(playlistId: String, track: Track) async throws -> Bool {
        guard !playlistId.isEmpty, !track.id.isEmpty else { return false }
        if let setId = track.playlistItemId, !setId.isEmpty {
            let resp = try await innertube("browse/edit_playlist", body: [
                "playlistId": playlistId,
                "actions": [[
                    "setVideoId":    setId,
                    "removedVideoId": track.id,
                    "action":        "ACTION_REMOVE_VIDEO",
                ]],
            ])
            let status = resp["status"] as? String
            return status == "STATUS_SUCCEEDED" || resp["playlistEditResults"] != nil
        }
        // Liked songs: unlike via rate_song
        let resp = try await innertube("like/dislike", body: [
            "target": ["videoId": track.id]
        ])
        return resp["status"] as? String != "FAILURE"
    }

    // MARK: - Innertube request (internal)

    func innertube(_ endpoint: String, body: [String: Any]) async throws -> [String: Any] {
        let urlStr = "\(ytmBaseURL)/\(endpoint)?alt=json&key=\(ytmInnertubeKey)"
        guard let url = URL(string: urlStr) else {
            throw YTMusicClientError.badURL(endpoint)
        }

        var fullBody = body
        fullBody["context"] = YTMusicAuth.innertubeContext()

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(ytmWindowsChromeUA, forHTTPHeaderField: "User-Agent")
        request.setValue(cookieStr, forHTTPHeaderField: "Cookie")
        request.setValue(YTMusicAuth.makeSapisidhash(sapisid), forHTTPHeaderField: "Authorization")
        request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        request.setValue(ytmOriginStr, forHTTPHeaderField: "x-origin")
        request.setValue(ytmOriginStr, forHTTPHeaderField: "Origin")
        request.setValue(ytmOriginStr + "/", forHTTPHeaderField: "Referer")
        request.httpBody = try JSONSerialization.data(withJSONObject: fullBody)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw YTMusicClientError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: - yt-dlp subprocess

    private func extractStreamURLViaYtDlp(videoId: String) async throws -> String {
        let commands = ytDlpCommands()
        guard !commands.isEmpty else {
            throw YTMusicClientError.ytDlpNotFound
        }
        var lastError: Error?
        for command in commands {
            do {
                return try await runYtDlp(command: command, videoId: videoId)
            } catch {
                lastError = error
                NSLog("[YTMusicClient] yt-dlp command failed (\(command.executable)): \(error.localizedDescription)")
            }
        }
        throw lastError ?? YTMusicClientError.noStreamURL(videoId)
    }

    private func runYtDlp(command: ProcessCommand, videoId: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = command.argumentsPrefix + [
                // Prefer m4a (AAC) — natively supported by AVFoundation.
                // WebM/Opus requires VLCKit and will silently fail without it.
                "--format", "bestaudio[ext=m4a]/best[ext=m4a]/bestaudio[ext=webm]/bestaudio/best",
                "--get-url",
                "--quiet",
                "--no-warnings",
                "https://music.youtube.com/watch?v=\(videoId)",
            ]
            process.environment = ExecutableResolver.environmentWithExpandedPATH()
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError  = errPipe

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: YTMusicClientError.ytDlpNotFound)
                return
            }

            process.terminationHandler = { _ in
                let rawOutput = String(
                    data: outPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                // yt-dlp may output multiple lines; take the first non-empty one
                let urlStr = rawOutput
                    .components(separatedBy: .newlines)
                    .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    ?? ""
                if process.terminationStatus != 0 || urlStr.isEmpty || !urlStr.hasPrefix("http") {
                    let errOutput = String(
                        data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    continuation.resume(throwing: YTMusicClientError.ytDlpFailed(errOutput))
                } else {
                    continuation.resume(returning: urlStr)
                }
            }
        }
    }

    private func ytDlpCommands() -> [ProcessCommand] {
        if let cachedYtDlpCommands {
            return cachedYtDlpCommands
        }

        var commands: [ProcessCommand] = []
        if let binary = findYtDlpBinary() {
            commands.append(ProcessCommand(executable: binary, argumentsPrefix: []))
        }
        if let python = ExecutableResolver.findExecutable(named: "python3") {
            commands.append(ProcessCommand(executable: python, argumentsPrefix: ["-m", "yt_dlp"]))
        }
        cachedYtDlpCommands = commands
        return commands
    }

    private func findYtDlpBinary() -> String? {
        ExecutableResolver.findExecutable(
            named: "yt-dlp",
            bundledResource: "yt-dlp",
            extraCandidates: [
                "/opt/homebrew/bin/yt-dlp",
                "/usr/local/bin/yt-dlp",
                (FileManager.default.homeDirectoryForCurrentUser.path as NSString)
                    .appendingPathComponent(".local/bin/yt-dlp"),
            ]
        )
    }

    // MARK: - Response parsers

    private func parseSearchTracks(_ data: [String: Any], limit: Int) -> [Track] {
        var tracks: [Track] = []
        for renderer in allMusicResponsiveListItemRenderers(in: data) {
            if let t = trackFromResponsiveRenderer(renderer) {
                tracks.append(t)
                if tracks.count >= limit { break }
            }
        }
        return tracks
    }

    private func parseSearchAlbums(_ data: [String: Any], limit: Int) -> [Album] {
        var albums: [Album] = []
        for r in allMusicTwoRowItemRenderers(in: data) {
            if let a = albumFromTwoRowRenderer(r) {
                albums.append(a)
                if albums.count >= limit { return albums }
            }
        }
        return albums
    }

    private func parseFirstArtist(_ data: [String: Any]) -> Artist? {
        for renderer in allMusicCardShelfRenderers(in: data) {
            if let a = artistFromCardShelfRenderer(renderer) { return a }
        }
        for renderer in allMusicResponsiveListItemRenderers(in: data) {
            if let a = artistFromResponsiveRenderer(renderer) { return a }
        }
        for r in allMusicTwoRowItemRenderers(in: data) {
            if let a = artistFromTwoRowRenderer(r) { return a }
        }
        return nil
    }

    private func parseHomeContents(_ data: [String: Any]) -> [(String, [Track])] {
        var result: [(String, [Track])] = []
        let sections = sectionListContents(in: data)
        for section in sections {
            guard let carousel = section["musicCarouselShelfRenderer"] as? [String: Any] else { continue }
            let title = carouselTitle(carousel)
            var tracks: [Track] = []
            let items = carousel["contents"] as? [[String: Any]] ?? []
            for item in items {
                if let r = item["musicResponsiveListItemRenderer"] as? [String: Any],
                   let t = trackFromResponsiveRenderer(r) {
                    tracks.append(t)
                } else if let r = item["musicTwoRowItemRenderer"] as? [String: Any],
                          let t = trackFromTwoRowRenderer(r) {
                    tracks.append(t)
                }
            }
            if !tracks.isEmpty { result.append((title, tracks)) }
            if result.count >= 5 { break }
        }
        return result
    }

    private func parseHomePlaylistFallbacks(_ data: [String: Any]) -> [(String, String)] {
        var fallbacks: [(String, String)] = []
        for section in sectionListContents(in: data) {
            guard let carousel = section["musicCarouselShelfRenderer"] as? [String: Any] else { continue }
            let title = carouselTitle(carousel)
            let items = carousel["contents"] as? [[String: Any]] ?? []
            for item in items {
                guard let r = item["musicTwoRowItemRenderer"] as? [String: Any],
                      let playlistId = playlistIdFromTwoRowRenderer(r),
                      !playlistId.isEmpty
                else { continue }
                fallbacks.append((title.isEmpty ? firstRunText(r["title"]) : title, playlistId))
                break
            }
        }
        return fallbacks
    }

    private func parseLibraryPlaylists(_ data: [String: Any]) -> [Playlist] {
        var playlists: [Playlist] = []
        for section in sectionListContents(in: data) {
            // gridRenderer
            if let grid = section["gridRenderer"] as? [String: Any] {
                for item in grid["items"] as? [[String: Any]] ?? [] {
                    if let r = item["musicTwoRowItemRenderer"] as? [String: Any],
                       let p = playlistFromTwoRowRenderer(r) {
                        playlists.append(p)
                    }
                }
            }
            // musicShelfRenderer
            for item in musicShelfContents(in: section) {
                if let r = item["musicResponsiveListItemRenderer"] as? [String: Any],
                   let p = playlistFromResponsiveRenderer(r) {
                    playlists.append(p)
                }
            }
        }
        return playlists
    }

    private func getLikedSongsPlaylistSummary() async throws -> Playlist? {
        let resp = try await innertube("browse", body: ["browseId": "VLLM"])
        let tracks = parsePlaylistTracks(resp)
        return Playlist(
            id: "LM",
            platform: "ytmusic",
            name: "喜欢的歌曲",
            coverURL: tracks.first?.albumCoverURL ?? "",
            trackCount: playlistTrackCount(from: resp) ?? tracks.count
        )
    }

    private func parsePlaylistTracks(_ data: [String: Any]) -> [Track] {
        var tracks: [Track] = []
        for r in allMusicResponsiveListItemRenderers(in: data) {
            if let t = trackFromResponsiveRenderer(r) {
                tracks.append(t)
            }
        }
        return tracks
    }

    private func parseAlbumTracks(_ data: [String: Any]) -> [Track] {
        var tracks: [Track] = []
        // Album header for cover URL
        let albumCover = albumCoverFromHeader(data)
        let albumName  = albumNameFromHeader(data)
        for r in allMusicResponsiveListItemRenderers(in: data) {
            if var t = trackFromResponsiveRenderer(r) {
                if t.albumCoverURL.isEmpty { t.albumCoverURL = albumCover }
                if t.album.isEmpty         { t.album = albumName }
                tracks.append(t)
            }
        }
        return tracks
    }

    private func parseArtistTopTracks(_ data: [String: Any], limit: Int) -> [Track] {
        // Look for musicShelfRenderer with songs under artist browse
        var tracks: [Track] = []
        for r in allMusicResponsiveListItemRenderers(in: data) {
            if let t = trackFromResponsiveRenderer(r) {
                tracks.append(t)
                if tracks.count >= limit { return tracks }
            }
        }
        for r in allMusicTwoRowItemRenderers(in: data) {
            if let t = trackFromTwoRowRenderer(r) {
                tracks.append(t)
                if tracks.count >= limit { return tracks }
            }
        }
        return tracks
    }

    private func parseWatchPlaylistTracks(_ data: [String: Any]) -> [Track] {
        let c0 = data["contents"] as? [String: Any]
        let single = c0?["singleColumnMusicWatchNextResultsRenderer"] as? [String: Any]
        let panel = single?["playlist"] as? [String: Any]
        let panelRenderer = panel?["playlistPanelRenderer"] as? [String: Any]
        let contents = panelRenderer?["contents"] as? [[String: Any]] ?? []
        return contents.compactMap { item -> Track? in
            guard let r = item["playlistPanelVideoRenderer"] as? [String: Any],
                  let videoId = r["videoId"] as? String, !videoId.isEmpty
            else { return nil }
            let title = firstRunText(r["title"])
            let artist = firstRunText(r["longBylineText"])
            let cover = lastThumbnailURL(r["thumbnail"] as? [String: Any])
            let durationMs = parseDurationText(firstRunText(r["lengthText"]))
            return Track(
                id: videoId, platform: "ytmusic",
                title: title, artist: artist, artists: artist.isEmpty ? [] : [artist],
                album: "", albumCoverURL: cover, durationMs: durationMs
            )
        }
    }

    // MARK: - Renderer helpers

    private func trackFromResponsiveRenderer(_ r: [String: Any]) -> Track? {
        // Video ID: overlay → playButtonRenderer → watchEndpoint
        let videoId = videoIdFromRenderer(r)
        guard !videoId.isEmpty else { return nil }

        let cols = r["flexColumns"] as? [[String: Any]] ?? []
        let col0Runs = flexColumnRuns(cols, index: 0)
        let col1Runs = flexColumnRuns(cols, index: 1)
        let col2Runs = flexColumnRuns(cols, index: 2)

        let title  = col0Runs.first?["text"] as? String ?? ""
        // col1 alternates: artist • album • year (or artist • duration)
        let subtitleTexts = col1Runs.compactMap { $0["text"] as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "•" }
        let artist = subtitleTexts.first ?? ""
        let albumFromColumn = col2Runs.first?["text"] as? String
        let album  = albumFromColumn ?? (subtitleTexts.count > 1 ? subtitleTexts[1] : "")

        let fixedCols = r["fixedColumns"] as? [[String: Any]] ?? []
        let fixedCol0 = fixedCols.first?["musicResponsiveListItemFixedColumnRenderer"] as? [String: Any]
        let fixedText = fixedCol0?["text"] as? [String: Any]
        let fixedRuns = fixedText?["runs"] as? [[String: Any]]
        let durationText = fixedText?["simpleText"] as? String ?? fixedRuns?.first?["text"] as? String ?? ""
        let durationMs = parseDurationText(durationText)

        let cover = thumbnailURL(from: r["thumbnail"])
        let playlistItemId = setVideoIdFromRenderer(r)

        return Track(
            id: videoId, platform: "ytmusic",
            title: title,
            artist: artist, artists: artist.isEmpty ? [] : [artist],
            album: album, albumCoverURL: cover,
            durationMs: durationMs,
            playlistItemId: playlistItemId
        )
    }

    private func trackFromTwoRowRenderer(_ r: [String: Any]) -> Track? {
        // Try navEndpoint.watchEndpoint.videoId first
        let navEp = r["navigationEndpoint"] as? [String: Any]
        let watchEp = navEp?["watchEndpoint"] as? [String: Any]
        let videoId: String
        if let v = watchEp?["videoId"] as? String, !v.isEmpty {
            videoId = v
        } else {
            // Try overlay path
            let overlay = r["overlay"] as? [String: Any]
            let overlayRenderer = overlay?["musicItemThumbnailOverlayRenderer"] as? [String: Any]
            let content = overlayRenderer?["content"] as? [String: Any]
            let pbr = content?["musicPlayButtonRenderer"] as? [String: Any]
            let playNav = pbr?["playNavigationEndpoint"] as? [String: Any]
            let we2 = playNav?["watchEndpoint"] as? [String: Any]
            guard let v = we2?["videoId"] as? String, !v.isEmpty else { return nil }
            videoId = v
        }
        guard !videoId.isEmpty else { return nil }

        let title  = firstRunText(r["title"])
        let parts = subtitleParts(from: r["subtitle"])
        let artist = parts.first ?? ""
        let cover  = thumbnailURL(from: r["thumbnailRenderer"])
        return Track(
            id: videoId, platform: "ytmusic",
            title: title, artist: artist, artists: artist.isEmpty ? [] : [artist],
            album: parts.count > 1 ? parts[1] : "", albumCoverURL: cover, durationMs: 0
        )
    }

    private func albumFromTwoRowRenderer(_ r: [String: Any]) -> Album? {
        let navEp = r["navigationEndpoint"] as? [String: Any]
        let browseEp = navEp?["browseEndpoint"] as? [String: Any]
        let browseId = browseEp?["browseId"] as? String ?? ""
        guard !browseId.isEmpty else { return nil }
        let name   = firstRunText(r["title"])
        guard !name.isEmpty else { return nil }
        let subs = subtitleParts(from: r["subtitle"])
        let artist = subs.count > 1 ? subs[1] : (subs.first ?? "")
        let year   = subs.count > 2 ? subs[2] : ""
        let cover  = thumbnailURL(from: r["thumbnailRenderer"])
        return Album(id: browseId, platform: "ytmusic", name: name, artist: artist,
                     coverURL: cover, trackCount: 0, year: year)
    }

    private func artistFromCardShelfRenderer(_ r: [String: Any]) -> Artist? {
        let name = firstRunText(r["title"])
        guard !name.isEmpty else { return nil }

        let subtitleTexts = collectText(in: r["subtitle"] ?? [:])
        if !subtitleTexts.isEmpty,
           !subtitleTexts.contains(where: isArtistTypeText) {
            return nil
        }

        guard let browseId = browseIdFromNavigationEndpoint(r["navigationEndpoint"] as? [String: Any])
                ?? browseIdFromTextRuns(r["title"]),
              !browseId.isEmpty else { return nil }
        let cover = thumbnailURL(from: r["thumbnail"] ?? r["thumbnailRenderer"])
        return Artist(id: browseId, platform: "ytmusic", name: name, imageURL: cover)
    }

    private func artistFromResponsiveRenderer(_ r: [String: Any]) -> Artist? {
        // Only match if overlay says it's an artist
        let cols = r["flexColumns"] as? [[String: Any]] ?? []
        let col1Runs = flexColumnRuns(cols, index: 1)
        let type = col1Runs.first?["text"] as? String ?? ""
        guard isArtistTypeText(type) else { return nil }

        let name = flexColumnRuns(cols, index: 0).first?["text"] as? String ?? ""
        guard !name.isEmpty else { return nil }
        let browseId = browseIdFromResponsiveRenderer(r)
        guard !browseId.isEmpty else { return nil }
        let cover = thumbnailURL(from: r["thumbnail"])
        return Artist(id: browseId, platform: "ytmusic", name: name, imageURL: cover)
    }

    private func artistFromTwoRowRenderer(_ r: [String: Any]) -> Artist? {
        let subtitle = subtitleParts(from: r["subtitle"])
        guard subtitle.contains(where: isArtistTypeText) else { return nil }
        let name = firstRunText(r["title"])
        guard !name.isEmpty else { return nil }
        let navEp = r["navigationEndpoint"] as? [String: Any]
        guard let browseId = browseIdFromNavigationEndpoint(navEp),
              !browseId.isEmpty else { return nil }
        let cover = thumbnailURL(from: r["thumbnailRenderer"])
        return Artist(id: browseId, platform: "ytmusic", name: name, imageURL: cover)
    }

    private func playlistFromTwoRowRenderer(_ r: [String: Any]) -> Playlist? {
        guard let playlistId = playlistIdFromTwoRowRenderer(r), !playlistId.isEmpty else { return nil }
        let name = firstRunText(r["title"])
        guard !name.isEmpty else { return nil }
        let cover = thumbnailURL(from: r["thumbnailRenderer"])
        let trackCount = PlaylistTrackCountParser.count(from: r["subtitle"]) ?? 0
        return Playlist(id: playlistId, platform: "ytmusic", name: name, coverURL: cover, trackCount: trackCount)
    }

    private func playlistFromResponsiveRenderer(_ r: [String: Any]) -> Playlist? {
        let cols = r["flexColumns"] as? [[String: Any]] ?? []
        let name = flexColumnRuns(cols, index: 0).first?["text"] as? String ?? ""
        guard !name.isEmpty else { return nil }
        let navEpR = r["navigationEndpoint"] as? [String: Any]
        let browseId = (navEpR?["browseEndpoint"] as? [String: Any])?["browseId"] as? String ?? ""
        let playlistId = browseId.hasPrefix("VL") ? String(browseId.dropFirst(2)) : browseId
        let cover = thumbnailURL(from: r["thumbnail"])
        let subtitleTexts = flexColumnRuns(cols, index: 1).compactMap { $0["text"] as? String }
        let trackCount = PlaylistTrackCountParser.count(fromTexts: subtitleTexts)
            ?? 0
        return Playlist(id: playlistId, platform: "ytmusic", name: name, coverURL: cover, trackCount: trackCount)
    }

    private func playlistIdFromTwoRowRenderer(_ r: [String: Any]) -> String? {
        let navEp = r["navigationEndpoint"] as? [String: Any]
        if let browseId = (navEp?["browseEndpoint"] as? [String: Any])?["browseId"] as? String,
           !browseId.isEmpty {
            return browseId.hasPrefix("VL") ? String(browseId.dropFirst(2)) : browseId
        }
        if let playlistId = (navEp?["watchEndpoint"] as? [String: Any])?["playlistId"] as? String,
           !playlistId.isEmpty {
            return playlistId
        }
        let overlay = r["overlay"] as? [String: Any]
        let overlayRenderer = overlay?["musicItemThumbnailOverlayRenderer"] as? [String: Any]
        let content = overlayRenderer?["content"] as? [String: Any]
        let pbr = content?["musicPlayButtonRenderer"] as? [String: Any]
        let playNav = pbr?["playNavigationEndpoint"] as? [String: Any]
        if let playlistId = (playNav?["watchEndpoint"] as? [String: Any])?["playlistId"] as? String,
           !playlistId.isEmpty {
            return playlistId
        }
        return nil
    }

    // MARK: - Navigation / structure helpers

    private func sectionListContents(in data: [String: Any]) -> [[String: Any]] {
        // Several possible paths to sectionListRenderer.contents
        let paths: [[String]] = [
            ["contents", "singleColumnBrowseResultsRenderer", "tabs"],
            ["contents", "tabbedSearchResultsRenderer", "tabs"],
            ["contents", "twoColumnBrowseResultsRenderer", "tabs"],
        ]
        for path in paths {
            var node: Any = data
            for key in path {
                if let d = node as? [String: Any], let next = d[key] { node = next }
                else { node = NSNull(); break }
            }
            if let tabs = node as? [[String: Any]] {
                let tabRenderer = tabs.first?["tabRenderer"] as? [String: Any]
                let tabContent = tabRenderer?["content"] as? [String: Any]
                let slc = tabContent?["sectionListRenderer"] as? [String: Any]
                if let contents = slc?["contents"] as? [[String: Any]] { return contents }
            }
        }
        if let contents = (((data["contents"] as? [String: Any])?["twoColumnBrowseResultsRenderer"] as? [String: Any])?["secondaryContents"] as? [String: Any])?["sectionListRenderer"] as? [String: Any],
           let sectionContents = contents["contents"] as? [[String: Any]] {
            return sectionContents
        }
        if let contents = (((data["contents"] as? [String: Any])?["twoColumnBrowseResultsRenderer"] as? [String: Any])?["tabs"] as? [[String: Any]])?.first?["tabRenderer"] as? [String: Any],
           let tabContent = contents["content"] as? [String: Any],
           let section = tabContent["sectionListRenderer"] as? [String: Any],
           let sectionContents = section["contents"] as? [[String: Any]] {
            return sectionContents
        }
        // Direct sectionListRenderer path
        if let slr = (data["contents"] as? [String: Any])?["sectionListRenderer"] as? [String: Any],
           let contents = slr["contents"] as? [[String: Any]] { return contents }
        return []
    }

    private func musicShelfContents(in section: [String: Any]) -> [[String: Any]] {
        (section["musicShelfRenderer"] as? [String: Any])?["contents"] as? [[String: Any]] ?? []
    }

    private func allMusicResponsiveListItemRenderers(in data: [String: Any]) -> [[String: Any]] {
        findRenderers(named: "musicResponsiveListItemRenderer", in: data)
    }

    private func allMusicTwoRowItemRenderers(in data: [String: Any]) -> [[String: Any]] {
        findRenderers(named: "musicTwoRowItemRenderer", in: data)
    }

    private func allMusicCardShelfRenderers(in data: [String: Any]) -> [[String: Any]] {
        findRenderers(named: "musicCardShelfRenderer", in: data)
    }

    private func findRenderers(named key: String, in value: Any) -> [[String: Any]] {
        var result: [[String: Any]] = []
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if let renderer = dict[key] as? [String: Any] {
                    result.append(renderer)
                }
                for child in dict.values { walk(child) }
            } else if let array = node as? [Any] {
                for child in array { walk(child) }
            }
        }
        walk(value)
        return result
    }

    private func flexColumnRuns(_ cols: [[String: Any]], index: Int) -> [[String: Any]] {
        guard index < cols.count,
              let col = cols[index]["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
              let text = col["text"] as? [String: Any],
              let runs = text["runs"] as? [[String: Any]]
        else { return [] }
        return runs
    }

    private func videoIdFromRenderer(_ r: [String: Any]) -> String {
        // Path 1: overlay
        if let overlay = r["overlay"] as? [String: Any],
           let content = (overlay["musicItemThumbnailOverlayRenderer"] as? [String: Any])?["content"] as? [String: Any],
           let pbr = content["musicPlayButtonRenderer"] as? [String: Any],
           let wep = (pbr["playNavigationEndpoint"] as? [String: Any])?["watchEndpoint"] as? [String: Any],
           let vid = wep["videoId"] as? String { return vid }
        // Path 2: flexColumns[0] runs navigationEndpoint
        let cols = r["flexColumns"] as? [[String: Any]] ?? []
        let runs0 = flexColumnRuns(cols, index: 0)
        for run in runs0 {
            if let vid = ((run["navigationEndpoint"] as? [String: Any])?["watchEndpoint"] as? [String: Any])?["videoId"] as? String {
                return vid
            }
        }
        if let menuItems = ((r["menu"] as? [String: Any])?["menuRenderer"] as? [String: Any])?["items"] as? [[String: Any]] {
            for item in menuItems {
                if let endpoint = (item["menuNavigationItemRenderer"] as? [String: Any])?["navigationEndpoint"] as? [String: Any],
                   let vid = (endpoint["watchEndpoint"] as? [String: Any])?["videoId"] as? String {
                    return vid
                }
                if let service = (item["menuServiceItemRenderer"] as? [String: Any])?["serviceEndpoint"] as? [String: Any],
                   let actions = (service["playlistEditEndpoint"] as? [String: Any])?["actions"] as? [[String: Any]],
                   let vid = actions.first?["removedVideoId"] as? String {
                    return vid
                }
            }
        }
        return ""
    }

    private func browseIdFromResponsiveRenderer(_ r: [String: Any]) -> String {
        if let browseId = browseIdFromNavigationEndpoint(r["navigationEndpoint"] as? [String: Any]) {
            return browseId
        }

        let cols = r["flexColumns"] as? [[String: Any]] ?? []
        for run in flexColumnRuns(cols, index: 0) {
            if let browseId = browseIdFromNavigationEndpoint(run["navigationEndpoint"] as? [String: Any]) {
                return browseId
            }
        }
        if let browseId = browseIdFromTextRuns((cols.first?["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any])?["text"]) {
            return browseId
        }
        return ""
    }

    private func browseIdFromNavigationEndpoint(_ endpoint: [String: Any]?) -> String? {
        guard let endpoint,
              let browseId = (endpoint["browseEndpoint"] as? [String: Any])?["browseId"] as? String,
              !browseId.isEmpty else { return nil }
        return browseId
    }

    private func browseIdFromTextRuns(_ obj: Any?) -> String? {
        guard let dict = obj as? [String: Any] else { return nil }
        if let browseId = browseIdFromNavigationEndpoint(dict["navigationEndpoint"] as? [String: Any]) {
            return browseId
        }
        for run in dict["runs"] as? [[String: Any]] ?? [] {
            if let browseId = browseIdFromNavigationEndpoint(run["navigationEndpoint"] as? [String: Any]) {
                return browseId
            }
        }
        return nil
    }

    private func setVideoIdFromRenderer(_ r: [String: Any]) -> String? {
        guard let menuItems = ((r["menu"] as? [String: Any])?["menuRenderer"] as? [String: Any])?["items"] as? [[String: Any]]
        else { return nil }
        for item in menuItems {
            if let service = (item["menuServiceItemRenderer"] as? [String: Any])?["serviceEndpoint"] as? [String: Any],
               let actions = (service["playlistEditEndpoint"] as? [String: Any])?["actions"] as? [[String: Any]],
               let setVideoId = actions.first?["setVideoId"] as? String,
               !setVideoId.isEmpty {
                return setVideoId
            }
        }
        return nil
    }

    private func carouselTitle(_ carousel: [String: Any]) -> String {
        let header = carousel["header"] as? [String: Any] ?? [:]
        if let basic = header["musicCarouselShelfBasicHeaderRenderer"] as? [String: Any] {
            return firstRunText(basic["title"])
        }
        if let immersive = header["musicImmersiveCarouselShelfRenderer"] as? [String: Any] {
            return firstRunText(immersive["title"])
        }
        return ""
    }

    private func albumCoverFromHeader(_ data: [String: Any]) -> String {
        let header = data["header"] as? [String: Any] ?? [:]
        for key in ["musicImmersiveHeaderRenderer", "musicDetailHeaderRenderer"] {
            if let h = header[key] as? [String: Any] {
                return thumbnailURL(from: h["thumbnail"] ?? h["thumbnailRenderer"])
            }
        }
        return ""
    }

    private func albumNameFromHeader(_ data: [String: Any]) -> String {
        let header = data["header"] as? [String: Any] ?? [:]
        for key in ["musicImmersiveHeaderRenderer", "musicDetailHeaderRenderer"] {
            if let h = header[key] as? [String: Any] { return firstRunText(h["title"]) }
        }
        return ""
    }

    private func playlistTrackCount(from data: [String: Any]) -> Int? {
        PlaylistTrackCountParser.count(from: data)
    }

    private func uniquedPlaylists(_ playlists: [Playlist]) -> [Playlist] {
        var seen: Set<String> = []
        var result: [Playlist] = []
        for playlist in playlists where !playlist.id.isEmpty {
            if seen.insert(playlist.id).inserted {
                result.append(playlist)
            }
        }
        return result
    }

    // MARK: - Generic helpers

    private func firstRunText(_ obj: Any?) -> String {
        guard let d = obj as? [String: Any] else { return "" }
        if let simple = d["simpleText"] as? String { return simple }
        guard let runs = d["runs"] as? [[String: Any]] else { return "" }
        return runs.compactMap { $0["text"] as? String }.joined()
    }

    private func subtitleParts(from obj: Any?) -> [String] {
        guard let d = obj as? [String: Any],
              let runs = d["runs"] as? [[String: Any]]
        else { return [] }
        return runs.compactMap { $0["text"] as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "•" }
    }

    private func isArtistTypeText(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("artist") || text.contains("艺术家") || text.contains("艺人") || text.contains("歌手")
    }

    private func collectText(in value: Any) -> [String] {
        var result: [String] = []
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if let text = dict["text"] as? String {
                    result.append(text)
                }
                if let simple = dict["simpleText"] as? String {
                    result.append(simple)
                }
                for child in dict.values { walk(child) }
            } else if let array = node as? [Any] {
                for child in array { walk(child) }
            }
        }
        walk(value)
        return result
    }

    private func thumbnailURL(from obj: Any?) -> String {
        if let d = obj as? [String: Any] {
            // musicThumbnailRenderer wrapping
            if let inner = d["musicThumbnailRenderer"] as? [String: Any] {
                return thumbnailURL(from: inner)
            }
            // thumbnail.thumbnails array
            if let thumbs = (d["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]] {
                return thumbs.last?["url"] as? String ?? ""
            }
            // direct thumbnails array
            if let thumbs = d["thumbnails"] as? [[String: Any]] {
                return thumbs.last?["url"] as? String ?? ""
            }
        }
        return ""
    }

    private func lastThumbnailURL(_ obj: [String: Any]?) -> String {
        guard let obj else { return "" }
        if let thumbs = obj["thumbnails"] as? [[String: Any]] {
            return thumbs.last?["url"] as? String ?? ""
        }
        return thumbnailURL(from: obj)
    }

    private func parseDurationText(_ text: String) -> Int {
        let parts = text.components(separatedBy: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        switch parts.count {
        case 2: return (parts[0] * 60 + parts[1]) * 1000
        case 3: return (parts[0] * 3600 + parts[1] * 60 + parts[2]) * 1000
        default: return 0
        }
    }
}

// MARK: - Error

public enum YTMusicClientError: LocalizedError {
    case badURL(String)
    case httpError(Int)
    case noStreamURL(String)
    case ytDlpNotFound
    case ytDlpFailed(String)

    public var errorDescription: String? {
        switch self {
        case .badURL(let u):       return "无效 URL：\(u)"
        case .httpError(let c):    return "HTTP 错误 \(c)"
        case .noStreamURL(let id): return "无法获取歌曲流地址（\(id)）"
        case .ytDlpNotFound:       return "找不到 yt-dlp，请先安装：brew install yt-dlp 或 python3 -m pip install -U yt-dlp"
        case .ytDlpFailed(let msg):
            return msg.isEmpty ? "yt-dlp 获取歌曲流地址失败" : "yt-dlp 获取歌曲流地址失败：\(msg)"
        }
    }
}
