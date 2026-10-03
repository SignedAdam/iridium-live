import Foundation

public actor OpenRouterClient {
    private nonisolated let apiKey: String?
    private nonisolated let session: URLSession
    private nonisolated let baseURL: URL

    public init(apiKey: String? = nil, session: URLSession = .shared,
                baseURL: URL = URL(string: "https://openrouter.ai/api/v1")!) {
        self.apiKey = apiKey?.isEmpty == true ? nil : apiKey
        self.session = session
        self.baseURL = baseURL
    }

    public func models() async throws -> [CatalogModel] {
        try await fetchModels()
    }

    public func endpoints(for modelID: String) async throws -> [CatalogEndpoint] {
        try await fetchEndpoints(modelID)
    }

    public func providers() async throws -> [CatalogProvider] {
        try await fetchProviders()
    }

    public func credits() async throws -> Credits {
        try await fetchCredits()
    }

    public func catalog(filter: ModelFilter = ModelFilter(), concurrency: Int = 12,
                        progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> Catalog {
        let all = try await fetchModels()
        let kept = all.filter { filter.matches($0) }
        let total = kept.count
        progress?(0, total)
        let lanes = max(1, concurrency)
        var endpoints: [CatalogEndpoint] = []
        endpoints.reserveCapacity(total * 3)
        var done = 0
        await withTaskGroup(of: [CatalogEndpoint].self) { group in
            var next = 0
            while next < kept.count, next < lanes {
                let id = kept[next].id
                group.addTask { (try? await self.fetchEndpoints(id)) ?? [] }
                next += 1
            }
            for await found in group {
                endpoints.append(contentsOf: found)
                done += 1
                progress?(done, total)
                if next < kept.count {
                    let id = kept[next].id
                    group.addTask { (try? await self.fetchEndpoints(id)) ?? [] }
                    next += 1
                }
            }
        }
        let providers = (try? await fetchProviders()) ?? []
        return Catalog(models: kept, endpoints: endpoints, providers: providers, fetched: Date())
    }

    private nonisolated func get(_ path: String) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL.appendingPathComponent("")) else {
            throw CatalogError.badRequest(path)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CatalogError.http(http.statusCode)
        }
        return data
    }

    private nonisolated func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CatalogError.decoding(String(describing: error))
        }
    }

    private nonisolated func fetchModels() async throws -> [CatalogModel] {
        let data = try await get("models")
        return try decode(Wrapper<[WireModel]>.self, data).data.map(\.model)
    }

    private nonisolated func fetchEndpoints(_ modelID: String) async throws -> [CatalogEndpoint] {
        let data = try await get("models/\(modelID)/endpoints")
        let wire = try decode(Wrapper<WireEndpoints>.self, data)
        return wire.data.endpoints.map { $0.endpoint(modelID: wire.data.id ?? modelID, modelName: wire.data.name ?? modelID) }
    }

    private nonisolated func fetchProviders() async throws -> [CatalogProvider] {
        let data = try await get("providers")
        return try decode(Wrapper<[WireProvider]>.self, data).data.map(\.provider)
    }

    private nonisolated func fetchCredits() async throws -> Credits {
        let data = try await get("credits")
        let wire = try decode(Wrapper<WireCredits>.self, data).data
        return Credits(total: wire.total_credits ?? 0, used: wire.total_usage ?? 0)
    }
}

private struct Wrapper<T: Decodable>: Decodable {
    let data: T
}

private struct Loose: Decodable, Sendable {
    let value: Double?

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
        } else if let number = try? container.decode(Double.self) {
            value = number
        } else if let text = try? container.decode(String.self) {
            value = Double(text)
        } else {
            value = nil
        }
    }
}

private struct WirePricing: Decodable {
    let prompt: Loose?
    let completion: Loose?
    let input_cache_read: Loose?
}

private struct WirePercentiles: Decodable {
    let p50: Loose?
    let p75: Loose?
    let p90: Loose?
    let p99: Loose?

