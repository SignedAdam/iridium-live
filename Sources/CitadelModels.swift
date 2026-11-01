import Foundation
import Observation

/// The models Vegeta serves, from Citadel's `GET /v1/models`, for the cleanup model menu. Empty when there is no
/// Albastov key or the list did not come: Settings then offers a text field for the model id.
@MainActor @Observable
final class CitadelModels {
    static let shared = CitadelModels()
    static let url = URL(string: "https://citadel.albastov.com/v1/models")!

    private(set) var ids: [String] = []
    private var loading = false

    func load() {
        guard !loading, let key = Keychain.shared.values()[ApiKey.citadel.id] else { return }
        loading = true
        var request = URLRequest(url: Self.url, timeoutInterval: 10)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("Iridium Live", forHTTPHeaderField: "User-Agent")
        Task {
            defer { loading = false }
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = object["data"] as? [[String: Any]] else { return }
            ids = models.compactMap { $0["id"] as? String }
        }
    }
}
