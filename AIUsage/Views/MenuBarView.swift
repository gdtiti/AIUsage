import SwiftUI

struct MenuBarView: View {
    @StateObject private var appState = AppState.shared

    private func t(_ en: String, _ zh: String) -> String {
        appState.language == "zh" ? zh : en
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 头部
            header
            
            Divider()
            
            // 提供商列表
            if appState.isLoading {
                loadingView
            } else if !appState.providers.isEmpty {
                providersList
            } else {
                emptyView
            }
            
            Divider()
            
            // 底部操作
            footer
        }
        .frame(width: 400, height: 500)
        .background(VisualEffectBlur())
    }
    
    // MARK: - Header
    
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("AIUsage")
                    .font(.headline)
                    .bold()
                
                if let lastRefresh = appState.lastRefreshTime {
                    Text(t("All apps updated", "全局更新于") + " " + formatRefreshTimestamp(lastRefresh, language: appState.language))
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text(t("Never updated", "尚未更新"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // 刷新按钮
            Button(action: { appState.refreshAllProviders() }) {
                Group {
                    if appState.isLoading || appState.isRefreshingAllProviders {
                        SmallProgressView().frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 16))
                    }
                }
            }
            .buttonStyle(.borderless)
            .disabled(appState.isLoading || appState.isRefreshingAllProviders)
            .help(t("Refresh every app and every account", "刷新所有应用和所有账号"))
        }
        .padding()
    }
    
    // MARK: - Providers List
    
    private var providersList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(appState.providers) { provider in
                    MenuBarProviderRow(provider: provider)
                        .environmentObject(appState)
                }
            }
            .padding()
        }
    }
    
    // MARK: - Loading View
    
    private var loadingView: some View {
        VStack(spacing: 16) {
            SmallProgressView().frame(width: 24, height: 24)
            Text(t("Loading...", "加载中..."))
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Empty View
    
    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            
            Text(t("No providers available", "暂无可用服务"))
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Button(t("Refresh", "刷新")) {
                appState.refreshAllProviders()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
    
    // MARK: - Footer
    
    private var footer: some View {
        HStack {
            Button(t("Open Dashboard", "打开面板")) {
                openMainWindow()
            }
            .buttonStyle(.borderedProminent)
            
            Spacer()
            
            Button(t("Settings", "设置")) {
                openSettings()
            }
            .buttonStyle(.borderless)
            
            Button(t("Quit", "退出")) {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
        }
        .padding()
    }
    
    // MARK: - Actions
    
    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
    }
    
    private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

// MARK: - Menu Bar Provider Row

struct MenuBarProviderRow: View {
    let provider: ProviderData
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        HStack(spacing: 12) {
            // 图标
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.15))
                    .frame(width: 32, height: 32)
                
                ProviderIconView(provider.providerId, size: 18)
            }
            
            // 信息
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.label)
                    .font(.subheadline)
                    .bold()
                
                Text(provider.headline.primary)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // 百分比或状态
            if let remaining = provider.remainingPercent {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(remaining))%")
                        .font(.headline)
                        .bold()
                        .foregroundColor(remaining > 50 ? .green : remaining > 20 ? .orange : .red)
                    
                    Text(appState.language == "zh" ? "剩余" : "remaining")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } else {
                Image(systemName: statusIcon)
                    .foregroundColor(statusColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }
    
    private var statusColor: Color {
        switch provider.status {
        case .healthy: return .green
        case .watch: return .orange
        case .critical: return .red
        case .error: return .gray
        case .tracking: return .blue
        case .idle: return .secondary
        }
    }
    
    private var statusIcon: String {
        switch provider.status {
        case .healthy: return "checkmark.circle.fill"
        case .watch: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.circle.fill"
        case .error: return "exclamationmark.circle.fill"
        case .tracking: return "chart.line.uptrend.xyaxis"
        case .idle: return "moon.fill"
        }
    }
    
}

// MARK: - Visual Effect Blur (毛玻璃效果)

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
}
