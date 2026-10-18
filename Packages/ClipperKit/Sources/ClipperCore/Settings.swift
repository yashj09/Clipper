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
        /// Which media get a proxy made after import.
        public enum ProxyPolicy: String, Codable, Sendable, CaseIterable {
            /// Sources beyond 1080p, ProRes and recordings over 20 minutes (`ProxyGenerator.wantsProxy`).
            case automatic
            /// Every video larger than a proxy.
            case always
            case never
        }
        public var proxyPolicy = ProxyPolicy.automatic
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self), d = Editing()
            rippleByDefault = c.value(.rippleByDefault, d.rippleByDefault)
            snapping = c.value(.snapping, d.snapping)
            previewScale = c.value(.previewScale, d.previewScale)
            useProxies = c.value(.useProxies, d.useProxies)
            proxyPolicy = c.value(.proxyPolicy, d.proxyPolicy)
        }
    }

    public struct Automation: Codable, Sendable, Equatable {
        public var defaultTemplate = "talking-head"
        public var captions = true
        public var music = true
        public var transcriptionLocale = "en-US"
        /// "apple" (SpeechTranscriber) or "whisper" (whisper.cpp, if installed).
        public var transcriber = "apple"
        public var faceTracking = true
        /// Drafts whose template cuts away to B-roll use library videos tagged or named "b-roll" when given none.
        public var autoBRoll = true
        /// Optional local LLM (OpenAI-compatible server on this Mac) for re-ranking highlights. Off by default.
        public var useLLM = false
        public var llmBaseURL = "http://localhost:11434/v1"
        public var llmModel = "qwen3:14b"
        public init() {}

        // Tolerant decoding so settings files from older versions keep loading.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self), d = Automation()
            defaultTemplate = c.value(.defaultTemplate, d.defaultTemplate)
            captions = c.value(.captions, d.captions)
            music = c.value(.music, d.music)
            transcriptionLocale = c.value(.transcriptionLocale, d.transcriptionLocale)
            transcriber = c.value(.transcriber, d.transcriber)
            faceTracking = c.value(.faceTracking, d.faceTracking)
            autoBRoll = c.value(.autoBRoll, d.autoBRoll)
            useLLM = c.value(.useLLM, d.useLLM)
            llmBaseURL = c.value(.llmBaseURL, d.llmBaseURL)
            llmModel = c.value(.llmModel, d.llmModel)
        }
    }

    public struct Export: Codable, Sendable, Equatable {
        public var defaultPreset = "shorts-1080x1920"
        /// Folder for exports; nil = ~/Movies/Clipper.
        public var outputFolder: URL?
        public var fileNamePattern = "{project} - {timeline}"
        public var writeSidecars = true
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self), d = Export()
            defaultPreset = c.value(.defaultPreset, d.defaultPreset)
            outputFolder = try? c.decodeIfPresent(URL.self, forKey: .outputFolder)
            fileNamePattern = c.value(.fileNamePattern, d.fileNamePattern)
            writeSidecars = c.value(.writeSidecars, d.writeSidecars)
        }
    }

    public struct Music: Codable, Sendable, Equatable {
        /// Folders scanned for the user's own tracks.
        public var folders: [URL] = []
        public var includeBundledLibrary = true
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self), d = Music()
            folders = c.value(.folders, d.folders)
            includeBundledLibrary = c.value(.includeBundledLibrary, d.includeBundledLibrary)
        }
    }

    public struct Integrations: Codable, Sendable, Equatable {
        public var watchFolders: [URL] = []
        /// Template used to auto-draft new recordings found in watch folders; nil = import only.
        public var watchTemplate: String? = nil
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            watchFolders = c.value(.watchFolders, [])
            watchTemplate = (try? c.decodeIfPresent(String.self, forKey: .watchTemplate)) ?? nil
        }
    }

    public var editing = Editing()
    public var automation = Automation()
    public var export = Export()
    public var music = Music()
    public var integrations = Integrations()
    /// Keyboard shortcuts the user changed (everything else uses the factory shortcuts).
    public var keyBindings = KeyBindings()

    public init() {}

    // Tolerant decoding: missing sections/keys fall back to defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        editing = (try? c.decode(Editing.self, forKey: .editing)) ?? Editing()
        automation = (try? c.decode(Automation.self, forKey: .automation)) ?? Automation()
        export = (try? c.decode(Export.self, forKey: .export)) ?? Export()
        music = (try? c.decode(Music.self, forKey: .music)) ?? Music()
        integrations = (try? c.decode(Integrations.self, forKey: .integrations)) ?? Integrations()
        keyBindings = (try? c.decode(KeyBindings.self, forKey: .keyBindings)) ?? KeyBindings()
    }
}

extension KeyedDecodingContainer {
    /// Decodes `key`, falling back to `fallback` when it is missing or has the wrong type (forward-compatible settings).
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T { ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback }
}
