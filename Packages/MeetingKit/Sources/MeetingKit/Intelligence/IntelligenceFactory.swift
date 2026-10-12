import Foundation

enum IntelligenceFactory {
    static func provider(for config: MeetingConfig) -> IntelligenceProvider? {
        switch config.summaryProvider {
        case "openrouter":
            if let key = config.key("openrouter"), !key.isEmpty {
                return OpenRouterProvider(apiKey: key, model: config.summaryModel)
            }
        case "anthropic":
            if let key = config.key("anthropic"), !key.isEmpty {
                return ClaudeProvider(apiKey: key, model: config.summaryModel)
            }
        default:
            break
        }
        return nil
    }
}
