# Omnia — Swift 迁移完整计划

> 文档用途：作为 AI vibe coding 的阶段性提示词上下文。每个 Phase 为一个独立的实现单元，可单独喂给 AI。  
> 目标技术栈：Swift 5.9+ / SwiftUI / macOS 13+  
> 参考源代码：当前 Python/PyQt6 版本（`/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/`）

---

## 项目总览

**Omnia** 是一款 macOS 原生音乐播放器，聚合 Spotify、YouTube Music、网易云音乐三个平台。核心特点：
- 不使用任何官方公开 API，通过逆向内部 HTTP 协议实现全功能
- 自绘 UI，深色现代风格（Spotify 桌面端风格）
- 登录通过隐藏 WebView 自动捕获 Cookie/Token

### 技术栈映射（Python → Swift）

| 功能 | Python 方案 | Swift 方案 |
|------|------------|-----------|
| UI 框架 | PyQt6 | SwiftUI |
| 网络请求 | httpx (async) | URLSession (async/await) |
| WebView 登录 | QWebEngineWidgets (Chromium) | WKWebView (WebKit) + Safari-like UA |
| 数据库 | aiosqlite / SQLite | GRDB.swift |
| 加密（网易云） | pycryptodome (AES/RSA) | CryptoKit + CommonCrypto |
| Spotify TOTP | hmac + hashlib | CryptoKit HMAC-SHA1 |
| Spotify 音频 | librespot subprocess | librespot binary subprocess（不变） |
| VLC 播放 | python-vlc | VLCKit (VideoLAN 官方) |
| yt-dlp | subprocess | subprocess（不变） |
| 封面颜色提取 | colorthief | Core Image CIAreaAverage |
| macOS 锁屏 | PyObjC MediaPlayer | MediaPlayer framework 原生 |
| macOS 状态栏 | PyObjC AppKit | AppKit / SwiftUI MenuBarExtra |
| 歌词解析 | 自实现 LRC/TTML | 自实现 Swift struct |
| 异步 | asyncio + qasync | Swift async/await + Combine |
| 打包 | PyInstaller (.app 约 300MB) | Xcode Archive (.app 约 30MB) |

### 依赖关系图

```
P0 (项目骨架)
  └── P1 (数据模型)
        ├── P2 (数据库层)
        ├── P3 (工具库: LRC/TTML/颜色)
        ├── P4 (网易云平台)
        ├── P5 (Spotify 平台)
        ├── P6 (YouTube Music 平台)
        └── P7 (音频后端: VLCKit + librespot)
              └── P8 (播放器状态机 + 队列)
                    └── P9 (AppController — 业务逻辑核心)
                          ├── P10 (macOS 系统集成)
                          └── P11 (UI 主题 + 主窗口骨架)
                                ├── P12 (登录 WebView 对话框)
                                ├── P13 (UI 通用组件)
                                └── P14 (页面: Home/Search/Library/Settings/Artist/Standby)
                                      └── P15 (完整连线 + 队列面板 + 歌单选择器)
                                            └── P16 (自动更新 + 打包)
```

---

## Phase 0 — Xcode 项目骨架 + 依赖管理

### 目标
创建 Xcode 项目，配置 Swift Package Manager 依赖，建立目录结构。

### 项目配置
- **项目名**: `Omnia`
- **Bundle ID**: `com.omnia.player`（或自定义）
- **最低系统版本**: macOS 13.0
- **语言**: Swift 5.9
- **UI**: SwiftUI

### SPM 依赖（Package.swift 或 Xcode Package Dependencies）

```swift
dependencies: [
    // SQLite ORM
    .package(url: "https://github.com/groue/GRDB.swift", from: "6.0.0"),
    
    // VLC 播放（注意：VLCKit 需要手动集成二进制，见下方说明）
    // VLCKit: https://code.videolan.org/videolan/VLCKit
    // 用 CocoaPods 或手动 xcframework
    
    // 可选：KeychainAccess（存储加密凭证）
    .package(url: "https://github.com/kishikawakatsumi/KeychainAccess", from: "4.2.1"),
]
```

> **VLCKit 说明**：VLCKit 目前最稳定的集成方式是从官网下载预编译 xcframework，拖入 Xcode。SPM 支持尚不完善，建议手动集成。

### 目录结构

```
Omnia/
├── OmniaApp.swift              # @main App 入口
├── Models/
│   ├── Track.swift
│   ├── Playlist.swift
│   ├── LyricLine.swift
│   ├── PlayerState.swift
│   └── Artist.swift
├── DB/
│   ├── AppDatabase.swift       # GRDB 数据库初始化
│   └── AppRepository.swift     # 数据访问层
├── Utils/
│   ├── LRCParser.swift
│   ├── TTMLParser.swift
│   └── DominantColor.swift     # Core Image 颜色提取
├── Platforms/
│   ├── PlatformProtocol.swift  # AbstractPlatform 协议
│   ├── Netease/
│   │   ├── NeteaseAuth.swift
│   │   ├── NeteaseCrypto.swift
│   │   ├── NeteaseClient.swift
│   │   └── NeteaseLyrics.swift
│   ├── Spotify/
│   │   ├── SpotifyAuth.swift
│   │   ├── SpotifyClient.swift
│   │   ├── LibrespotBridge.swift
│   │   └── SpotifyLyrics.swift
│   └── YTMusic/
│       ├── YTMusicAuth.swift
│       ├── YTMusicClient.swift
│       └── YTMusicLyrics.swift
├── Audio/
│   ├── VLCBackend.swift
│   └── LibrespotBackend.swift
├── Core/
│   ├── PlayerStateMachine.swift
│   ├── PlayQueue.swift
│   ├── LyricsEngine.swift
│   └── AppController.swift
├── macOS/
│   ├── MacOSMediaHandler.swift # MPNowPlayingInfoCenter + 状态栏
│   └── StatusItemManager.swift
├── UI/
│   ├── Theme.swift             # 颜色/字体常量
│   ├── MainWindowView.swift    # 主窗口布局
│   ├── Components/
│   │   ├── SidebarView.swift
│   │   ├── NowPlayingBarView.swift
│   │   ├── LyricsView.swift
│   │   ├── TrackListView.swift
│   │   ├── TrackRowView.swift
│   │   ├── CoverArtView.swift
│   │   ├── QueuePanelView.swift
│   │   ├── PlaylistPickerView.swift
│   │   └── LoginWebView.swift
│   └── Pages/
│       ├── HomePageView.swift
│       ├── SearchPageView.swift
│       ├── LibraryPageView.swift
│       ├── SettingsPageView.swift
│       ├── ArtistPageView.swift
│       └── StandbyPageView.swift
└── Resources/
    ├── Assets.xcassets
    └── Fonts/                  # Inter 字体文件
```

### 验证标准
- Xcode 项目能编译通过（空壳）
- GRDB.swift 可 import
- VLCKit xcframework 已链接

---

## Phase 1 — 数据模型

### 目标
定义所有跨平台使用的 Swift 数据结构，对应 Python `core/models.py`。

### 参考源文件
`/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/core/models.py`

### 实现内容

```swift
// Models/Track.swift
struct Track: Identifiable, Equatable, Hashable, Codable {
    let id: String
    let platform: String           // "spotify" | "ytmusic" | "netease"
    var title: String
    var artist: String
    var artists: [String]
    var album: String
    var albumCoverURL: String
    var durationMs: Int
    var isExplicit: Bool = false
    var streamURL: String? = nil
    var playlistItemId: String? = nil  // Spotify playlist uid
}

// Models/LyricLine.swift
struct LyricWord: Equatable {
    let startMs: Int
    let endMs: Int
    let text: String
}

struct LyricLine: Identifiable, Equatable {
    let id = UUID()
    let startMs: Int
    let endMs: Int
    let text: String
    var words: [LyricWord]        // 空数组 = 仅逐行模式
}

// Models/Playlist.swift
struct Playlist: Identifiable, Equatable {
    let id: String
    let platform: String
    var name: String
    var coverURL: String
    var trackCount: Int
    var tracks: [Track] = []
}

// Models/PlayerState.swift
enum PlaybackStatus: String, Equatable {
    case idle, loading, playing, paused, error
}

enum RepeatMode: String, Equatable, CaseIterable {
    case none, one, all
}

struct PlayerState: Equatable {
    var status: PlaybackStatus = .idle
    var currentTrack: Track? = nil
    var positionMs: Int = 0
    var durationMs: Int = 0
    var volume: Int = 70
    var shuffle: Bool = false
    var repeatMode: RepeatMode = .none
}

// Models/Artist.swift
struct Artist: Identifiable, Equatable {
    let id: String
    let platform: String
    var name: String
    var imageURL: String
}

// Models/Album.swift
struct Album: Identifiable, Equatable {
    let id: String
    let platform: String
    var name: String
    var artist: String
    var coverURL: String
    var trackCount: Int
    var year: String
}

// Models/UpdateStatus.swift
struct UpdateStatus {
    var available: Bool = false
    var remoteShort: String = ""
    var commitMessages: [String] = []
    var error: String? = nil
}
```

