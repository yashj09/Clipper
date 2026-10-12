import AppKit
import ClipperAnalysis
import AVFoundation
import ClipperCore
import ClipperEngine
import Foundation
import Observation

/// One open project: the timeline being edited, selection, playhead, undo history and the preview player.
/// Every change goes through `perform(_:)`, so it is validated, undoable and re-rendered the same way.
@MainActor @Observable
final class EditorModel {
    private(set) var project: Project
    var timelineIndex = 0
    private(set) var history = EditHistory()
    var selection: Set<ItemID> = []
    var playhead: RationalTime = .zero
    var lastError: String?

    /// Assets the timeline can reference (library media + music), by ID.
    var assets: [AssetID: MediaAsset]
    let player = PlayerController()

    @ObservationIgnored var onChange: ((Project) -> Void)?
    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    var settings: ClipperSettings

    init(project: Project, assets: [AssetID: MediaAsset], settings: ClipperSettings) {
        self.project = project
        self.assets = assets
        self.settings = settings
        // AVPlayer reports nanosecond times; keep the model on the timeline's frame grid.
        player.onTime = { [weak self] t in
            guard let self else { return }
            self.playhead = t.roundedToFrame(self.timeline.canvas.frameRate)
        }
        rebuildPreview(immediately: true)
    }

    var timeline: Timeline {
        get { project.timelines[timelineIndex] }
        set { project.timelines[timelineIndex] = newValue }
    }

    var context: EditContext {
        EditContext(assetDurations: assets.mapValues(\.info.duration))
    }

    var selectedItems: [Item] { selection.compactMap { timeline.item($0) } }

    // MARK: Editing

    func perform(_ command: any EditCommand) {
        var tl = timeline
        do {
            try history.perform(command, on: &tl, context: context)
        } catch {
            lastError = (error as? EditError)?.description ?? "\(error)"
            NSSound.beep()
            return
        }
        timeline = tl
        selection = selection.filter { tl.item($0) != nil }
        registerUndo(name: command.name)
        changed()
    }

    /// Finishes a continuous gesture (slider drag) so the next change becomes a new undo step.
    func endGesture() { history.breakCoalescing() }

    func undo() {
        guard history.canUndo else { return }
        var tl = timeline
        history.undo(&tl)
        timeline = tl
        changed()
    }

    func redo() {
        guard history.canRedo else { return }
        var tl = timeline
        history.redo(&tl)
        timeline = tl
        changed()
    }

    /// Bridges our snapshot history to the window's undo manager so Edit ▸ Undo shows the right names.
    private func registerUndo(name: String) {
        guard let um = undoManager else { return }
        um.registerUndo(withTarget: self) { target in
            target.undo()
            um.registerUndo(withTarget: target) { $0.redo() }
        }
        um.setActionName(name)
    }

    private func changed() {
        rebuildPreview()
        saveTask?.cancel()
        let snapshot = project
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.onChange?(snapshot)
        }
    }

    /// Switches between the shorts of a multi-timeline project (e.g. VOD highlights). Undo history is per timeline session.
    func selectTimeline(_ index: Int) {
        guard project.timelines.indices.contains(index), index != timelineIndex else { return }
        timelineIndex = index
        history = EditHistory()
        selection = []
        playhead = .zero
        rebuildPreview(immediately: true)
    }

    func replaceProject(_ p: Project) {
        project = p
        timelineIndex = min(timelineIndex, p.timelines.count - 1)
        history = EditHistory()
        rebuildPreview(immediately: true)
    }

    // MARK: Common edits

    func bladeAtPlayhead() {
        let tracks = selection.isEmpty ? nil : Set(selectedItems.compactMap { item in timeline.tracks.first { $0.items.contains { $0.id == item.id } }?.id })
        perform(Blade(at: playhead.roundedToFrame(timeline.canvas.frameRate), tracks: tracks))
    }

    func deleteSelection(ripple: Bool) {
        guard !selection.isEmpty else { return }
        perform(DeleteItems(selection, ripple: ripple))
        selection = []
    }

    func toggleLock() {
        for id in selection {
            let locked = timeline.item(id)?.locked ?? false
            perform(ModifyItem(id, name: locked ? "Unlock" : "Lock") { $0.locked = !locked })
        }
    }

    // MARK: Captions

    /// Adds (or refreshes) a hidden caption track translated on-device to `language`.
    func translateCaptions(to language: String) async {
        let source = timeline.tracks.first { $0.kind == .caption }?.language ?? "en"
        do {
            let tl = try await CaptionTranslator(source: Locale.Language(identifier: source))
                .addTranslatedTrack(to: timeline, target: Locale.Language(identifier: language))
            perform(ReplaceTimeline(tl, name: "Translate Captions (\(language))"))
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    /// Shows one caption language on the video (burned in) and hides the others.
    func showCaptions(language: String?) {
        for track in timeline.tracks where track.kind == .caption {
            let show = track.language == language || (language == nil && track.id == timeline.tracks.first { $0.kind == .caption }?.id)
            if track.hidden == show { perform(ModifyTrack(track.id, name: "Show Captions") { $0.hidden = !show }) }
        }
    }

    // MARK: Playback

    func rebuildPreview(immediately: Bool = false) {
        player.schedule(timeline: timeline, assets: assets, scale: settings.editing.previewScale,
                        proxies: settings.editing.useProxies, at: playhead, delay: immediately ? 0 : 0.15)
    }

    func togglePlay() { player.isPlaying ? player.pause() : player.play() }

    func seek(to t: RationalTime) {
        let clamped = RationalTime.min(RationalTime.max(t, .zero), timeline.duration)
        playhead = clamped.roundedToFrame(timeline.canvas.frameRate)
        player.seek(playhead)
    }

    func step(frames: Int) {
        seek(to: playhead + timeline.canvas.frameRate.frameDuration * Double(frames))
    }
}

/// Owns the AVPlayer. Rebuilding the composition is debounced while editing; the playhead is preserved.
@MainActor @Observable
final class PlayerController {
    let player = AVPlayer()
    private(set) var isPlaying = false
    private(set) var isBuilding = false
    var lastError: String?
    @ObservationIgnored var onTime: ((RationalTime) -> Void)?
    @ObservationIgnored private var buildTask: Task<Void, Never>?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var generation = 0

    init() {
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.onTime?(RationalTime(t))
                if self.player.rate == 0 { self.isPlaying = false }
            }
        }
    }

    func schedule(timeline: Timeline, assets: [AssetID: MediaAsset], scale: Double, proxies: Bool, at time: RationalTime, delay: Double) {
        buildTask?.cancel()
        generation += 1
        let gen = generation
        buildTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            self.isBuilding = true
            defer { if gen == self.generation { self.isBuilding = false } }
            do {
                let built = try await CompositionBuilder.build(timeline, assets: assets,
                                                               options: BuildOptions(renderScale: scale, useProxies: proxies))
                guard !Task.isCancelled, gen == self.generation else { return }
                let wasPlaying = self.isPlaying
                let current = self.player.currentItem == nil ? time : RationalTime(self.player.currentTime())
                self.player.replaceCurrentItem(with: built.makePlayerItem())
                await self.player.seek(to: current.cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
                if wasPlaying { self.player.play() }
                self.lastError = nil
            } catch {
                self.lastError = "\(error)"
            }
        }
    }

    func play() {
        if let item = player.currentItem, item.currentTime() >= item.duration - CMTime(value: 1, timescale: 30) {
            player.seek(to: .zero)
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
        onTime?(RationalTime(player.currentTime()))
    }

    func seek(_ t: RationalTime) {
        player.seek(to: t.cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }
}
