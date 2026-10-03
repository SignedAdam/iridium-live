import Foundation

public enum EndpointMetric: String, Codable, Hashable, Sendable, CaseIterable {
    case latency
    case throughput
    case inputPrice
    case outputPrice
    case uptime
    case context

    public func value(_ endpoint: CatalogEndpoint) -> Double? {
        switch self {
        case .latency: endpoint.latency.p50
        case .throughput: endpoint.throughput.p50
        case .inputPrice: endpoint.inputPrice
        case .outputPrice: endpoint.outputPrice
        case .uptime: endpoint.uptime30m
        case .context: endpoint.contextLength.map(Double.init)
        }
    }

    public var lowerIsBetter: Bool {
        switch self {
        case .latency, .inputPrice, .outputPrice: true
        case .throughput, .uptime, .context: false
        }
    }

    public func better(_ one: CatalogEndpoint, than other: CatalogEndpoint) -> Bool {
        guard let mine = value(one) else { return false }
        guard let theirs = value(other) else { return true }
        return lowerIsBetter ? mine < theirs : mine > theirs
    }
}

extension Sequence where Element == CatalogEndpoint {
    public func best(by metric: EndpointMetric) -> [CatalogEndpoint] {
        var picked: [String: CatalogEndpoint] = [:]
        var order: [String] = []
        for endpoint in self {
            if let standing = picked[endpoint.modelID] {
                if metric.better(endpoint, than: standing) { picked[endpoint.modelID] = endpoint }
            } else {
                picked[endpoint.modelID] = endpoint
                order.append(endpoint.modelID)
            }
        }
        return order.compactMap { picked[$0] }
    }

    public func best(by metric: EndpointMetric, of modelID: String) -> CatalogEndpoint? {
        var standing: CatalogEndpoint?
        for endpoint in self where endpoint.modelID == modelID {
            if standing == nil || metric.better(endpoint, than: standing!) { standing = endpoint }
        }
        return standing
    }

    public func fastest(of modelID: String) -> CatalogEndpoint? { best(by: .latency, of: modelID) }

    public func quickest(of modelID: String) -> CatalogEndpoint? { best(by: .throughput, of: modelID) }

    public func cheapest(of modelID: String) -> CatalogEndpoint? { best(by: .inputPrice, of: modelID) }
}

extension RandomAccessCollection {
    public func page(_ index: Int, size: Int) -> [Element] {
        guard size > 0, index >= 0 else { return [] }
        let start = self.index(startIndex, offsetBy: index * size, limitedBy: endIndex) ?? endIndex
        let end = self.index(start, offsetBy: size, limitedBy: endIndex) ?? endIndex
        return Array(self[start..<end])
    }

    public func pageCount(size: Int) -> Int {
        guard size > 0 else { return 0 }
        return (count + size - 1) / size
    }
}
