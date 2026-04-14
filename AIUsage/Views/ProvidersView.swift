import SwiftUI
import QuotaBackend

struct ProvidersView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var accountStore: AccountStore
    @State private var searchText = ""
    @State private var selectedChannel: String = "all"
    @State private var selectedProviderFilter: String = "all"
    @State private var accountEditorTarget: ProviderEditorTarget?
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            filterBar
            Divider()

            if filteredGroups.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(filteredGroups) { group in
                            ProviderAccountGroupSection(
                                group: group,
                                onAddAccount: {
                                    accountEditorTarget = ProviderEditorTarget(providerId: group.providerId)
                                }
                            )
                            .environmentObject(appState)
                        }
                    }
                    .padding()
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $accountEditorTarget) { target in
            ProviderAccountEditorView(providerId: target.providerId)
                .environmentObject(appState)
        }
    }

    private var serviceGroups: [ProviderAccountGroup] {
        appState.providerAccountGroups.filter { group in
            appState.providerCatalogItem(for: group.providerId)?.kind == .official
        }
    }

    private var availableProviderFilters: [ProviderAccountGroup] {
        serviceGroups.filter { selectedChannel == "all" || $0.channel == selectedChannel }
    }

    private var filteredGroups: [ProviderAccountGroup] {
        availableProviderFilters.compactMap { group -> ProviderAccountGroup? in
            guard selectedProviderFilter == "all" || group.providerId == selectedProviderFilter else { return nil }

            if group.accounts.isEmpty {
                let matchesGroup = searchText.isEmpty || group.title.localizedCaseInsensitiveContains(searchText)
                return matchesGroup ? group : nil
            }

            let filteredAccounts = group.accounts.filter { account in
                searchText.isEmpty ||
                group.title.localizedCaseInsensitiveContains(searchText) ||
                (account.accountEmail?.localizedCaseInsensitiveContains(searchText) ?? false) ||
                (account.accountDisplayName?.localizedCaseInsensitiveContains(searchText) ?? false) ||
                (account.accountNote?.localizedCaseInsensitiveContains(searchText) ?? false)
            }

            if filteredAccounts.isEmpty {
                let matchesGroup = searchText.isEmpty || group.title.localizedCaseInsensitiveContains(searchText)
                guard matchesGroup else { return nil }
                return ProviderAccountGroup(
                    id: group.id,
                    providerId: group.providerId,
                    title: group.title,
                    subtitle: group.subtitle,
                    channel: group.channel,
                    isScanningEnabled: group.isScanningEnabled,
                    accounts: []
                )
            }

            return ProviderAccountGroup(
                id: group.id,
                providerId: group.providerId,
                title: group.title,
                subtitle: group.subtitle,
                channel: group.channel,
                isScanningEnabled: group.isScanningEnabled,
                accounts: filteredAccounts
            )
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 16) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)

                TextField(L("Search accounts...", "搜索账号..."), text: $searchText)
                    .textFieldStyle(.plain)

                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)

            Picker(L("Channel", "渠道"), selection: $selectedChannel) {
                Text(L("All", "全部")).tag("all")
                Text("CLI").tag("cli")
                Text("IDE").tag("ide")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            Spacer()

            Button {
                appState.presentManageProviderPicker()
            } label: {
                Label(L("Manage Sources", "管理来源"), systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.bordered)

            if !accountStore.hiddenAccounts().isEmpty {
                Menu {
                    ForEach(accountStore.hiddenAccounts()) { storedAccount in
                        Button {
                            appState.restoreAccount(storedAccount.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(storedAccount.preferredLabel)
                                Text(appState.providerCatalogItem(for: storedAccount.providerId)?.title(for: appState.language) ?? storedAccount.providerId)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } label: {
                    Label(L("Hidden Accounts", "已隐藏账号"), systemImage: "eye.slash")
                }
            }

            Button {
                if appState.unselectedProviderCatalog.filter({ $0.kind == .official }).isEmpty {
                    appState.presentManageProviderPicker()
                } else {
                    appState.presentAddProviderPicker()
                }
            } label: {
                Label(L("Add App", "添加应用"), systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding([.horizontal, .top])
        .padding(.bottom, 10)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                providerFilterChip(id: "all", title: L("All Apps", "全部应用"))

                ForEach(availableProviderFilters) { group in
                    providerFilterChip(id: group.providerId, title: group.title, providerId: group.providerId)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
    }

    private func providerFilterChip(id: String, title: String, providerId: String? = nil) -> some View {
        let isSelected = selectedProviderFilter == id

        return Button {
            selectedProviderFilter = id
        } label: {
            HStack(spacing: 8) {
                if let providerId {
                    ProviderIconView(providerId, size: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 16, height: 16)
                }

                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule()
                    .fill(isSelected ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "person.2.crop.square.stack")
                .font(.system(size: 56))
                .foregroundColor(.secondary)

            Text(L("No accounts found", "未找到账号"))
                .font(.title2)
                .bold()

            if !searchText.isEmpty {
                Text(L("Try another app filter or search keyword.", "试试其他应用筛选或搜索关键词。"))
                    .font(.body)
                    .foregroundColor(.secondary)
            } else {
                Text(L("Add a provider app first, then each app can keep multiple accounts under the same group.", "先添加服务应用，之后每个应用都可以在同一分组下管理多个账号。"))
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)

                Button {
                    appState.presentAddProviderPicker()
                } label: {
                    Label(L("Add App", "添加应用"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct ProviderEditorTarget: Identifiable {
    let providerId: String
    var id: String { providerId }
}
