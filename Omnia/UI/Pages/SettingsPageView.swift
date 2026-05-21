import SwiftUI
import AppKit

// MARK: - SettingsPageView

public struct SettingsPageView: View {
    @ObservedObject var ctrl: AppController

    // Account names loaded async
    @State private var neteaseAccountName: String? = nil
    @State private var spotifyAccountName: String? = nil
    @State private var ytMusicAccountName: String? = nil

    // Display name editing
    @State private var displayNameField: String = ""

    // Playback
    @State private var volumeValue: Double = 70
    @State private var coverRotation: Bool = true

    // Interface
    @State private var backgroundPathField: String = ""
    @State private var pureBlackBackground: Bool = false

    // Update
    @State private var isCheckingUpdate: Bool = false

    public init(ctrl: AppController) {
        self.ctrl = ctrl
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                // MARK: 账号
                sectionHeader("账号")
                accountsSection

                sectionDivider

                // MARK: 显示名称
                sectionHeader("显示名称")
                displayNameSection

                sectionDivider

                // MARK: 播放
                sectionHeader("播放")
                playbackSection

                sectionDivider

                // MARK: 界面
                sectionHeader("界面")
                interfaceSection

                sectionDivider

                // MARK: 更新
                sectionHeader("更新")
                updateSection

                sectionDivider

                // MARK: 关于
                sectionHeader("关于")
                aboutSection
            }
            .padding(28)
        }
        .background(Theme.surfaceBackground(hasBackgroundImage: !ctrl.backgroundImagePath.isEmpty))
        .foregroundStyle(Theme.primaryText)
        .onAppear {
            displayNameField   = ctrl.displayName
            backgroundPathField = ctrl.backgroundImagePath
            volumeValue        = Double(ctrl.playerState.volume)
        }
        .task {
            await loadAccountNames()
        }
        .onChange(of: ctrl.isNeteaseAuthenticated) { _ in
            Task { await loadAccountNames() }
        }
        .onChange(of: ctrl.isSpotifyAuthenticated) { _ in
            Task { await loadAccountNames() }
        }
        .onChange(of: ctrl.isYTMusicAuthenticated) { _ in
            Task { await loadAccountNames() }
        }
    }

    // MARK: - Section: Accounts

    private var accountsSection: some View {
        VStack(spacing: 0) {
            accountRow(
                platform: "netease",
                platformLabel: "网易云音乐",
                isAuthenticated: ctrl.isNeteaseAuthenticated,
                accountName: neteaseAccountName,
                onLogin:  { ctrl.requestLogin(for: "netease") },
                onLogout: { Task { await ctrl.logoutNetease() } }
            )
            Divider().background(Theme.divider)
            accountRow(
                platform: "spotify",
                platformLabel: "Spotify",
                isAuthenticated: ctrl.isSpotifyAuthenticated,
                accountName: spotifyAccountName,
                onLogin:  { ctrl.requestLogin(for: "spotify") },
                onLogout: { Task { await ctrl.logoutSpotify() } }
            )
            Divider().background(Theme.divider)
            accountRow(
                platform: "ytmusic",
                platformLabel: "YouTube Music",
                isAuthenticated: ctrl.isYTMusicAuthenticated,
                accountName: ytMusicAccountName,
                onLogin:  { ctrl.requestLogin(for: "ytmusic") },
                onLogout: { Task { await ctrl.logoutYTMusic() } }
            )
        }
        .background(Theme.bgElevated)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMD))
    }

    @ViewBuilder
    private func accountRow(
        platform: String,
        platformLabel: String,
        isAuthenticated: Bool,
        accountName: String?,
        onLogin: @escaping () -> Void,
        onLogout: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            // Auth status dot
            Circle()
                .fill(isAuthenticated ? Theme.accent : Theme.mutedText)
                .frame(width: 8, height: 8)

            // Platform name + optional account name
            VStack(alignment: .leading, spacing: 2) {
                Text(platformLabel)
                    .font(Theme.font(Theme.fontMD, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                if isAuthenticated, let name = accountName {
                    Text(name)
                        .font(Theme.font(Theme.fontSM))
                        .foregroundStyle(Theme.secondaryText)
                } else if isAuthenticated {
                    Text("已登录")
                        .font(Theme.font(Theme.fontSM))
                        .foregroundStyle(Theme.secondaryText)
                } else {
                    Text("未登录")
                        .font(Theme.font(Theme.fontSM))
                        .foregroundStyle(Theme.mutedText)
                }
            }

            Spacer()

            // Platform color badge
            Text(platformLabel)
                .font(Theme.font(Theme.fontXS, weight: .medium))
                .foregroundStyle(Theme.platformColor(for: platform))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.platformColor(for: platform).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM))

            // Login / Logout button
            if isAuthenticated {
                Button("注销") { onLogout() }
                    .font(Theme.font(Theme.fontSM))
                    .foregroundStyle(Color.red.opacity(0.85))
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.red.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM))
            } else {
                Button("登录") { onLogin() }
                    .font(Theme.font(Theme.fontSM, weight: .medium))
                    .foregroundStyle(Theme.bgBase)
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSM))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Section: Display Name

    private var displayNameSection: some View {
        HStack(spacing: 12) {
            TextField("显示名称", text: $displayNameField)
                .font(Theme.font(Theme.fontMD))
                .foregroundStyle(Theme.primaryText)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.bgElevated)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMD))
                .onSubmit {
                    Task { await ctrl.saveSetting(key: "display_name", value: displayNameField) }
                }

            Button("保存") {
                Task { await ctrl.saveSetting(key: "display_name", value: displayNameField) }
            }
            .font(Theme.font(Theme.fontSM, weight: .medium))
            .foregroundStyle(Theme.bgBase)
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Theme.accent)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMD))
        }
    }

    // MARK: - Section: Playback

    private var playbackSection: some View {
        VStack(spacing: 16) {
            // Volume
            HStack(spacing: 12) {
                Image(systemName: "speaker.fill")
                    .font(.system(size: Theme.fontSM))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 16)

                Text("音量")
                    .font(Theme.font(Theme.fontMD))
                    .foregroundStyle(Theme.primaryText)

                Spacer()

                Slider(value: $volumeValue, in: 0...100, step: 1) { editing in
                    if !editing {
                        ctrl.setVolume(Int(volumeValue))
                    }
                }
                .frame(width: 180)
                .tint(Theme.accent)

                Text("\(Int(volumeValue))")
                    .font(Theme.font(Theme.fontSM))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 30, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.bgElevated)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMD))

            // Cover rotation
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: Theme.fontSM))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 16)

                Text("封面旋转动画")
                    .font(Theme.font(Theme.fontMD))
                    .foregroundStyle(Theme.primaryText)

                Spacer()

                Toggle("", isOn: $coverRotation)
                    .toggleStyle(.switch)
                    .tint(Theme.accent)
                    .labelsHidden()
                    .onChange(of: coverRotation) { val in
                        Task { await ctrl.saveSetting(key: "cover_rotation", value: val ? "true" : "false") }
                    }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.bgElevated)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMD))
        }
    }

    // MARK: - Section: Interface

    private var interfaceSection: some View {
        VStack(spacing: 16) {
            // Background image
            VStack(alignment: .leading, spacing: 8) {
                Text("背景图片路径")
                    .font(Theme.font(Theme.fontSM))
                    .foregroundStyle(Theme.secondaryText)

                HStack(spacing: 8) {
                    TextField("选择或输入图片路径…", text: $backgroundPathField)
                        .font(Theme.font(Theme.fontMD))
                        .foregroundStyle(Theme.primaryText)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.bgElevated)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMD))
                        .onSubmit {
                            Task { await ctrl.saveSetting(key: "background_image_path", value: backgroundPathField) }
                        }

                    Button("选择…") {
                        pickBackgroundImage()
                    }
                    .font(Theme.font(Theme.fontSM, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.bgHover)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMD))
                }
            }

            // Pure black background toggle
            HStack(spacing: 12) {
                Image(systemName: "circle.fill")
                    .font(.system(size: Theme.fontSM))
                    .foregroundStyle(Theme.bgBase)
                    .frame(width: 16)

                Text("纯黑背景")
                    .font(Theme.font(Theme.fontMD))
                    .foregroundStyle(Theme.primaryText)

                Spacer()

                Toggle("", isOn: $pureBlackBackground)
                    .toggleStyle(.switch)
                    .tint(Theme.accent)
                    .labelsHidden()
                    .onChange(of: pureBlackBackground) { val in
                        Task { await ctrl.saveSetting(key: "background_pure_black", value: val ? "true" : "false") }
                    }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.bgElevated)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMD))
        }
    }

    // MARK: - Section: Update

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    isCheckingUpdate = true
                    Task {
                        await ctrl.checkForUpdate()
                        isCheckingUpdate = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isCheckingUpdate {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: Theme.fontSM))
                        }
                        Text("检查更新")
                            .font(Theme.font(Theme.fontMD))
                    }
                }
                .foregroundStyle(Theme.primaryText)
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Theme.bgElevated)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMD))
                .disabled(isCheckingUpdate)

                Spacer()
            }

            if let status = ctrl.updateStatus {
                HStack(spacing: 8) {
                    if status.available {
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundStyle(Theme.accent)
                        Text("有新版本可用：\(status.remoteShort)")
                            .font(Theme.font(Theme.fontSM))
                            .foregroundStyle(Theme.accent)
                    } else if let err = status.error {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(err)
                            .font(Theme.font(Theme.fontSM))
                            .foregroundStyle(.orange)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.accent)
                        Text("已是最新版本")
                            .font(Theme.font(Theme.fontSM))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.bgElevated)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMD))
            }
        }
    }

    // MARK: - Section: About

    private var aboutSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.system(size: Theme.fontLG))
                .foregroundStyle(Theme.accent)

            VStack(alignment: .leading, spacing: 4) {
                Text("Omnia")
                    .font(Theme.font(Theme.fontMD, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text("版本 \(appVersion)")
                    .font(Theme.font(Theme.fontSM))
                    .foregroundStyle(Theme.secondaryText)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.bgElevated)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMD))
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(Theme.font(Theme.fontSM, weight: .semibold))
            .foregroundStyle(Theme.secondaryText)
            .textCase(.uppercase)
            .tracking(0.8)
    }

    private var sectionDivider: some View {
        Divider()
            .background(Theme.divider)
    }

    private func loadAccountNames() async {
        async let n = ctrl.getAccountName(for: "netease")
        async let s = ctrl.getAccountName(for: "spotify")
        async let y = ctrl.getAccountName(for: "ytmusic")
        neteaseAccountName = await n
        spotifyAccountName = await s
        ytMusicAccountName = await y
    }

    private func pickBackgroundImage() {
        let panel = NSOpenPanel()
        panel.title = "选择背景图片"
        panel.allowedContentTypes = [.image, .png, .jpeg, .tiff, .bmp, .gif]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        backgroundPathField = url.path
        Task { await ctrl.saveSetting(key: "background_image_path", value: url.path) }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}
