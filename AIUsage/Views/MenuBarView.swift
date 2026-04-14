import SwiftUI

// MARK: - Menu Bar View (Main Container)

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var refreshCoordinator: ProviderRefreshCoordinator
    @State private var activationMessage: String?
    @State private var activationSuccess = true
    var body: some View {
        VStack(spacing: 0) {
            menuBarHeader
            Divider()
            menuBarContent
            Divider()
            menuBarFooter
        }
        .frame(width: 400)
        .background(VisualEffectBlur())
    }

    // MARK: - Header

    private var menuBarHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("AIUsage")
                    .font(.system(size: 14, weight: .bold, design: .rounded))

                if let lastRefresh = refreshCoordinator.lastRefreshTime {
                    RefreshableTimeView(
                        date: lastRefresh,
                        language: appState.language,
                        font: .system(size: 10),
                        foregroundStyle: .secondary
                    )
                } else {
                    Text(L("Not refreshed yet", "尚未刷新"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                refreshCoordinator.refreshAllProviders()
            } label: {
                Group {
                    if refreshCoordinator.isLoading || refreshCoordinator.isRefreshingAllProviders {
                        SmallProgressView().frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.06))
                .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(refreshCoordinator.isLoading || refreshCoordinator.isRefreshingAllProviders)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Content

    private var menuBarContent: some View {
        Group {
            if refreshCoordinator.isLoading && refreshCoordinator.providers.isEmpty {
                VStack(spacing: 12) {
                    SmallProgressView().frame(width: 20, height: 20)
                    Text(L("Loading...", "加载中..."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            } else if appState.providerAccountGroups.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text(L("No providers", "暂无服务"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(appState.providerAccountGroups) { group in
                            MenuBarProviderSection(
                                group: group,
                                activationMessage: $activationMessage,
                                activationSuccess: $activationSuccess
                            )
                            .environmentObject(appState)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 800)
                .overlay(alignment: .bottom) {
                    if let message = activationMessage {
                        activationToast(message: message, success: activationSuccess)
                    }
                }
            }
        }
    }

    private func activationToast(message: String, success: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(success ? .green : .red)
                .font(.system(size: 12))
            Text(message)
                .font(.system(size: 11))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation(.easeOut(duration: 0.3)) {
                    activationMessage = nil
                }
            }
        }
    }

    // MARK: - Footer

    private var menuBarFooter: some View {
        HStack(spacing: 0) {
            footerButton(L("Dashboard", "面板"), icon: "rectangle.3.group") {
                openMainWindow(section: .dashboard)
            }
            footerButton(L("Cost", "费用"), icon: "dollarsign.circle") {
                openMainWindow(section: .costTracking)
            }
            footerButton(L("Settings", "设置"), icon: "gearshape") {
                openSettings()
            }

            Spacer()

            footerButton(L("Quit", "退出"), icon: "power") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func footerButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                Text(title)
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .frame(width: 56, height: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    private func openMainWindow(section: AppSection) {
        AppState.shared.selectedSection = section
        NSApp.activate(ignoringOtherApps: true)
        let window = NSApp.windows.max(by: { $0.frame.width < $1.frame.width }) ?? NSApp.windows.first
        if let window {
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func openSettings() {
        openMainWindow(section: .settings)
    }
}

// MARK: - Provider Section

struct MenuBarProviderSection: View {
    let group: ProviderAccountGroup
    @Binding var activationMessage: String?
    @Binding var activationSuccess: Bool
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    private var accentColor: Color {
        switch group.providerId {
        case "antigravity": return .cyan
        case "copilot": return .blue
        case "claude": return .purple
        case "cursor": return .green
        case "gemini": return .orange
        case "kiro": return .purple
        case "codex": return .indigo
        case "droid": return .yellow
        case "warp": return .pink
        case "amp": return .teal
        default: return .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 4)

            ForEach(group.accounts) { entry in
                MenuBarAccountRow(
                    entry: entry,
                    providerId: group.providerId,
                    accentColor: accentColor,
                    activationMessage: $activationMessage,
                    activationSuccess: $activationSuccess
                )
                .environmentObject(appState)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.025))
        )
        .padding(.vertical, 2)
    }

    private var sectionHeader: some View {
        HStack(spacing: 8) {
            ProviderIconView(group.providerId, size: 16)

            Text(group.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)

            if group.accounts.count > 1 {
                Text("\(group.accounts.count)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
            }

            Spacer()

            if let channel = group.channel {
                Text(channel.uppercased())
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Account Row

struct MenuBarAccountRow: View {
    let entry: ProviderAccountEntry
    let providerId: String
    let accentColor: Color
    @Binding var activationMessage: String?
    @Binding var activationSuccess: Bool
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var activationManager: ProviderActivationManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    private var isActive: Bool {
        activationManager.isActiveAccount(entry)
    }

    private var canActivate: Bool {
        activationManager.canActivateProvider(providerId) && !isActive
    }

    private var remainingPercent: Double? {
        entry.liveProvider?.remainingPercent
    }

    private var isCostProvider: Bool {
        entry.liveProvider?.category == "local-cost"
    }

    private var costMonthUsd: Double? {
        entry.liveProvider?.costSummary?.month?.usd
    }

    private var primaryLabel: String {
        if let email = entry.accountEmail, !email.isEmpty { return email }
        if let name = entry.accountDisplayName, !name.isEmpty { return name }
        return entry.providerTitle
    }

    private var secondaryLabel: String? {
        if let note = entry.accountNote, !note.isEmpty { return note }
        return nil
    }

    var body: some View {
        HStack(spacing: 8) {
            if isCostProvider {
                statusDot(color: entry.isConnected ? .orange : .gray)
            } else if let percent = remainingPercent {
                MiniQuotaRing(remainingPercent: percent, accentColor: accentColor)
            } else if entry.isConnected {
                let dotColor: Color = entry.liveProvider?.status == .error ? .orange : .green
                statusDot(color: dotColor)
            } else {
                statusDot(color: .gray)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(primaryLabel)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                if let secondary = secondaryLabel {
                    Text(secondary)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if isCostProvider, let usd = costMonthUsd {
                Text(formatCostCompact(usd))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.orange)
            } else if let percent = remainingPercent {
                Text("\(Int(percent))%")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(percentColor(percent))
            }

            if isActive && activationManager.canActivateProvider(providerId) {
                activeBadge
            } else if canActivate {
                switchButton
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            if canActivate { performActivation() }
        }
    }

    private func statusDot(color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .frame(width: 28, height: 28)
    }

    private var activeBadge: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(.green)
                .frame(width: 6, height: 6)
            Text(L("Active", "活跃"))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.green)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.green.opacity(0.12))
        .clipShape(Capsule())
    }

    private var switchButton: some View {
        Button {
            performActivation()
        } label: {
            Text(L("Switch", "切换"))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(accentColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(accentColor.opacity(0.12))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func performActivation() {
        do {
            try activationManager.activateAccount(entry: entry)
            withAnimation(.easeInOut(duration: 0.3)) {
                activationSuccess = true
                activationMessage = L("Switched to ", "已切换至 ") + primaryLabel
            }
        } catch {
            withAnimation(.easeInOut(duration: 0.3)) {
                activationSuccess = false
                activationMessage = L("Switch failed", "切换失败")
            }
        }
    }

    private func percentColor(_ percent: Double) -> Color {
        if percent >= 70 { return Color(red: 0.15, green: 0.78, blue: 0.40) }
        if percent >= 35 { return Color(red: 0.96, green: 0.64, blue: 0.18) }
        return Color(red: 0.92, green: 0.25, blue: 0.28)
    }

    private func formatCostCompact(_ usd: Double) -> String {
        if usd == 0 { return "$0" }
        if usd < 1 { return String(format: "$%.2f", usd) }
        if usd < 100 { return String(format: "$%.1f", usd) }
        return String(format: "$%.0f", usd)
    }
}

// MARK: - Mini Quota Ring

struct MiniQuotaRing: View {
    let remainingPercent: Double
    let accentColor: Color

    @Environment(\.colorScheme) private var colorScheme

    private var clamped: Double {
        min(max(remainingPercent, 0), 100)
    }

    private var gradientColors: [Color] {
        switch clamped {
        case 70...:
            return [
                Color(red: 0.37, green: 0.94, blue: 0.62),
                Color(red: 0.11, green: 0.74, blue: 0.39)
            ]
        case 35...:
            return [
                Color(red: 1.00, green: 0.84, blue: 0.34),
                Color(red: 0.96, green: 0.56, blue: 0.17)
            ]
        default:
            return [
                Color(red: 1.00, green: 0.54, blue: 0.28),
                Color(red: 0.90, green: 0.20, blue: 0.29)
            ]
        }
    }

    private var trackColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(trackColor, lineWidth: 3.5)

            Circle()
                .trim(from: 0, to: clamped / 100)
                .stroke(
                    AngularGradient(
                        colors: [
                            gradientColors[0].opacity(0.6),
                            gradientColors[0],
                            gradientColors[1],
                            gradientColors[1].opacity(0.6)
                        ],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 28, height: 28)
    }
}

// MARK: - Visual Effect Blur

struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

#Preview {
    MenuBarView()
        .environmentObject(AppState.shared)
        .environmentObject(ProviderRefreshCoordinator.shared)
        .environmentObject(ProviderActivationManager.shared)
}
