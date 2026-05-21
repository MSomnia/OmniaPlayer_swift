import SwiftUI
import AppKit

// MARK: - Theme
//
// Mirrors Python ui/theme.py (COLORS + FONTS).
// All constants match the Python values; use Theme.xxx everywhere in SwiftUI.

public enum Theme {

    // MARK: - Background layers

    public static let bgBase     = Color(hex: "#0D0D0D")   // deepest black
    public static let bgPanel    = Color(hex: "#1A1A1A")   // sidebar / panel
    public static let bgSurface  = Color(hex: "#161616")   // content surface
    public static let bgElevated = Color(hex: "#1E1E1E")   // cards / elevated items
    public static let bgHover    = Color(hex: "#2A2A2A")   // hover / selection highlight

    // Alias used by existing stubs
    public static var background: Color { bgBase }
    public static var surface:    Color { bgPanel }

    public static func panelBackground(hasBackgroundImage: Bool) -> Color {
        hasBackgroundImage ? bgPanel.opacity(0.78) : bgPanel
    }

    public static func surfaceBackground(hasBackgroundImage: Bool) -> Color {
        hasBackgroundImage ? bgSurface.opacity(0.72) : bgSurface
    }

    public static func elevatedBackground(hasBackgroundImage: Bool) -> Color {
        hasBackgroundImage ? bgElevated.opacity(0.82) : bgElevated
    }

    public static func hoverBackground(hasBackgroundImage: Bool) -> Color {
        hasBackgroundImage ? bgHover.opacity(0.72) : bgHover
    }

    // MARK: - Accent

    public static let accent    = Color(hex: "#1DB954")
    public static let accentDim = Color(hex: "#158A3E")

    // MARK: - Text

    public static let primaryText   = Color(hex: "#FFFFFF")
    public static let secondaryText = Color(hex: "#A0A0A0")
    public static let mutedText     = Color(hex: "#5A5A5A")

    // MARK: - Platform brand colors

    public static let spotifyColor  = Color(hex: "#1DB954")
    public static let ytMusicColor  = Color(hex: "#FF0000")
    public static let neteaseColor  = Color(hex: "#E60026")

    // MARK: - Structural

    public static let border  = Color(hex: "#2C2C2C")
    public static let divider = Color(hex: "#1F1F1F")

    // MARK: - Lyrics states

    public static let lyricsActive = Color(hex: "#FFFFFF")
    public static let lyricsPast   = Color(hex: "#4A4A4A")
    public static let lyricsFuture = Color(hex: "#6E6E6E")

    // MARK: - Font sizes

    public static let fontXS:     CGFloat = 10
    public static let fontSM:     CGFloat = 12
    public static let fontMD:     CGFloat = 14
    public static let fontLG:     CGFloat = 18
    public static let fontXL:     CGFloat = 24
    public static let fontLyrics: CGFloat = 22

    // MARK: - Font helper

    /// Returns a font at the given size and weight.
    /// Uses Inter if installed; falls back to the system font to avoid weight-mapping warnings.
    public static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if interAvailable {
            return .custom("Inter", size: size, relativeTo: .body).weight(weight)
        }
        return .system(size: size, weight: weight, design: .default)
    }

    private static let interAvailable: Bool = {
        NSFont(name: "Inter", size: 12) != nil
    }()

    // MARK: - Corner radii

    public static let radiusSM: CGFloat = 4
    public static let radiusMD: CGFloat = 8
    public static let radiusLG: CGFloat = 12

    // MARK: - Platform color helper

    public static func platformColor(for platform: String) -> Color {
        switch platform {
        case "spotify":  return spotifyColor
        case "ytmusic":  return ytMusicColor
        case "netease":  return neteaseColor
        default:         return accent
        }
    }
}

// MARK: - Color(hex:) initialiser

extension Color {
    /// Create a Color from a CSS hex string, e.g. "#1DB954" or "1DB954".
    public init(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h = String(h.dropFirst()) }
        let value = UInt64(h, radix: 16) ?? 0
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >>  8) & 0xFF) / 255
        let b = Double( value        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
