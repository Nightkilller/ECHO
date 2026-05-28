import Foundation

/// Groq API helper to replace ClaudeAPI.
class GroqAPI {
    var model: String
    private let session: URLSession

    init(model: String = Config.shared.modelName) {
        self.model = model
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)
    }

    private var resolvedModel: String {
        if model == "claude-sonnet-4-6" {
            return Config.shared.modelName.isEmpty || Config.shared.modelName.contains("claude") ? "llama-3.3-70b-versatile" : Config.shared.modelName
        } else if model == "claude-opus-4-6" {
            return "llama-3.3-70b-versatile"
        }
        return model
    }

    private func makeAPIRequest() -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(Config.shared.groqApiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        guard !Config.shared.groqApiKey.isEmpty else {
            throw NSError(domain: "GroqAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "GROQ_API_KEY is not configured in .env"])
        }

        var request = makeAPIRequest()
        var messages: [[String: Any]] = []

        messages.append(["role": "system", "content": systemPrompt])

        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        var contentBlocks: [[String: Any]] = []
        for image in images {
            contentBlocks.append([
                "type": "image_url",
                "image_url": [
                    "url": "data:image/jpeg;base64,\(image.data.base64EncodedString())"
                ]
            ])
            contentBlocks.append([
                "type": "text",
                "text": image.label
            ])
        }
        contentBlocks.append([
            "type": "text",
            "text": userPrompt
        ])
        messages.append(["role": "user", "content": contentBlocks])

        let body: [String: Any] = [
            "model": resolvedModel,
            "max_tokens": 1024,
            "temperature": 0.3,
            "stream": false, // We use non-streaming for simplicity
            "messages": messages
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "GroqAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "GroqAPI", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "API Error (\(httpResponse.statusCode)): \(errorBody)"])
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw NSError(domain: "GroqAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response format"])
        }

        await onTextChunk(text)

        let duration = Date().timeIntervalSince(startTime)
        return (text: text, duration: duration)
    }

    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval) {
        return try await analyzeImageStreaming(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            onTextChunk: { _ in }
        )
    }
}
