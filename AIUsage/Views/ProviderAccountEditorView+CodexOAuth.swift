import SwiftUI
import WebKit

// MARK: - Codex OAuth Browser

struct CodexOAuthBrowserPane: View {
    let loginURL: URL?
    let phase: CodexLoginCoordinator.Phase
    let language: String
    let onObservedCallback: (URL) -> Void
    let onOpenInBrowser: () -> Void
    let onCopyLink: () -> Void

    @State private var isLoading = true
    @State private var currentURL: URL?
    @State private var pageTitle = ""

    private var isCallbackTransitioning: Bool {
        guard let host = currentURL?.host?.lowercased() else { return false }
        return host.contains("localhost") || host.contains("127.0.0.1")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pageTitle.nilIfBlank ?? L("OpenAI Sign-In", "OpenAI 登录"))
                        .font(.subheadline.weight(.semibold))
                    if let currentURL {
                        Text(currentURL.host?.nilIfBlank ?? currentURL.absoluteString)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    onCopyLink()
                } label: {
                    Label(L("Copy Link", "复制链接"), systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(loginURL == nil)

                Button {
                    onOpenInBrowser()
                } label: {
                    Label(L("Open in Browser", "浏览器打开"), systemImage: "safari")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(loginURL == nil)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(nsColor: .controlBackgroundColor))

                if let loginURL {
                    CodexOAuthWebView(
                        url: loginURL,
                        isLoading: $isLoading,
                        currentURL: $currentURL,
                        pageTitle: $pageTitle,
                        onNavigation: { navigatedURL in
                            if let navigatedURL, isSuccessfulCallbackURL(navigatedURL) {
                                onObservedCallback(navigatedURL)
                            }
                        }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    if isCallbackTransitioning || phase == .waitingForCompletion || phase == .succeeded {
                        callbackOverlay
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "globe")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(L("Preparing the official login page…", "正在准备官方登录页面…"))
                            .font(.subheadline.weight(.semibold))
                        Text(L("If nothing appears in a moment, use the button above to open the page in your browser.", "如果稍后仍未出现，请使用上方按钮在浏览器中打开登录页。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 320)
                    }
                }
            }
            .frame(minHeight: 360)
        }
    }

    private func isSuccessfulCallbackURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(),
              host.contains("localhost") || host.contains("127.0.0.1") else {
            return false
        }

        let path = url.path.lowercased()
        if path.contains("success") || path.contains("callback") {
            return true
        }

        let queryNames = Set((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map {
            $0.name.lowercased()
        })
        return queryNames.contains("id_token")
            || queryNames.contains("access_token")
            || queryNames.contains("code")
    }

    private var callbackOverlay: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.large)
            Text(L("Completing Codex login…", "正在完成 Codex 登录…"))
                .font(.headline)
            Text(L("You can return to AIUsage now. The account will connect automatically after Codex finishes.", "现在可以回到 AIUsage。Codex 完成收尾后，账号会自动接入。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }
}

struct CodexOAuthWebView: NSViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    @Binding var currentURL: URL?
    @Binding var pageTitle: String
    let onNavigation: (URL?) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if nsView.url?.absoluteString != url.absoluteString {
            nsView.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: CodexOAuthWebView

        init(parent: CodexOAuthWebView) {
            self.parent = parent
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if let requestURL = navigationAction.request.url {
                DispatchQueue.main.async {
                    self.parent.currentURL = requestURL
                    self.parent.onNavigation(requestURL)
                }
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = true
                self.parent.currentURL = webView.url
                self.parent.pageTitle = webView.title ?? ""
                self.parent.onNavigation(webView.url)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.currentURL = webView.url
                self.parent.pageTitle = webView.title ?? ""
                self.parent.onNavigation(webView.url)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.currentURL = webView.url
                self.parent.onNavigation(webView.url)
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.currentURL = webView.url
                self.parent.onNavigation(webView.url)
            }
        }
    }
}
