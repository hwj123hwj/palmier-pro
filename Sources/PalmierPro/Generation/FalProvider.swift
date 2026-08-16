import Foundation

/// fal.ai queue API client: submit → poll status → fetch result. One job per request.
struct FalProvider: Sendable {
    struct SubmitResponse: Decodable {
        let request_id: String
        let status_url: String?
        let response_url: String?
    }

    struct StatusResponse: Decodable {
        let status: String
        let queue_position: Int?
    }

    enum ProviderError: LocalizedError {
        case missingKey
        case http(Int, String)
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .missingKey: "No fal.ai API key is set. Add one in Settings → Agent."
            case .http(let code, let body): "fal.ai request failed (HTTP \(code)): \(body.prefix(300))"
            case .malformed(let detail): "Unexpected fal.ai response: \(detail)"
            }
        }
    }

    private let base = URL(string: "https://queue.fal.run")!
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        session = URLSession(configuration: config)
    }

    /// `input` fields use each model's endpoint schema (see GenerationModels).
    func submit(endpoint: String, input: [String: Any]) async throws -> SubmitResponse {
        let data = try JSONSerialization.data(withJSONObject: input)
        let body = try await request(path: endpoint, method: "POST", body: data)
        return try decode(SubmitResponse.self, from: body, context: "submit")
    }

    func status(submit: SubmitResponse) async throws -> StatusResponse {
        guard let url = URL(string: submit.status_url ?? "") else {
            throw ProviderError.malformed("missing status_url")
        }
        let body = try await raw(url: url)
        return try decode(StatusResponse.self, from: body, context: "status")
    }

    /// Terminal payload: `{video: {url}}` or `{images: [{url}], description}`.
    func result(submit: SubmitResponse) async throws -> [String: Any] {
        guard let url = URL(string: submit.response_url ?? "") else {
            throw ProviderError.malformed("missing response_url")
        }
        let body = try await raw(url: url)
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw ProviderError.malformed("response is not a JSON object")
        }
        return json
    }

    static func resultURLs(_ payload: [String: Any]) -> [URL] {
        var urls: [URL] = []
        if let video = payload["video"] as? [String: Any],
           let urlString = video["url"] as? String, let url = URL(string: urlString) {
            urls.append(url)
        }
        for image in (payload["images"] as? [[String: Any]]) ?? [] {
            if let urlString = image["url"] as? String, let url = URL(string: urlString) {
                urls.append(url)
            }
        }
        return urls
    }

    /// Builds the endpoint-specific input object from the catalog-neutral request.
    static func input(
        model: GenerationModel,
        prompt: String,
        aspectRatio: String,
        durationSeconds: Int?,
        resolution: String?,
        sourceImageDataURI: String?,
        referenceImageDataURIs: [String]
    ) -> [String: Any] {
        var input: [String: Any] = ["prompt": prompt]
        switch model.type {
        case .video:
            input["aspect_ratio"] = aspectRatio
            if let durationSeconds, !model.durations.isEmpty {
                let nearest = model.durations.min { abs($0 - durationSeconds) < abs($1 - durationSeconds) }
                input["duration"] = String(nearest ?? model.durations[0])
            }
            if let sourceImageDataURI { input["image_url"] = sourceImageDataURI }
        case .image:
            input["aspect_ratio"] = aspectRatio
            if let resolution { input["resolution"] = resolution }
            if !referenceImageDataURIs.isEmpty {
                input["image_url"] = referenceImageDataURIs[0]
            }
            if referenceImageDataURIs.count > 1 {
                input["image_urls"] = Array(referenceImageDataURIs.dropFirst())
            }
        }
        return input
    }

    private func request(path: String, method: String, body: Data?) async throws -> Data {
        guard var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw ProviderError.malformed("invalid endpoint path")
        }
        components.percentEncodedPath = components.percentEncodedPath
            .replacingOccurrences(of: "//", with: "/")
        guard let url = components.url else { throw ProviderError.malformed("invalid URL") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        return try await raw(request: request)
    }

    private func raw(url: URL) async throws -> Data {
        var mutable = URLRequest(url: url)
        mutable.timeoutInterval = 120
        return try await raw(request: mutable)
    }

    private func raw(request incoming: URLRequest) async throws -> Data {
        let key = GenerationKeyStore.storedKey
        guard !key.isEmpty else { throw ProviderError.missingKey }
        var request = incoming
        request.setValue("Key \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProviderError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, context: String) throws -> T {
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            throw ProviderError.malformed("\(context) response did not decode")
        }
        return decoded
    }
}
