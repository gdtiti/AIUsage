import SwiftUI
import AppKit

// MARK: - JSON Raw Editor View
// Full-screen code editor for raw JSON editing of settings.json content.
// Uses NSTextView via NSViewRepresentable with syntax highlighting for
// keys, string values, numbers, and booleans/null.

struct JSONRawEditorView: View {
    @Binding var jsonText: String
    @Binding var error: String?
    @State private var lineCount: Int = 1
    @State private var showValidationSuccess = false

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

                if showValidationSuccess {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill")
                        Text(L("Valid JSON", "JSON 有效"))
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.green)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
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
        showValidationSuccess = false
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
            showValidationSuccess = false
            return
        }
        do {
            let obj = try JSONSerialization.jsonObject(with: data)
            guard obj is [String: Any] else {
                error = L("Root must be a JSON object", "根节点必须是 JSON 对象")
                showValidationSuccess = false
                return
            }
            error = nil
            withAnimation(.easeInOut(duration: 0.25)) { showValidationSuccess = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                withAnimation(.easeOut(duration: 0.3)) { showValidationSuccess = false }
            }
        } catch {
            self.error = error.localizedDescription
            showValidationSuccess = false
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
        textView.font = JSONSyntaxHighlighter.font
        textView.textColor = .textColor
        textView.backgroundColor = NSColor.controlBackgroundColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.delegate = context.coordinator

        context.coordinator.isUpdating = true
        textView.string = text
        context.coordinator.isUpdating = false

        JSONSyntaxHighlighter.highlight(textView.textStorage!)

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        DispatchQueue.main.async {
            lineCount = text.components(separatedBy: "\n").count
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            let range = textView.selectedRange()
            context.coordinator.isUpdating = true
            textView.string = text
            context.coordinator.isUpdating = false
            textView.setSelectedRange(NSRange(location: min(range.location, (text as NSString).length), length: 0))
            JSONSyntaxHighlighter.highlight(textView.textStorage!)
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
        var isUpdating = false

        init(_ parent: JSONTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating else { return }
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.lineCount = textView.string.components(separatedBy: "\n").count
            JSONSyntaxHighlighter.highlight(textView.textStorage!)
        }
    }
}

// MARK: - JSON Syntax Highlighter

enum JSONSyntaxHighlighter {
    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    private static let stringPattern = try! NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*""#)
    private static let numberPattern = try! NSRegularExpression(pattern: #"-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?"#)
    private static let constantPattern = try! NSRegularExpression(pattern: #"\b(?:true|false|null)\b"#)

    static func highlight(_ textStorage: NSTextStorage) {
        let text = textStorage.string
        let fullRange = NSRange(location: 0, length: textStorage.length)
        guard fullRange.length > 0 else { return }

        textStorage.beginEditing()

        textStorage.addAttribute(.foregroundColor, value: NSColor.textColor, range: fullRange)
        textStorage.addAttribute(.font, value: font, range: fullRange)

        for match in numberPattern.matches(in: text, range: fullRange) {
            textStorage.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: match.range)
        }

        for match in constantPattern.matches(in: text, range: fullRange) {
            textStorage.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: match.range)
        }

        let nsText = text as NSString
        for match in stringPattern.matches(in: text, range: fullRange) {
            let matchRange = match.range
            let isKey = Self.isJSONKey(in: nsText, afterStringEnd: matchRange.location + matchRange.length)
            textStorage.addAttribute(
                .foregroundColor,
                value: isKey ? NSColor.systemTeal : NSColor.systemGreen,
                range: matchRange
            )
        }

        textStorage.endEditing()
    }

    private static func isJSONKey(in nsText: NSString, afterStringEnd end: Int) -> Bool {
        var idx = end
        while idx < nsText.length {
            let ch = nsText.character(at: idx)
            if ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x0D {
                idx += 1
                continue
            }
            return ch == 0x3A // ':'
        }
        return false
    }
}
