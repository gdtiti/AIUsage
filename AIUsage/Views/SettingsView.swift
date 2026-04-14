import SwiftUI
import Sparkle
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var refreshCoordinator: ProviderRefreshCoordinator
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var sparkle: SparkleController
    @State var hideDockIcon = UserDefaults.standard.bool(forKey: DefaultsKey.hideDockIcon)
    @State var launchAtLogin: Bool = {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }()
    @State var showNotifications = UserDefaults.standard.bool(forKey: DefaultsKey.showNotifications)
    @State var lowQuotaThreshold: Double = UserDefaults.standard.double(forKey: DefaultsKey.lowQuotaThreshold)
    @State var remoteHostInput: String = ""
    @State var remotePortInput: String = ""
    @State var isTestingRemoteConnection = false
    @State var remoteConnectionState: RemoteConnectionState = .idle
    @State var remoteConnectionMessage: String?
    @AppStorage(DefaultsKey.proxyLogRetentionDays) var proxyLogRetentionDays: Int = 30

    enum RemoteConnectionState {
        case idle
        case success
        case failure
    }

    init() {
        if _lowQuotaThreshold.wrappedValue == 0 {
            _lowQuotaThreshold = State(initialValue: 20.0)
        }
    }

    var repositoryURL: URL? {
        if let raw = Bundle.main.infoDictionary?["ProjectRepositoryURL"] as? String,
           let url = URL(string: raw) {
            return url
        }

        guard let owner = gitHubOwner, let repository = gitHubRepository else { return nil }
        return URL(string: "https://github.com/\(owner)/\(repository)")
    }

    var gitHubOwner: String? {
        (Bundle.main.infoDictionary?["ProjectGitHubOwner"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
    }

    var gitHubRepository: String? {
        (Bundle.main.infoDictionary?["ProjectGitHubRepository"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    settingsHero
                    settingsSections(for: proxy.size.width)
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 24)
                .frame(maxWidth: 1120, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(settingsBackground.ignoresSafeArea())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            remoteHostInput = settings.remoteHost
            remotePortInput = "\(settings.remotePort)"
        }
        .onChange(of: hideDockIcon) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.hideDockIcon)
            updateDockIconVisibility(hidden: newValue)
        }
        .onChange(of: launchAtLogin) { _, newValue in
            if #available(macOS 13.0, *) {
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            }
        }
        .onChange(of: showNotifications) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.showNotifications)
        }
        .onChange(of: lowQuotaThreshold) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.lowQuotaThreshold)
        }
        .onChange(of: settings.autoRefreshInterval) { _, _ in
            settings.saveSettings()
            refreshCoordinator.setupAutoRefresh()
        }
        .onChange(of: settings.claudeCodeRefreshInterval) { _, _ in
            settings.saveSettings()
            refreshCoordinator.setupClaudeCodeAutoRefresh()
        }
        .onChange(of: settings.themeMode) { _, _ in
            settings.saveSettings()
        }
        .onChange(of: settings.quotaIndicatorStyle) { _, _ in
            settings.saveSettings()
        }
        .onChange(of: settings.quotaIndicatorMetric) { _, _ in
            settings.saveSettings()
        }
        .onChange(of: settings.language) { _, _ in
            settings.saveSettings()
            refreshCoordinator.refreshAllProviders()
        }
    }

    @ViewBuilder
    func settingsSections(for availableWidth: CGFloat) -> some View {
        if availableWidth >= 1100 {
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 20) {
                    backendCard
                    appearanceCard
                }
                .frame(maxWidth: .infinity, alignment: .top)

                VStack(spacing: 20) {
                    generalCard
                    notificationsCard
                    aboutCard
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        } else {
            VStack(spacing: 20) {
                backendCard
                generalCard
                appearanceCard
                notificationsCard
                aboutCard
            }
        }
    }

    var settingsBackground: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                Color.accentColor.opacity(0.06),
                Color(nsColor: .windowBackgroundColor)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var settingsHero: some View {
        VStack(spacing: 16) {
            if let icon = NSImage(named: "AppIcon") {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: Color.accentColor.opacity(0.3), radius: 16, y: 6)
            } else {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 88, height: 88)
            }

            Text("AIUsage")
                .font(.system(size: 28, weight: .bold, design: .rounded))

            Text(L("Your AI Quota Command Center", "您的 AI 额度指挥中心"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Label(L("Version", "版本") + " " + appVersion, systemImage: "tag")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
            }

            HStack(spacing: 10) {
                heroPill(
                    title: L("Backend", "后端"),
                    value: settings.backendMode == "remote" ? L("Remote", "远程") : L("Local", "本地"),
                    tint: .blue
                )
                heroPill(
                    title: L("Auto Refresh", "自动刷新"),
                    value: autoRefreshTitle(for: settings.autoRefreshInterval),
                    tint: .teal
                )
                heroPill(
                    title: L("Theme", "主题"),
                    value: {
                        switch settings.themeMode {
                        case "light": return L("Light", "浅色")
                        case "dark": return L("Dark", "深色")
                        default: return L("System", "系统")
                        }
                    }(),
                    tint: .orange
                )
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 28)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    func updateDockIconVisibility(hidden: Bool) {
        if hidden {
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState.shared)
        .environmentObject(AppSettings.shared)
}
