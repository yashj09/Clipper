import ClipperCore
import ClipperEngine
import Foundation

/// Editing proxies, made one at a time in the background (the hardware encoder is shared; exports go first through
/// `EncodeScheduler`). Progress shows in the activity bar when nothing else is running.
@MainActor
extension AppModel {
    /// Queues proxies for the `assets` the proxy setting picks — or, with `force`, for every video larger than a proxy.
    func queueProxies(for assets: [MediaAsset], force: Bool = false) {
        let policy = settings.editing.proxyPolicy
        let picked = assets.filter { a in
            guard !hasProxy(a) else { return false }
            return force ? min(a.info.naturalWidth, a.info.naturalHeight) > ProxyGenerator.shortSide && a.info.kind == .video
                         : ProxyGenerator.wantsProxy(a.info, policy: policy)
        }
        for a in picked where !proxyQueue.contains(a.id) { proxyQueue.append(a.id) }
        if proxyTask == nil, !proxyQueue.isEmpty { proxyTask = Task { await runProxyQueue() } }
    }

    func hasProxy(_ asset: MediaAsset) -> Bool {
        asset.proxyURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    func removeProxy(_ asset: MediaAsset) {
        guard let library, var a = try? library.asset(asset.id) else { return }
        if let url = a.proxyURL { try? FileManager.default.removeItem(at: url) }
        a.proxyURL = nil
        do { try library.updateAsset(a) } catch { alert = "Couldn't update \(a.name): \(error)" }
        proxyChanged(a)
    }

    private func runProxyQueue() async {
        defer { proxyJob = nil; proxyTask = nil }
        while !proxyQueue.isEmpty, let library {
            let id = proxyQueue.removeFirst()
            guard var asset = try? library.asset(id), !hasProxy(asset), let out = try? library.proxyFileURL(for: asset) else { continue }
            let left = proxyQueue.count
            proxyJob = Activity(title: "Making proxy", detail: asset.name + (left > 0 ? " (+\(left) more)" : ""), progress: 0)
            do {
                try await ProxyGenerator.make(source: asset.renderURL, info: asset.info, to: out) { f in
                    Task { @MainActor in self.proxyJob?.progress = f }
                }
                asset.proxyURL = out
                try library.updateAsset(asset)
                proxyChanged(asset)
            } catch is CancellationError {
                return
            } catch {
                // A proxy is an optimisation: the original still plays, so note it rather than interrupt.
                proxyJob = Activity(title: "Proxy failed", detail: "\(asset.name): \(error)")
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// Picks up a new or removed proxy: the library lists, and the open editor's preview if it uses the asset.
    private func proxyChanged(_ asset: MediaAsset) {
        refresh()
        guard let editor, editor.assets[asset.id] != nil else { return }
        editor.assets[asset.id] = asset
        if settings.editing.useProxies { editor.rebuildPreview() }
    }
}
