import Foundation

/// Storage for per-asset analysis results, keyed by content (not path) so results survive renames and are
/// shared across projects. Implemented by the library bundle; a plain directory implementation serves the CLI.
public protocol AnalysisCache: Sendable {
    /// Returns cached bytes for `analyzer` at `version`, or nil (a different version counts as a miss).
    func load(key: AssetKey, analyzer: String, version: Int) async -> Data?
    func store(_ data: Data, key: AssetKey, analyzer: String, version: Int) async throws
}

/// Centralized, user-editable settings. One JSON document; every field has a default so old files keep loading.
public struct ClipperSettings: Codable, Sendable, Equatable {
    public struct Editing: Codable, Sendable, Equatable {
        public var rippleByDefault = true
        public var snapping = true
        /// Preview resolution relative to the canvas (1 = full).
        public var previewScale = 0.5
        public var useProxies = true
        public init() {}
    }

    public struct Automation: Codable, Sendable, Equatable {
        public var defaultTemplate = "talking-head"
        public var captions = true
        public var music = true
        public var transcriptionLocale = "en-US"
        /// "apple" (SpeechTranscriber) or "whisper" (whisper.cpp, if installed).
        public var transcriber = "apple"
        public var faceTracking = true
        /// Optional local LLM (OpenAI-compatible server on this Mac) for re-ranking highlights. Off by default.
        public var useLLM = false
        public var llmBaseURL = "http://localhost:11434/v1"
        public var llmModel = "qwen3:14b"
        public init() {}

        // Tolerant decoding so settings files from older versions keep loading.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Automation()
            defaultTemplate = (try? c.decode(String.self, forKey: .defaultTemplate)) ?? d.defaultTemplate
            captions = (try? c.decode(Bool.self, forKey: .captions)) ?? d.captions
            music = (try? c.decode(Bool.self, forKey: .music)) ?? d.music
            transcriptionLocale = (try? c.decode(String.self, forKey: .transcriptionLocale)) ?? d.transcriptionLocale
            transcriber = (try? c.decode(String.self, forKey: .transcriber)) ?? d.transcriber
            faceTracking = (try? c.decode(Bool.self, forKey: .faceTracking)) ?? d.faceTracking
            useLLM = (try? c.decode(Bool.self, forKey: .useLLM)) ?? d.useLLM
            llmBaseURL = (try? c.decode(String.self, forKey: .llmBaseURL)) ?? d.llmBaseURL
            llmModel = (try? c.decode(String.self, forKey: .llmModel)) ?? d.llmModel
        }
    }

    public struct Export: Codable, Sendable, Equatable {
        public var defaultPreset = "shorts-1080x1920"
        /// Folder for exports; nil = ~/Movies/Clipper.
        public var outputFolder: URL?
        public var fileNamePattern = "{project} - {timeline}"
        public var writeSidecars = true
        public init() {}
    }

    public struct Music: Codable, Sendable, Equatable {
        /// Folders scanned for the user's own tracks.
        public var folders: [URL] = []
        public var includeBundledLibrary = true
        public init() {}
    }

    public struct Integrations: Codable, Sendable, Equatable {
        public var watchFolders: [URL] = []
        public init() {}
    }

    public var editing = Editing()
    public var automation = Automation()
    public var export = Export()
    public var music = Music()
    public var integrations = Integrations()

    public init() {}

    // Tolerant decoding: missing sections/keys fall back to defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        editing = (try? c.decode(Editing.self, forKey: .editing)) ?? Editing()
        automation = (try? c.decode(Automation.self, forKey: .automation)) ?? Automation()
        export = (try? c.decode(Export.self, forKey: .export)) ?? Export()
        music = (try? c.decode(Music.self, forKey: .music)) ?? Music()
        integrations = (try? c.decode(Integrations.self, forKey: .integrations)) ?? Integrations()
    }
}
