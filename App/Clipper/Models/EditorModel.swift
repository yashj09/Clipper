import AppKit
import ClipperAnalysis
import AVFoundation
import ClipperCore
import ClipperEngine
import Foundation
import Observation

/// One open project: the timeline being edited, selection, playhead, undo history and the preview player.
/// Every change goes through `perform(_:)`, so it is validated, undoable and re-rendered the same way.
/// Undo/redo is `EditHistory` alone; the Edit menu (ClipperApp) drives it directly.
@MainActor @Observable
final class EditorModel {
    private(set) var project: Project
    var timelineIndex = 0
    private(set) var history = EditHistory()
    var selection: Set<ItemID> = []
    var playhead: RationalTime = .zero
    var lastError: String?
    /// In and Out marks (I / O). Transient: they aren't saved with the project.
    var inPoint: RationalTime?
    var outPoint: RationalTime?
    /// Zoom changes asked of the timeline view by toolbar buttons and shortcuts.
    var zoomRequest: ZoomRequest? = .fit(UUID())
    /// What's selected in the editor's media browser — the source for Q / W / E / D edits.
    var browserSelection: BrowserItem?

    /// Assets the timeline can reference (library media + music), by ID.
    var assets: [AssetID: MediaAsset]
    let player = PlayerController()

    @ObservationIgnored var onChange: ((Project) -> Void)?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// The latest edited project not yet handed to `onChange` (saves are debounced).
    @ObservationIgnored private var pendingSave: Project?

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

    private func changed() {
        rebuildPreview()
        saveTask?.cancel()
        pendingSave = project
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.flushSave()
        }
    }

    /// Saves a pending (debounced) change right away. Call before the editor is replaced or closed and when the app
    /// quits; otherwise the last second of edits would be lost with the editor.
    func flushSave() {
        saveTask?.cancel()
        saveTask = nil
        guard let snapshot = pendingSave else { return }
        pendingSave = nil
        onChange?(snapshot)
    }

    /// Drops a pending save (the project is being deleted).
    func discardPendingSave() {
        saveTask?.cancel()
        saveTask = nil
        pendingSave = nil
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

    /// Locks the selection, or unlocks it when every selected item is already locked. One undo step.
    func toggleLock() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        let lock = !items.allSatisfy(\.locked)
        perform(Batch(items.map { item in ModifyItem(item.id, name: "") { $0.locked = lock } }, name: lock ? "Lock" : "Unlock"))
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

    /// J / L: start playing in that direction, or double the speed if already going that way (up to 8×). Reverse play
    /// needs the composition to support it; otherwise J jumps back a second.
    func shuttle(forward: Bool) {
        let rate = player.player.rate
        if forward {
            player.setRate(rate >= 1 ? min(rate * 2, 8) : 1)
        } else if player.player.currentItem?.canPlayReverse == true {
            player.setRate(rate <= -1 ? max(rate * 2, -8) : -1)
        } else {
            player.pause()
            step(frames: -Int(timeline.canvas.frameRate.fps.rounded()))
        }
    }

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

    isolated deinit {
        // AVPlayer keeps a periodic observer (and its block) until whoever added it removes it.
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

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

    func setRate(_ rate: Float) {
        if rate > 0, let item = player.currentItem, item.currentTime() >= item.duration - CMTime(value: 1, timescale: 30) {
            player.seek(to: .zero)
        }
        player.rate = rate
        isPlaying = rate != 0
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
