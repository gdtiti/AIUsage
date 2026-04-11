import SwiftUI

struct AccountNoteEditorView: View {
    let providerTitle: String
    let accountLabel: String
    let note: String?
    let onSave: (String?) -> Void

    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var draftNote: String

    init(providerTitle: String, accountLabel: String, note: String?, onSave: @escaping (String?) -> Void) {
        self.providerTitle = providerTitle
        self.accountLabel = accountLabel
        self.note = note
        self.onSave = onSave
        _draftNote = State(initialValue: note ?? "")
    }

    private func t(_ en: String, _ zh: String) -> String {
        appState.language == "zh" ? zh : en
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t("Edit Account Note", "编辑账号注释"))
                .font(.title3)
                .bold()

            Text("\(providerTitle) · \(accountLabel)")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField(t("e.g. Main account / Work account / Test machine", "例如：主账号 / 工作账号 / 测试机器"), text: $draftNote)
                .textFieldStyle(.roundedBorder)

            Spacer()

            HStack {
                Button(t("Cancel", "取消")) {
                    dismiss()
                }
                .buttonStyle(.borderless)

                Spacer()

                Button(t("Save", "保存")) {
                    onSave(draftNote.nilIfBlank)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 460, height: 200)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