    var percentiles: Percentiles {
        Percentiles(p50: p50?.value, p75: p75?.value, p90: p90?.value, p99: p99?.value)
    }
}

private struct WireArchitecture: Decodable {
    let input_modalities: [String]?
    let output_modalities: [String]?
}

private struct WireTopProvider: Decodable {
    let context_length: Int?
    let max_completion_tokens: Int?
}

private struct WireModel: Decodable {
    let id: String
    let name: String?
    let created: Double?
    let context_length: Int?
    let architecture: WireArchitecture?
    let pricing: WirePricing?
    let top_provider: WireTopProvider?
    let supported_parameters: [String]?

    var model: CatalogModel {
        CatalogModel(id: id,
                     name: name ?? id,
                     created: created.map { Date(timeIntervalSince1970: $0) },
                     contextLength: context_length ?? top_provider?.context_length,
                     maxCompletionTokens: top_provider?.max_completion_tokens,
                     inputModalities: architecture?.input_modalities ?? [],
                     outputModalities: architecture?.output_modalities ?? [],
                     inputPrice: pricing?.prompt?.value.map { $0 * 1_000_000 },
                     outputPrice: pricing?.completion?.value.map { $0 * 1_000_000 },
                     supportedParameters: supported_parameters ?? [])
    }
}

private struct WireEndpoints: Decodable {
    let id: String?
    let name: String?
    let endpoints: [WireEndpoint]

    private enum CodingKeys: String, CodingKey { case id, name, endpoints }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        endpoints = try container.decodeIfPresent([WireEndpoint].self, forKey: .endpoints) ?? []
    }
}

private struct WireEndpoint: Decodable {
    let name: String?
    let model_id: String?
    let model_name: String?
    let provider_name: String?
    let tag: String?
    let quantization: String?
    let context_length: Int?
    let max_completion_tokens: Int?
    let pricing: WirePricing?
    let supported_parameters: [String]?
    let status: Loose?
    let uptime_last_5m: Loose?
    let uptime_last_30m: Loose?
    let uptime_last_1d: Loose?
    let latency_last_30m: WirePercentiles?
    let throughput_last_30m: WirePercentiles?

    func endpoint(modelID: String, modelName: String) -> CatalogEndpoint {
        let provider = provider_name ?? tag ?? "Unknown"
        let id = model_id ?? modelID
        return CatalogEndpoint(name: name ?? "\(provider) | \(id)",
                               modelID: id,
                               modelName: model_name ?? modelName,
                               providerName: provider,
                               tag: tag ?? provider.lowercased(),
                               quantization: quantization,
                               contextLength: context_length,
                               maxCompletionTokens: max_completion_tokens,
                               inputPrice: pricing?.prompt?.value.map { $0 * 1_000_000 },
                               outputPrice: pricing?.completion?.value.map { $0 * 1_000_000 },
                               cacheReadPrice: pricing?.input_cache_read?.value.map { $0 * 1_000_000 },
                               supportedParameters: supported_parameters ?? [],
                               status: status?.value,
                               uptime5m: uptime_last_5m?.value,
                               uptime30m: uptime_last_30m?.value,
                               uptime1d: uptime_last_1d?.value,
                               latency: latency_last_30m?.percentiles ?? Percentiles(),
                               throughput: throughput_last_30m?.percentiles ?? Percentiles())
    }
}

private struct WireProvider: Decodable {
    let name: String?
    let slug: String?
    let privacy_policy_url: String?
    let terms_of_service_url: String?
    let status_page_url: String?
    let headquarters: String?
    let datacenters: [String]?

    var provider: CatalogProvider {
        CatalogProvider(name: name ?? slug ?? "",
                        slug: slug ?? name ?? "",
                        privacyPolicyURL: privacy_policy_url,
                        termsOfServiceURL: terms_of_service_url,
                        statusPageURL: status_page_url,
                        headquarters: headquarters,
                        datacenters: datacenters ?? [])
    }
}

private struct WireCredits: Decodable {
    let total_credits: Double?
    let total_usage: Double?
}
