import Foundation
import QuotaBackend

class APIService {
    static let shared = APIService()
    
    private var baseURL: String
    private let session: URLSession
    
    private init() {
        let defaults = UserDefaults.standard
        let host = defaults.string(forKey: DefaultsKey.remoteHost) ?? "127.0.0.1"
        let port = defaults.integer(forKey: DefaultsKey.remotePort) == 0 ? 4318 : defaults.integer(forKey: DefaultsKey.remotePort)
        self.baseURL = "http://\(host):\(port)"
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    func updateBaseURL(_ url: String) {
        self.baseURL = url.hasSuffix("/") ? String(url.dropLast()) : url
    }
    
    // MARK: - Dashboard API
    
    func fetchDashboard(providerIds: [String] = []) async throws -> DashboardResponse {
        guard var components = URLComponents(string: "\(baseURL)/api/dashboard") else {
            throw APIError.invalidURL
        }
        if !providerIds.isEmpty {
            components.queryItems = [
                URLQueryItem(name: "ids", value: providerIds.joined(separator: ","))
            ]
        }
        guard let url = components.url else {
            throw APIError.invalidURL
        }

        return try await decode(DashboardResponse.self, from: url)
    }
    
    func fetchProviders(_ providerId: String) async throws -> [ProviderData] {
        let dashboard = try await fetchDashboard(providerIds: [providerId])
        return dashboard.providers.map(\.summary)
    }
    
    func checkHealth() async throws -> HealthResponse {
        guard let url = URL(string: "\(baseURL)/health") else {
            throw APIError.invalidURL
        }
        let data = try await requestData(from: url)
        let decoder = JSONDecoder()

        do {
            return try decoder.decode(HealthResponse.self, from: data)
        } catch let decodeError {
            if let legacy = try? decoder.decode(LegacyHealthResponse.self, from: data) {
                return HealthResponse(
                    ok: legacy.status?.lowercased() == "ok",
                    generatedAt: legacy.time ?? SharedFormatters.iso8601String(from: Date())
                )
            }
            throw APIError.decodingError(decodeError)
        }
    }

    private func requestData(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        let data = try await requestData(from: url)

        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }
}

// MARK: - Helper Models

struct HealthResponse: Decodable {
    let ok: Bool
    let generatedAt: String

    init(ok: Bool, generatedAt: String) {
        self.ok = ok
        self.generatedAt = generatedAt
    }
}

private struct LegacyHealthResponse: Decodable {
    let status: String?
    let time: String?
}

// MARK: - Errors

enum APIError: LocalizedError {
    case invalidResponse
    case invalidURL
    case httpError(statusCode: Int)
    case decodingError(Error)
    case networkError(Error)
    
    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid server response"
        case .invalidURL:
            return "Invalid server URL"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .decodingError(let error):
            return "Failed to parse data: \(error.localizedDescription)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}
