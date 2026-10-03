import Foundation

public struct ModelFilter: Codable, Hashable, Sendable {
    public var search: String
    public var inputModalities: Set<String>
    public var outputModalities: Set<String>
    public var minimumContext: Int
    public var maximumInputPrice: Double?
    public var maximumOutputPrice: Double?
    public var requiredParameters: Set<String>
    public var needsLatency: Bool

    public init(search: String = "", inputModalities: Set<String> = [], outputModalities: Set<String> = ["text"],
                minimumContext: Int = 0, maximumInputPrice: Double? = nil, maximumOutputPrice: Double? = nil,
                requiredParameters: Set<String> = [], needsLatency: Bool = false) {
        self.search = search
        self.inputModalities = inputModalities
        self.outputModalities = outputModalities
        self.minimumContext = minimumContext
        self.maximumInputPrice = maximumInputPrice
        self.maximumOutputPrice = maximumOutputPrice
        self.requiredParameters = requiredParameters
        self.needsLatency = needsLatency
    }

    public func matches(_ model: CatalogModel) -> Bool {
        guard hits(words: [model.id, model.name]) else { return false }
        guard covers(inputModalities, model.inputModalities), covers(outputModalities, model.outputModalities) else { return false }
        guard model.contextLength ?? 0 >= minimumContext else { return false }
        guard within(maximumInputPrice, model.inputPrice), within(maximumOutputPrice, model.outputPrice) else { return false }
        guard requiredParameters.isSubset(of: Set(model.supportedParameters)) else { return false }
        return true
    }

    public func matches(_ endpoint: CatalogEndpoint, model: CatalogModel? = nil) -> Bool {
        guard hits(words: [endpoint.modelID, endpoint.modelName, endpoint.providerName]) else { return false }
        if let model {
            guard covers(inputModalities, model.inputModalities), covers(outputModalities, model.outputModalities) else { return false }
        }
        guard endpoint.contextLength ?? 0 >= minimumContext else { return false }
        guard within(maximumInputPrice, endpoint.inputPrice), within(maximumOutputPrice, endpoint.outputPrice) else { return false }
        guard requiredParameters.isSubset(of: Set(endpoint.supportedParameters)) else { return false }
        if needsLatency, !endpoint.hasLatency { return false }
        return true
    }

    private func hits(words: [String]) -> Bool {
        let wanted = search.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return true }
        return words.contains { $0.range(of: wanted, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    private func covers(_ wanted: Set<String>, _ have: [String]) -> Bool {
        wanted.isEmpty || wanted.isSubset(of: Set(have))
    }

    private func within(_ limit: Double?, _ price: Double?) -> Bool {
        guard let limit else { return true }
        guard let price else { return false }
        return price <= limit
    }
}
