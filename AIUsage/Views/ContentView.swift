import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedSection: AppSection = AppState.shared.selectedSection
    
    private func t(_ en: String, _ zh: String) -> String {
        appState.language == "zh" ? zh : en
    }

    private var inboxLabel: some View {
        HStack {
            Label(t("Inbox", "消息"), systemImage: appState.unreadAlertCount > 0 ? "bell.badge.fill" : "bell.fill")
            Spacer()
            if appState.unreadAlertCount > 0 {
                Text("\(appState.unreadAlertCount)")
                    .font(.caption2)
                    .bold()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red)
                    .clipShape(Capsule())
            }
        }
    }
    
    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                Label(t("Dashboard", "仪表盘"), systemImage: "chart.bar.doc.horizontal")
                    .tag(AppSection.dashboard)

                Label(t("Providers", "服务商"), systemImage: "square.grid.2x2")
                    .tag(AppSection.providers)

                Label(t("Cost Tracking", "费用追踪"), systemImage: "banknote")
                    .tag(AppSection.costTracking)

                inboxLabel
                    .tag(AppSection.inbox)

                Divider()

                Label(t("Settings", "设置"), systemImage: "gearshape")
                    .tag(AppSection.settings)
            }
            .listStyle(.sidebar)
            .frame(minWidth: 200)
            .navigationTitle("AIUsage")
        } detail: {
            // 主内容区
            ZStack {
                switch selectedSection {
                case .dashboard:
                    DashboardView()
                case .providers:
                    ProvidersView()
                case .costTracking:
                    CostTrackingView()
                case .inbox:
                    InboxView()
                case .settings:
                    SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            selectedSection = appState.selectedSection
        }
        .onChange(of: selectedSection) { _, newValue in
            guard appState.selectedSection != newValue else { return }
            DispatchQueue.main.async {
                appState.selectedSection = newValue
            }
        }
        .onChange(of: appState.selectedSection) { _, newValue in
            guard selectedSection != newValue else { return }
            selectedSection = newValue
        }
        .task {
            await appState.performStartupFlowIfNeeded()
            await appState.fetchDashboard()
        }
        .sheet(item: $appState.providerPickerMode) { mode in
            ProviderPickerView(mode: mode)
                .environmentObject(appState)
                .interactiveDismissDisabled(mode == .initialSetup)
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button(action: { appState.refreshAllProviders() }) {
                    HStack(spacing: 5) {
                        if appState.isLoading || appState.isRefreshingAllProviders {
                            SmallProgressView().frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(t("Refresh All", "全部刷新"))
                            .font(.subheadline)
                    }
                }
                .help(t("Refresh every app and every account", "刷新所有应用和所有账号"))
                .disabled(appState.isLoading || appState.isRefreshingAllProviders)
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState.shared)
        .frame(width: 1100, height: 700)
}
