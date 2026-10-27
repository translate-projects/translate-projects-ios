import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ApiError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

/** What the translator needs from the API; a fake one in the tests. */
public protocol TranslateApi: AnyObject {
    var requests: Int { get }
    func validateChanges(_ fileHashes: [String: String]) async throws -> [String: JSON]
    func loadSources(_ texts: [String: String], sourceLang: String, routeFile: String, version: String) async throws -> String?
    func makeTranslations(sourceLang: String, targetLang: String, routeFile: String, version: String) async throws -> String?
    func getTranslations(_ targetLang: String) async throws -> [String: String]
}

public final class Api: TranslateApi {
    // shortcut: the backend has no "ios" type_project yet; switch when it is added to seeders/type_projects.py
    static let typeProject = "json"
    private static let retryStatus: Set<Int> = [429, 500, 502, 503, 504, 524]

    let token: String?
    let baseUrl: String
    public var timeout: TimeInterval = 60
    public private(set) var requests = 0

    public init(token: String?, baseUrl: String = "https://api.translateprojects.dev") {
        self.token = token
        self.baseUrl = baseUrl
    }

    public func validateChanges(_ fileHashes: [String: String]) async throws -> [String: JSON] {
        try await data("POST", "/v1/translations/validate-changes-files", body: .object(fileHashes.mapValues(JSON.string)))?.object ?? [:]
    }

    public func loadSources(_ texts: [String: String], sourceLang: String, routeFile: String, version: String) async throws -> String? {
        try await data("POST", "/v1/translations/load-sources",
                       ["source_lang": sourceLang, "route_file": routeFile, "type_project": Api.typeProject, "cache_hash": version],
                       body: .object(texts.mapValues(JSON.string)))?["task_id"]?.string
    }

    public func makeTranslations(sourceLang: String, targetLang: String, routeFile: String, version: String) async throws -> String? {
        try await data("POST", "/v1/translations/",
                       ["source_lang": sourceLang, "target_lang": targetLang, "route_file": routeFile, "cache_hash": version])?["task_id"]?.string
    }

    public func getTranslations(_ targetLang: String) async throws -> [String: String] {
        (try await data("GET", "/v1/translations/language-project", ["target_lang": targetLang])?.object ?? [:]).compactMapValues(\.string)
    }

    /** Calls the API retrying network errors, 429 and 5xx with backoff; any other error throws. */
    func data(_ method: String, _ path: String, _ params: [String: String] = [:], body: JSON? = nil) async throws -> JSON? {
        guard let token, !token.isEmpty else {
            throw ApiError("MISSING_API_KEY: set TRANSLATE_PROJECTS_API_KEY or tokenFile in translate-projects.json")
        }
        var components = URLComponents(string: baseUrl + path)!
        if !params.isEmpty { components.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = try JSONEncoder().encode(body) }
        for attempt in 1...3 {
            if attempt > 1 { try await Task.sleep(nanoseconds: UInt64(1 << (attempt - 2)) * 1_000_000_000) }
            requests += 1
            let data: Data, status: Int
            do {
                let (d, response) = try await URLSession.shared.data(for: request)
                (data, status) = (d, (response as? HTTPURLResponse)?.statusCode ?? 0)
            } catch {
                log("Translate Projects: request failed: \(error.localizedDescription) (attempt \(attempt)/3)")
                continue
            }
            if status == 200 {
                let json = try JSON.parse(data)
                if let s = json["status"]?.string, s != "SUCCESS", let message = json["message"]?.string {
                    log("Translate Projects: \(json["error"]?.string ?? json["code"]?.string ?? s): \(message)")
                }
                return json["data"]
            }
            if Api.retryStatus.contains(status) {
                log("Translate Projects: API \(status) (attempt \(attempt)/3), retrying...")
                continue
            }
            let error = try? JSON.parse(data)
            let detail = error.map { "\($0["code"]?.string ?? "") \($0["message"]?.string ?? "")".trimmingCharacters(in: .whitespaces) }
            throw ApiError("Translate Projects API error (\(status)): \(detail ?? String(decoding: data.prefix(200), as: UTF8.self))")
        }
        throw ApiError("Translate Projects: max retries reached for \(path)")
    }
}

func log(_ message: String) {
    print(message)
}
