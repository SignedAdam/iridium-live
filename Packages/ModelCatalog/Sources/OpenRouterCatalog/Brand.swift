import Foundation

public struct Brand: Hashable, Sendable {
    public let slug: String
    public let name: String
    public let hex: UInt32
    public let icon: String?

    public init(slug: String, name: String, hex: UInt32, icon: String? = nil) {
        self.slug = slug
        self.name = name
        self.hex = hex
        self.icon = icon
    }

    public var initials: String {
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "." })
        guard let first = parts.first?.first else { return "?" }
        if parts.count > 1, let second = parts[1].first { return String(first) + String(second) }
        return String(first).uppercased()
    }

    public static func named(_ slug: String) -> Brand {
        let key = canonical(slug)
        if let found = table[key] { return found }
        return Brand(slug: key, name: pretty(key), hex: derived(key), icon: nil)
    }

    public static func maker(ofModel modelID: String) -> Brand {
        named(String(modelID.prefix(while: { $0 != "/" })))
    }

    public static func provider(tag: String) -> Brand {
        named(String(tag.prefix(while: { $0 != "/" })))
    }

    public static func canonical(_ slug: String) -> String {
        let lower = slug.lowercased()
        return aliases[lower] ?? lower
    }

    private static func pretty(_ slug: String) -> String {
        slug.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static func derived(_ slug: String) -> UInt32 {
        var hash: UInt64 = 5381
        for byte in slug.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        let hue = Double(hash % 360) / 360
        let (r, g, b) = rgb(hue: hue, saturation: 0.55, brightness: 0.86)
        return UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
    }

    private static func rgb(hue: Double, saturation: Double, brightness: Double) -> (Int, Int, Int) {
        let sector = hue * 6
        let index = Int(sector) % 6
        let fraction = sector - Double(Int(sector))
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * fraction)
        let t = brightness * (1 - saturation * (1 - fraction))
        let channels: (Double, Double, Double)
        switch index {
        case 0: channels = (brightness, t, p)
        case 1: channels = (q, brightness, p)
        case 2: channels = (p, brightness, t)
        case 3: channels = (p, q, brightness)
        case 4: channels = (t, p, brightness)
        default: channels = (brightness, p, q)
        }
        return (Int(channels.0 * 255), Int(channels.1 * 255), Int(channels.2 * 255))
    }

    private static let table: [String: Brand] = [
    "openai": Brand(slug: "openai", name: "OpenAI", hex: 0x10A37F, icon: "openai"),
    "anthropic": Brand(slug: "anthropic", name: "Anthropic", hex: 0xD97757, icon: "claude"),
    "google": Brand(slug: "google", name: "Google", hex: 0x4285F4, icon: "google"),
    "meta": Brand(slug: "meta", name: "Meta", hex: 0x0081FB, icon: "meta"),
    "qwen": Brand(slug: "qwen", name: "Qwen", hex: 0x615CED, icon: "qwen"),
    "deepseek": Brand(slug: "deepseek", name: "DeepSeek", hex: 0x4D6BFE, icon: "deepseek"),
    "mistralai": Brand(slug: "mistralai", name: "Mistral", hex: 0xFA520F, icon: "mistral"),
    "x-ai": Brand(slug: "x-ai", name: "xAI", hex: 0xE6E6E6, icon: "grok"),
    "z-ai": Brand(slug: "z-ai", name: "Z.AI", hex: 0x3859FF, icon: "zhipu"),
    "moonshotai": Brand(slug: "moonshotai", name: "Moonshot AI", hex: 0x8E7BFF, icon: "kimi"),
    "nvidia": Brand(slug: "nvidia", name: "NVIDIA", hex: 0x76B900, icon: "nvidia"),
    "cohere": Brand(slug: "cohere", name: "Cohere", hex: 0xFF7759, icon: "cohere"),
    "microsoft": Brand(slug: "microsoft", name: "Microsoft", hex: 0x00A4EF, icon: "microsoft"),
    "amazon": Brand(slug: "amazon", name: "Amazon", hex: 0xFF9900, icon: "aws"),
    "perplexity": Brand(slug: "perplexity", name: "Perplexity", hex: 0x22B8CF, icon: "perplexity"),
    "minimax": Brand(slug: "minimax", name: "MiniMax", hex: 0xFF4D6D, icon: "minimax"),
    "tencent": Brand(slug: "tencent", name: "Tencent", hex: 0x3B82F6, icon: "tencent"),
    "bytedance": Brand(slug: "bytedance", name: "ByteDance", hex: 0x4E6EF2, icon: "bytedance"),
    "baidu": Brand(slug: "baidu", name: "Baidu", hex: 0x2932E1, icon: "baidu"),
    "xiaomi": Brand(slug: "xiaomi", name: "Xiaomi", hex: 0xFF6900, icon: nil),
    "upstage": Brand(slug: "upstage", name: "Upstage", hex: 0x908CFF, icon: "upstage"),
    "stepfun": Brand(slug: "stepfun", name: "StepFun", hex: 0x3D7BFF, icon: "stepfun"),
    "sakana": Brand(slug: "sakana", name: "Sakana AI", hex: 0xE0514B, icon: "sakana"),
    "poolside": Brand(slug: "poolside", name: "Poolside", hex: 0xC8FA3C, icon: "poolside"),
    "rekaai": Brand(slug: "rekaai", name: "Reka", hex: 0xFF5C00, icon: "reka"),
    "relace": Brand(slug: "relace", name: "Relace", hex: 0x7C5CFF, icon: "relace"),
    "morph": Brand(slug: "morph", name: "Morph", hex: 0x00D1B2, icon: "morph"),
    "perceptron": Brand(slug: "perceptron", name: "Perceptron", hex: 0xFF5A5F, icon: "perceptron"),
    "inception": Brand(slug: "inception", name: "Inception", hex: 0x8B7BF0, icon: "inception"),
    "liquid": Brand(slug: "liquid", name: "Liquid AI", hex: 0x2C6BED, icon: "liquid"),
    "writer": Brand(slug: "writer", name: "Writer", hex: 0x8B5CF6, icon: nil),
    "nousresearch": Brand(slug: "nousresearch", name: "Nous Research", hex: 0xD7D7D7, icon: nil),
    "ibm-granite": Brand(slug: "ibm-granite", name: "IBM Granite", hex: 0x4589FF, icon: "ibm"),
    "openrouter": Brand(slug: "openrouter", name: "OpenRouter", hex: 0x8183F4, icon: "openrouter"),
    "arcee-ai": Brand(slug: "arcee-ai", name: "Arcee AI", hex: 0x6366F1, icon: nil),
    "thinkingmachines": Brand(slug: "thinkingmachines", name: "Thinking Machines", hex: 0xFF6A3D, icon: nil),
    "meituan": Brand(slug: "meituan", name: "Meituan", hex: 0xFFD100, icon: nil),
    "kwaipilot": Brand(slug: "kwaipilot", name: "Kwaipilot", hex: 0xFF5000, icon: nil),
    "inclusionai": Brand(slug: "inclusionai", name: "InclusionAI", hex: 0x4B6BFB, icon: nil),
    "inference-net": Brand(slug: "inference-net", name: "Inference.net", hex: 0x5AC8FA, icon: nil),
    "nex-agi": Brand(slug: "nex-agi", name: "Nex AGI", hex: 0x9B8CFF, icon: nil),
    "aion-labs": Brand(slug: "aion-labs", name: "AionLabs", hex: 0x6E8BFF, icon: "aionlabs"),
    "stealth": Brand(slug: "stealth", name: "Stealth", hex: 0x9CA3AF, icon: nil),
    "groq": Brand(slug: "groq", name: "Groq", hex: 0xF55036, icon: "groq"),
    "cerebras": Brand(slug: "cerebras", name: "Cerebras", hex: 0xF05A28, icon: "cerebras"),
    "together": Brand(slug: "together", name: "Together", hex: 0x1C66FF, icon: "together"),
    "fireworks": Brand(slug: "fireworks", name: "Fireworks", hex: 0x6B2FF5, icon: "fireworks"),
    "deepinfra": Brand(slug: "deepinfra", name: "DeepInfra", hex: 0x5A7BFF, icon: "deepinfra"),
    "novita": Brand(slug: "novita", name: "Novita", hex: 0x22C55E, icon: "novita"),
    "nebius": Brand(slug: "nebius", name: "Nebius", hex: 0xE5E5E5, icon: "nebius"),
    "sambanova": Brand(slug: "sambanova", name: "SambaNova", hex: 0xEE3A23, icon: "sambanova"),
    "chutes": Brand(slug: "chutes", name: "Chutes", hex: 0xF0A202, icon: "chutes"),
    "baseten": Brand(slug: "baseten", name: "BaseTen", hex: 0xB57BFF, icon: "baseten"),
    "parasail": Brand(slug: "parasail", name: "Parasail", hex: 0x60A5FA, icon: "parasail"),
    "crusoe": Brand(slug: "crusoe", name: "Crusoe", hex: 0xFF5B04, icon: "crusoe"),
    "cloudflare": Brand(slug: "cloudflare", name: "Cloudflare", hex: 0xF6821F, icon: "cloudflare"),
    "phala": Brand(slug: "phala", name: "Phala", hex: 0xCDFA50, icon: "phala"),
    "friendli": Brand(slug: "friendli", name: "Friendli", hex: 0xD8D8D8, icon: "friendli"),
    "digitalocean": Brand(slug: "digitalocean", name: "DigitalOcean", hex: 0x0080FF, icon: "digitalocean"),
    "azure": Brand(slug: "azure", name: "Azure", hex: 0x0078D4, icon: "azure"),
    "alibaba": Brand(slug: "alibaba", name: "Alibaba", hex: 0xFF6A00, icon: "alibaba"),
    "siliconflow": Brand(slug: "siliconflow", name: "SiliconFlow", hex: 0x7C5CFF, icon: "siliconcloud"),
    "venice": Brand(slug: "venice", name: "Venice", hex: 0xE53935, icon: "venice"),
    "nextbit": Brand(slug: "nextbit", name: "NextBit", hex: 0x38BDF8, icon: "nextbit"),
    "akashml": Brand(slug: "akashml", name: "AkashML", hex: 0xFF414C, icon: "akashchat"),
    "atlas-cloud": Brand(slug: "atlas-cloud", name: "AtlasCloud", hex: 0x4ADE80, icon: "atlascloud"),
    "gmicloud": Brand(slug: "gmicloud", name: "GMICloud", hex: 0xE0E0E0, icon: "gmicloud"),
    "decart": Brand(slug: "decart", name: "Decart", hex: 0xFF4FA3, icon: "decart"),
    "modal": Brand(slug: "modal", name: "Modal", hex: 0x7FEE64, icon: nil),
    "coreweave": Brand(slug: "coreweave", name: "CoreWeave", hex: 0xFF5A1F, icon: nil),
    "mancer": Brand(slug: "mancer", name: "Mancer", hex: 0xB388FF, icon: nil),
    "io-net": Brand(slug: "io-net", name: "Io Net", hex: 0x4F46E5, icon: nil),
    "ionstream": Brand(slug: "ionstream", name: "Ionstream", hex: 0x38BDF8, icon: nil),
    "near-ai": Brand(slug: "near-ai", name: "Near AI", hex: 0x00EC97, icon: nil),
    "primeintellect": Brand(slug: "primeintellect", name: "PrimeIntellect", hex: 0x7C3AED, icon: nil),
    "tenstorrent": Brand(slug: "tenstorrent", name: "Tenstorrent", hex: 0x7C68FA, icon: nil),
    "infermatic": Brand(slug: "infermatic", name: "Infermatic", hex: 0x8B5CF6, icon: "infermatic"),
    "featherless": Brand(slug: "featherless", name: "Featherless", hex: 0xC084FC, icon: "featherless"),
    "targon": Brand(slug: "targon", name: "Targon", hex: 0x34D399, icon: "targon"),
    "hyperbolic": Brand(slug: "hyperbolic", name: "Hyperbolic", hex: 0x2BD67B, icon: "hyperbolic"),
    "ai21": Brand(slug: "ai21", name: "AI21", hex: 0xE34C5C, icon: "ai21"),
    "inflection": Brand(slug: "inflection", name: "Inflection", hex: 0xD4D4D4, icon: "inflection"),
    "yi": Brand(slug: "yi", name: "Yi", hex: 0x003425, icon: "yi"),
    "internlm": Brand(slug: "internlm", name: "InternLM", hex: 0x3F7EFF, icon: "internlm"),
    ]

    private static let aliases: [String: String] = [
    "aionlabs": "aion-labs",
    "akash": "akashml",
    "alibaba-cloud": "alibaba",
    "amazon-bedrock": "amazon",
    "atlascloud": "atlas-cloud",
    "aws": "amazon",
    "azure-openai": "azure",
    "bedrock": "amazon",
    "bytedance-seed": "bytedance",
    "chatglm": "z-ai",
    "claude": "anthropic",
    "claude-on-aws": "anthropic",
    "doubao": "bytedance",
    "gemini": "google",
    "gemma": "google",
    "glm": "z-ai",
    "google-ai-studio": "google",
    "google-vertex": "google",
    "granite": "ibm-granite",
    "grok": "x-ai",
    "ibm": "ibm-granite",
    "inference-net-io": "inference-net",
    "inferencenet": "inference-net",
    "kimi": "moonshotai",
    "llama": "meta",
    "meta-llama": "meta",
    "metaai": "meta",
    "mistral": "mistralai",
    "moonshot": "moonshotai",
    "nvidia-nim": "nvidia",
    "openai-platform": "openai",
    "qwen3": "qwen",
    "reka": "rekaai",
    "sambanova-turbo": "sambanova",
    "seed": "bytedance",
    "xai": "x-ai",
    "zhipu": "z-ai",
    "~anthropic": "anthropic",
    "~deepseek": "deepseek",
    "~google": "google",
    "~meta-llama": "meta",
    "~moonshotai": "moonshotai",
    "~openai": "openai",
    "~qwen": "qwen",
    "~x-ai": "x-ai",
    "~z-ai": "z-ai",
    ]
}
