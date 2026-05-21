# VLCKit

Phase 0 reserves this location for the manually integrated VLCKit xcframework.

Recommended integration:

1. Download the official macOS VLCKit xcframework from VideoLAN.
2. Place the framework at `Vendor/VLCKit/VLCKit.xcframework`.
3. Add it to the Xcode target's Frameworks, Libraries, and Embedded Content.
4. Keep `Omnia/Audio/VLCBackend.swift` guarded with `canImport(VLCKit)` until Phase 7 implements playback.

VLCKit is intentionally not fetched through Swift Package Manager because the
migration plan notes that SPM support is not the stable integration path.
