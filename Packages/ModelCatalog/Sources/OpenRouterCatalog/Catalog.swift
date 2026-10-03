import Foundation

public struct Percentiles: Codable, Hashable, Sendable {
    public var p50: Double?
    public var p75: Double?
    public var p90: Double?
    public var p99: Double?

    public init(p50: Double? = nil, p75: Double? = nil, p90: Double? = nil, p99: Double? = nil) {
        self.p50 = p50
        self.p75 = p75
        self.p90 = p90
        self.p99 = p99
    }

    public var isEmpty: Bool { p50 == nil && p75 == nil && p90 == nil && p99 == nil }
}

public struct CatalogModel: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var created: Date?
    public var contextLength: Int?
    public var maxCompletionTokens: Int?
    public var inputModalities: [String]
    public var outputModalities: [String]
    public var inputPrice: Double?
    public var outputPrice: Double?
    public var supportedParameters: [String]

    public init(id: String, name: String, created: Date? = nil, contextLength: Int? = nil,
                maxCompletionTokens: Int? = nil, inputModalities: [String] = [], outputModalities: [String] = [],
                inputPrice: Double? = nil, outputPrice: Double? = nil, supportedParameters: [String] = []) {
        self.id = id
        self.name = name
        self.created = created
        self.contextLength = contextLength
        self.maxCompletionTokens = maxCompletionTokens
        self.inputModalities = inputModalities
        self.outputModalities = outputModalities
        self.inputPrice = inputPrice
        self.outputPrice = outputPrice
        self.supportedParameters = supportedParameters
    }

    public var author: String {
        name.range(of: ": ").map { String(name[..<$0.lowerBound]) } ?? String(id.prefix(while: { $0 != "/" }))
    }

    public var shortName: String {
        name.range(of: ": ").map { String(name[$0.upperBound...]) } ?? name
    }
}

public struct CatalogEndpoint: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var modelID: String
    public var modelName: String
    public var providerName: String
    public var tag: String
    public var quantization: String?
    public var contextLength: Int?
    public var maxCompletionTokens: Int?
    public var inputPrice: Double?
    public var outputPrice: Double?
    public var cacheReadPrice: Double?
    public var supportedParameters: [String]
    public var status: Double?
    public var uptime5m: Double?
    public var uptime30m: Double?
    public var uptime1d: Double?
    public var latency: Percentiles
    public var throughput: Percentiles

    public init(name: String, modelID: String, modelName: String, providerName: String, tag: String,
                quantization: String? = nil, contextLength: Int? = nil, maxCompletionTokens: Int? = nil,
                inputPrice: Double? = nil, outputPrice: Double? = nil, cacheReadPrice: Double? = nil,
                supportedParameters: [String] = [], status: Double? = nil, uptime5m: Double? = nil,
                uptime30m: Double? = nil, uptime1d: Double? = nil,
                latency: Percentiles = Percentiles(), throughput: Percentiles = Percentiles()) {
        self.id = "\(modelID)|\(name)"
        self.name = name
        self.modelID = modelID
        self.modelName = modelName
        self.providerName = providerName
        self.tag = tag
        self.quantization = quantization
        self.contextLength = contextLength
        self.maxCompletionTokens = maxCompletionTokens
        self.inputPrice = inputPrice
        self.outputPrice = outputPrice
        self.cacheReadPrice = cacheReadPrice
        self.supportedParameters = supportedParameters
        self.status = status
        self.uptime5m = uptime5m
        self.uptime30m = uptime30m
        self.uptime1d = uptime1d
        self.latency = latency
        self.throughput = throughput
    }

    public var modelShortName: String {
        modelName.range(of: ": ").map { String(modelName[$0.upperBound...]) } ?? modelName
    }

    public var savedID: String { "\(modelID)@\(tag)" }

    public var hasLatency: Bool { latency.p50 != nil }
}

public struct CatalogProvider: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var slug: String
    public var privacyPolicyURL: String?
    public var termsOfServiceURL: String?
    public var statusPageURL: String?
    public var headquarters: String?
    public var datacenters: [String]

    public var id: String { slug }

    public init(name: String, slug: String, privacyPolicyURL: String? = nil, termsOfServiceURL: String? = nil,
                statusPageURL: String? = nil, headquarters: String? = nil, datacenters: [String] = []) {
        self.name = name
        self.slug = slug
        self.privacyPolicyURL = privacyPolicyURL
        self.termsOfServiceURL = termsOfServiceURL
        self.statusPageURL = statusPageURL
        self.headquarters = headquarters
        self.datacenters = datacenters
    }
}

public struct Credits: Codable, Hashable, Sendable {
    public var total: Double
    public var used: Double

    public init(total: Double, used: Double) {
        self.total = total
        self.used = used
    }

    public var left: Double { total - used }
}

public struct Catalog: Codable, Hashable, Sendable {
    public var models: [CatalogModel]
    public var endpoints: [CatalogEndpoint]
    public var providers: [CatalogProvider]
    public var fetched: Date

    public init(models: [CatalogModel] = [], endpoints: [CatalogEndpoint] = [],
                providers: [CatalogProvider] = [], fetched: Date = Date()) {
        self.models = models
        self.endpoints = endpoints
        self.providers = providers
        self.fetched = fetched
    }

    public var age: TimeInterval { Date().timeIntervalSince(fetched) }

    public var modelsByID: [String: CatalogModel] {
        Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public var endpointsByModel: [String: [CatalogEndpoint]] {
        Dictionary(grouping: endpoints, by: \.modelID)
    }

    public func model(_ id: String) -> CatalogModel? {
        models.first { $0.id == id }
    }

    public func endpoints(of modelID: String) -> [CatalogEndpoint] {
        endpoints.filter { $0.modelID == modelID }
    }

    public func endpoint(savedID: String) -> CatalogEndpoint? {
        endpoints.first { $0.savedID == savedID }
    }
}

public enum CatalogError: Error, Sendable, Equatable {
    case http(Int)
    case decoding(String)
    case badRequest(String)
}
