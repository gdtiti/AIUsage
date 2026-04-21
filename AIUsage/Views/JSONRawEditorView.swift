import SwiftUI
import AppKit

// MARK: - JSON Raw Editor View
// Full-screen code editor for raw JSON editing of settings.json content.
// Uses NSTextView via NSViewRepresentable for performant text editing with monospaced font.

struct JSONRawEditorView: View {
    @Binding var jsonText: String
    @Binding var error: String?
    @State private var lineCount: Int = 1

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "curlybraces")
                    .foregroundStyle(.secondary)
                Text(L("settings.json", "settings.json"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(L("\(lineCount) lines", "\(lineCount) 行"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Button {
                    formatJSON()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "text.alignleft")
                        Text(L("Format", "格式化"))
                    }
                    .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)

                Button {
                    validateJSON()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle")
                        Text(L("Validate", "校验"))
                    }
                    .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            JSONTextEditor(text: $jsonText, lineCount: $lineCount)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let error {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.08))
            }
        }
    }

    private func formatJSON() {
        guard let data = jsonText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let formatted = try? JSONSerialization.data(
                  withJSONObject: obj,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ),
              let str = String(data: formatted, encoding: .utf8) else {
            error = L("Cannot format: invalid JSON", "无法格式化：JSON 格式无效")
            return
        }
        jsonText = str
        error = nil
    }

    private func validateJSON() {
        guard let data = jsonText.data(using: .utf8) else {
            error = L("Invalid encoding", "编码无效")
            return
        }
        do {
            let obj = try JSONSerialization.jsonObject(with: data)
            guard obj is [String: Any] else {
                error = L("Root must be a JSON object", "根节点必须是 JSON 对象")
                return
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - NSTextView Wrapper

private struct JSONTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var lineCount: Int

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = NSColor.controlBackgroundColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.delegate = context.coordinator
        textView.string = text

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        DispatchQueue.main.async {
            lineCount = text.components(separatedBy: "\n").count
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            let range = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(location: min(range.location, text.count), length: 0))
            DispatchQueue.main.async {
                lineCount = text.components(separatedBy: "\n").count
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: JSONTextEditor

        init(_ parent: JSONTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.lineCount = textView.string.components(separatedBy: "\n").count
        }
    }
}
