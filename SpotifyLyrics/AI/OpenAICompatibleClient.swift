import Foundation
import os

public protocol AIHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: AIHTTPClient {}

public struct AITranslationHTTPResult: Equatable, Sendable {
    public let content: Data
    public let statusCode: Int
    public let requestID: String
    public let elapsed: TimeInterval

    public init(content: Data, statusCode: Int, requestID: String, elapsed: TimeInterval) {
        self.content = content
        self.statusCode = statusCode
        self.requestID = requestID
        self.elapsed = elapsed
    }
}

public struct OpenAICompatibleClient: Sendable {
    private let httpClient: any AIHTTPClient
    private let logger = Logger(subsystem: "com.spotifylyrics.app", category: "ai.translation")

    public init(httpClient: any AIHTTPClient = URLSession.shared) {
        self.httpClient = httpClient
    }

    public func complete(
        prompt: AITranslationPrompt,
        configuration: AITranslationConfiguration,
        apiKey: String,
        inputLineCount: Int
    ) async throws -> AITranslationHTTPResult {
        try await send(
            system: prompt.system,
            user: prompt.user,
            prompt: prompt,
            configuration: configuration,
            apiKey: apiKey,
            inputLineCount: inputLineCount
        )
    }

    public func testConnection(
        configuration: AITranslationConfiguration,
        apiKey: String
    ) async throws -> AITranslationHTTPResult {
        let prompt = AITranslationPrompt(
            system: "Return only a JSON array with one item: {\"index\":0,\"translation\":\"ok\"}.",
            user: "{\"lines\":[{\"index\":0,\"text\":\"ping\"}]}" ,
            promptHash: "connection-test"
        )
        return try await send(
            system: prompt.system,
            user: prompt.user,
            prompt: prompt,
            configuration: configuration,
            apiKey: apiKey,
            inputLineCount: 1
        )
    }

    /// Reads only the model directory. This is deliberately separate from
    /// translation execution so settings can cache model names and never
    /// send the current lyric document while browsing configuration.
    public func listModels(
        configuration: AITranslationConfiguration,
        apiKey: String
    ) async throws -> [TranslationModelDescriptor] {
        guard !apiKey.isEmpty else { throw AITranslationError.missingAPIKey }
        let endpoint = AITranslationEndpoint(baseURL: configuration.baseURL)
        guard endpoint.modelsURL.scheme == "http" || endpoint.modelsURL.scheme == "https" else {
            throw AITranslationError.invalidEndpoint
        }
        var request = URLRequest(url: endpoint.modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = configuration.timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await httpClient.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            switch status {
            case 401, 403: throw AITranslationError.unauthorized
            case 429: throw AITranslationError.rateLimited
            default: throw AITranslationError.server(status)
            }
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw AITranslationError.invalidResponse("模型目录响应不是有效 JSON")
        }
        guard let dictionary = object as? [String: Any],
              let rows = dictionary["data"] as? [[String: Any]] else {
            throw AITranslationError.invalidResponse("模型目录响应缺少 data")
        }
        var models: [TranslationModelDescriptor] = []
        for row in rows {
            guard let id = row["id"] as? String, !id.isEmpty else {
                throw AITranslationError.invalidResponse("模型目录条目缺少非空 ID")
            }
            models.append(TranslationModelDescriptor(id: id))
        }
        return models.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    private func send(
        system: String,
        user: String,
        prompt: AITranslationPrompt,
        configuration: AITranslationConfiguration,
        apiKey: String,
        inputLineCount: Int
    ) async throws -> AITranslationHTTPResult {
        guard !apiKey.isEmpty else { throw AITranslationError.missingAPIKey }
        let endpoint = AITranslationEndpoint(baseURL: configuration.baseURL)
        let url = try endpoint.validatedChatCompletionsURL()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": configuration.model,
            "temperature": configuration.temperature,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let requestID = UUID().uuidString
        let started = Date()
        do {
            let (data, response) = try await httpClient.data(for: request)
            let elapsed = Date().timeIntervalSince(started)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let elapsedText = String(format: "%.3f", elapsed)
            logger.info("AI request id=\(requestID, privacy: .public) model=\(configuration.model, privacy: .public) host=\(endpoint.hostForLogging, privacy: .public) inputLines=\(inputLineCount, privacy: .public) outputLines=0 status=\(status, privacy: .public) elapsed=\(elapsedText, privacy: .public)")
            guard (200..<300).contains(status) else {
                switch status {
                case 401, 403: throw AITranslationError.unauthorized
                case 429: throw AITranslationError.rateLimited
                default: throw AITranslationError.server(status)
                }
            }
            let content = try extractMessageContent(from: data)
            return AITranslationHTTPResult(
                content: content,
                statusCode: status,
                requestID: requestID,
                elapsed: elapsed
            )
        } catch is CancellationError {
            throw AITranslationError.cancelled
        } catch let error as URLError where error.code == .timedOut {
            throw AITranslationError.timedOut
        } catch let error as AITranslationError {
            throw error
        } catch {
            throw AITranslationError.network(error.localizedDescription)
        }
    }

    private func extractMessageContent(from data: Data) throws -> Data {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw AITranslationError.invalidResponse("API 响应不是 JSON")
        }
        guard let root = object as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            throw AITranslationError.invalidResponse("API 响应缺少 choices.message")
        }
        if let content = message["content"] as? String {
            return Data(content.utf8)
        }
        // Some compatible gateways return an array of text content blocks.
        if let blocks = message["content"] as? [[String: Any]] {
            let text = blocks.compactMap { $0["text"] as? String }.joined()
            guard !text.isEmpty else { throw AITranslationError.invalidResponse("API 响应内容为空") }
            return Data(text.utf8)
        }
        throw AITranslationError.invalidResponse("API 响应内容为空")
    }
}
