import SwiftUI

// MARK: - Proxy Config Editor

struct ProxyConfigEditorView: View {
    @EnvironmentObject var viewModel: ProxyViewModel
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var config: ProxyConfiguration
    @State private var isNew: Bool

    private func t(_ en: String, _ zh: String) -> String {
        appState.language == "zh" ? zh : en
    }

    init(config: ProxyConfiguration? = nil) {
        if let config = config {
            _config = State(initialValue: config)
            _isNew = State(initialValue: false)
            _pricingCurrency = State(initialValue: config.modelMapping.bigModel.pricing.currency)
        } else {
            _config = State(initialValue: ProxyConfiguration(name: ""))
            _isNew = State(initialValue: true)
            _pricingCurrency = State(initialValue: .usd)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? t("New Node", "新建节点") : t("Edit Node", "编辑节点"))
                    .font(.title2.weight(.bold))
                Spacer()
                Button(t("Cancel", "取消")) {
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
                    Button(t("Delete", "删除"), role: .destructive) {
                        viewModel.deleteConfiguration(config.id)
                        dismiss()
                    }
                }
                Spacer()
                Button(t("Cancel", "取消")) {
                    dismiss()
                }
                Button(isNew ? t("Create", "创建") : t("Save", "保存")) {
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
            Text(t("Node Type", "节点类型"))
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

            Text(config.nodeType == .anthropicDirect
                 ? t("Connect directly to Anthropic or compatible API. No proxy process needed.",
                     "直接连接 Anthropic 或兼容 API，无需代理进程。")
                 : t("Translate Claude API to OpenAI-compatible API via local proxy.",
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
            Text(t("Basic Information", "基本信息"))
                .font(.headline.weight(.bold))

            VStack(alignment: .leading, spacing: 8) {
                Text(t("Name", "名称"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField(
                    config.nodeType == .anthropicDirect
                        ? t("e.g., Anthropic Official", "例如：Anthropic 官方")
                        : t("e.g., OpenAI Proxy", "例如：OpenAI 代理"),
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
            Text(t("Anthropic API", "Anthropic API"))
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

            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.blue)
                Text(t("These values will be written to ~/.claude/settings.json when activated.",
                       "激活时会将这些值写入 ~/.claude/settings.json。"))
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

    // MARK: - Network Section (OpenAI Proxy)

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("Local Proxy", "本地代理"))
                .font(.headline.weight(.bold))

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(t("Host", "主机"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("127.0.0.1", text: $config.host)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(t("Port", "端口"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("8080", value: $config.port, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
            }

            Toggle(t("Allow LAN Access (0.0.0.0)", "允许局域网访问 (0.0.0.0)"), isOn: $config.allowLAN)
                .font(.caption.weight(.medium))

            if config.allowLAN {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(t("Warning: This will expose the proxy to your local network",
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
            Text(t("Upstream Provider", "上游服务"))
                .font(.headline.weight(.bold))

            VStack(alignment: .leading, spacing: 8) {
                Text(t("Base URL", "基础 URL"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("https://api.openai.com/v1", text: $config.upstreamBaseURL)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("API Key")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                SecureField("sk-...", text: $config.upstreamAPIKey)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.blue)
                Text(t("This key will be used to call the upstream API",
                       "此密钥将用于调用上游 API"))
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

    // MARK: - Model Mapping Section (OpenAI Proxy)

    // MARK: - Model Configuration Section

    private var modelMappingSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t("Model Configuration", "模型配置"))
                .font(.headline.weight(.bold))

            Text(t("These model names will be written to ~/.claude/settings.json and used directly by Claude Code for requests and statistics.",
                   "这些模型名将写入 ~/.claude/settings.json，Claude Code 会直接使用它们发起请求和统计用量。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            // Default Model
            VStack(alignment: .leading, spacing: 6) {
                Text(t("Default Model", "主模型"))
                    .font(.subheadline.weight(.semibold))
                TextField(config.nodeType == .openaiProxy ? "deepseek-chat" : "claude-sonnet-4-20250514",
                          text: $config.defaultModel)
                    .textFieldStyle(.roundedBorder)
                Text(t("The model field in settings.json. Claude Code uses this as the active model.",
                       "settings.json 中的 model 字段，Claude Code 以此作为当前使用的模型。"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Divider()

            // Model Slots
            VStack(alignment: .leading, spacing: 10) {
                Text(t("Model Slots", "模型槽位"))
                    .font(.subheadline.weight(.semibold))

                modelSlotRow(label: "Opus", binding: $config.modelMapping.bigModel.name,
                             placeholder: config.nodeType == .openaiProxy ? "gpt-4o" : "claude-3-opus-20240229")
                modelSlotRow(label: "Sonnet", binding: $config.modelMapping.middleModel.name,
                             placeholder: config.nodeType == .openaiProxy ? "gpt-4o-mini" : "claude-sonnet-4-20250514")
                modelSlotRow(label: "Haiku", binding: $config.modelMapping.smallModel.name,
                             placeholder: config.nodeType == .openaiProxy ? "gpt-3.5-turbo" : "claude-3-haiku-20240307")
            }

            if config.nodeType == .openaiProxy {
                Divider()

                // Pricing
                modelPricingSection

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text(t("Max Output Tokens", "最大输出 Token"))
                        .font(.subheadline.weight(.semibold))
                    HStack(spacing: 8) {
                        TextField("0", value: $config.maxOutputTokens, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                        Text(t("0 = unlimited", "0 = 不限制"))
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

            TextField(placeholder, text: binding)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
        }
    }

    // MARK: - Pricing Sub-section

    @State private var pricingCurrency: ProxyConfiguration.PricingCurrency = .usd

    private var modelPricingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(t("Pricing", "定价"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Picker("", selection: $pricingCurrency) {
                    Text("USD ($)").tag(ProxyConfiguration.PricingCurrency.usd)
                    Text("CNY (¥)").tag(ProxyConfiguration.PricingCurrency.cny)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .onChange(of: pricingCurrency) { newCurrency in
                    config.modelMapping.bigModel.pricing.currency = newCurrency
                    config.modelMapping.middleModel.pricing.currency = newCurrency
                    config.modelMapping.smallModel.pricing.currency = newCurrency
                }
            }

            // Table Header
            HStack(spacing: 0) {
                Text("")
                    .frame(width: 56, alignment: .trailing)
                Spacer().frame(width: 10)
                Text(t("Input", "输入"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(t("Output", "输出"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(t("Cache", "缓存"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(t("/ M tokens", "/ 百万"))
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
            Text(t("Security", "安全设置"))
                .font(.headline.weight(.bold))

            VStack(alignment: .leading, spacing: 8) {
                Text(t("Expected Client API Key (Optional)", "客户端 API Key（可选）"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                SecureField(t("Leave empty to accept any key", "留空则接受任意 Key"), text: $config.expectedClientKey)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.green)
                Text(t("If set, clients must provide this key in x-api-key or Authorization header",
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
            return nameValid && !config.anthropicBaseURL.isEmpty && !config.anthropicAPIKey.isEmpty
        case .openaiProxy:
            return nameValid &&
                !config.host.isEmpty &&
                config.port > 0 && config.port < 65536 &&
                !config.upstreamBaseURL.isEmpty &&
                !config.upstreamAPIKey.isEmpty &&
                !config.modelMapping.bigModel.name.isEmpty &&
                !config.modelMapping.middleModel.name.isEmpty &&
                !config.modelMapping.smallModel.name.isEmpty
        }
    }

    // MARK: - Actions

    private func saveConfiguration() {
        if isNew {
            viewModel.addConfiguration(config)
        } else {
            viewModel.updateConfiguration(config)
        }
        dismiss()
    }
}

#Preview {
    ProxyConfigEditorView()
        .environmentObject(ProxyViewModel())
        .environmentObject(AppState.shared)
}
