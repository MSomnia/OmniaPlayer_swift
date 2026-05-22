import SwiftUI

public struct SidebarView: View {
    @Binding var currentPage: PageID
    @ObservedObject var ctrl: AppController

    public init(currentPage: Binding<PageID>, ctrl: AppController) {
        _currentPage = currentPage
        self.ctrl = ctrl
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // App name — tap to open standby view
            Text(greetingWithName)
                .font(Theme.font(Theme.fontLG, weight: .bold))
                .foregroundStyle(Theme.primaryText)
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 20)
                .contentShape(Rectangle())
                .onTapGesture { currentPage = .standby }

            // Navigation items
            navItem(label: "首页", icon: "house.fill",      page: .home, activeIconColor: .white, indicatorColor: .white)
            navItem(label: "搜索", icon: "magnifyingglass", page: .search, activeIconColor: .white, indicatorColor: .white)
            navItem(label: "聚合搜索", icon: "square.grid.2x2", page: .aggregateSearch, activeIconColor: .white, indicatorColor: .white)

            Divider()
                .background(Theme.divider)
                .padding(.vertical, 12)

            // Platform library rows
            platformLabel
            platformRow(platform: "netease", label: "网易云音乐",
                        isAuth: ctrl.isNeteaseAuthenticated)
            platformRow(platform: "spotify", label: "Spotify",
                        isAuth: ctrl.isSpotifyAuthenticated)
            platformRow(platform: "ytmusic", label: "YouTube Music",
                        isAuth: ctrl.isYTMusicAuthenticated)

            Spacer()

            // Bottom: Settings
            navItem(label: "设置", icon: "gearshape", page: .settings)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.panelBackground(hasBackgroundImage: !ctrl.backgroundImagePath.isEmpty))
    }

    // MARK: - Greeting

    private var greetingWithName: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let prefix: String
        switch hour {
        case 5..<12: prefix = "早安，"
        case 12..<18: prefix = "午安，"
        default: prefix = "晚安，"
        }
        return prefix + ctrl.displayName
    }

    // MARK: - Section label

    private var platformLabel: some View {
        Text("音乐库")
            .font(Theme.font(Theme.fontXS, weight: .semibold))
            .foregroundStyle(Theme.mutedText)
            .tracking(0.6)
            .padding(.horizontal, 20)
            .padding(.bottom, 4)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func navItem(
        label: String,
        icon: String,
        page: PageID,
        activeIconColor: Color = Theme.accent,
        indicatorColor: Color = Theme.accent
    ) -> some View {
        let active = currentPage == page
        HStack(spacing: 10) {
            if active {
                Rectangle()
                    .fill(indicatorColor)
                    .frame(width: 3)
            } else {
                Color.clear.frame(width: 3)
            }
            Image(systemName: icon)
                .foregroundStyle(active ? activeIconColor : Theme.secondaryText)
                .frame(width: 18)
            Text(label)
                .font(Theme.font(Theme.fontMD, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Theme.primaryText : Theme.secondaryText)
            Spacer()
        }
        .frame(height: 36)
        .background(active ? Theme.hoverBackground(hasBackgroundImage: !ctrl.backgroundImagePath.isEmpty) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { currentPage = page }
    }

    @ViewBuilder
    private func platformRow(platform: String, label: String, isAuth: Bool) -> some View {
        let isActive = currentPage == .library && ctrl.libraryPlatform == platform
        let platformColor = Theme.platformColor(for: platform)

        HStack(spacing: 10) {
            // Active accent bar
            if isActive {
                Rectangle()
                    .fill(platformColor)
                    .frame(width: 3)
            } else {
                Color.clear.frame(width: 3)
            }

            // Status dot
            Circle()
                .fill(isAuth ? platformColor : Theme.mutedText)
                .frame(width: 8, height: 8)

            // Label
            Text(label)
                .font(Theme.font(Theme.fontSM, weight: isActive ? .semibold : .regular))
                .foregroundStyle(
                    isAuth
                        ? (isActive ? Theme.primaryText : Theme.secondaryText)
                        : Theme.mutedText
                )

            Spacer()

            // Login button (not-logged-in only)
            if !isAuth {
                Button("登录") { ctrl.requestLogin(for: platform) }
                    .font(Theme.font(Theme.fontXS, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.plain)
                    .padding(.trailing, 12)
            } else {
                // Library chevron hint
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isActive ? Theme.accent : Theme.mutedText.opacity(0.5))
                    .padding(.trailing, 14)
            }
        }
        .frame(height: 34)
        .background(isActive ? Theme.hoverBackground(hasBackgroundImage: !ctrl.backgroundImagePath.isEmpty) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if isAuth {
                ctrl.libraryPlatform = platform
                currentPage = .library
            } else {
                ctrl.requestLogin(for: platform)
            }
        }
    }
}
