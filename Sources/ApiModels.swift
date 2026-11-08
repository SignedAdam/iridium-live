import Foundation
import Observation

/// The models of the API in Settings, Provider, from its `GET {base}/models` (the engine's `models` command), for the
/// cleanup model picker. `auto` is among them only when the API offers it. Empty when the list did not come: Settings
/// then offers a text field for the model id.
@MainActor @Observable
final class ApiModels {
    static let shared = ApiModels()

    private(set) var ids: [String] = []
    private(set) var base: String?
    private(set) var problem: String?

    /// What the engine answered for `base`.
    func received(base: String?, ids: [String], problem: String) {
        self.base = base
        self.ids = ids
        self.problem = problem.isEmpty ? nil : problem
    }
}
