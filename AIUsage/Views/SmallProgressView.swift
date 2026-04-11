import SwiftUI
import AppKit

// 用 NSViewRepresentable 直接包装 NSProgressIndicator，
// 避免 SwiftUI ProgressView 的 AutoLayout min/max 约束警告
struct SmallProgressView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSProgressIndicator {
        let v = NSProgressIndicator()
        v.style = .spinning
        v.controlSize = .small
        v.isIndeterminate = true
        v.translatesAutoresizingMaskIntoConstraints = false
        v.startAnimation(nil)
        return v
    }
    func updateNSView(_ nsView: NSProgressIndicator, context: Context) {}
}
