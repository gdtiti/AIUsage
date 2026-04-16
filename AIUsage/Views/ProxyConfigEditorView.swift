import SwiftUI
import QuotaBackend

// MARK: - Proxy Config Editor

struct ProxyConfigEditorView: View {
    @EnvironmentObject var viewModel: ProxyViewModel
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var config: ProxyConfiguration
    @State private var isNew: Bool
    @State private var availableModels: [String] = []
    @State private var isFetchingModels: Bool = false
    @State private var fetchModelsError: String?
    init(config: ProxyConfiguration? = nil) {
        if let config = config {
            _config = State(initialValue: config)
            _isNew = State(initialValue: false)
            _pricingCurrency = State(initialValue: config.modelMapping.bigModel.pricing.currency)
        } else {
            _config = State(initialValue: ProxyConfiguration(
                name: "",
                defaultModel: "gpt-5.4",
                modelMapping: .openAIDefault
            ))
            _isNew = State(initialValue: true)
            _pricingCurrency = State(initialValue: .usd)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? L("New Node", "新建节点") : L("Edit Node", "编辑节点"))
                    .font(.title2.weight(.bold))
                Spacer()
                Button(L("Cancel", "取消")) {
                    dismiss()
                }
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    nodeTypeSection
                    basicSection

                    switch config.nodeType {
                    case .anthropicDirect:
                        anthropicDirectSection
                        modelMappingSection
                    case .openaiProxy:
                        networkSection
                        upstreamSection
                        modelMappingSection
                        securitySection
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                if !isNew {
                    Button(L("Delete", "删除"), role: .destructive) {
                        Task {
                            await viewModel.deleteConfiguration(config.id)
                            dismiss()
                        }
                    }
                }
                Spacer()
                Button(L("Cancel", "取消")) {
                    dismiss()
                }
                Button(isNew ? L("Create", "创建") : L("Save", "保存")) {
                    saveConfiguration()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
            .padding(20)
        }
        .frame(width: 600, height: 700)
    }

    // MARK: - Node Type Section

    private var nodeTypeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Node Type", "节点类型"))
                .font(.headline.weight(.bold))

            Picker("", selection: $config.nodeType) {
                Label {
                    Text("Anthropic Direct")
                } icon: {
                    Image(systemName: "bolt.horizontal.fill")
                }
                .tag(NodeType.anthropicDirect)

                Label {
                    Text("OpenAI Proxy")
                } icon: {
                    Image(systemName: "arrow.triangle.swap")
                }
                .tag(NodeType.openaiProxy)
            }
            .pickerStyle(.segmented)
            .onChange(of: config.nodeType) { _, newType in
                if isNew {
                    switch newType {
                    case .anthropicDirect:
                        config.modelMapping = .anthropicDefault
                        config.defaultModel = "claude-sonnet-4-6"
                    case .openaiProxy:
                        config.modelMapping = .openAIDefault
                        config.defaultModel = "gpt-5.4"
                    }
                }
            }

            Text(config.nodeType == .anthropicDirect
                 ? L("Connect directly to Anthropic or compatible API. No proxy process needed.",
                     "直接连接 Anthropic 或兼容 API，无需代理进程。")
                 : L("Translate Claude API to OpenAI-compatible API via local proxy.",
                     "通过本地代理将 Claude API 转换为 OpenAI 兼容 API。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    // MARK: - Basic Section

    private var basicSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Basic Information", "基本信息"))
                .font(.headline.weight(.bold))

            VStack(alignment: .leading, spacing: 8) {
                Text(L("Name", "名称"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField(
                    config.nodeType == .anthropicDirect
                        ? L("e.g., Anthropic Official", "例如：Anthropic 官方")
                        : L("e.g., OpenAI Proxy", "例如：OpenAI 代理"),
                    text: $config.name
                )
                .textFieldStyle(.roundedBorder)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    // MARK: - Anthropic Direct Section

    private var anthropicDirectSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Anthropic API", "Anthropic API"))
                .font(.headline.weight(.bold))

            VStack(alignment: .leading, spacing: 8) {
                Text("Base URL")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("https://api.anthropic.com", text: $config.anthropicBaseURL)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("API Key")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                SecureField("sk-ant-...", text: $config.anthropicAPIKey)
                    .textFieldStyle(.roundedBorder)
            }

            Divider()

            Toggle(isOn: $config.usePassthroughProxy) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Transparent Proxy (Log Usage)", "透明代理（记录用量）"))
                        .font(.subheadline.weight(.semibold))
                    Text(L("Route requests through a local proxy to log token usage without modifying the API format.",
                           "请求经由本地代理透传，记录 Token 用量但不修改 API 格式。"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            if config.usePassthroughProxy {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("Host", "主机"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("127.0.0.1", text: $config.host)
                            .textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("Port", "端口"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("8080", value: $config.port, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.teal)
                    Text(L("ANTHROPIC_BASE_URL will point to the local proxy. Requests are forwarded to the upstream API as-is.",
                           "ANTHROPIC_BASE_URL 将指向本地代理，请求原样转发至上游 API。"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                    Text(L("These values will be written to ~/.claude/settings.json when activated.",
                           "激活时会将这些值写入 ~/.claude/settings.json。"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    // MARK: - Network Section (OpenAI Proxy)

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Local Proxy", "本地代理"))
                .font(.headline.weight(.bold))

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Host", "主机"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("127.0.0.1", text: $config.host)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Port", "端口"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("8080", value: $config.port, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
            }

            Toggle(L("Allow LAN Access (0.0.0.0)", "允许局域网访问 (0.0.0.0)"), isOn: $config.allowLAN)
                .font(.caption.weight(.medium))

            if config.allowLAN {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(L("Warning: This will expose the proxy to your local network",
                           "警告：这将把代理暴露到你的局域网"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.orange.opacity(0.1))
                )
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    // MARK: - Upstream Section (OpenAI Proxy)

    private var upstreamSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Upstream Provider", "上游服务"))
                .font(.headline.weight(.bold))

            VStack(alignment: .leading, spacing: 8) {
                Text(L("Base URL", "基础 URL"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("https://api.openai.com", text: $config.upstreamBaseURL)
                    .textFieldStyle(.roundedBorder)
                Text(L(
                    "Enter only the provider root URL. AIUsage will append /v1 and the selected endpoint automatically, and older values ending in /v1 or /v1/chat/completions remain compatible.",
                    "这里只填写服务根地址即可。AIUsage 会根据所选接口自动补上 /v1 和具体端点，旧版本里以 /v1 或 /v1/chat/completions 结尾的配置也会自动兼容。"
                ))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L("Upstream API", "上游接口"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("", selection: $config.openAIUpstreamAPI) {
                    Text("Chat Completions").tag(OpenAIUpstreamAPI.chatCompletions)
                    Text("Responses").tag(OpenAIUpstreamAPI.responses)
                }
                .pickerStyle(.segmented)
                Text(L(
                    "Responses is recommended for new OpenAI integrations. Keep Chat Completions for older compatible providers that only implement /v1/chat/completions.",
                    "官方新的 OpenAI 集成更推荐 Responses；如果你的兼容服务仍只实现 /v1/chat/completions，请继续选择 Chat Completions。"
                ))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("API Key")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                SecureField("sk-...", text: $config.upstreamAPIKey)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 8) {
                Button {
                    fetchModels()
                } label: {
                    HStack(spacing: 4) {
                        if isFetchingModels {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.down.circle")
                        }
                        Text(L("Fetch Models", "获取模型"))
                    }
                    .font(.caption.weight(.semibold))
                }
                .disabled(config.normalizedUpstreamBaseURL.isEmpty || config.upstreamAPIKey.isEmpty || isFetchingModels)

                if !availableModels.isEmpty {
                    Text(L("\(availableModels.count) models available", "已获取 \(availableModels.count) 个模型"))
                        .font(.caption2)
                        .foregroundStyle(.green)
                } else if let error = fetchModelsError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    // MARK: - Model Configuration Section

    private var modelMappingSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Model Configuration", "模型配置"))
                .font(.headline.weight(.bold))

            Text(L("These model names will be written to ~/.claude/settings.json and used directly by Claude Code for requests and statistics.",
                   "这些模型名将写入 ~/.claude/settings.json，Claude Code 会直接使用它们发起请求和统计用量。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text(L("Default Model", "主模型"))
                    .font(.subheadline.weight(.semibold))
                modelTextField(text: $config.defaultModel,
                               placeholder: config.nodeType == .openaiProxy ? "gpt-5.4" : "claude-sonnet-4-6")
                Text(L("The model field in settings.json. Claude Code uses this as the active model.",
                       "settings.json 中的 model 字段，Claude Code 以此作为当前使用的模型。"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Divider()

            // Model Slots
            VStack(alignment: .leading, spacing: 10) {
                Text(L("Model Slots", "模型槽位"))
                    .font(.subheadline.weight(.semibold))

                modelSlotRow(label: "Opus", binding: $config.modelMapping.bigModel.name,
                             placeholder: config.nodeType == .openaiProxy ? "gpt-5.4" : "claude-opus-4-6")
                modelSlotRow(label: "Sonnet", binding: $config.modelMapping.middleModel.name,
                             placeholder: config.nodeType == .openaiProxy ? "gpt-5.4-mini" : "claude-sonnet-4-6")
                modelSlotRow(label: "Haiku", binding: $config.modelMapping.smallModel.name,
                             placeholder: config.nodeType == .openaiProxy ? "gpt-4o-mini" : "claude-haiku-4-5")
            }

            if config.needsProxyProcess {
                Divider()
                modelPricingSection
            }

            if config.nodeType == .openaiProxy {
                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Max Output Tokens", "最大输出 Token"))
                        .font(.subheadline.weight(.semibold))
                    HStack(spacing: 8) {
                        TextField("0", value: $config.maxOutputTokens, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                        Text(L("0 = unlimited", "0 = 不限制"))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func modelSlotRow(label: String, binding: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)

            modelTextField(text: binding, placeholder: placeholder)
        }
    }

    private func modelTextField(text: Binding<String>, placeholder: String) -> some View {
        let suggestions = filteredModels(for: text.wrappedValue)
        let showSuggestions = !availableModels.isEmpty && !text.wrappedValue.isEmpty && !suggestions.isEmpty
            && !suggestions.contains(where: { $0 == text.wrappedValue })

        return VStack(alignment: .leading, spacing: 0) {
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            if showSuggestions {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(suggestions.prefix(8), id: \.self) { model in
                            Button {
                                text.wrappedValue = model
                            } label: {
                                Text(model)
                                    .font(.system(size: 12, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                            .background(Color.primary.opacity(0.04))
                        }
                    }
                }
                .frame(maxHeight: 160)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1)))
            }
        }
    }

    // MARK: - Pricing Sub-section

    @State private var pricingCurrency: ProxyConfiguration.PricingCurrency = .usd

    private var modelPricingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("Pricing", "定价"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Picker("", selection: $pricingCurrency) {
                    Text("USD ($)").tag(ProxyConfiguration.PricingCurrency.usd)
                    Text("CNY (¥)").tag(ProxyConfiguration.PricingCurrency.cny)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .onChange(of: pricingCurrency) { _, newCurrency in
                    config.modelMapping.bigModel.pricing.currency = newCurrency
                    config.modelMapping.middleModel.pricing.currency = newCurrency
                    config.modelMapping.smallModel.pricing.currency = newCurrency
                }
            }

            if config.nodeType == .anthropicDirect {
                Text(L("This node uses the pricing here for spend statistics. In Anthropic passthrough mode, you only need to configure this once.",
                       "这个节点会直接使用这里的价格做消费统计。在 Anthropic 透传模式下，只需要配置这一处。"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Table Header
            HStack(spacing: 0) {
                Text("")
                    .frame(width: 56, alignment: .trailing)
                Spacer().frame(width: 10)
                Text(L("Input", "输入"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(L("Output", "输出"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(L("Cache", "缓存"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(L("/ M tokens", "/ 百万"))
                    .frame(width: 64, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.tertiary)

            pricingRow(label: "Opus", pricing: $config.modelMapping.bigModel.pricing)
            pricingRow(label: "Sonnet", pricing: $config.modelMapping.middleModel.pricing)
            pricingRow(label: "Haiku", pricing: $config.modelMapping.smallModel.pricing)
        }
    }

    private func pricingRow(label: String, pricing: Binding<ProxyConfiguration.ModelPricing>) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)

            Spacer().frame(width: 10)

            TextField("0", value: pricing.inputPerMillion, format: .number.precision(.fractionLength(0...4)))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity)

            Spacer().frame(width: 6)

            TextField("0", value: pricing.outputPerMillion, format: .number.precision(.fractionLength(0...4)))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity)

            Spacer().frame(width: 6)

            TextField("0", value: pricing.cachePerMillion, format: .number.precision(.fractionLength(0...4)))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity)

            Spacer().frame(width: 64)
        }
    }

    // MARK: - Security Section (OpenAI Proxy)

    private var securitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Security", "安全设置"))
                .font(.headline.weight(.bold))

            VStack(alignment: .leading, spacing: 8) {
                Text(L("Expected Client API Key (Optional)", "客户端 API Key（可选）"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                SecureField(L("Leave empty to accept any key", "留空则接受任意 Key"), text: $config.expectedClientKey)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.green)
                Text(L("If set, clients must provide this key in x-api-key or Authorization header",
                       "设置后，客户端需在 x-api-key 或 Authorization 头中提供此 Key"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    // MARK: - Validation

    private var isValid: Bool {
        let nameValid = !config.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        switch config.nodeType {
        case .anthropicDirect:
            let baseValid = nameValid && !config.anthropicBaseURL.isEmpty && !config.anthropicAPIKey.isEmpty
            if config.usePassthroughProxy {
                return baseValid && !config.host.isEmpty && config.port > 0 && config.port < 65536
            }
            return baseValid
        case .openaiProxy:
            return nameValid &&
                !config.host.isEmpty &&
                config.port > 0 && config.port < 65536 &&
                !config.normalizedUpstreamBaseURL.isEmpty &&
                !config.upstreamAPIKey.isEmpty &&
                !config.modelMapping.bigModel.name.isEmpty &&
                !config.modelMapping.middleModel.name.isEmpty &&
                !config.modelMapping.smallModel.name.isEmpty
        }
    }

    // MARK: - Model Fetching

    private func fetchModels() {
        let baseURL: String
        let apiKey: String

        if config.nodeType == .openaiProxy {
            baseURL = config.normalizedUpstreamBaseURL
            apiKey = config.upstreamAPIKey
        } else {
            baseURL = config.anthropicBaseURL
            apiKey = config.anthropicAPIKey
        }

        guard !baseURL.isEmpty, !apiKey.isEmpty else { return }

        let urlString: String
        if config.nodeType == .openaiProxy {
            urlString = baseURL.hasSuffix("/")
                ? baseURL + "v1/models"
                : baseURL + "/v1/models"
        } else {
            urlString = baseURL.hasSuffix("/")
                ? baseURL + "models"
                : baseURL + "/models"
        }
        guard let url = URL(string: urlString) else { return }

        isFetchingModels = true
        fetchModelsError = nil
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { data, _, error in
            defer { DispatchQueue.main.async { isFetchingModels = false } }
            if let error = error {
                DispatchQueue.main.async { fetchModelsError = error.localizedDescription }
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataArr = json["data"] as? [[String: Any]] else {
                DispatchQueue.main.async { fetchModelsError = "Invalid response" }
                return
            }

            let models = dataArr.compactMap { $0["id"] as? String }.sorted()
            DispatchQueue.main.async {
                availableModels = models
                fetchModelsError = models.isEmpty ? "No models found" : nil
            }
        }.resume()
    }

    private func filteredModels(for text: String) -> [String] {
        guard !text.isEmpty else { return availableModels }
        return availableModels.filter { $0.localizedCaseInsensitiveContains(text) }
    }

    // MARK: - Actions

    private func saveConfiguration() {
        Task {
            let normalizedConfig = config.normalizedForPersistence()
            if isNew {
                viewModel.addConfiguration(normalizedConfig)
            } else {
                await viewModel.updateConfiguration(normalizedConfig)
            }
            dismiss()
        }
    }
}

#Preview {
    ProxyConfigEditorView()
        .environmentObject(ProxyViewModel())
        .environmentObject(AppState.shared)
}