### 验证标准
- 所有结构体编译通过
- Track/Playlist/LyricLine 可 Codable 序列化

---

## Phase 2 — 数据库层（GRDB）

### 目标
实现 SQLite 数据持久化，对应 Python `db/repository.py` + `db/schema.sql`。

### 参考源文件
`/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/db/repository.py`, `/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/db/schema.sql`

### 数据库 Schema

```sql
-- 与 Python 版完全一致
CREATE TABLE IF NOT EXISTS credentials (
    platform    TEXT PRIMARY KEY,
    data        BLOB NOT NULL,      -- AES-256-GCM 加密的 JSON
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
```

### 实现内容

```swift
// DB/AppDatabase.swift
import GRDB

final class AppDatabase {
    static let shared = AppDatabase()
    private var dbQueue: DatabaseQueue!
    
    func setup() async throws {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Omnia/omnia.db")
        dbQueue = try DatabaseQueue(path: url.path)
        try await migrate()
    }
    
    private func migrate() async throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            // 建表语句（见上方 schema）
        }
        try await migrator.migrate(dbQueue)
    }
}

// DB/AppRepository.swift
actor AppRepository {
    // 凭证存取（AES-256-GCM 加密，key 存 Keychain）
    func saveCredential(_ platform: String, data: [String: String]) async throws
    func loadCredential(_ platform: String) async throws -> [String: String]?
    func deleteCredential(_ platform: String) async throws
    
    // 设置
    func getSetting(_ key: String) async throws -> String?
    func setSetting(_ key: String, value: String) async throws
    
    // 播放历史
    func addPlayHistory(track: Track) async throws
    func getPlayHistory(limit: Int) async throws -> [Track]
}
```

**加密方案**：凭证数据用 AES-256-GCM 加密后存入 `data` 字段，加密 key 存 Keychain（使用 KeychainAccess 库）。Python 版用 AES-256，Swift 版改用 CryptoKit `AES.GCM`，两者不兼容但迁移时无需兼容旧数据（用户重新登录）。

### 验证标准
- 数据库文件在 `~/Library/Application Support/Omnia/omnia.db` 正确创建
- 凭证写入/读取/删除正常
- 设置读写正常

---

## Phase 3 — 工具库（歌词解析 + 颜色提取）

### 目标
实现 LRC、TTML 歌词格式解析器，和封面主色提取。对应 Python `utils/lrc_parser.py`、`utils/ttml_parser.py`、`colorthief`。

### 参考源文件
`/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/utils/lrc_parser.py`, `/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/core/lyrics_engine.py`

### 实现内容

#### LRC 解析器

LRC 格式：`[mm:ss.xx] 歌词文本`，逐行时间轴。

```swift
// Utils/LRCParser.swift
struct LRCParser {
    static func parse(_ text: String) -> [LyricLine] {
        // 解析 [00:12.34] 格式的时间戳
        // 返回按时间排序的 LyricLine 数组
        // words 为空（纯逐行格式）
    }
}
```

#### TTML 解析器

TTML 格式：XML，Spotify 和网易云逐字歌词使用。

```swift
// Utils/TTMLParser.swift
// 使用 XMLParser (Foundation) 解析
struct TTMLParser: NSObject, XMLParserDelegate {
    static func parse(_ data: Data) -> [LyricLine]
    // 提取 <p begin="..."> 和 <span begin="..."> 的时间和文本
    // begin/end 格式: "00:12.340" 或 "PT12.340S"
}
```

#### 封面颜色提取

```swift
// Utils/DominantColor.swift
import CoreImage

struct DominantColor {
    static func extract(from imageData: Data) async -> (Int, Int, Int)? {
        // 用 CIFilter "CIAreaAverage" 提取主色
        // 在后台线程执行
        await Task.detached(priority: .utility) {
            guard let ciImage = CIImage(data: imageData) else { return nil }
            let filter = CIFilter(name: "CIAreaAverage", parameters: [
                kCIInputImageKey: ciImage,
                kCIInputExtentKey: CIVector(cgRect: ciImage.extent)
            ])
            // 读取输出像素 RGBA → 返回 (r, g, b)
        }.value
    }
}
```

#### 歌词引擎

```swift
// Core/LyricsEngine.swift
// 根据当前播放位置，返回当前行 index 和当前字 index
// 对应 Python core/lyrics_engine.py
struct LyricsEngine {
    var lines: [LyricLine] = []
    
    func currentLineIndex(positionMs: Int) -> Int?
    func currentWordIndex(lineIndex: Int, positionMs: Int) -> Int?
    func progressInLine(lineIndex: Int, positionMs: Int) -> Double  // 0.0-1.0
}
```

### 验证标准
- LRC 解析：给定标准 LRC 文本，返回正确的时间戳和歌词
- TTML 解析：给定 Spotify 返回的 TTML XML，正确解析逐字时间
- 颜色提取：给定一张图片 Data，返回非零 RGB 值

---

## Phase 4 — 网易云平台

### 目标
实现网易云音乐的完整平台层：加密算法、认证、搜索、播放、歌词、歌单。对应 Python `platforms/netease/`。

> **重要**：Swift 版本**直接调用网易云 API**，不再使用 Node.js `NeteaseCloudMusicApi` 代理。Python 版有 `crypto.py` 实现了全套加密算法，直接移植。

### 参考源文件
`/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/platforms/netease/crypto.py`, `/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/platforms/netease/client.py`, `/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/platforms/netease/auth.py`, `/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/platforms/netease/lyrics.py`

### 4.1 加密算法 `NeteaseCrypto.swift`

#### weapi 加密
```
1. JSON 序列化 params
2. 生成随机 16 字节密钥 (randomKey)
3. AES-128-CBC 加密: key="0CoJUm6Qyw8W8jud", iv="0102030405060708"
4. 再用 randomKey AES-128-CBC 加密步骤3的结果
5. RSA 加密 randomKey（固定模数/指数，见 Python 版）
6. 返回 {params: base64(...), encSecKey: hex(...)}
```

```swift
// Platforms/Netease/NeteaseCrypto.swift
import CryptoKit
import CommonCrypto  // AES-CBC (CryptoKit 不支持 CBC，用 CommonCrypto)

struct NeteaseCrypto {
    static func weapiEncrypt(_ params: [String: Any]) throws -> [String: String]
    static func eapiEncrypt(url: String, params: [String: Any]) throws -> [String: String]
    static func linuxapiEncrypt(_ params: [String: Any]) throws -> [String: String]
    
    // 内部方法
    private static func aesCBCEncrypt(data: Data, key: Data, iv: Data) -> Data
    private static func rsaEncrypt(_ data: Data) -> String  // 使用固定模数 BigInteger
}
```

