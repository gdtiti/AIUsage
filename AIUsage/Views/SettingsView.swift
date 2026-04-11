import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var hideDockIcon = UserDefaults.standard.bool(forKey: "hideDockIcon")
    @State private var launchAtLogin = false
    @State private var showNotifications = UserDefaults.standard.bool(forKey: "showNotifications")
    @State private var lowQuotaThreshold: Double = UserDefaults.standard.double(forKey: "lowQuotaThreshold")
    @State private var remoteHostInput: String = ""
    @State private var remotePortInput: String = ""
    @State private var isTestingRemoteConnection = false
    @State private var remoteConnectionState: RemoteConnectionState = .idle
    @State private var remoteConnectionMessage: String?
    @State private var isCheckingForUpdates = false
    @State private var updateCheckState: UpdateCheckState = .idle
    @State private var updateCheckMessage: String?
    @State private var latestRelease: GitHubRelease?

    init() {
        if _lowQuotaThreshold.wrappedValue == 0 {
            _lowQuotaThreshold = State(initialValue: 20.0)
        }
    }
    
    private func t(_ en: String, _ zh: String) -> String {
        appState.language == "zh" ? zh : en
    }

    private var repositoryURL: URL? {
        if let raw = Bundle.main.infoDictionary?["ProjectRepositoryURL"] as? String,
           let url = URL(string: raw) {
            return url
        }

        guard let owner = gitHubOwner, let repository = gitHubRepository else { return nil }
        return URL(string: "https://github.com/\(owner)/\(repository)")
    }

    private var gitHubOwner: String? {
        (Bundle.main.infoDictionary?["ProjectGitHubOwner"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
    }

    private var gitHubRepository: String? {
        (Bundle.main.infoDictionary?["ProjectGitHubRepository"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
    }

    private enum RemoteConnectionState {
        case idle
        case success
        case failure
    }

    private enum UpdateCheckState {
        case idle
        case upToDate
        case updateAvailable
        case failure
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
            remoteHostInput = appState.remoteHost
            remotePortInput = "\(appState.remotePort)"
        }
        .onChange(of: hideDockIcon) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: "hideDockIcon")
            updateDockIconVisibility(hidden: newValue)
        }
        .onChange(of: showNotifications) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: "showNotifications")
        }
        .onChange(of: lowQuotaThreshold) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: "lowQuotaThreshold")
        }
        .onChange(of: appState.autoRefreshInterval) { _, _ in
            appState.saveSettings()
            appState.setupAutoRefresh()
        }
        .onChange(of: appState.isDarkMode) { _, _ in
            appState.saveSettings()
        }
        .onChange(of: appState.quotaIndicatorStyle) { _, _ in
            appState.saveSettings()
        }
        .onChange(of: appState.quotaIndicatorMetric) { _, _ in
            appState.saveSettings()
        }
        .onChange(of: appState.language) { _, _ in
            appState.saveSettings()
            appState.refreshAllProviders()
        }
    }

    @ViewBuilder
    private func settingsSections(for availableWidth: CGFloat) -> some View {
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

    private var settingsBackground: some View {
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

    private var settingsHero: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(t("Settings", "设置"))
                .font(.system(size: 30, weight: .bold, design: .rounded))

            Text(
                t(
                    "Tune refresh, appearance, notifications, and backend behavior in one place.",
                    "把刷新、外观、通知和后端模式放到一个地方统一调整。"
                )
            )
            .font(.body)
            .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                heroPill(
                    title: t("Backend", "后端"),
                    value: appState.backendMode == "remote" ? t("Remote", "远程") : t("Local", "本地"),
                    tint: .blue
                )
                heroPill(
                    title: t("Auto Refresh", "自动刷新"),
                    value: autoRefreshTitle(for: appState.autoRefreshInterval),
                    tint: .teal
                )
                heroPill(
                    title: t("Theme", "主题"),
                    value: appState.isDarkMode ? t("Dark", "深色") : t("Light", "浅色"),
                    tint: .orange
                )
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 28)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var backendCard: some View {
        settingsCard(
            title: t("Backend", "后端"),
            subtitle: t("Choose whether AIUsage reads data locally or from a remote QuotaServer.", "选择 AIUsage 从本地还是远程 QuotaServer 读取数据。")
        ) {
            settingsBlock(title: t("Mode", "模式")) {
                Picker("", selection: $appState.backendMode) {
                    Text(t("Local", "本地")).tag("local")
                    Text(t("Remote", "远程")).tag("remote")
                }
                .pickerStyle(.segmented)
                .onChange(of: appState.backendMode) { _, _ in
                    appState.saveSettings()
                    appState.refreshAllProviders()
                }
            }

            if appState.backendMode == "remote" {
                Divider()

                settingsBlock(title: t("Host", "地址")) {
                    TextField("127.0.0.1", text: $remoteHostInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { applyRemoteSettings() }
                }

                Divider()

                settingsBlock(title: t("Port", "端口")) {
                    TextField("4318", text: $remotePortInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 120, alignment: .leading)
                        .onSubmit { applyRemoteSettings() }
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Button(t("Apply", "应用")) { applyRemoteSettings() }
                            .buttonStyle(.borderedProminent)

                        Button {
                            Task { await testRemoteConnection() }
                        } label: {
                            HStack(spacing: 6) {
                                if isTestingRemoteConnection {
                                    SmallProgressView()
                                        .frame(width: 12, height: 12)
                                } else {
                                    Image(systemName: "bolt.horizontal.circle")
                                }
                                Text(t("Test Connection", "测试连接"))
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isTestingRemoteConnection)
                    }

                    remoteConnectionStatusView

                    Text(
                        t(
                            "Connect to a QuotaServer running on another machine. Start server: swift run QuotaServer --host 0.0.0.0 --port 4318",
                            "连接到其他机器上的 QuotaServer。启动命令：swift run QuotaServer --host 0.0.0.0 --port 4318"
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var generalCard: some View {
        settingsCard(
            title: t("General", "通用"),
            subtitle: t("Control refresh cadence and language.", "控制刷新频率和界面语言。")
        ) {
            settingsBlock(title: t("Auto-refresh interval", "自动刷新间隔")) {
                Picker("", selection: $appState.autoRefreshInterval) {
                    ForEach(AppState.supportedAutoRefreshIntervals, id: \.self) { interval in
                        Text(autoRefreshTitle(for: interval)).tag(interval)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 180, alignment: .leading)
            }

            Divider()

            settingsToggleRow(
                title: t("Dark Mode", "深色模式"),
                subtitle: t("Use a darker app appearance for low-light work.", "使用更适合低光环境的界面风格。"),
                isOn: $appState.isDarkMode
            )

            Divider()

            settingsBlock(title: t("Language", "语言")) {
                Picker("", selection: $appState.language) {
                    Text("English").tag("en")
                    Text("中文").tag("zh")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220, alignment: .leading)
            }
        }
    }

    private var appearanceCard: some View {
        settingsCard(
            title: t("Appearance", "外观"),
            subtitle: t("Adjust how quota cards present information.", "调整额度卡片的呈现方式。")
        ) {
            settingsToggleRow(
                title: t("Hide Dock Icon", "隐藏 Dock 图标"),
                subtitle: t("Keep AIUsage in the menu bar only.", "让 AIUsage 只出现在菜单栏。"),
                isOn: $hideDockIcon
            )
            .help(t("The app will only appear in the menu bar", "应用将只显示在菜单栏"))

            Divider()

            settingsToggleRow(
                title: t("Launch at Login", "开机启动"),
                subtitle: t("Open AIUsage automatically after login.", "登录系统后自动打开 AIUsage。"),
                isOn: $launchAtLogin
            )

            Divider()

            settingsBlock(title: t("Quota card style", "额度卡片样式")) {
                Picker("", selection: $appState.quotaIndicatorStyle) {
                    ForEach(CardQuotaIndicatorStyle.allCases, id: \.self) { style in
                        Text(quotaStyleTitle(style)).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 340, alignment: .leading)
            }

            Divider()

            settingsBlock(title: t("Progress meaning", "进度语义")) {
                Picker("", selection: $appState.quotaIndicatorMetric) {
                    ForEach(CardQuotaIndicatorMetric.allCases, id: \.self) { metric in
                        Text(quotaMetricTitle(metric)).tag(metric)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240, alignment: .leading)
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text(t("Preview", "预览"))
                    .font(.subheadline.weight(.semibold))

                quotaIndicatorPreview

                Text(t("Applies instantly to all provider cards.", "会立即应用到所有服务卡片。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var notificationsCard: some View {
        settingsCard(
            title: t("Notifications", "通知"),
            subtitle: t("Decide when AIUsage should proactively nudge you.", "设置 AIUsage 在什么情况下主动提醒你。")
        ) {
            settingsToggleRow(
                title: t("Enable Notifications", "启用通知"),
                subtitle: t("Show desktop alerts for low quota and other status changes.", "为低额度和状态变化显示桌面提醒。"),
                isOn: $showNotifications
            )

            Divider()

            settingsBlock(
                title: t("Low Quota Alert", "低额度提醒"),
                subtitle: t("Trigger when remaining quota drops below the selected threshold.", "当剩余额度低于阈值时触发提醒。")
            ) {
                HStack(spacing: 14) {
                    Slider(value: $lowQuotaThreshold, in: 5...50, step: 5)
                    Text("\(Int(lowQuotaThreshold))%")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 54, alignment: .trailing)
                }
            }
            .opacity(showNotifications ? 1 : 0.45)
            .disabled(!showNotifications)
        }
    }

    private var aboutCard: some View {
        settingsCard(
            title: t("About", "关于"),
            subtitle: t("Version information and update checks.", "版本信息与更新检查。")
        ) {
            settingsValueRow(title: t("Version", "版本"), value: appVersion)
            Divider()
            settingsValueRow(title: t("Build", "构建号"), value: appBuild)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    if let repositoryURL {
                        Link(destination: repositoryURL) {
                            Label("GitHub", systemImage: "link")
                        }
                    }

                    Button {
                        Task { await checkForUpdates() }
                    } label: {
                        HStack(spacing: 6) {
                            if isCheckingForUpdates {
                                SmallProgressView()
                                    .frame(width: 12, height: 12)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath.circle")
                            }
                            Text(t("Check for Updates", "检查更新"))
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isCheckingForUpdates)
                }

                updateStatusView
            }
        }
    }

    private func heroPill(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(tint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func settingsCard<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title3.weight(.bold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func settingsBlock<Content: View>(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsToggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            Toggle("", isOn: isOn)
                .labelsHidden()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsValueRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
    
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }
    
    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    private func quotaStyleTitle(_ style: CardQuotaIndicatorStyle) -> String {
        switch style {
        case .bar:
            return t("Bar", "条形")
        case .ring:
            return t("Ring", "圆环")
        case .segments:
            return t("Segments", "分段")
        }
    }

    private func autoRefreshTitle(for interval: Int) -> String {
        switch interval {
        case 0:
            return t("Off", "关闭")
        case 30:
            return t("30 seconds", "30 秒")
        case 60:
            return t("1 minute", "1 分钟")
        case 180:
            return t("3 minutes", "3 分钟")
        case 300:
            return t("5 minutes", "5 分钟")
        case 600:
            return t("10 minutes", "10 分钟")
        case 900:
            return t("15 minutes", "15 分钟")
        case 1800:
            return t("30 minutes", "30 分钟")
        case 3600:
            return t("1 hour", "1 小时")
        default:
            return interval >= 60
                ? t("\(interval / 60) minutes", "\(interval / 60) 分钟")
                : t("\(interval) seconds", "\(interval) 秒")
        }
    }

    private func quotaMetricTitle(_ metric: CardQuotaIndicatorMetric) -> String {
        switch metric {
        case .remaining:
            return t("Remaining", "剩余")
        case .used:
            return t("Used", "已用")
        }
    }

    private var previewRemainingPercent: Double {
        68
    }

    private var previewDisplayPercent: Double {
        appState.quotaIndicatorMetric == .remaining ? previewRemainingPercent : 100 - previewRemainingPercent
    }

    private var previewValueText: String {
        let rounded = (previewDisplayPercent * 10).rounded() / 10
        if abs(rounded.rounded() - rounded) < 0.05 {
            return "\(Int(rounded.rounded()))%"
        }
        return String(format: "%.1f%%", rounded)
    }

    private var quotaIndicatorPreview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("Cursor")
                            .font(.headline)
                            .bold()

                        Text("Pro")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.12))
                            .clipShape(Capsule())
                    }

                    Text(t("Sample Card", "示例卡片"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(previewValueText)
                        .font(.system(size: 28, weight: .bold, design: .rounded))

                    Text(
                        appState.quotaIndicatorMetric == .remaining
                        ? t("Healthy reserve for the current cycle", "当前周期余量依然充足")
                        : t("Usage is visible without feeling alarming", "使用趋势清晰，但还不紧张")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 16)

                QuotaIndicatorView(remainingPercent: previewRemainingPercent, accentColor: .blue)
                    .frame(width: appState.quotaIndicatorStyle == .ring ? 120 : 220)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
    
    private var remoteConnectionStatusView: some View {
        let icon: String
        let tint: Color
        let title: String
        switch remoteConnectionState {
        case .idle:
            icon = "network"; tint = .secondary; title = t("Connection not tested", "\u{5C1A}\u{672A}\u{6D4B}\u{8BD5}\u{8FDE}\u{63A5}")
        case .success:
            icon = "checkmark.circle.fill"; tint = .green; title = t("Remote server reachable", "\u{8FDC}\u{7A0B}\u{670D}\u{52A1}\u{53EF}\u{8FDE}\u{63A5}")
        case .failure:
            icon = "xmark.octagon.fill"; tint = .red; title = t("Connection failed", "\u{8FDE}\u{63A5}\u{5931}\u{8D25}")
        }

        return HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(remoteConnectionMessage?.nilIfBlank ?? title)
                .font(.caption)
                .foregroundStyle(tint)
            Spacer()
        }
        .padding(8)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var updateStatusView: some View {
        let icon: String
        let tint: Color
        let title: String

        switch updateCheckState {
        case .idle:
            icon = "shippingbox"
            tint = .secondary
            title = t("GitHub Releases not checked yet", "尚未检查 GitHub Releases")
        case .upToDate:
            icon = "checkmark.circle.fill"
            tint = .green
            title = t("Current version is up to date", "当前版本已是最新")
        case .updateAvailable:
            icon = "arrow.down.circle.fill"
            tint = .blue
            title = t("A newer release is available", "发现新版本")
        case .failure:
            icon = "xmark.octagon.fill"
            tint = .red
            title = t("Update check failed", "检查更新失败")
        }

        return HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(updateCheckMessage?.nilIfBlank ?? title)
                .font(.caption)
                .foregroundStyle(tint)
            Spacer()
            if updateCheckState == .updateAvailable,
               let releaseURL = latestRelease?.preferredAssetURL ?? latestRelease?.htmlURL {
                Button(t("Download", "下载")) {
                    NSWorkspace.shared.open(releaseURL)
                }
                .buttonStyle(.plain)
                .foregroundStyle(tint)
            }
        }
        .padding(8)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func applyRemoteSettings(refreshDashboard: Bool = true) {
        let host = remoteHostInput.trimmingCharacters(in: .whitespaces)
        let port = Int(remotePortInput.trimmingCharacters(in: .whitespaces)) ?? 4318
        appState.remoteHost = host.isEmpty ? "127.0.0.1" : host
        appState.remotePort = port
        appState.saveSettings()
        remoteConnectionState = .idle
        remoteConnectionMessage = nil
        if refreshDashboard {
            appState.refreshAllProviders()
        }
    }

    @MainActor
    private func testRemoteConnection() async {
        applyRemoteSettings(refreshDashboard: false)
        isTestingRemoteConnection = true
        defer { isTestingRemoteConnection = false }

        APIService.shared.updateBaseURL("http://\(appState.remoteHost):\(appState.remotePort)")
        let startedAt = Date()

        do {
            let response = try await APIService.shared.checkHealth()
            let latencyMs = max(1, Int(Date().timeIntervalSince(startedAt) * 1000))
            remoteConnectionState = response.ok ? .success : .failure
            remoteConnectionMessage = t(
                "Responded in \(latencyMs) ms · \(response.generatedAt)",
                "响应耗时 \(latencyMs) ms · \(response.generatedAt)"
            )
        } catch {
            remoteConnectionState = .failure
            remoteConnectionMessage = error.localizedDescription
        }
    }

    @MainActor
    private func checkForUpdates() async {
        guard let owner = gitHubOwner, let repository = gitHubRepository else {
            updateCheckState = .failure
            updateCheckMessage = t(
                "GitHub repository is not configured",
                "GitHub 仓库尚未配置"
            )
            latestRelease = nil
            return
        }

        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }

        do {
            let release = try await GitHubReleaseClient.fetchLatestRelease(owner: owner, repository: repository)
            latestRelease = release

            let currentVersion = normalizedVersion(appVersion)
            let latestVersion = normalizedVersion(release.versionString)

            switch compareVersionStrings(currentVersion, latestVersion) {
            case .orderedAscending:
                updateCheckState = .updateAvailable
                updateCheckMessage = t(
                    "Latest release: \(latestVersion) · published \(release.displayPublishedAt)",
                    "最新版本：\(latestVersion) · 发布时间 \(release.displayPublishedAt)"
                )
            default:
                updateCheckState = .upToDate
                updateCheckMessage = t(
                    "Current: \(currentVersion) · latest: \(latestVersion)",
                    "当前版本：\(currentVersion) · 最新版本：\(latestVersion)"
                )
            }
        } catch {
            updateCheckState = .failure
            updateCheckMessage = error.localizedDescription
        }
    }

    private func normalizedVersion(_ version: String) -> String {
        version.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^[vV]\s*"#, with: "", options: .regularExpression)
    }

    private func compareVersionStrings(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = versionComponents(from: lhs)
        let right = versionComponents(from: rhs)
        let count = max(left.count, right.count)

        for index in 0..<count {
            let leftValue = index < left.count ? left[index] : 0
            let rightValue = index < right.count ? right[index] : 0
            if leftValue < rightValue { return .orderedAscending }
            if leftValue > rightValue { return .orderedDescending }
        }

        return .orderedSame
    }

    private func versionComponents(from version: String) -> [Int] {
        version
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
    }

    private func updateDockIconVisibility(hidden: Bool) {
        if hidden {
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
        }
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let htmlURL: URL
    let publishedAt: String?
    let assets: [GitHubReleaseAsset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case assets
    }

    var versionString: String {
        tagName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? tagName
    }

    var preferredAssetURL: URL? {
        let dmg = assets.first { $0.name.lowercased().hasSuffix(".dmg") }
        let zip = assets.first { $0.name.lowercased().hasSuffix(".zip") }
        return dmg?.downloadURL ?? zip?.downloadURL
    }

    var displayPublishedAt: String {
        guard
            let publishedAt,
            let date = ISO8601DateFormatter().date(from: publishedAt)
        else {
            return "unknown"
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

private struct GitHubReleaseAsset: Decodable {
    let name: String
    let downloadURL: URL

    private enum CodingKeys: String, CodingKey {
        case name
        case downloadURL = "browser_download_url"
    }
}

private enum GitHubReleaseClient {
    static func fetchLatestRelease(owner: String, repository: String) async throws -> GitHubRelease {
        guard
            let escapedOwner = owner.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
            let escapedRepository = repository.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
            let url = URL(string: "https://api.github.com/repos/\(escapedOwner)/\(escapedRepository)/releases/latest")
        else {
            throw GitHubReleaseError.invalidRepository
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AIUsage", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubReleaseError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            do {
                return try JSONDecoder().decode(GitHubRelease.self, from: data)
            } catch {
                throw GitHubReleaseError.decodingFailed
            }
        case 404:
            throw GitHubReleaseError.notFound
        case 403:
            throw GitHubReleaseError.rateLimited
        default:
            throw GitHubReleaseError.httpError(httpResponse.statusCode)
        }
    }
}

private enum GitHubReleaseError: LocalizedError {
    case invalidRepository
    case invalidResponse
    case notFound
    case rateLimited
    case decodingFailed
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidRepository:
            return "Invalid GitHub repository"
        case .invalidResponse:
            return "Invalid GitHub response"
        case .notFound:
            return "GitHub repository or release not found"
        case .rateLimited:
            return "GitHub API rate limit reached"
        case .decodingFailed:
            return "Failed to parse GitHub release data"
        case .httpError(let code):
            return "GitHub API returned HTTP \(code)"
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState.shared)
}
