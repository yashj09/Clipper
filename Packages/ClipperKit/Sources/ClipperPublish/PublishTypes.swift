import ClipperCore
import Foundation

/// Where a video can be published.
public enum Platform: String, Codable, Sendable, CaseIterable {
    case youtube, tiktok, instagram
    public var displayName: String {
        switch self { case .youtube: "YouTube"; case .tiktok: "TikTok"; case .instagram: "Instagram" }
    }
}

public enum Visibility: String, Codable, Sendable { case `private`, unlisted, `public` }

/// What to publish: the exported file plus platform-neutral metadata.
public struct PublishRequest: Codable, Sendable, Equatable {
    public var file: URL
    public var title: String
    public var description: String
    public var tags: [String]
    public var visibility: Visibility
    /// Caption sidecars to attach where the platform supports it (YouTube).
    public var captions: [URL]
    /// Credits that must appear in the description (CC-BY music).
    public var attributions: [String]
    public var isShort: Bool

    public init(file: URL, title: String, description: String = "", tags: [String] = [], visibility: Visibility = .private,
                captions: [URL] = [], attributions: [String] = [], isShort: Bool = true) {
        self.file = file; self.title = title; self.description = description; self.tags = tags; self.visibility = visibility
        self.captions = captions; self.attributions = attributions; self.isShort = isShort
    }

    /// Description with required credits appended (never dropped).
    public var fullDescription: String {
        let credits = attributions.isEmpty ? "" : "\n\nMusic:\n" + attributions.joined(separator: "\n")
        return description + credits
    }
}

public struct PublishResult: Codable, Sendable, Equatable {
    public var platform: Platform
    /// Platform's id for the upload (video id, publish id, media id).
    public var remoteID: String
    public var url: URL?
    /// Human-readable state, e.g. "uploaded as private (unverified API project)", "sent to TikTok inbox".
    public var status: String
    public init(platform: Platform, remoteID: String, url: URL?, status: String) {
        self.platform = platform; self.remoteID = remoteID; self.url = url; self.status = status
    }
}

public struct UploadProgress: Sendable {
    public var fraction: Double
    public var message: String
    public init(fraction: Double, message: String) { self.fraction = fraction; self.message = message }
}

public protocol Publisher: Sendable {
    var platform: Platform { get }
    /// Whether credentials are configured and a token is stored (no network call).
    func isConnected() async -> Bool
    func publish(_ request: PublishRequest, progress: (@Sendable (UploadProgress) -> Void)?) async throws -> PublishResult
}
