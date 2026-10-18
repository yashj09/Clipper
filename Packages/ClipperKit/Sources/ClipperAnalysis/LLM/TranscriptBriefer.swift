import ClipperCore
import CryptoKit
import Foundation

/// Asks a local LLM for a title, hook sentence, per-sentence importance, chapters, description and hashtags of a whole
/// transcript, and caches the answer per asset.
///
/// Transcripts of at most `chunkWords` words go in one request. Longer ones are split on sentence boundaries into
/// chunks of at most `chunkWords` words: each chunk returns importances, chapter starts and a summary, then one last
/// request over the summaries and each chunk's strongest sentences picks the title, hook, description and hashtags.
public struct TranscriptBriefer: Sendable {
    public static let version = 1
    static let maxHashtags = 8
    /// Strongest sentences per chunk offered to the final request as hook candidates.
    static let hooksPerChunk = 3

    public let endpoint: LLMEndpoint
    let cache: (any AnalysisCache)?
    let chunkWords: Int
    let session: URLSession

    public init(endpoint: LLMEndpoint, cache: (any AnalysisCache)?, chunkWords: Int = 1500,
                session: URLSession = .shared) {
        self.endpoint = endpoint; self.cache = cache; self.chunkWords = max(1, chunkWords); self.session = session
    }

