import ArgumentParser
import ClipperCore
import ClipperEngine
import Foundation

struct Proxy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Make editing proxies (720p HEVC) for library media; the app's preview uses them when \"Use proxies\" is on.")
    @OptionGroup var lib: LibraryOptions
    @Argument(help: "Asset names or id prefixes (default: every asset the proxy setting picks).") var assets: [String] = []
    @Flag(help: "Make proxies even where the setting wouldn't, and remake existing ones.") var force = false
    @Flag(help: "Remove the proxies of the selected assets instead.") var remove = false

    func run() async throws {
        let s = try Services(lib)
        let policy = try s.library.settings().editing.proxyPolicy
        let all = try s.library.assets().filter { $0.info.kind == .video }
        let named = assets.isEmpty ? all : all.filter { a in
            assets.contains { a.name.localizedCaseInsensitiveContains($0) || a.id.uuidString.lowercased().hasPrefix($0.lowercased()) }
        }
        if remove {
            for var a in named where a.proxyURL != nil {
                if let u = a.proxyURL { try? FileManager.default.removeItem(at: u) }
                a.proxyURL = nil
                try s.library.updateAsset(a)
                Console.line("Removed the proxy of \(a.name)")
            }
            return
        }
        let todo = named.filter { a in
            let has = a.proxyURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            return force ? min(a.info.naturalWidth, a.info.naturalHeight) > ProxyGenerator.shortSide
                         : !has && ProxyGenerator.wantsProxy(a.info, policy: policy)
        }
        if todo.isEmpty { Console.line("Nothing to do (setting: \(policy.rawValue); use --force for others)."); return }
        for (i, var a) in todo.enumerated() {
            let out = try s.library.proxyFileURL(for: a)
            let start = ContinuousClock.now
            let label = "\(i + 1)/\(todo.count) \(a.name)"
            try await ProxyGenerator.make(source: a.renderURL, info: a.info, to: out) { f in Console.progress(f, label) }
            Console.clearStatus()
            a.proxyURL = out
            try s.library.updateAsset(a)
            let secs = (ContinuousClock.now - start).seconds
            Console.line(String(format: "✓ %@  %.0fs → %.1fs (%.1f× realtime)", a.name, a.info.duration.seconds, secs, a.info.duration.seconds / max(secs, 0.01)))
        }
    }
}