**RSA 实现**：Swift 标准库无 BigInteger，需手动实现模幂运算 (`pow(base, exp, mod)`)，或引入 [BigInt Swift 库](https://github.com/attaswift/BigInt)（SPM 可用）。RSA 密钥是固定的（不需要 SecKey）。

#### eapi 加密
```
固定 key: "e82ckenh8dichen8"
MD5 签名 + AES-128-ECB
```

### 4.2 认证 `NeteaseAuth.swift`

```swift
// 登录方式：WKWebView 加载 music.163.com，捕获 MUSIC_U + __csrf Cookie
// 与 Python 版逻辑相同

actor NeteaseAuth {
    func login(windowScene: NSWindowScene?) async -> [String: String]?
    func loadCookies() async throws -> [String: String]?
    func logout() async throws
    func getDisplayName() async -> String?
    
    // Cookie 捕获：在 WKWebView loadFinished 后
    // 监听 WKHTTPCookieStore 获取 MUSIC_U + __csrf
}
```

### 4.3 客户端 `NeteaseClient.swift`

所有请求均使用 weapi 加密，通过 URLSession POST。

```swift
actor NeteaseClient: PlatformProtocol {
    let cookies: [String: String]  // MUSIC_U + __csrf
    
    // PlatformProtocol
    func search(query: String, limit: Int) async throws -> [Track]
    func searchAlbums(query: String, limit: Int) async throws -> [Album]
    func getAlbumTracks(albumId: String) async throws -> [Track]
    func getStreamURL(track: Track) async throws -> String
    func getLyrics(track: Track) async throws -> [LyricLine]
    func getHome() async throws -> [(String, [Track])]
    func getLibraryPlaylists() async throws -> [Playlist]
    func getPlaylistTracks(playlistId: String) async throws -> [Track]
    func getRecommendations(track: Track) async throws -> [Track]
    func searchArtist(name: String) async throws -> Artist?
    func getArtistTopTracks(artistId: String, limit: Int) async throws -> [Track]
    func addTrackToPlaylist(playlistId: String, track: Track) async throws -> Bool
    func removeTrackFromPlaylist(playlistId: String, track: Track) async throws -> Bool
    func getAddablePlaylists() async throws -> [Playlist]
}
```

**关键 API 端点**（直接调用，无代理）：
```
搜索:      POST https://music.163.com/weapi/cloudsearch/pc
流地址:    POST https://music.163.com/weapi/song/enhance/player/url/v1
歌词:      POST https://music.163.com/weapi/song/lyric/v1
每日推荐:  POST https://music.163.com/weapi/v3/discovery/recommend/songs
我的歌单:  POST https://music.163.com/weapi/user/playlist
专辑详情:  POST https://music.163.com/weapi/v1/album/{id}
```

**Cookie 构造**：每次请求在 Header 中添加：
```
Cookie: MUSIC_U=xxx; __csrf=xxx
```
不使用 URLSession 共享 Cookie，手动构造。

### 4.4 歌词 `NeteaseLyrics.swift`

```swift
// 调用 /weapi/song/lyric/v1 接口
// 返回 JSON 含:
//   lrc.lyric  → LRC 格式逐行歌词
//   klyric.lyric → 逐字 JSON 格式歌词
// 优先用逐字 (klyric)，降级到逐行 (lrc)

struct NeteaseLyrics {
    static func fetch(trackId: String, client: NeteaseClient) async throws -> [LyricLine]
    private static func parseKlyric(_ text: String) -> [LyricLine]  // 逐字 JSON
    private static func parseLrc(_ text: String) -> [LyricLine]     // 逐行 LRC
}
```

### 验证标准
- weapi_encrypt 输出与 Python 版一致（用已知测试向量验证）
- 搜索"周杰伦"返回结果
- 播放一首网易云歌曲（返回可访问的 CDN URL）
- 歌词接口返回正确数据

---

## Phase 5 — Spotify 平台

### 目标
实现 Spotify 完整平台层：TOTP 鉴权、Partner API（GraphQL）、librespot 桥接、歌词。对应 Python `platforms/spotify/`。

### 参考源文件
`/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/platforms/spotify/auth.py`, `/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/platforms/spotify/client.py`, `/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/platforms/spotify/lyrics.py`, `/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/platforms/spotify/librespot_bridge.py`

### 5.1 鉴权 `SpotifyAuth.swift`

#### TOTP 生成（对应 Python `auth.py:240-308`）

```swift
// Platforms/Spotify/SpotifyAuth.swift
import CryptoKit

struct SpotifyAuth {
    // 内置 fallback secret（与 Python _TOTP_SECRET_RAW 相同）
    private static let totpSecretRaw: [Int] = [12, 56, 76, 33, 88, 44, 88, 33, 78, 78, 11, 66, 22, 22, 55, 69, 54]
    
    // XOR 混淆解码（对应 _totp_secret_from_bytes）
    private static func decodeTotpSecret(_ values: [Int]) -> Data {
        let xored = values.enumerated().map { idx, val in val ^ ((idx % 33) + 9) }
        let str = xored.map { String($0) }.joined()
        return Data(str.utf8)
    }
    
    // HMAC-SHA1 TOTP（RFC 6238，30s 步长，6位）
    static func generateTOTP(timestamp: Int, secret: Data) -> String {
        let counter = UInt64(timestamp / 30).bigEndian
        var counterBytes = withUnsafeBytes(of: counter) { Data($0) }
        let key = SymmetricKey(data: secret)
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: counterBytes, using: key)
        let digest = Data(mac)
        let offset = Int(digest[digest.count - 1] & 0x0F)
        let code = digest[offset..<offset+4].withUnsafeBytes {
            $0.load(as: UInt32.self).bigEndian
        } & 0x7FFFFFFF
        return String(format: "%06d", code % 1_000_000)
    }
}
```

#### Token 获取流程（对应 Python `auth.py:80-188`）

```swift
actor SpotifyAuth {
    private var cachedToken: String?
    private var tokenExpiresAt: Date = .distantPast
    private var totpSecret: Data?
    private var totpVersion: Int = 5
    
    // 1. 获取服务器时间
    func getServerTime() async -> Int?
    
    // 2. 从 web-player JS bundle 提取 TOTP 配置
    //    - GET https://open.spotify.com/
    //    - 找到 web-player.xxx.js URL
    //    - 正则匹配 {secret: '...', version: N}
    func getTotpConfig() async -> (Data, Int)
    
    // 3. 构造 token 请求
    //    GET https://open.spotify.com/api/token
    //    Params: reason=transport&productType=web-player&totp=xxx&totpServer=xxx&totpVer=N
    //    Cookie: sp_dc=xxx
    func getAccessToken() async throws -> String
    
    // 4. 403 fallback: 用 WKWebView 加载 token URL，读取 document.body.innerText
    func getAccessTokenViaWebView(params: [String: String]) async throws -> [String: Any]
    
    // 5. WebView 登录（捕获 sp_dc cookie）
    func login(windowScene: NSWindowScene?) async -> String?
    
    // 获取显示名（访问 accounts.spotify.com/en/status）
    func getDisplayName() async -> String?
}
```

**TOTP Config 提取**（正则，对应 Python `auth.py:280-293`）：
```swift
let pattern = /\{\s*secret\s*:\s*(?<secret>'[^']*'|"[^"]*")\s*,\s*version\s*:\s*(?<version>\d+)\s*\}/
```

### 5.2 Client Token + Partner API `SpotifyClient.swift`

```swift
actor SpotifyClient: PlatformProtocol {
    private let auth: SpotifyAuth
    private var clientToken: String?
    private var clientVersion: String?
    private var deviceId: String = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    
    // 静态 hash 缓存（对应 Python _op_hash_cache class variable）
    private static var opHashCache: [String: String] = [:]
    
    // 1. 获取 client token
    //    POST https://clienttoken.spotify.com/v1/clienttoken
    //    Body: {client_data: {client_version, client_id, js_sdk_data: {...}}}
    func getClientToken() async throws -> String?
    
    // 2. 从 web-player bundle 提取 operation hashes
    //    正则: new\s+\w[\w$.]*\s*\(\s*"([^"]{2,60})"\s*,\s*"(?:query|mutation)"\s*,\s*"([0-9a-f]{64})"\s*,\s*null\s*\)
    func getPartnerHash(for operation: String) async throws -> String?
    
    // Partner API 通用方法
    func partnerQuery(operation: String, variables: [String: Any]) async throws -> [String: Any]
    
    // PlatformProtocol 实现（与网易云接口一致）
    func search(query: String, limit: Int) async throws -> [Track]
    func searchAlbums(query: String, limit: Int) async throws -> [Album]
    func getAlbumTracks(albumId: String) async throws -> [Track]
    func getStreamURL(track: Track) async throws -> String  // 返回 "spotify:track:{id}"
    func getLyrics(track: Track) async throws -> [LyricLine]
    func getHome() async throws -> [(String, [Track])]
    func getLibraryPlaylists() async throws -> [Playlist]
    func getPlaylistTracks(playlistId: String) async throws -> [Track]
    func getRecommendations(track: Track) async throws -> [Track]
    func searchArtist(name: String) async throws -> Artist?
    func getArtistTopTracks(artistId: String, limit: Int) async throws -> [Track]
    func addTrackToPlaylist(playlistId: String, track: Track) async throws -> Bool
    func removeTrackFromPlaylist(playlistId: String, track: Track) async throws -> Bool
    func getAddablePlaylists() async throws -> [Playlist]
}
```

**固定常量**（对应 Python `client.py`）：
```swift
let partnerURL = "https://api-partner.spotify.com/pathfinder/v2/query"
let clientTokenURL = "https://clienttoken.spotify.com/v1/clienttoken"
let webClientID = "d8a5ed958d274c2e8ee717e6a4b0971d"
let searchSuggestionsHash = "556f5a15b2fdd3a7113ffd377ad9805e38a3a27b8bb1ca7d6d76bad54aa8ee12"
let addToPlaylistFallbackHash = "47b2a1234b17748d332dd0431534f22450e9ecbb3d5ddcdacbd83368636a0990"
```

**Partner Headers**：
```swift
func partnerHeaders(token: String, clientToken: String?) -> [String: String] {
    var h = [
        "Authorization": "Bearer \(token)",
        "Accept": "application/json",
        "Content-Type": "application/json;charset=UTF-8",
        "Origin": "https://open.spotify.com",
        "Referer": "https://open.spotify.com/",
        "User-Agent": webUA,
        "App-Platform": "WebPlayer",
        "Spotify-App-Version": "1.2.50.248",
    ]
    if let ct = clientToken { h["client-token"] = ct }
    return h
}
```

### 5.3 librespot 桥接 `LibrespotBridge.swift`

```swift
// 对应 Python platforms/spotify/librespot_bridge.py
// librespot-python 在 Swift 不可用，改为：
// 1. 调用系统中已安装的 librespot 二进制（Rust 版）
// 2. 或打包 librespot 二进制到 app bundle Resources/

actor LibrespotBridge {
    private var credentialsPath: String  // ~/.omnia/spotify_credentials.json
    private var hasActiveSession: Bool = false
    
    // 用 sp_dc access token 创建 session（写入 credentials.json）
    func createSessionWithToken(_ token: String) async throws
    
    // 检查 credentials.json 是否存在且有效
    func hasSession() -> Bool
    
    // OAuth 流程（打开系统浏览器）
    func createSessionOAuth(urlCallback: @escaping (String) -> Void) async throws
    
    func close()
}
```

### 5.4 歌词 `SpotifyLyrics.swift`

```swift
// GET https://spclient.wg.spotify.com/color-lyrics/v2/track/{trackId}
// Headers: Authorization, App-Platform: WebPlayer
// 返回 TTML 格式逐字歌词
// 降级到 lyrics.lines[] 逐行

struct SpotifyLyrics {
    static func fetch(trackId: String, token: String) async throws -> [LyricLine]
}
```

### 验证标准
- TOTP 生成值与 Python 版一致（给定相同时间戳和 secret）
- Access token 能正常获取（不触发 403）
- Partner API 搜索返回结果
- 歌词接口返回数据

---

## Phase 6 — YouTube Music 平台

### 目标
实现 YouTube Music 平台层：WebView 登录 + Cookie 捕获、API 从零重实现（替代 ytmusicapi Python 库）、歌词。

> **核心难点**：`ytmusicapi` Python 库无 Swift 等价，需根据其源码重新实现需要的 API 方法。

### 参考源文件
`/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/platforms/ytmusic/auth.py`, `/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/platforms/ytmusic/client.py`, `/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/platforms/ytmusic/lyrics.py`

### 6.1 认证 `YTMusicAuth.swift`

#### WKWebView 登录策略

WKWebView 底层是 WebKit，与 Safari 使用同一引擎（JavaScriptCore）。使用 **Safari-like User-Agent**，使 UA 声明与 JS 引擎行为保持一致：Google 检测 Chrome UA 时会验证 `window.chrome`、V8 特性等 Chromium 专属 API，而 WKWebView 并不具备——UA 和引擎的不匹配反而更容易被检测到。Safari UA 则与 WKWebView 的实际行为一致，不存在这种矛盾。

**UA 字符串**：
```
Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15
```

> **注意**：Google 对 WKWebView 登录的限制是概率性的，不同账号/网络环境下表现不同。若登录被拦截，备用方案是在界面上提供"手动输入 Cookie"入口（界面预留，不默认展示）。

```swift
// Safari-like UA（与 WKWebView 实际引擎一致，避免 Chrome UA 的引擎不匹配检测）
private let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"

actor YTMusicAuth {
    private let repo: AppRepository
    
    func login(windowScene: NSWindowScene?) async -> [String: String]?
    // WKWebView 加载 music.youtube.com，customUserAgent = safariUA
    // 捕获目标 Cookie: __Secure-3PAPISID, SAPISID, __Secure-1PAPISID
    // 构建 ytmusicapi 格式的 headers dict
    
    func loadAuth() async throws -> [String: String]?
    func logout() async throws
    func getDisplayName() async -> String?
    
    // 构造 headers（对应 Python _build_headers）
    // 注意：headers 中的 User-Agent 仍使用 safariUA 保持一致性
    func buildHeaders(cookies: [String: String]) -> [String: String]
    // 包含: User-Agent(safariUA), Cookie, Authorization(SAPISIDHASH), X-Goog-AuthUser, x-origin
    
    // SAPISIDHASH 计算（对应 Python _make_sapisidhash）
    func makeSapisidhash(sapisid: String) -> String
    // SHA1("{timestamp} {sapisid} https://music.youtube.com")
}
```

### 6.2 YTMusic 客户端 `YTMusicClient.swift`

YouTube Music 内部 API 基础端点：
```
POST https://music.youtube.com/youtubei/v1/{endpoint}?key={INNERTUBE_KEY}
Headers: 需要 Cookie + X-Goog-AuthUser + Authorization(SAPISIDHASH) + x-origin
Body: {context: {...}, ...method-specific params...}
```

**Context 模板**（从 ytmusicapi 源码提取）：
```json
{
  "context": {
    "client": {
      "clientName": "WEB_REMIX",
      "clientVersion": "1.20240101.01.00",
      "hl": "zh-CN",
      "gl": "CN"
    },
    "user": {}
  }
}
```

**INNERTUBE_KEY**（ytmusicapi 内置）：通过环境变量 `INNERTUBE_API_KEY` 传入，不硬编码

```swift
actor YTMusicClient: PlatformProtocol {
    private let headers: [String: String]  // 来自 YTMusicAuth
    private let session: URLSession
    
    // 通用内部请求方法
    func innertubeRequest(endpoint: String, body: [String: Any]) async throws -> [String: Any]
    
    // 搜索（对应 ytmusicapi.search()）
    // POST /youtubei/v1/search
    // Body: {context, query, params: "EgWKAQIIAWoKEAoQAxAEEAkQBQ=="}  (filter: songs)
    func search(query: String, limit: Int) async throws -> [Track]
    
    // 获取播放流地址
    // POST /youtubei/v1/player
    // 返回 streamingData.adaptiveFormats，选最高码率 audio
    func getStreamURL(track: Track) async throws -> String
    
    // 首页推荐（对应 ytmusicapi.get_home()）
    // POST /youtubei/v1/browse  Body: {browseId: "FEmusic_home"}
    func getHome() async throws -> [(String, [Track])]
    
    // 我的收藏歌单（对应 ytmusicapi.get_library_playlists()）
    // POST /youtubei/v1/browse  Body: {browseId: "FEmusic_liked_playlists"}
    func getLibraryPlaylists() async throws -> [Playlist]
    
    // 歌单曲目（对应 ytmusicapi.get_playlist()）
    // POST /youtubei/v1/browse  Body: {browseId: "VL{playlistId}"}
    func getPlaylistTracks(playlistId: String) async throws -> [Track]
    
    // 获取专辑曲目
    func getAlbumTracks(albumId: String) async throws -> [Track]
    
    // 搜索（辅助 searchAlbums/searchArtist）
    func searchAlbums(query: String, limit: Int) async throws -> [Album]
    func searchArtist(name: String) async throws -> Artist?
    func getArtistTopTracks(artistId: String, limit: Int) async throws -> [Track]
    
    // 推荐（基于 watch playlist）
    func getRecommendations(track: Track) async throws -> [Track]
    
    // 歌单管理（对应 ytmusicapi.create_playlist/edit_playlist）
    func addTrackToPlaylist(playlistId: String, track: Track) async throws -> Bool
    func removeTrackFromPlaylist(playlistId: String, track: Track) async throws -> Bool
    func getAddablePlaylists() async throws -> [Playlist]
}
```

**JSON 解析策略**：YouTube Music 返回大量嵌套的 `musicResponsiveListItemRenderer`/`musicTwoRowItemRenderer` 等。建议定义 Codable 结构体而非手写 optional chaining。

### 6.3 歌词 `YTMusicLyrics.swift`

```swift
// 三级降级策略（对应 Python）：
// 1. ytmusicapi get_watch_playlist → get_lyrics（YTMusic 内部）
//    POST /youtubei/v1/next  获取 lyrics browseId
//    POST /youtubei/v1/browse  用 browseId 获取歌词
// 2. LRCLIB.net API（公共接口，无 key）
//    GET https://lrclib.net/api/search?track_name=xxx&artist_name=xxx
// 3. 降级显示"暂无歌词"

struct YTMusicLyrics {
    static func fetch(track: Track, client: YTMusicClient) async throws -> [LyricLine]
    private static func fetchFromLRCLIB(track: Track) async throws -> [LyricLine]
}
```

### 验证标准
- WKWebView 登录：Google 不弹"not secure"拦截（或有备用方案）
- 搜索返回结果（Track 字段正确填充）
- 获取流地址：URL 可被 VLCKit 直接播放
- 首页和歌单加载正常

---

## Phase 7 — 音频后端

### 目标
实现 VLCKit 播放后端（YouTube Music、网易云）和 librespot subprocess 后端（Spotify）。对应 Python `core/vlc_backend.py` + `core/librespot_backend.py`。

### 参考源文件
`/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/core/vlc_backend.py`, `/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/core/librespot_backend.py`

### 7.1 VLCKit 后端 `VLCBackend.swift`

VLCKit API（macOS 版）：
```swift
// 依赖：VLCKit.xcframework（从 https://nightlies.videolan.org/build/macosx/ 下载）
import VLCKit

final class VLCBackend: NSObject, VLCMediaPlayerDelegate {
    private var mediaPlayer: VLCMediaPlayer
    
    // 回调（替代 Qt Signal）
    var onPositionChanged: ((Int) -> Void)?      // ms
    var onDurationChanged: ((Int) -> Void)?      // ms
    var onEndReached: (() -> Void)?
    var onError: ((String) -> Void)?
    
    func play(url: String, httpUA: String? = nil) {
        let media = VLCMedia(url: URL(string: url)!)
        if let ua = httpUA {
            media.addOption(":http-user-agent=\(ua)")
        }
        mediaPlayer.media = media
        mediaPlayer.play()
    }
    
    func pause()
    func stop()
    func seek(to ms: Int)
    func setVolume(_ volume: Int)  // 0-100
    
    var positionMs: Int { /* 从 mediaPlayer.time.intValue */ }
    var durationMs: Int { /* 从 mediaPlayer.media.length.intValue */ }
    
    // VLCMediaPlayerDelegate
    func mediaPlayerTimeChanged(_ notification: Notification)
    func mediaPlayerStateChanged(_ notification: Notification)
}
```

**YouTube Music UA**（与 Python 版一致）：
```
Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0.0.0 Safari/537.36
```

### 7.2 librespot 后端 `LibrespotBackend.swift`

```swift
// librespot 子进程管理（对应 Python core/librespot_backend.py）
// librespot 二进制以 PCM pipe 模式输出音频数据

final class LibrespotBackend {
    private var process: Process?
    private var audioPlayerTask: Task<Void, Never>?
    
    var onPositionChanged: ((Int) -> Void)?
    var onEndReached: (() -> Void)?
    var onError: ((String) -> Void)?
    var onPlaybackStarted: (() -> Void)?
    
    // 播放 spotify:track:{id}
    func play(trackId: String) async throws {
        // 1. 启动 librespot 子进程（pipe 输出 PCM）
        // 2. 读取 stdout PCM 数据
        // 3. 用 AVAudioEngine 或 CoreAudio 输出到音频设备
    }
    
    func pause()
    func resume()
    func stop()
    func seek(to ms: Int)
    func setVolume(_ volume: Int)
}
```

**PCM 播放**：使用 `AVAudioEngine` + `AVAudioPlayerNode`，推荐用 `scheduleBuffer` 持续送入 PCM 数据块。

### 验证标准
- VLCKit 能播放一个网易云 CDN URL
- VLCKit 能播放一个 YouTube 音频流 URL（带 UA）
- librespot subprocess 启动，能播放 Spotify 曲目
- 音量控制、Seek、暂停恢复正常

---

## Phase 8 — 播放器状态机 + 队列

### 目标
实现统一播放器状态机和队列管理。对应 Python `core/player.py` + `core/queue.py`。

### 参考源文件
`/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/core/player.py`, `/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/core/queue.py`

### 8.1 播放器状态机

```swift
// Core/PlayerStateMachine.swift
// 使用 @Published + ObservableObject（或 Combine Subject）替代 Qt Signal

@MainActor
final class PlayerStateMachine: ObservableObject {
    @Published private(set) var state: PlayerState = PlayerState()
    
    // 状态转换（与 Python 版完全对应）
    func load(_ track: Track)
    func onLoadSuccess()
    func onLoadError(_ message: String)
    func pause()
    func resume()
    func stop()
    func seek(to ms: Int)
    func setVolume(_ volume: Int)
    func setShuffle(_ enabled: Bool)
    func setRepeatMode(_ mode: RepeatMode)
    func updatePosition(_ ms: Int)
    func updateDuration(_ ms: Int)
}
```

**状态机**（与 Python 版完全一致）：
```
IDLE → load() → LOADING → onLoadSuccess() → PLAYING
PLAYING → pause() → PAUSED → resume() → PLAYING
任意状态 → stop() → IDLE
LOADING → onLoadError() → ERROR
PLAYING/PAUSED → seek() → 保持当前状态
```

### 8.2 播放队列

```swift
// Core/PlayQueue.swift
final class PlayQueue: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var currentIndex: Int = -1
    
    var currentTrack: Track? { /* tracks[currentIndex] */ }
    
    func setTracks(_ tracks: [Track], startAt index: Int)
    func next(repeatMode: RepeatMode) -> Track?
    func previous() -> Track?
    func peekNext(repeatMode: RepeatMode) -> Track?
    func add(_ track: Track)
    func shuffle()
    func remove(at index: Int)
    func move(from: IndexSet, to: Int)
}
```

### 验证标准
- 状态机转换逻辑正确（用 XCTest 验证所有状态转换）
- 队列的 next/previous 在各 repeat mode 下正确
- shuffle 后顺序改变，再次 shuffle 能恢复

---

## Phase 9 — AppController

### 目标
实现统一的业务逻辑控制器，连接所有平台和播放器。对应 Python `core/app_controller.py`。

### 参考源文件
`/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/core/app_controller.py`（1048行，是整个 Python 版的核心）

### 架构

```swift
// Core/AppController.swift
// 替代 Qt Signal 机制，使用 Combine Publisher 或 @Published

@MainActor
final class AppController: ObservableObject {
    // 状态（UI 直接 observe）
    @Published private(set) var playerState: PlayerState = PlayerState()
    @Published private(set) var queue: [Track] = []
    @Published private(set) var queueIndex: Int = -1
    @Published private(set) var currentLyrics: [LyricLine] = []
    @Published private(set) var currentCoverColor: (Int, Int, Int) = (0, 0, 0)
    @Published private(set) var currentCoverData: Data? = nil
    @Published private(set) var isNeteaseAuthenticated: Bool = false
    @Published private(set) var isYTMusicAuthenticated: Bool = false
    @Published private(set) var isSpotifyAuthenticated: Bool = false
    @Published private(set) var displayName: String = "Omnia"
    @Published private(set) var backgroundImagePath: String = ""
    @Published private(set) var homeSections: [String: [(String, [Track])]] = [:]
    @Published private(set) var library: [String: [Playlist]] = [:]
    @Published private(set) var searchResults: [Track] = []
    @Published private(set) var albumSearchResults: [String: [Album]] = [:]
    @Published private(set) var artistInfo: Artist? = nil
    @Published private(set) var artistTracks: [Track] = []
    @Published private(set) var updateStatus: UpdateStatus? = nil
    
    // 子系统
    private let repo: AppRepository
    private let playerMachine: PlayerStateMachine
    private let playQueue: PlayQueue
    private let vlc: VLCBackend
    private let librespot: LibrespotBackend
    private var neteaseClient: NeteaseClient?
    private var ytmClient: YTMusicClient?
    private var spotifyClient: SpotifyClient?
    private let neteaseAuth: NeteaseAuth
    private let ytmAuth: YTMusicAuth
    private let spotifyAuth: SpotifyAuth
    private let librespotBridge: LibrespotBridge
    private let macosMedia: MacOSMediaHandler
    
    // 缓存（与 Python 版 TTL 相同）
    private var homeCache: [String: (Date, [(String, [Track])])] = [:]
    private var libraryCache: [String: (Date, [Playlist])] = [:]
    private var tracksCache: [String: (Date, [Track])] = [:]
    
    // 预取
    private var prefetchTask: Task<Void, Never>? = nil
    private var prefetchedAutoplay: [Track]? = nil
}
```

**完整方法列表**（与 Python 版对应）：

```swift
// 初始化
func initialize() async throws  // 还原登录状态、初始化 DB、macOS 媒体

// 认证
func ensureNeteaseAuth(from window: NSWindow?) async -> Bool
func ensureYTMusicAuth(from window: NSWindow?) async -> Bool
func ensureSpotifyAuth(from window: NSWindow?) async -> Bool
func logoutNetease() async
func logoutYTMusic() async
func logoutSpotify() async
func getAccountName(for platform: String) async -> String?

// 搜索
func search(query: String, platform: String) async -> [Track]
func searchAlbums(query: String, platform: String) async
func getAlbumTracks(_ album: Album) async -> [Track]
func searchHistory(for platform: String) async -> [String]
func addSearchHistory(query: String, platform: String) async
func clearSearchHistory(for platform: String) async

// 播放
func playTrack(_ track: Track) async
func playNext() async
func playPrev() async
func togglePlayPause()
func seek(to ms: Int)
func setVolume(_ volume: Int)
func toggleShuffle()
func cycleRepeatMode()

// 队列
func addToQueue(_ track: Track)
func playQueueTracks(_ tracks: [Track], startAt index: Int)
func jumpToQueueIndex(_ index: Int) async
func removeFromQueue(at index: Int)

// 首页 + 库
func loadHome(for platform: String) async
func loadLibrary(for platform: String) async
func getPlaylistTracks(_ playlist: Playlist) async -> [Track]
func getAddablePlaylists(for platform: String) async -> [Playlist]
func addTrackToPlaylist(_ track: Track, to playlist: Playlist) async -> Bool
func removeTrackFromPlaylist(_ track: Track, from playlist: Playlist) async -> Bool

// 艺术家
func loadArtist(name: String, platform: String) async

// 推荐
func autoplay(seed: Track) async

// 设置
func loadSettings() async
func saveSetting(key: String, value: String) async

// 更新
func checkForUpdate() async
func applyUpdate() async
```

**预取逻辑**（与 Python 版相同）：
```swift
// 各平台触发预取的剩余时间阈值
let prefetchThreshold: [String: Int] = [
    "netease": 5_000,    // 5s
    "ytmusic": 25_000,   // 25s
    "spotify": 20_000,   // 20s
]
```

### 验证标准
- 登录后 isXxxAuthenticated 正确变为 true
- playTrack 能触发 VLC/librespot 播放
- 搜索结果正确更新 searchResults
- 首页、库加载使用 TTL 缓存
- 队列 add/remove/jump 操作正确

---

## Phase 10 — macOS 系统集成

### 目标
实现 macOS 锁屏信息中心、状态栏图标（菜单栏）、媒体键响应。对应 Python `core/macos_media.py`。

### 参考源文件
`/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/core/macos_media.py`

### 10.1 锁屏信息中心

```swift
// macOS/MacOSMediaHandler.swift
import MediaPlayer

final class MacOSMediaHandler {
    private let nowPlayingCenter = MPNowPlayingInfoCenter.default()
    private let commandCenter = MPRemoteCommandCenter.shared()
    
    weak var controller: AppController?
    
    func setup(controller: AppController) {
        self.controller = controller
        setupRemoteCommands()
    }
    
    func updateNowPlaying(track: Track?, positionMs: Int, isPlaying: Bool) {
        guard let track else {
            nowPlayingCenter.nowPlayingInfo = nil
            return
        }
        nowPlayingCenter.nowPlayingInfo = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(positionMs) / 1000,
            MPMediaItemPropertyPlaybackDuration: Double(track.durationMs) / 1000,
        ]
    }
    
    func setCoverArt(data: Data) {
        // MPMediaItemArtwork with UIImage/NSImage
    }
    
    private func setupRemoteCommands() {
        // 媒体键: play, pause, nextTrack, previousTrack, changePlaybackPosition
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.controller?.togglePlayPause()
            return .success
        }
        // ... 其他命令
    }
}
```

### 10.2 状态栏

```swift
// macOS/StatusItemManager.swift
import AppKit

final class StatusItemManager {
    private var statusItem: NSStatusItem?
    private var scrollTimer: Timer?
    
    // 在状态栏显示 ♪/Ⅱ + 滚动歌名（与 Python 版逻辑相同，最多15字+滚动）
    func setup()
    func updateTitle(track: Track?, isPlaying: Bool)
    func showContextMenu()  // 右键菜单：上一首/播放暂停/下一首/退出
}
```

**状态栏固定宽度**：155px（与 Python 版 `_STATUS_ITEM_WIDTH = 155.0` 一致）

### 验证标准
- 锁屏界面显示曲目信息和封面
- 媒体键（键盘 F7/F8/F9）控制播放
- 状态栏图标出现，菜单功能正常
- 歌名过长时状态栏文字滚动

---

## Phase 11 — UI 主题 + 主窗口骨架

### 目标
建立 SwiftUI 主题系统和主窗口布局骨架。对应 Python `ui/theme.py` + `ui/app_window.py` 布局部分。

### 参考源文件
`/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/ui/theme.py`, `/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/ui/app_window.py`

### 11.1 主题系统

```swift
// UI/Theme.swift
struct Theme {
    // 背景层级（与 Python COLORS 完全对应）
    static let bgBase      = Color(hex: "#0D0D0D")
    static let bgSurface   = Color(hex: "#161616")
    static let bgElevated  = Color(hex: "#1E1E1E")
    static let bgHover     = Color(hex: "#2A2A2A")
    
    // 强调色
    static let accent      = Color(hex: "#1DB954")
    static let accentDim   = Color(hex: "#158A3E")
    
    // 文字
    static let textPrimary   = Color(hex: "#FFFFFF")
    static let textSecondary = Color(hex: "#A0A0A0")
    static let textMuted     = Color(hex: "#5A5A5A")
    
    // 平台标识色
    static let platformSpotify  = Color(hex: "#1DB954")
    static let platformYTMusic  = Color(hex: "#FF0000")
    static let platformNetease  = Color(hex: "#E60026")
    
    // 功能色
    static let border      = Color(hex: "#2C2C2C")
    static let divider     = Color(hex: "#1F1F1F")
    static let lyricsActive  = Color(hex: "#FFFFFF")
    static let lyricsPast    = Color(hex: "#4A4A4A")
    static let lyricsFuture  = Color(hex: "#6E6E6E")
    
    // 字体尺寸
    static let fontXS: CGFloat = 10
    static let fontSM: CGFloat = 12
    static let fontMD: CGFloat = 14
    static let fontLG: CGFloat = 18
    static let fontXL: CGFloat = 24
    static let fontLyrics: CGFloat = 22
    
    // 字体
    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("Inter", size: size, relativeTo: .body).weight(weight)
    }
}
```

### 11.2 主窗口布局

```swift
// UI/MainWindowView.swift
// 使用 SwiftUI WindowGroup + NSWindow 配置（无边框 + 暗色外观 + 圆角）

struct MainWindowView: View {
    @StateObject var ctrl: AppController
    @State private var currentPage: PageID = .home
    @State private var previousPage: PageID = .home
    @State private var pageBeforeArtist: PageID = .home
    @State private var showingLyrics: Bool = false
    @State private var showingQueue: Bool = false
    @State private var errorToastVisible: Bool = false
    @State private var statusToastMessage: String = ""
    @State private var idleTimer: Timer? = nil
    @State private var showingStandby: Bool = false
    
    enum PageID: String {
        case home, search, library, settings, lyrics, artist
    }
    
    var body: some View {
        HStack(spacing: 12) {
            SidebarView(currentPage: $currentPage, ctrl: ctrl)
                .frame(width: 200)
            
            ZStack {
                // 毛玻璃内容区
                FrostedPanel()
                
                // 页面切换（NavigationStack 或条件视图）
                Group {
                    switch currentPage {
                    case .home:    HomePageView(ctrl: ctrl)
                    case .search:  SearchPageView(ctrl: ctrl)
                    case .library: LibraryPageView(ctrl: ctrl)
                    case .settings: SettingsPageView(ctrl: ctrl)
                    case .lyrics:  LyricsView(ctrl: ctrl)
                    case .artist:  ArtistPageView(ctrl: ctrl)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: currentPage)
            }
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 0, trailing: 12))
        .overlay(alignment: .bottom) {
            NowPlayingBarView(ctrl: ctrl)
                .frame(height: 90)
        }
        .overlay(alignment: .top) {
            // Toast 浮层
            if errorToastVisible { ErrorToastView() }
        }
        .background(backgroundView)
        // 待机页浮层
        .overlay { if showingStandby { StandbyPageView(ctrl: ctrl) } }
        // 全局 Space 键处理
        .onKeyPress(.space) { handleSpaceKey() }
        // 闲置计时器
        .onContinuousHover { _ in resetIdleTimer() }
        .frame(minWidth: 900, minHeight: 600)
    }
}
```

**macOS 窗口配置**（在 App 入口设置）：
```swift
// OmniaApp.swift
@main
struct OmniaApp: App {
    var body: some Scene {
        WindowGroup {
            MainWindowView(ctrl: AppController())
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)            // 隐藏标题栏
        .windowResizability(.contentSize)
        .commands { OmniaCommands() }            // 菜单栏
    }
}
```

**毛玻璃效果**：
```swift
// UI/Components/FrostedPanel.swift
struct FrostedPanel: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
```

**背景图**：在 `MainWindowView.backgroundView` 中 `Image(nsImage:).resizable().scaledToFill()`。

### 11.3 菜单栏命令

```swift
// 对应 Python _setup_menu_bar()
struct OmniaCommands: Commands {
    // Omnia 菜单: About, Settings, Quit
    // View 菜单: Home/Search/Library/Lyrics/Settings/Standby
    // Playback 菜单: Play/Pause, Previous, Next, Show Queue
    // Window 菜单: Minimize, Zoom, Bring All to Front
    // Help 菜单
}
```

### 验证标准
- 窗口无标题栏，圆角，暗色
- 主题颜色系统可全局访问
- 三栏布局（侧边栏 200px / 内容区 flex / 底部播放栏 90px）正确显示
- 页面切换有过渡动画

---

## Phase 12 — 登录 WebView 对话框

### 目标
实现三个平台的 WebView 登录弹窗，捕获相应的 Cookie/Header。对应 Python `ui/components/login_dialog.py`。

### 参考源文件
`/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/ui/components/login_dialog.py`, `/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/platforms/netease/auth.py`, `/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/platforms/spotify/auth.py`, `/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/platforms/ytmusic/auth.py`

### 通用 LoginWebView 组件

所有三个平台统一使用 **Safari-like UA**，与 WKWebView（WebKit 引擎）实际行为一致，不注入任何 JavaScript。

```swift
// UI/Components/LoginWebView.swift
import WebKit
import SwiftUI

// 三个平台统一使用的 Safari-like UA
// 理由：WKWebView 底层是 WebKit/JavaScriptCore，Safari UA 与引擎行为匹配；
//       使用 Chrome UA 反而会因缺少 window.chrome 等 V8 特性而被检测到引擎不匹配。
private let kSafariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"

struct LoginWebView: NSViewRepresentable {
    let url: URL
    let onCookiesCaptured: ([String: String]) -> Void
    let onDismiss: () -> Void
    
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()  // 隔离 Cookie，强制重新登录
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = kSafariUA
        webView.navigationDelegate = context.coordinator
        webView.configuration.websiteDataStore.httpCookieStore.add(context.coordinator)
        webView.load(URLRequest(url: url))
        return webView
    }
}

// Coordinator 实现 WKHTTPCookieStoreObserver
class Coordinator: NSObject, WKHTTPCookieStoreObserver, WKNavigationDelegate {
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        cookieStore.getAllCookies { cookies in
            let dict = Dictionary(uniqueKeysWithValues: cookies.map { ($0.name, $0.value) })
            // 检查是否包含目标 cookie，触发 onCookiesCaptured
        }
    }
}
```

### 各平台登录配置

| 平台 | URL | 目标 Cookie | UA 策略 |
|------|-----|------------|---------|
| 网易云 | `https://music.163.com` | `MUSIC_U`, `__csrf` | Safari-like UA（统一） |
| Spotify | `https://open.spotify.com/` | `sp_dc`, `sp_key` | Safari-like UA（统一） |
| YouTube Music | `https://music.youtube.com` | `__Secure-3PAPISID`, `SAPISID` | Safari-like UA（统一，无 JS 注入） |

### 对话框 UI

```swift
struct LoginSheet: View {
    let platform: String
    let title: String
    let url: URL
    let userAgent: String
    let onComplete: ([String: String]?) -> Void
    
    @Environment(\.dismiss) var dismiss
    @State private var capturedCookies: [String: String] = [:]
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏（与 Python 版样式一致）
            HStack {
                Text(title).font(Theme.font(14, weight: .semibold))
                Spacer()
                Button("我已登录") { onComplete(capturedCookies); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
            .padding()
            
            LoginWebView(url: url, userAgent: userAgent,
                        onCookiesCaptured: { capturedCookies = $0 },
                        onDismiss: { onComplete(nil); dismiss() })
        }
        .frame(width: 900, height: 650)
        .background(Theme.bgBase)
    }
}
```

### 验证标准
- 三个平台 WebView 能正常加载登录页
- 登录完成后 Cookie 正确捕获并保存
- YouTube Music 登录使用 Safari-like UA；若 Google 仍拦截则界面显示"手动输入 Cookie"备用入口
- 对话框关闭后 WebView 实例释放

---

## Phase 13 — UI 通用组件

### 目标
实现所有可复用 UI 组件。对应 Python `ui/components/` 目录。

### 参考源文件
`/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/ui/components/sidebar.py`, `/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/ui/components/now_playing_bar.py`, `/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/ui/components/track_list.py`, `/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/ui/components/track_row.py`, `/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/ui/components/lyrics_view.py`

### 13.1 侧边栏 `SidebarView.swift`

```swift
struct SidebarView: View {
    @Binding var currentPage: MainWindowView.PageID
    @ObservedObject var ctrl: AppController
    
    // 导航项: 搜索/首页/我的库
    // 平台账号区: 各平台头像+用户名+登录状态圆点
    // 底部: 设置、待机切换
    // 悬停效果: bgHover 背景 + 左侧 3px accent 竖线
}
```

### 13.2 底部播放控制栏 `NowPlayingBarView.swift`

```swift
// 高度: 90px
// 左: 封面缩略图(48x48, 圆角6px) + 歌名/歌手（可点击歌手名）
// 中: ← ⏸ → + 进度条
// 右: 🔀 🔁 歌词 队列 歌单 🔊
struct NowPlayingBarView: View {
    @ObservedObject var ctrl: AppController
    
    // 进度条: 自定义绘制，4px→悬停6px，滑块圆点仅悬停时显示
    // 音量: 100px 宽度，与进度条同样样式
    // 各按钮回调对应 AppController 方法
}
```

### 13.3 歌曲列表 `TrackListView.swift` + `TrackRowView.swift`

```swift
// 虚拟列表（SwiftUI List 或 LazyVStack）
struct TrackListView: View {
    let tracks: [Track]
    let onPlay: (Track) -> Void
    let onAddToQueue: (Track) -> Void
    let onArtistClicked: (Track) -> Void
    let onAddToPlaylist: (Track) -> Void
}

struct TrackRowView: View {
    let track: Track
    let index: Int
    let isCurrentTrack: Bool
    
    // 布局: 序号/播放图标 | 封面小图 | 歌名+歌手 | 专辑 | 时长 | 平台徽章 | 操作菜单
    // 右键菜单: 播放/加入队列elinleiheleeekdfkcdkldfrke3r目前所歌单/查看艺术家
    // 双击播放
}
```

### 13.4 歌词视图 `LyricsView.swift`

```swift
// 全屏歌词视图
struct LyricsView: View {
    @ObservedObject var ctrl: AppController
    @State private var scrollProxy: ScrollViewProxy?
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(ctrl.currentLyrics.indices, id: \.self) { idx in
                        LyricLineView(
                            line: ctrl.currentLyrics[idx],
                            isCurrentLine: idx == currentLineIdx,
                            positionMs: ctrl.playerState.positionMs
                        )
                        .id(idx)
                    }
                }
            }
            .onChange(of: currentLineIdx) { idx in
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo(idx, anchor: .center)
                }
            }
        }
        .background(lyricsBackground)  // 封面颜色渐变
    }
}

struct LyricLineView: View {
    // 当前行: 22px 白色加粗，逐字高亮（已过 = lyricsPast，当前字 = accent，未到 = lyricsFuture）
    // 非当前行: 18px lyricsFuture，缩放 0.9 + 透明度降低
    // 逐字高亮: 根据 positionMs 计算每个 word 的高亮状态
}
```

### 13.5 封面图 `CoverArtView.swift`

```swift
struct CoverArtView: View {
    let coverData: Data?
    let isPlaying: Bool
    @State private var rotation: Double = 0
    
    var body: some View {
        // 圆角12px + 阴影（封面主色，模糊40px，透明度80%）
        // 播放时旋转动画（可在设置中关闭）
        AsyncImage(url: ...) { image in
            image.resizable()
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: dominantColor.opacity(0.8), radius: 40)
                .rotationEffect(.degrees(rotation))
                .animation(isPlaying ? .linear(duration: 20).repeatForever(autoreverses: false) : .default,
                           value: isPlaying)
        }
    }
}
```

### 验证标准
- 侧边栏导航切换正常，悬停效果正确
- 播放控制栏进度条可拖拽，音量可调
- 歌词视图当前行自动居中滚动
- 歌词逐字高亮随时间更新
- 曲目列表右键菜单功能完整
- 封面旋转动画播放时转、暂停时停

---

## Phase 14 — 页面实现

### 目标
实现所有页面视图。对应 Python `ui/pages/` 目录。

### 参考源文件
`/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/ui/pages/home_page.py`, `/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/ui/pages/search_page.py`, `/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/ui/pages/library_page.py`, `/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/ui/pages/settings_page.py`, `/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/ui/pages/artist_page.py`, `/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/ui/pages/standby_page.py`

### 14.1 首页 `HomePageView.swift`

```swift
struct HomePageView: View {
    @ObservedObject var ctrl: AppController
    
    // 平台 Tab（Spotify / YouTube Music / 网易云）
    // 各平台分区：横向可滚动卡片列表，每区显示 8 首
    // 点击曲目 → 播放
    // 点击艺术家名 → 艺术家页
    // 右键/长按 → 加入队列/加入歌单
    // 空状态：未登录时显示"点击登录"
}
```

### 14.2 搜索页 `SearchPageView.swift`

```swift
struct SearchPageView: View {
    @ObservedObject var ctrl: AppController
    @State private var query: String = ""
    @State private var selectedPlatform: String = "netease"
    @State private var debounceTask: Task<Void, Never>? = nil
    
    // 搜索框 + 平台选择 Tab（Spotify/YTMusic/网易云）
    // 输入停止 400ms 后触发搜索（debounce）
    // 曲目结果列表（TrackListView）
    // 专辑结果区（横向滚动卡片）
    // 搜索历史（点击快速搜索，可清除）
}
```

### 14.3 我的库 `LibraryPageView.swift`

```swift
struct LibraryPageView: View {
    @ObservedObject var ctrl: AppController
    @State private var selectedPlatform: String = "netease"
    @State private var selectedPlaylist: Playlist? = nil
    
    // 平台 Tab
    // 歌单列表（封面 + 名称 + 曲目数）
    // 点击歌单 → 展开显示曲目
    // 歌单曲目支持：播放/加入队列/从歌单移除/加入其他歌单
    // 状态消息 Toast（操作成功/失败提示）
}
```

### 14.4 设置页 `SettingsPageView.swift`

```swift
struct SettingsPageView: View {
    @ObservedObject var ctrl: AppController
    
    // 各平台账号管理（登录/注销/显示用户名）
    // 显示名称设置
    // 背景图片设置（文件选择器 / 纯黑模式）
    // 封面旋转动画开关
    // 自动待机时间（分钟）
    // 自动更新开关
    // 版本信息（当前版本 + 检查更新按钮）
    // 更新弹窗（发现新版本时，显示 commit 消息）
}
```

### 14.5 艺术家页 `ArtistPageView.swift`

```swift
struct ArtistPageView: View {
    @ObservedObject var ctrl: AppController
    
    // 返回按钮（回到来源页面）
    // 艺术家头像 + 名称
    // 热门曲目列表（TrackListView）
    // 点击艺术家名（其他曲目里的）→ 嵌套导航
}
```

### 14.6 待机页 `StandbyPageView.swift`

```swift
struct StandbyPageView: View {
    @ObservedObject var ctrl: AppController
    
    // 全屏浮层（覆盖主界面）
    // 大封面居中显示（带颜色阴影）
    // 歌词显示（居中，大字号）
    // 曲目信息（歌名 + 歌手）
    // 时钟（右下角）
    // 点击任意位置退出待机
    // 封面颜色渐变背景
}
```

### 验证标准
- 首页各平台数据正确加载和展示
- 搜索 debounce 正确（400ms）
- 库页歌单点击展开/收起正常
- 设置保存后立即生效
- 艺术家页返回导航正确
- 待机页点击退出、空格键播放/暂停

---

## Phase 15 — 完整连线 + 队列面板 + 歌单选择器

### 目标
完成所有组件的信号/事件连线，实现队列面板和歌单选择弹窗。

### 参考源文件
`/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/ui/components/queue_panel.py`, `/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/ui/components/playlist_picker_popup.py`, `/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/ui/app_window.py`（信号连线部分）

### 15.1 队列面板 `QueuePanelView.swift`

```swift
// 弹出式悬浮面板（位于 NowPlayingBar 队列按钮正上方）
struct QueuePanelView: View {
    @ObservedObject var ctrl: AppController
    @Binding var isPresented: Bool
    
    // 当前播放曲目（高亮）
    // 待播队列列表（可拖拽排序、右键删除）
    // 点击跳转到对应曲目
    // 最近关闭时间守卫（防止按钮 press 关闭后 release 立刻重开）
}
```

### 15.2 歌单选择弹窗 `PlaylistPickerView.swift`

```swift
// 弹出式选择器（位于触发按钮下方或 NowPlayingBar 上方）
struct PlaylistPickerView: View {
    let platform: String
    @Binding var isPresented: Bool
    let onSelected: (Playlist) -> Void
    
    @State private var playlists: [Playlist] = []
    @State private var isLoading: Bool = true
    @State private var error: String? = nil
    
    // 加载中: 骨架屏
    // 歌单列表（封面 + 名称）
    // 点击后触发 onSelected 并关闭
}
```

### 15.3 完整连线清单

以下 AppController ↔ UI 的事件连线需要在 Phase 15 完成验证：

- `playerState` → `NowPlayingBarView`（进度、状态、封面、歌名）
- `playerState.status == .error` → 错误 Toast 弹出 + 3s 后自动下一首
- `currentLyrics` → `LyricsView`
- `currentCoverData` → `LyricsView` + `NowPlayingBarView` + `StandbyPageView`
- `currentCoverColor` → `LyricsView` 背景 + `StandbyPageView` 背景
- `isXxxAuthenticated` → `SidebarView` 平台状态点
- `homeSections` → `HomePageView`
- `library` → `LibraryPageView`
- `searchResults` → `SearchPageView`
- `artistInfo + artistTracks` → `ArtistPageView`
- `queue + queueIndex` → `QueuePanelView`
- `updateStatus` → `SettingsPageView` 更新提示

**全局 Space 键**：焦点不在文本输入框时，Space 触发 `togglePlayPause()`。

**闲置自动待机**：鼠标/键盘无操作 N 分钟后进入待机页（N 来自设置，默认 5min）。

### 验证标准
- 所有 AppController @Published 变量变化时，对应 UI 自动更新
- 队列面板拖拽排序生效
- 歌单选择器能从正确平台加载歌单并成功加入
- 错误 Toast 正确弹出并自动跳到下一首
- 待机页进入/退出逻辑正确

---

## Phase 16 — 自动更新 + 打包

### 目标
实现 git 版本检测、自动更新、Xcode 打包配置。对应 Python `core/updater.py` + `Omnia.spec`。

### 参考源文件
`/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/core/updater.py`

### 16.1 自动更新

```swift
// Core/Updater.swift
// 通过 git 检测更新（与 Python 版逻辑一致）

struct UpdateStatus {
    var available: Bool = false
    var remoteShort: String = ""     // 远端 commit hash 前7位
    var commitMessages: [String] = []
    var error: String? = nil
}

struct Updater {
    static func checkForUpdate() async -> UpdateStatus {
        // 1. git fetch origin
        // 2. 比较 HEAD 与 origin/HEAD
        // 3. 获取新 commit 消息列表
    }
    
    static func applyUpdate() async -> (Bool, String) {
        // 1. git pull --ff-only
        // 2. 成功则重启 App
    }
    
    static func restartApp() {
        // Process.launchPath = Bundle.main.executablePath
        // NSApp.terminate(nil)
    }
}
```

### 16.2 Xcode 打包配置

**Entitlements**（对应功能需要）：
```xml
<!-- Omnia.entitlements -->
<key>com.apple.security.network.client</key><true/>         <!-- 网络请求 -->
<key>com.apple.security.app-sandbox</key><false/>           <!-- 非沙盒（librespot subprocess + yt-dlp） -->
<key>com.apple.security.files.user-selected.read-write</key><true/>  <!-- 背景图片选择 -->
```

> **非沙盒说明**：librespot 子进程、yt-dlp 子进程、npx（如果保留）均要求非沙盒模式。与 Python PyInstaller 版一致，无法上 Mac App Store。

**打包产物**：
- Xcode Archive → Export → Developer ID Application
- 包含：VLCKit.framework、librespot 二进制、yt-dlp 二进制
- 目标体积 < 100MB（vs Python 版 ~300MB）

**应用 Bundle 内置二进制**：
```
Omnia.app/
└── Contents/
    ├── MacOS/Omnia
    └── Resources/
        ├── librespot         # Rust 编译的 librespot 二进制
        ├── yt-dlp            # yt-dlp 单文件二进制
        └── Fonts/            # Inter 字体
```

获取 librespot 二进制：
```bash
cargo install librespot --features alsa-backend
# 或从 https://github.com/librespot-org/librespot/releases 下载预编译版本
```

### 16.3 代码签名

```bash
codesign --deep --force --sign "Developer ID Application: ..." \
  Omnia.app/Contents/Resources/librespot
codesign --deep --force --sign "Developer ID Application: ..." \
  Omnia.app/Contents/Resources/yt-dlp
codesign --deep --force --sign "Developer ID Application: ..." \
  Omnia.app
```

### 验证标准
- `checkForUpdate()` 在有新 commit 时返回 `available: true`
- 点击"立即更新"执行 `git pull` 并重启
- 打包的 .app 在未安装 Python/Qt 的 Mac 上能正常运行
- librespot 和 yt-dlp 二进制签名通过 Gatekeeper

---

## 各阶段快速参考

### 依赖前置条件

| Phase | 前置 Phase | 可单独开发 |
|-------|-----------|----------|
| P0 项目骨架 | 无 | ✅ |
| P1 数据模型 | P0 | ✅ |
| P2 数据库层 | P0, P1 | ✅ |
| P3 工具库 | P0, P1 | ✅ |
| P4 网易云 | P0, P1, P2 | ✅ |
| P5 Spotify | P0, P1, P2 | ✅ |
| P6 YouTube Music | P0, P1, P2 | ✅ |
| P7 音频后端 | P0, P1 | ✅ |
| P8 播放器+队列 | P0, P1 | ✅ |
| P9 AppController | P2-P8 | ❌ |
| P10 macOS 集成 | P8, P9 | ❌ |
| P11 UI 骨架 | P0, P1 | ✅ |
| P12 登录对话框 | P4, P5, P6, P11 | ❌ |
| P13 UI 组件 | P1, P11 | ✅ |
| P14 页面 | P9, P13 | ❌ |
| P15 完整连线 | P9-P14 | ❌ |
| P16 更新+打包 | P15 | ❌ |

### 推荐并行开发顺序

**批次 1**（可完全并行）：P0 → 同时开发 P1 + P11

**批次 2**（P1 完成后并行）：P2、P3、P4、P5、P6、P7、P8、P13

**批次 3**（批次2完成后）：P9

**批次 4**（P9 + P11 + P13 完成后）：P10、P12、P14

**批次 5**（批次4完成后）：P15

**批次 6**：P16

### 关键风险点与缓解策略

| 风险 | 缓解 |
|------|------|
| Google 拦截 WKWebView 登录（YouTube Music） | Safari-like UA（引擎与 UA 一致）；备用"手动输入 Cookie"入口 |
| Spotify Partner API hash 失效 | 动态从 web-player bundle 提取；硬编码 fallback hash |
| librespot 协议更新 | 使用最新版 Rust 二进制；监控 librespot 仓库 |
| yt-dlp YouTube 反爬 | 定期更新 yt-dlp 二进制 |
| VLCKit 版本兼容 | 固定 VLCKit 版本；测试 macOS 13/14/15 |
| ytmusicapi 内部 API 变更 | YouTube Music 内部 API 相对稳定；参考 ytmusicapi 源码更新 |
| RSA BigInteger 实现 | 引入 BigInt SPM 库，或自实现 256位模幂 |

---

*文档生成日期：2026-05-15*  
*参考 Python 版本路径：`/Users/msomnia/Library/CloudStorage/OneDrive-Personal/1MSomnia/code/SomniaPlayer/`（分支：feat/phase4-youtube-music）*
