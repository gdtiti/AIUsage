import SwiftUI

// MARK: - Global Config Section
// Collapsible card for editing the shared settings.json fragment.
// When enabled, its contents are deep-merged with the active node's
// settings during activation (node values take priority).

struct GlobalConfigSection: View {
    @EnvironmentObject var viewModel: ProxyViewModel
    @State private var isExpanded = false
    @State private var jsonText = "{}"
    @State private var jsonError: String?
    @State private var hasUnsavedChanges = false
    @State private var isLoadingFromStore = false

    private var store: NodeProfileStore { viewModel.profileStore }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            if isExpanded {
                Divider()
                    .padding(.horizontal, 16)
                editorContent
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
        .onAppear { loadFromStore() }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))

                    Image(systemName: "gearshape.2.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.orange)

                    Text(L("Global Config", "通用配置"))
                        .font(.headline.weight(.bold))
                }
            }
            .buttonStyle(.plain)

            Spacer()

            if hasUnsavedChanges {
                Text(L("Unsaved", "未保存"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.12)))
            }

            Toggle(isOn: Binding(
                get: { store.globalConfig.enabled },
                set: { newValue in
                    store.globalConfig.enabled = newValue
                    store.saveGlobalConfig()
                }
            )) {
                Text(L("Merge on Activate", "激活时合并"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    // MARK: - Editor

    private var editorContent: some View {
        VStack(spacing: 0) {
            Text(L(
                "Shared settings fragment merged into every node's settings.json on activation. Node-specific values always override.",
                "通用配置片段，激活节点时合并写入 settings.json。节点配置的同名字段优先级更高。"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            JSONRawEditorView(jsonText: $jsonText, error: $jsonError)
                .frame(height: 280)
                .padding(.horizontal, 8)
                .onChange(of: jsonText) { _ in
                    guard !isLoadingFromStore else { return }
                    hasUnsavedChanges = true
                }

            HStack {
                Spacer()
                Button {
                    saveToStore()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                        Text(L("Save", "保存"))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
                .disabled(!hasUnsavedChanges || jsonError != nil)
                .opacity(hasUnsavedChanges && jsonError == nil ? 1 : 0.5)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Persistence

    private func loadFromStore() {
        isLoadingFromStore = true
        let settings = store.globalConfig.settings
        if settings.isEmpty {
            jsonText = "{\n  \n}"
        } else if let data = try? JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ), let str = String(data: data, encoding: .utf8) {
            jsonText = str
        }
        hasUnsavedChanges = false
        DispatchQueue.main.async { isLoadingFromStore = false }
    }

    private func saveToStore() {
        guard let data = jsonText.data(using: .utf8) else {
            jsonError = L("Invalid text encoding", "文本编码无效")
            return
        }
        do {
            let obj = try JSONSerialization.jsonObject(with: data)
            guard let dict = obj as? [String: Any] else {
                jsonError = L("Root must be a JSON object", "根节点必须是 JSON 对象")
                return
            }
            store.globalConfig.settings = dict
            store.saveGlobalConfig()
            jsonError = nil
            hasUnsavedChanges = false
        } catch {
            jsonError = error.localizedDescription
        }
    }
}
