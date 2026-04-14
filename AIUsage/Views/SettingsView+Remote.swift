import SwiftUI

extension SettingsView {

    var remoteConnectionStatusView: some View {
        let icon: String
        let tint: Color
        let title: String
        switch remoteConnectionState {
        case .idle:
            icon = "network"; tint = .secondary; title = L("Connection not tested", "\u{5C1A}\u{672A}\u{6D4B}\u{8BD5}\u{8FDE}\u{63A5}")
        case .success:
            icon = "checkmark.circle.fill"; tint = .green; title = L("Remote server reachable", "\u{8FDC}\u{7A0B}\u{670D}\u{52A1}\u{53EF}\u{8FDE}\u{63A5}")
        case .failure:
            icon = "xmark.octagon.fill"; tint = .red; title = L("Connection failed", "\u{8FDE}\u{63A5}\u{5931}\u{8D25}")
        }

        return HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(remoteConnectionMessage?.nilIfBlank ?? title)
                .font(.caption)
                .foregroundStyle(tint)
            Spacer()
        }
        .padding(8)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    func applyRemoteSettings(refreshDashboard: Bool = true) {
        let host = remoteHostInput.trimmingCharacters(in: .whitespaces)
        let port = Int(remotePortInput.trimmingCharacters(in: .whitespaces)) ?? 4318
        settings.remoteHost = host.isEmpty ? "127.0.0.1" : host
        settings.remotePort = port
        settings.saveSettings()
        remoteConnectionState = .idle
        remoteConnectionMessage = nil
        if refreshDashboard {
            refreshCoordinator.refreshAllProviders()
        }
    }

    @MainActor
    func testRemoteConnection() async {
        applyRemoteSettings(refreshDashboard: false)
        isTestingRemoteConnection = true
        defer { isTestingRemoteConnection = false }

        APIService.shared.updateBaseURL("http://\(settings.remoteHost):\(settings.remotePort)")
        let startedAt = Date()

        do {
            let response = try await APIService.shared.checkHealth()
            let latencyMs = max(1, Int(Date().timeIntervalSince(startedAt) * 1000))
            remoteConnectionState = response.ok ? .success : .failure
            remoteConnectionMessage = L(
                "Responded in \(latencyMs) ms · \(response.generatedAt)",
                "响应耗时 \(latencyMs) ms · \(response.generatedAt)"
            )
        } catch {
            remoteConnectionState = .failure
            remoteConnectionMessage = error.localizedDescription
        }
    }
}
