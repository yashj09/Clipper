import Foundation

/// One entry of the model's `{"rankings":[...]}` reply. `id` is the 1-based candidate position in the batch.
struct LLMRanking: Sendable, Equatable {
    var id: Int
    var score: Double
    var title: String?
    var reason: String?
}

/// Lenient parsing of what local models actually send back: markdown fences, `<think>` blocks (Qwen3, DeepSeek-R1),
/// prose around the JSON, ids as strings, scores as strings.
enum LLMResponseParser {
    /// Text candidates from a chat-completion response, best first: `message.content`, then reasoning fields
    /// (some servers put everything there when the model only "thinks"). Falls back to the raw body.
    static func messageContents(_ data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (root["choices"] as? [[String: Any]])?.first else {
            return [String(decoding: data, as: UTF8.self)]
        }
        let message = (choice["message"] as? [String: Any]) ?? [:]
        var out: [String] = []
        for key in ["content", "reasoning_content", "reasoning"] {
            if let s = message[key] as? String, !s.isEmpty {
                out.append(s)
            } else if let parts = message[key] as? [[String: Any]] {
                let s = parts.compactMap { $0["text"] as? String }.joined()
                if !s.isEmpty { out.append(s) }
            }
        }
        if out.isEmpty, let text = choice["text"] as? String { out.append(text) }  // legacy completions shape
        return out
    }

    /// Rankings from a model reply, or nil if no usable JSON was found.
    static func rankings(from content: String) -> [LLMRanking]? {
        let text = stripThinking(content)
        let bytes = Array(text.utf8)
        var tries = 0
        var i = 0
        while i < bytes.count, tries < 64 {
            let b = bytes[i]
            guard b == UInt8(ascii: "{") || b == UInt8(ascii: "[") else { i += 1; continue }
            tries += 1
            if let end = balancedEnd(bytes, from: i),
               let value = try? JSONSerialization.jsonObject(with: Data(bytes[i...end]), options: [.fragmentsAllowed]),
               let rankings = extract(value) {
                return rankings
            }
            i += 1
        }
        return nil
    }

    /// Removes `<think>…</think>` blocks, a dangling `…</think>` prefix (templates that pre-open the tag) and an
    /// unterminated trailing `<think>…`.
    static func stripThinking(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression)
        if let close = t.range(of: "</think>", options: .backwards) { t = String(t[close.upperBound...]) }
        if let open = t.range(of: "<think>") { t = String(t[..<open.lowerBound]) }
        return t
    }

    /// Index of the bracket closing the one at `start`, honoring JSON strings and escapes.
    static func balancedEnd(_ b: [UInt8], from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < b.count {
            let c = b[i]
            if inString {
                if escaped { escaped = false } else if c == UInt8(ascii: "\\") { escaped = true } else if c == UInt8(ascii: "\"") { inString = false }
            } else {
                switch c {
                case UInt8(ascii: "\""): inString = true
                case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return i }
                    if depth < 0 { return nil }
                default: break
                }
            }
            i += 1
        }
        return nil
    }

    static func extract(_ value: Any) -> [LLMRanking]? {
        let items: [Any]
        if let dict = value as? [String: Any] {
            if let list = dict["rankings"] as? [Any] {
                items = list
            } else if dict["id"] != nil, dict["score"] != nil {
                items = [dict]
            } else if let list = dict.values.compactMap({ $0 as? [Any] }).first(where: { $0.first is [String: Any] }) {
                items = list
            } else {
                return nil
            }
        } else if let list = value as? [Any], list.first is [String: Any] {
            items = list
        } else {
            return nil
        }
        let parsed = items.compactMap { ($0 as? [String: Any]).flatMap(ranking) }
        return parsed.isEmpty && !items.isEmpty ? nil : parsed
    }

    static func ranking(_ d: [String: Any]) -> LLMRanking? {
        guard let id = int(d["id"]), let raw = double(d["score"]), raw.isFinite else { return nil }
        return LLMRanking(id: id, score: min(max(raw, 0), 10), title: d["title"] as? String,
                          reason: (d["reason"] as? String) ?? (d["why"] as? String))
    }

    static func int(_ v: Any?) -> Int? {
        if let n = v as? NSNumber {
            let d = n.doubleValue
            return d.isFinite && d == d.rounded() ? Int(d) : nil
        }
        guard let s = v as? String else { return nil }
        // "3", "#3", "c3", "candidate 3"
        guard let digits = s.split(whereSeparator: { !$0.isNumber }).first else { return nil }
        return Int(digits)
    }

    static func double(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        guard let s = v as? String else { return nil }
        // "8", "8.5", "8/10"
        let head = s.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber || $0 == "." || $0 == "-" }
        return Double(head)
    }
}
