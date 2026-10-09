import Foundation

/// Per-token prices for models outside Anthropic's table (GPT, OpenRouter, ...), from LiteLLM's
/// public price list, fetched once a day and kept in `~/.claude/notch/model-prices.json` so a
/// scan works offline.
final class PriceBook: @unchecked Sendable {
    /// One model's per-token prices, keyed like LiteLLM's fields without their stem:
    /// `input`, `output`, `cacheRead`, `cacheWrite`, each optionally with LiteLLM's suffixes
    /// (`_above_272k_tokens` for long requests, `_priority` / `_flex` for service tiers).
    struct Rate: Codable {
        var prices: [String: Double]

        var input: Double { prices["input"] ?? 0 }
        var output: Double { prices["output"] ?? 0 }
        var cacheRead: Double { prices["cacheRead"] ?? input }
        var cacheWrite: Double { prices["cacheWrite"] ?? input }

        /// The price of `kind` for a request on `tier` (`priority`, `flex`, else standard),
        /// `isLong` when its input passes 272K tokens; the plainer price when a variant is unlisted.
        func price(_ kind: String, tier: String?, isLong: Bool) -> Double {
            let tierSuffix = tier == "priority" || tier == "flex" ? "_\(tier!)" : ""
            let longSuffix = isLong ? "_above_272k_tokens" : ""
            for key in [kind + longSuffix + tierSuffix, kind + tierSuffix, kind + longSuffix, kind] {
                if let value = prices[key] { return value }
            }
            return kind == "cacheRead" || kind == "cacheWrite" ? price("input", tier: tier, isLong: isLong) : 0
        }
    }

    private static let source = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    private let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/notch/model-prices.json")
    private let lock = NSLock()
    private var rates: [String: Rate] = [:]

    init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([String: Rate].self, from: data) {
            rates = saved
        }
        // With no list at all, wait for one: a Codex request priced at zero would stay at zero.
        refreshIfStale(waiting: rates.isEmpty)
    }

    /// The model's rate: its exact name, without a provider prefix, or with an `openai/` one.
    func rate(_ model: String) -> Rate? {
        lock.lock()
        defer { lock.unlock() }
        let name = model.lowercased()
        let bare = name.split(separator: "/").last.map(String.init) ?? name
        return rates[name] ?? rates[bare] ?? rates["openai/\(bare)"]
    }

    private func refreshIfStale(waiting: Bool) {
        let age = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date).map { -$0.timeIntervalSinceNow } ?? .infinity
        guard age > 86_400 else { return }
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: Self.source) { [weak self] data, _, _ in
            defer { done.signal() }
            guard let self, let data, let table = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]] else { return }
            let stems = [("input_cost_per_token", "input"), ("output_cost_per_token", "output"),
                         ("cache_read_input_token_cost", "cacheRead"), ("cache_creation_input_token_cost", "cacheWrite")]
            var parsed: [String: Rate] = [:]
            for (name, entry) in table {
                var prices: [String: Double] = [:]
                for (field, value) in entry {
                    guard let value = value as? Double, let stem = stems.first(where: { field.hasPrefix($0.0) }) else { continue }
                    let suffix = String(field.dropFirst(stem.0.count))
                    guard suffix.isEmpty || ["_above_272k_tokens", "_priority", "_flex", "_above_272k_tokens_priority", "_above_272k_tokens_flex"].contains(suffix) else { continue }
                    prices[stem.1 + suffix] = value
                }
                if prices["input"] != nil, prices["output"] != nil { parsed[name.lowercased()] = Rate(prices: prices) }
            }
            guard !parsed.isEmpty else { return }
            lock.lock()
            rates = parsed
            lock.unlock()
            if let encoded = try? JSONEncoder().encode(parsed) { try? encoded.write(to: file, options: .atomic) }
        }.resume()
        if waiting { _ = done.wait(timeout: .now() + 20) }
    }
}