    /// The model plus a digest of what was sent: the brief's sentence indices only fit the transcript it was made from.
    public func analyzerID(_ transcript: Transcript, context: String?) -> String {
        let sent = Self.sentences(transcript).map(\.text).joined(separator: "\n") + "\u{0}" + (context ?? "")
        let digest = SHA256.hash(data: Data(sent.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "brief.\(endpoint.model).\(digest)"
    }

    public func brief(_ transcript: Transcript, key: AssetKey, context: String? = nil,
                      progress: (@Sendable (Double) -> Void)? = nil) async throws -> TranscriptBrief {
        if let why = endpoint.nonLocalReason { throw LLMRankerError.notLocal(why) }
        let id = analyzerID(transcript, context: context)
        if let cache, let data = await cache.load(key: key, analyzer: id, version: Self.version),
           let hit = try? CacheCodec.decoder.decode(TranscriptBrief.self, from: data) {
            progress?(1)
            return hit
        }
        let sentences = Self.sentences(transcript)
        guard !sentences.isEmpty else { return TranscriptBrief(model: endpoint.model) }
        progress?(0)
        let llm = LocalLLM(endpoint: endpoint, session: session)
        let chunks = Self.chunks(sentences, budget: chunkWords)
        let context = context?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        var brief = TranscriptBrief(model: endpoint.model)
        var final: Reply
        if chunks.count == 1 {
            final = try await llm.complete(system: Self.wholePrompt,
                                           user: Self.sentencesMessage(sentences, context: context),
                                           schema: Self.schema("transcript_brief", Self.wholeFields)) {
                Self.reply($0, requiring: ["title", "importance"])
            }
            brief.sentenceImportance = Self.importances(final.importance, count: sentences.count)
            brief.chapters = Self.chapters(final.chapters, in: sentences.indices, sentences)
        } else {
            var summaries: [String] = []
            for (n, chunk) in chunks.enumerated() {
                let part = try await llm.complete(system: Self.chunkPrompt,
                                                  user: Self.sentencesMessage(Array(sentences[chunk]), context: context),
                                                  schema: Self.schema("transcript_part", Self.chunkFields)) {
                    Self.reply($0, requiring: ["summary", "importance"])
                }
                brief.sentenceImportance += Self.importances(part.importance, count: chunk.count)
                brief.chapters += Self.chapters(part.chapters, in: chunk, sentences)
                summaries.append(part.summary.map(LocalLLMRanker.oneLine) ?? "")
                progress?(Double(n + 1) / Double(chunks.count + 1))
            }
            let hooks = chunks.flatMap { chunk in
                chunk.sorted { brief.sentenceImportance[$0] > brief.sentenceImportance[$1] }.prefix(Self.hooksPerChunk)
            }.sorted()
            final = try await llm.complete(system: Self.finalPrompt,
                                           user: Self.finalMessage(summaries, hooks: hooks.map { sentences[$0] },
                                                                   context: context),
                                           schema: Self.schema("transcript_brief", Self.finalFields)) {
                Self.reply($0, requiring: ["title"])
            }
            brief.chapters = Self.uniqueByStart(brief.chapters)
        }
        brief.title = final.title.map(Self.cleanTitle)?.nilIfEmpty
        brief.hookSentence = final.hook.flatMap { sentences.indices.contains($0) ? $0 : nil }
        brief.description = final.description?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        brief.hashtags = Self.hashtags(final.hashtags)

        if let cache, let data = try? CacheCodec.encoder.encode(brief) {
            try? await cache.store(data, key: key, analyzer: id, version: Self.version)
        }
        progress?(1)
        return brief
    }

    // MARK: Sentences and chunks

    struct Sentence: Sendable, Equatable {
        var id: Int
        var start: Double
        /// Words without fillers.
        var text: String
        var wordCount: Int
    }

    static func sentences(_ transcript: Transcript) -> [Sentence] {
        Transcript.sentences(transcript.words).enumerated().map { i, range in
            let words = transcript.words[range].filter { !$0.isFiller }
            return Sentence(id: i, start: transcript.words[range.lowerBound].start,
                            text: words.map(\.text).joined(separator: " "), wordCount: words.count)
        }
    }

    /// Consecutive sentence ranges of at most `budget` words each. A sentence longer than the budget is a chunk alone.
    static func chunks(_ sentences: [Sentence], budget: Int) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start = 0, words = 0
        for (i, s) in sentences.enumerated() {
            if words + s.wordCount > budget, i > start {
                out.append(start..<i)
                start = i; words = 0
            }
            words += s.wordCount
        }
        if start < sentences.count { out.append(start..<sentences.count) }
        return out
    }

    // MARK: Parsing and cleanup

    struct Reply: Sendable {
        struct Chapter: Sendable { var sentence: Int; var title: String }
        var title: String?
        var hook: Int?
        var importance: [Double] = []
        var chapters: [Chapter] = []
        var description: String?
        var hashtags: [String] = []
        var summary: String?
    }

    /// The first JSON object in `text` that has at least one of `keys`.
    static func reply(_ text: String, requiring keys: Set<String>) -> Reply? {
        LLMResponseParser.firstJSON(in: text) { value -> Reply? in
            guard let d = value as? [String: Any], !keys.isDisjoint(with: d.keys) else { return nil }
            let chapters = (d["chapters"] as? [Any] ?? []).compactMap { item -> Reply.Chapter? in
                guard let c = item as? [String: Any], let s = LLMResponseParser.int(c["sentence"] ?? c["id"]),
                      let title = c["title"] as? String else { return nil }
                return Reply.Chapter(sentence: s, title: title)
            }
            return Reply(title: d["title"] as? String, hook: LLMResponseParser.int(d["hook"]),
                         importance: (d["importance"] as? [Any] ?? []).map { LLMResponseParser.double($0) ?? 0 },
                         chapters: chapters, description: d["description"] as? String,
                         hashtags: (d["hashtags"] as? [Any] ?? []).compactMap { $0 as? String },
                         summary: d["summary"] as? String)
        }
    }

    /// Clamped to 0…1, one per sentence. Models miscount long arrays: missing tail entries score 0 and extras are
    /// dropped, rather than discarding the whole answer.
    static func importances(_ raw: [Double], count: Int) -> [Double] {
        let clamped = raw.prefix(count).map { $0.isFinite ? min(max($0, 0), 1) : 0 }
        return clamped + Array(repeating: 0, count: count - clamped.count)
    }

    /// Chapters whose sentence lies in `range`, timed at that sentence's start, in time order.
    static func chapters(_ raw: [Reply.Chapter], in range: Range<Int>, _ sentences: [Sentence]) -> [TranscriptBrief.Chapter] {
        uniqueByStart(raw.compactMap { c in
            guard range.contains(c.sentence) else { return nil }
            let title = cleanTitle(c.title)
            return title.isEmpty ? nil : TranscriptBrief.Chapter(start: sentences[c.sentence].start, title: title)
        })
    }

    static func uniqueByStart(_ chapters: [TranscriptBrief.Chapter]) -> [TranscriptBrief.Chapter] {
        var seen: Set<Double> = []
        return chapters.sorted { $0.start < $1.start }.filter { seen.insert($0.start).inserted }
    }

    /// One line, at most 60 characters, without emoji or quotes.
    static func cleanTitle(_ s: String) -> String {
        let scalars = s.unicodeScalars.filter { u in
            !(u.properties.isEmoji && u.value > 0xFF) && u != "\u{FE0F}" && u != "\u{200D}" && !"\"“”«»".unicodeScalars.contains(u)
        }
        let collapsed = String(String.UnicodeScalarView(scalars)).split(separator: " ").joined(separator: " ")
        return LocalLLMRanker.cleanTitle(collapsed)
    }

    /// Lowercase words without "#" or spaces, deduplicated, at most 8.
    static func hashtags(_ raw: [String]) -> [String] {
        var seen: Set<String> = []
        return raw.map { String($0.lowercased().filter { $0.isLetter || $0.isNumber }) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(maxHashtags).map { $0 }
    }

    // MARK: Prompts

    static func sentencesMessage(_ sentences: [Sentence], context: String?) -> String {
        var user = context.map { "About the recording: \($0)\n\n" } ?? ""
        user += "Sentences (\(sentences.count)):\n"
        user += sentences.map { "[\($0.id)] \($0.text)" }.joined(separator: "\n")
        user += "\n\nReturn exactly \(sentences.count) importance values, one per sentence in order."
        return user
    }

    static func finalMessage(_ summaries: [String], hooks: [Sentence], context: String?) -> String {
        var user = context.map { "About the recording: \($0)\n\n" } ?? ""
        user += "Parts, in order:\n" + summaries.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n")
        user += "\n\nCandidate opening sentences:\n" + hooks.map { "[\($0.id)] \($0.text)" }.joined(separator: "\n")
        return user
    }

    private static let rules = """
    - title: a catchy title of at most 60 characters. No emoji, no quotes, no hashtags.
    - hook: the id of the one sentence that would best grab a viewer as the opening line.
    - description: one to three sentences for the video's description.
    - hashtags: up to 8 relevant hashtags, lowercase, without the # sign.
    """

    private static let perSentenceRules = """
    - importance: one number from 0 (skippable) to 1 (essential) for every sentence, in id order.
    - chapters: where a new topic starts, as the id of its first sentence and a short title. Use an empty list when \
    the topic does not change.
    """

    static let wholePrompt = """
    You help a video editor understand a recording before cutting it into short videos. You get its transcript as \
    numbered sentences, "[id] text".

    Reply with strict JSON only, no prose and no markdown:
    {"title":"...","hook":3,"importance":[0.2,0.9],"chapters":[{"sentence":0,"title":"..."}],"description":"...","hashtags":["..."]}

    \(rules)
    \(perSentenceRules)
    """

    static let chunkPrompt = """
    You help a video editor understand a long recording before cutting it into short videos. You get one part of its \
    transcript as numbered sentences, "[id] text".

    Reply with strict JSON only, no prose and no markdown:
    {"summary":"...","importance":[0.2,0.9],"chapters":[{"sentence":40,"title":"..."}]}

    - summary: two sentences on what this part covers.
    \(perSentenceRules)
    """

    static let finalPrompt = """
    You help a video editor understand a long recording before cutting it into short videos. You get a summary of \
    each part of it, in order, and candidate opening sentences as "[id] text".

    Reply with strict JSON only, no prose and no markdown:
    {"title":"...","hook":3,"description":"...","hashtags":["..."]}

    \(rules)
    The hook must be one of the candidate ids.
    """

    // MARK: Schemas

    static let chapterSchema: [String: any Sendable] = [
        "type": "array",
        "items": [
            "type": "object",
            "properties": ["sentence": ["type": "integer"], "title": ["type": "string"]],
            "required": ["sentence", "title"],
            "additionalProperties": false,
        ] as [String: any Sendable],
    ]
    static let importanceSchema: [String: any Sendable] = [
        "type": "array", "items": ["type": "number", "minimum": 0, "maximum": 1] as [String: any Sendable],
    ]
    static let wholeFields: [String: [String: any Sendable]] = [
        "title": ["type": "string"], "hook": ["type": "integer"], "importance": importanceSchema,
        "chapters": chapterSchema, "description": ["type": "string"],
        "hashtags": ["type": "array", "items": ["type": "string"]],
    ]
    static let chunkFields: [String: [String: any Sendable]] = [
        "summary": ["type": "string"], "importance": importanceSchema, "chapters": chapterSchema,
    ]
    static let finalFields: [String: [String: any Sendable]] = [
        "title": ["type": "string"], "hook": ["type": "integer"], "description": ["type": "string"],
        "hashtags": ["type": "array", "items": ["type": "string"]],
    ]

    /// A strict `json_schema` object requiring every field.
    static func schema(_ name: String, _ fields: [String: [String: any Sendable]]) -> [String: Any] {
        [
            "name": name,
            "strict": true,
            "schema": [
                "type": "object",
                "properties": fields,
                "required": fields.keys.sorted(),
                "additionalProperties": false,
            ] as [String: Any],
        ]
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
