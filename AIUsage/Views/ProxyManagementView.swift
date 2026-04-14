import SwiftUI

// MARK: - Proxy Management View

struct ProxyManagementView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var viewModel: ProxyViewModel
    @State private var showingNewConfigEditor = false
    @State private var editingConfig: ProxyConfiguration?
    @State private var selectedConfigId: String?
    var body: some View {
        VStack(spacing: 0) {
            if viewModel.configurations.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        summaryStrip
                        configurationsList
                        if let config = selectedConfiguration,
                           config.needsProxyProcess {
                            statisticsSection(for: config)
                            recentRequestsSection(for: config)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: { showingNewConfigEditor = true }) {
                    HStack(spacing: 5) {
                        Image(systemName: "plus.circle.fill")
                        Text(L("New Node", "新建节点"))
                    }
                }
            }
        }
        .sheet(isPresented: $showingNewConfigEditor) {
            ProxyConfigEditorView()
                .environmentObject(viewModel)
                .environmentObject(appState)
        }
        .sheet(item: $editingConfig) { config in
            ProxyConfigEditorView(config: config)
                .environmentObject(viewModel)
                .environmentObject(appState)
        }
        .alert(
            L("Node Operation Failed", "节点操作失败"),
            isPresented: Binding(
                get: { viewModel.operationErrorMessage != nil },
                set: { newValue in
                    if !newValue {
                        viewModel.operationErrorMessage = nil
                    }
                }
            )
        ) {
            Button("OK") {
                viewModel.operationErrorMessage = nil
            }
        } message: {
            Text(viewModel.operationErrorMessage ?? "")
        }
    }

    // MARK: - Summary Strip

    private var summaryStrip: some View {
        HStack(spacing: 12) {
            summaryCell(
                icon: "point.3.connected.trianglepath.dotted",
                title: L("Nodes", "节点数"),
                value: "\(viewModel.configurations.count)",
                tint: .blue
            )
            summaryCell(
                icon: "checkmark.circle.fill",
                title: L("Active", "已激活"),
                value: viewModel.activatedConfigId != nil ? "1" : "0",
                tint: .green
            )
            summaryCell(
                icon: "arrow.up.arrow.down",
                title: L("Total Requests", "总请求"),
                value: formatCompactNumber(Double(totalRequests)),
                tint: .orange
            )
            summaryCell(
                icon: "checkmark.shield.fill",
                title: L("Success Rate", "成功率"),
                value: String(format: "%.1f%%", totalSuccessRate),
                tint: .purple
            )
            summaryCell(
                icon: "bolt.fill",
                title: L("Total Tokens", "总 Tokens"),
                value: formatCompactNumber(Double(totalTokens)),
                tint: .pink
            )
            summaryCell(
                icon: "dollarsign.circle.fill",
                title: L("Total Cost", "总费用"),
                value: formatProxyCurrency(totalCost),
                tint: .red
            )
        }
    }

    private func summaryCell(icon: String, title: String, value: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(tint.opacity(0.12)))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - Configurations List

    private var configurationsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Node Configurations", "节点配置"))
                    .font(.headline.weight(.bold))
                Spacer()
            }

            VStack(spacing: 8) {
                ForEach(viewModel.configurations) { config in
                    configurationCard(config)
                }
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

    private func configurationCard(_ config: ProxyConfiguration) -> some View {
        let isActive = viewModel.activatedConfigId == config.id
        let isBusy = viewModel.isOperationInProgress(config.id)
        let isSelected = selectedConfigId == config.id
        let stats = viewModel.statistics[config.id] ?? .empty

        let brandColor: Color = config.nodeType == .anthropicDirect ? Self.anthropicBrand : Self.openAIBrand

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Circle()
                    .fill(isActive ? brandColor : Color.gray.opacity(0.4))
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(config.name)
                            .font(.system(size: 15, weight: .bold))
                        nodeTypeBadge(config)
                    }
                    Text(config.displayURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if config.needsProxyProcess {
                    HStack(spacing: 16) {
                        statPill(
                            icon: "arrow.up.arrow.down",
                            value: "\(stats.totalRequests)",
                            color: .blue
                        )
                        statPill(
                            icon: "checkmark.circle",
                            value: String(format: "%.0f%%", stats.successRate),
                            color: .green
                        )
                    }
                }

                HStack(spacing: 8) {
                    Button(action: { Task { await viewModel.toggleActivation(config.id) } }) {
                        Group {
                            if isBusy {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: isActive ? "stop.circle.fill" : "power.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(isActive ? .orange : .green)
                            }
                        }
                        .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                    .help(isActive ? L("Deactivate", "停用") : L("Activate", "激活"))

                    Button(action: { editConfig(config) }) {
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                    .help(L("Edit", "编辑"))

                    Button(action: { Task { await deleteConfig(config) } }) {
                        Image(systemName: "trash.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                    .help(L("Delete", "删除"))
                }
            }

            if isSelected {
                Divider()
                configDetailRow(config)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isActive
                      ? brandColor.opacity(0.06)
                      : isSelected
                        ? brandColor.opacity(0.04)
                        : Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isActive
                        ? brandColor.opacity(0.5)
                        : isSelected
                          ? brandColor.opacity(0.25)
                          : Color.primary.opacity(0.06),
                        lineWidth: isActive ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedConfigId = isSelected ? nil : config.id
            }
        }
        .contextMenu {
            Button {
                editingConfig = config
            } label: {
                Label(L("Edit", "编辑"), systemImage: "pencil")
            }
            Button {
                duplicateConfig(config)
            } label: {
                Label(L("Duplicate", "复制节点"), systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) {
                Task { await deleteConfig(config) }
            } label: {
                Label(L("Delete", "删除"), systemImage: "trash")
            }
        }
    }

    private static let anthropicBrand = Color(red: 0.85, green: 0.47, blue: 0.34)
    private static let openAIBrand = Color(red: 0.29, green: 0.73, blue: 0.56)

    private func nodeTypeBadge(_ config: ProxyConfiguration) -> some View {
        let (label, icon, color): (String, String, Color) = {
            switch config.nodeType {
            case .anthropicDirect:
                if config.usePassthroughProxy {
                    return ("Anthropic Proxy", "bolt.shield.fill", Self.anthropicBrand)
                }
                return ("Anthropic Direct", "bolt.horizontal.fill", Self.anthropicBrand)
            case .openaiProxy:
                return ("OpenAI Proxy", "arrow.triangle.swap", Self.openAIBrand)
            }
        }()

        return HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 7, weight: .bold))
            Text(label)
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    private func statPill(icon: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .rounded))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    private func configDetailRow(_ config: ProxyConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch config.nodeType {
            case .anthropicDirect:
                detailItem(label: "Base URL", value: config.anthropicBaseURL)
                if config.usePassthroughProxy {
                    detailItem(label: L("Local Proxy", "本地代理"), value: "http://\(config.host):\(config.port)")
                }
            case .openaiProxy:
                detailItem(label: L("Upstream", "上游"), value: config.upstreamBaseURL)
                detailItem(
                    label: L("Model Mapping", "模型映射"),
                    value: "Opus\u{2192}\(config.modelMapping.bigModel.name), Sonnet\u{2192}\(config.modelMapping.middleModel.name), Haiku\u{2192}\(config.modelMapping.smallModel.name)"
                )
                detailItem(label: L("LAN Access", "局域网访问"), value: config.allowLAN ? L("Enabled", "已启用") : L("Disabled", "已禁用"))
            }
            if let lastUsed = config.lastUsedAt {
                detailItem(label: L("Last Used", "最后使用"), value: formatRelativeTime(lastUsed))
            }
        }
        .font(.caption)
    }

    private func detailItem(label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }

    // MARK: - Statistics Section

    private func statisticsSection(for config: ProxyConfiguration) -> some View {
        let stats = viewModel.statistics[config.id] ?? .empty

        return VStack(alignment: .leading, spacing: 12) {
            Text(L("Statistics", "统计信息"))
                .font(.headline.weight(.bold))

            HStack(spacing: 12) {
                statsCard(
                    title: L("Total Requests", "总请求"),
                    value: "\(stats.totalRequests)",
                    icon: "arrow.up.arrow.down",
                    color: .blue
                )
                statsCard(
                    title: L("Successful", "成功"),
                    value: "\(stats.successfulRequests)",
                    icon: "checkmark.circle",
                    color: .green
                )
                statsCard(
                    title: L("Failed", "失败"),
                    value: "\(stats.failedRequests)",
                    icon: "xmark.circle",
                    color: .red
                )
                statsCard(
                    title: L("Avg Response", "平均响应"),
                    value: String(format: "%.0fms", stats.averageResponseTime),
                    icon: "timer",
                    color: .orange
                )
            }

            HStack(spacing: 12) {
                statsCard(
                    title: L("Input Tokens", "输入 Tokens"),
                    value: formatCompactNumber(Double(stats.totalTokensInput)),
                    icon: "arrow.down.circle",
                    color: .purple
                )
                statsCard(
                    title: L("Output Tokens", "输出 Tokens"),
                    value: formatCompactNumber(Double(stats.totalTokensOutput)),
                    icon: "arrow.up.circle",
                    color: .pink
                )
                statsCard(
                    title: L("Cache Tokens", "缓存 Tokens"),
                    value: formatCompactNumber(Double(stats.totalTokensCache)),
                    icon: "memorychip",
                    color: .cyan
                )
                statsCard(
                    title: L("Estimated Cost", "预估费用"),
                    value: formatProxyCurrency(stats.estimatedCostUSD),
                    icon: "dollarsign.circle",
                    color: .red
                )
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

    private func statsCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(Circle().fill(color.opacity(0.12)))

            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))

            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(color.opacity(0.05))
        )
    }

    // MARK: - Recent Requests Section

    private func recentRequestsSection(for config: ProxyConfiguration) -> some View {
        let logs = viewModel.recentLogs[config.id] ?? []

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Recent Requests", "最近请求"))
                    .font(.headline.weight(.bold))
                Spacer()
                if !logs.isEmpty {
                    Button(L("Clear", "清除")) {
                        viewModel.clearLogs(for: config.id)
                    }
                    .font(.caption.weight(.semibold))
                }
            }

            if logs.isEmpty {
                Text(L("No requests yet", "暂无请求"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(logs.prefix(10).enumerated()), id: \.element.id) { index, log in
                        requestLogRow(log)
                        if index < min(9, logs.count - 1) {
                            Divider().padding(.horizontal, 12)
                        }
                    }
                }
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

    private func requestLogRow(_ log: ProxyRequestLog) -> some View {
        HStack(spacing: 12) {
            Image(systemName: log.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(log.success ? .green : .red)
                .font(.system(size: 14))

            VStack(alignment: .leading, spacing: 2) {
                Text("\(log.method) \(log.path)")
                    .font(.caption.weight(.semibold))
                Text(log.upstreamModel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                Text(String(format: "%.0fms", log.responseTimeMs))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)

                Text(formatCompactNumber(Double(log.tokensInput + log.tokensOutput)))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.blue)

                Text(formatProxyCurrency(log.estimatedCostUSD))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
            }

            Text(formatRelativeTime(log.timestamp))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(L("No Nodes", "暂无节点"))
                .font(.title3.weight(.bold))
            Text(L("Add Anthropic Direct or OpenAI Proxy nodes to manage Claude Code endpoints.",
                    "添加 Anthropic 直连或 OpenAI 代理节点来管理 Claude Code 端点。"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: { showingNewConfigEditor = true }) {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text(L("Add Node", "添加节点"))
                }
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Computed Properties

    private var selectedConfiguration: ProxyConfiguration? {
        guard let id = selectedConfigId else { return nil }
        return viewModel.configurations.first { $0.id == id }
    }

    private var totalRequests: Int {
        viewModel.statistics.values.reduce(0) { $0 + $1.totalRequests }
    }

    private var totalSuccessRate: Double {
        let total = viewModel.statistics.values.reduce(0) { $0 + $1.totalRequests }
        let successful = viewModel.statistics.values.reduce(0) { $0 + $1.successfulRequests }
        guard total > 0 else { return 0 }
        return Double(successful) / Double(total) * 100
    }

    private var totalTokens: Int {
        viewModel.statistics.values.reduce(0) { $0 + $1.totalTokens }
    }

    private var totalCost: Double {
        viewModel.statistics.values.reduce(0) { $0 + $1.estimatedCostUSD }
    }

    // MARK: - Actions

    private func editConfig(_ config: ProxyConfiguration) {
        editingConfig = config
    }

    private func duplicateConfig(_ config: ProxyConfiguration) {
        let usedPorts = Set(viewModel.configurations.map(\.port))
        var newPort = config.port + 1
        while usedPorts.contains(newPort) && newPort < 65535 { newPort += 1 }

        let copy = ProxyConfiguration(
            name: config.name + " " + L("(Copy)", "(副本)"),
            nodeType: config.nodeType,
            anthropicBaseURL: config.anthropicBaseURL,
            anthropicAPIKey: config.anthropicAPIKey,
            usePassthroughProxy: config.usePassthroughProxy,
            host: config.host,
            port: newPort,
            allowLAN: config.allowLAN,
            upstreamBaseURL: config.upstreamBaseURL,
            upstreamAPIKey: config.upstreamAPIKey,
            expectedClientKey: config.expectedClientKey,
            defaultModel: config.defaultModel,
            modelMapping: config.modelMapping,
            maxOutputTokens: config.maxOutputTokens,
            passthroughPricing: config.passthroughPricing
        )
        viewModel.addConfiguration(copy)
    }

    private func deleteConfig(_ config: ProxyConfiguration) async {
        if selectedConfigId == config.id { selectedConfigId = nil }
        await viewModel.deleteConfiguration(config.id)
    }

    // MARK: - Helpers

    private func formatRelativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Format Helpers

// formatCompactNumber is defined in Utilities.swift

fileprivate func formatProxyCurrency(_ value: Double) -> String {
    formatCurrency(value)
}

#Preview {
    ProxyManagementView()
        .environmentObject(AppState.shared)
        .environmentObject(ProxyViewModel())
        .frame(width: 1100, height: 700)
}
