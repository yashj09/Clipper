import ClipperCore
import CryptoKit
import Foundation
import Testing
@testable import ClipperLibrary

/// A temp folder removed when the suite instance goes away (each @Test gets a fresh instance).
final class TempDir {
    let url: URL
    init() throws {
        url = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory).resolvingSymlinksInPath()
            .appending(path: "ClipperLibraryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    func file(_ name: String, contents: String, in sub: String? = nil) throws -> URL {
        var folder = url
        if let sub { folder = url.appending(path: sub, directoryHint: .isDirectory) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let f = folder.appending(path: name, directoryHint: .notDirectory)
        try Data(contents.utf8).write(to: f)
        return f
    }
}

/// Stand-in for `MediaProbe.makeAsset`: the key is the SHA-256 of the file's bytes.
let fakeProbe: @Sendable (URL) async throws -> MediaAsset = { url in
    let data = try Data(contentsOf: url)
    let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return MediaAsset(key: AssetKey(key), name: url.deletingPathExtension().lastPathComponent, url: url,
                      info: MediaInfo(kind: .video, duration: RationalTime(seconds: 10), naturalWidth: 1920, naturalHeight: 1080))
}

func canonicalPath(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }

@Suite struct LibraryLifecycleTests {
    let tmp: TempDir
    init() throws { tmp = try TempDir() }

    var libURL: URL { tmp.url.appending(path: "Test.clipperlib", directoryHint: .isDirectory) }

    @Test func createOpenAndOpenOrCreate() throws {
        _ = try Library.create(at: libURL)
        for sub in ["index.sqlite", "Projects", "Projects/.backups", "Media", "Proxies", "Cache", "Templates", "Exports"] {
            #expect(FileManager.default.fileExists(atPath: libURL.appending(path: sub).path), "\(sub)")
        }
        #expect(throws: LibraryError.alreadyExists(libURL)) { try Library.create(at: libURL) }
        _ = try Library.open(at: libURL)          // re-running migrations is a no-op
        _ = try Library.openOrCreate(at: libURL)

        let other = tmp.url.appending(path: "Other.clipperlib", directoryHint: .isDirectory)
        #expect(throws: LibraryError.notALibrary(other)) { try Library.open(at: other) }
        _ = try Library.openOrCreate(at: other)
        #expect(FileManager.default.fileExists(atPath: other.appending(path: "index.sqlite").path))
    }

    @Test func reopeningKeepsDataAndSchema() throws {
        do {
            let lib = try Library.create(at: libURL)
            try lib.saveProject(Project(name: "Kept"))
        }
        let lib = try Library.open(at: libURL)
        #expect(try lib.projects().map(\.name) == ["Kept"])
        let applied = try lib.dbPool.read { db in try Schema.migrator.appliedMigrations(db) }
        #expect(applied == ["v1"])
    }

    @Test func twoInstancesShareTheBundle() async throws {
        let app = try Library.create(at: libURL)
        let cli = try Library.open(at: libURL)
        let file = try tmp.file("clip.mov", contents: "frames")
        let imported = try await cli.importMedia([file], mode: .copy, probe: fakeProbe)
        try cli.saveProject(Project(name: "From CLI"))
        try cli.enqueueJob(JobRecord(kind: "export", title: "Export"))

        #expect(try app.assets() == imported)
        #expect(try app.projects().map(\.name) == ["From CLI"])
        #expect(try app.jobs().count == 1)
    }

    @Test func defaultURL() {
        #expect(Library.defaultURL.path.hasSuffix("Movies/Clipper/Clipper.clipperlib"))
    }
}

@Suite struct LibraryMediaTests {
    let tmp: TempDir
    let lib: Library
    init() throws {
        tmp = try TempDir()
        lib = try Library.create(at: tmp.url.appending(path: "Test.clipperlib", directoryHint: .isDirectory))
    }

    @Test func copyModeCopiesWithCollisionSafeNamesAndDedupes() async throws {
        let a = try tmp.file("clip.mov", contents: "A", in: "one")
        let b = try tmp.file("clip.mov", contents: "B", in: "two")
        let assets = try await lib.importMedia([a, b], mode: .copy, probe: fakeProbe)
        #expect(assets.count == 2)
        #expect(assets.map(\.url.lastPathComponent) == ["clip.mov", "clip 2.mov"])
        for asset in assets {
            #expect(asset.url.deletingLastPathComponent().standardizedFileURL == lib.mediaURL.standardizedFileURL)
            #expect(FileManager.default.fileExists(atPath: asset.url.path))
            #expect(try lib.isManaged(asset.id))
        }
        #expect(try String(contentsOf: assets[1].url, encoding: .utf8) == "B")

        // Same content again (even under another name) → the existing asset, no new copy.
        let again = try tmp.file("renamed.mov", contents: "A", in: "three")
        let second = try await lib.importMedia([again], mode: .copy, probe: fakeProbe)
        #expect(second == [assets[0]])
        #expect(try lib.assets().count == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: lib.mediaURL.path).sorted() == ["clip 2.mov", "clip.mov"])
        #expect(try lib.asset(key: assets[1].key) == assets[1])
        #expect(try lib.asset(assets[0].id) == assets[0])
    }

    @Test func concurrentImportsOfSameFileYieldOneAsset() async throws {
        let file = try tmp.file("race.mov", contents: "same")
        let lib = self.lib
        let results = try await withThrowingTaskGroup(of: [MediaAsset].self) { group in
            for _ in 0..<8 { group.addTask { try await lib.importMedia([file], mode: .copy, probe: fakeProbe) } }
            return try await group.reduce(into: []) { $0 += $1 }
        }
        #expect(Set(results.map(\.id)).count == 1)
        #expect(try lib.assets().count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: lib.mediaURL.path) == [results[0].url.lastPathComponent])
    }

    @Test func referenceModeKeepsOriginalPath() async throws {
        let file = try tmp.file("ref.mov", contents: "R", in: "outside")
        let asset = try #require(try await lib.importMedia([file], mode: .reference, probe: fakeProbe).first)
        #expect(canonicalPath(asset.url) == canonicalPath(file))
        #expect(try !lib.isManaged(asset.id))
        #expect(try FileManager.default.contentsOfDirectory(atPath: lib.mediaURL.path).isEmpty)

        // Removing a referenced asset never deletes the user's file.
        try lib.removeAsset(asset.id, deleteManagedFile: true)
        #expect(try lib.asset(asset.id) == nil)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func removeAssetDeletesManagedCopyOnlyWhenAsked() async throws {
        let keep = try tmp.file("keep.mov", contents: "K")
        let drop = try tmp.file("drop.mov", contents: "D")
        let assets = try await lib.importMedia([keep, drop], mode: .copy, probe: fakeProbe)
        try lib.removeAsset(assets[0].id, deleteManagedFile: false)
        try lib.removeAsset(assets[1].id, deleteManagedFile: true)
        #expect(FileManager.default.fileExists(atPath: assets[0].url.path))
        #expect(!FileManager.default.fileExists(atPath: assets[1].url.path))
        #expect(FileManager.default.fileExists(atPath: drop.path))
        #expect(try lib.assets().isEmpty)
    }

    @Test func updateAssetPersistsChanges() async throws {
        let file = try tmp.file("u.mov", contents: "U")
        var asset = try #require(try await lib.importMedia([file], mode: .copy, probe: fakeProbe).first)
        asset.tags = ["intro", "b-roll"]
        asset.name = "Renamed"
        asset.proxyURL = try lib.proxiesURL(for: asset.key).appending(path: "proxy.mov")
        asset.playableURL = tmp.url.appending(path: "elsewhere/playable.mov")
        try lib.updateAsset(asset)
        #expect(try lib.asset(asset.id) == asset)
        #expect(throws: LibraryError.self) { try lib.updateAsset(MediaAsset(key: AssetKey("x"), name: "x", url: file, info: asset.info)) }
    }

    @Test func relinkFollowsMovedFilesAndReportsMissing() async throws {
        let moved = try tmp.file("moved.mov", contents: "M", in: "a")
        let gone = try tmp.file("gone.mov", contents: "G", in: "a")
        let assets = try await lib.importMedia([moved, gone], mode: .reference, probe: fakeProbe)
        #expect(try lib.relink().isEmpty)

        let dest = tmp.url.appending(path: "b", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let newURL = dest.appending(path: "renamed.mov")
        try FileManager.default.moveItem(at: moved, to: newURL)
        try FileManager.default.removeItem(at: gone)

        let missing = try lib.relink()
        #expect(missing.map(\.id) == [assets[1].id])
        #expect(canonicalPath(try #require(try lib.asset(assets[0].id)).url) == canonicalPath(newURL))
    }

    @Test func relinkBySearchingFoldersMatchesKeys() async throws {
        let file = try tmp.file("lost.mov", contents: "L", in: "a")
        let asset = try #require(try await lib.importMedia([file], mode: .reference, probe: fakeProbe).first)
        try FileManager.default.removeItem(at: file)
        let copy = try tmp.file("found.mov", contents: "L", in: "search/deep")
        _ = try tmp.file("other.mov", contents: "nope", in: "search")

        let missing = try await lib.relink(searchFolders: [tmp.url.appending(path: "search")]) { try await fakeProbe($0).key }
        #expect(missing.isEmpty)
        #expect(canonicalPath(try #require(try lib.asset(asset.id)).url) == canonicalPath(copy))
    }

    @Test(.timeLimit(.minutes(1))) func observeAssetsEmitsAfterImport() async throws {
        var updates = lib.observeAssets().makeAsyncIterator()
        #expect(try await updates.next() == [])
        let file = try tmp.file("obs.mov", contents: "O")
        let imported = try await lib.importMedia([file], mode: .copy, probe: fakeProbe)
        #expect(try await updates.next() == imported)
    }
}

@Suite struct LibraryProjectTests {
    let tmp: TempDir
    let lib: Library
    init() throws {
        tmp = try TempDir()
        lib = try Library.create(at: tmp.url.appending(path: "Test.clipperlib", directoryHint: .isDirectory))
    }

    func sampleProject() -> Project {
        let asset = UUID()
        let item = Item(name: "A", range: TimeRange(seconds: 0, 4),
                        content: .media(MediaRef(asset: asset, source: TimeRange(seconds: 10, 14))))
        let tl = Timeline(name: "Short 1", canvas: .vertical1080, tracks: [Track(kind: .video, items: [item]), Track(kind: .title)])
        return Project(name: "VOD cuts", timelines: [tl, Timeline(name: "Short 2", canvas: .vertical1080, tracks: [])],
                       created: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func saveLoadRoundTrip() throws {
        let project = sampleProject()
        let saved = try lib.saveProject(project)
        #expect(saved.modified > project.modified)
        let loaded = try lib.loadProject(project.id)
        #expect(loaded == saved)
        #expect(loaded.timelines == project.timelines)
        #expect(try ClipperJSON.encode(loaded) == Data(contentsOf: lib.projectURL(project.id)))
        let unknown = UUID()
        #expect(throws: LibraryError.projectNotFound(unknown)) { try lib.loadProject(unknown) }
    }

    @Test func rollingBackupsKeepTen() throws {
        var project = sampleProject()
        for i in 0..<12 {
            project.name = "v\(i)"
            project = try lib.saveProject(project)
        }
        let backups = try lib.backups(of: project.id)
        #expect(backups.count == 10)
        // Newest first: the newest backup is the state before the last save.
        let newest = try ClipperJSON.decodeProject(Data(contentsOf: backups[0]))
        #expect(newest.name == "v10")
        let oldest = try ClipperJSON.decodeProject(Data(contentsOf: backups[9]))
        #expect(oldest.name == "v1")
        #expect(try lib.loadProject(project.id).name == "v11")
    }

    @Test func summariesAndDelete() throws {
        let a = try lib.saveProject(sampleProject())
        var b = Project(name: "Second", created: Date(timeIntervalSince1970: 1_600_000_000))
        b = try lib.saveProject(b)
        let list = try lib.projects()
        #expect(Set(list.map(\.id)) == [a.id, b.id])
        let summaryA = try #require(list.first { $0.id == a.id })
        #expect(summaryA == ProjectSummary(id: a.id, name: "VOD cuts", modified: a.modified, timelineCount: 2))

        try lib.saveProject(a)   // creates a backup
        try lib.deleteProject(a.id)
        #expect(try lib.projects().map(\.id) == [b.id])
        #expect(!FileManager.default.fileExists(atPath: lib.projectURL(a.id).path))
        #expect(try lib.backups(of: a.id).isEmpty)
    }

    @Test func rebuildIndexFromDocuments() throws {
        let a = try lib.saveProject(sampleProject())
        _ = try lib.dbPool.write { db in try ProjectRow.deleteAll(db) }
        #expect(try lib.projects().isEmpty)
        try lib.rebuildProjectIndex()
        #expect(try lib.projects().map(\.id) == [a.id])
    }

    @Test(.timeLimit(.minutes(1))) func observeProjectsEmitsAfterSave() async throws {
        var updates = lib.observeProjects().makeAsyncIterator()
        #expect(try await updates.next() == [])
        let p = try lib.saveProject(Project(name: "Watched"))
        #expect(try await updates.next()?.map(\.id) == [p.id])
    }
}

@Suite struct LibraryDocumentTests {
    let tmp: TempDir
    let lib: Library
    init() throws {
        tmp = try TempDir()
        lib = try Library.create(at: tmp.url.appending(path: "Test.clipperlib", directoryHint: .isDirectory))
    }

    @Test func templatesRoundTrip() throws {
        let slot = Slot(id: "main", name: "Main", role: .primary)
        let b = Template(id: "b-tpl", name: "Beta", contentType: .vlog, canvas: .vertical1080, slots: [slot])
        let a = Template(id: "a-tpl", name: "Alpha", contentType: .talkingHead, canvas: .landscape1080, slots: [slot])
        try lib.saveTemplate(b)
        try lib.saveTemplate(a)
        #expect(try lib.userTemplates() == [a, b])

        var a2 = a; a2.summary = "edited"
        try lib.saveTemplate(a2)
        #expect(try lib.userTemplates() == [a2, b])

        try Data("not json".utf8).write(to: lib.templatesURL.appending(path: "broken.json"))
        try lib.deleteTemplate(id: "b-tpl")
        #expect(try lib.userTemplates() == [a2])
        #expect(throws: LibraryError.invalidIdentifier("../escape")) {
            try lib.saveTemplate(Template(id: "../escape", name: "x", contentType: .custom, canvas: .square1080, slots: []))
        }
    }

    @Test func musicUpsertAndList() throws {
        let t1 = MusicTrack(id: "t1", title: "Zephyr", artist: "A", url: URL(filePath: "/tmp/z.m4a"), duration: 120,
                            license: .ccBy(attribution: "A — CC BY"), moods: ["calm"], bpm: 90,
                            beats: BeatGrid(bpm: 90, beats: [0, 0.666, 1.333]))
        var t2 = MusicTrack(id: "t2", title: "Anthem", artist: "B", url: URL(filePath: "/tmp/a.m4a"), duration: 60, license: .cc0)
        try lib.upsertMusic([t1, t2])
        #expect(try lib.music() == [t2, t1])

        t2.title = "Bravo"; t2.energy = 0.8
        try lib.upsertMusic([t2])
        #expect(try lib.music() == [t2, t1])
        try lib.deleteMusic(ids: ["t1"])
        #expect(try lib.music() == [t2])
    }

    @Test func settingsDefaultAndRoundTrip() throws {
        #expect(try lib.settings() == ClipperSettings())
        #expect(try lib.exportFolder() == lib.exportsURL)
        var s = ClipperSettings()
        s.editing.previewScale = 1
        s.automation.transcriber = "whisper"
        s.export.outputFolder = URL(filePath: "/tmp/exports", directoryHint: .isDirectory)
        s.music.folders = [URL(filePath: "/tmp/music", directoryHint: .isDirectory)]
        try lib.saveSettings(s)
        #expect(try lib.settings() == s)
        #expect(try lib.exportFolder() == s.export.outputFolder)
    }

    @Test func analysisCacheStoreLoadAndVersionMiss() async throws {
        let cache = lib.analysisCache
        let key = AssetKey("abc123")
        #expect(await cache.load(key: key, analyzer: "speech", version: 1) == nil)

        try await cache.store(Data("v1".utf8), key: key, analyzer: "speech", version: 1)
        try await cache.store(Data("beats".utf8), key: key, analyzer: "beats", version: 3)
        #expect(await cache.load(key: key, analyzer: "speech", version: 1) == Data("v1".utf8))
        #expect(await cache.load(key: key, analyzer: "speech", version: 2) == nil)
        #expect(await cache.load(key: AssetKey("other"), analyzer: "speech", version: 1) == nil)

        // A new version replaces the old one.
        try await cache.store(Data("v2!".utf8), key: key, analyzer: "speech", version: 2)
        #expect(await cache.load(key: key, analyzer: "speech", version: 1) == nil)
        #expect(await cache.load(key: key, analyzer: "speech", version: 2) == Data("v2!".utf8))
        let entries = try lib.analysisCacheEntries(for: key)
        #expect(entries.map { "\($0.analyzer)@\($0.version):\($0.bytes)" } == ["beats@3:5", "speech@2:3"])
        #expect(FileManager.default.fileExists(atPath: lib.cacheURL.appending(path: "abc123/speech@2.json").path))
        #expect(!FileManager.default.fileExists(atPath: lib.cacheURL.appending(path: "abc123/speech@1.json").path))

        try lib.removeAnalysisCache(for: key)
        #expect(await cache.load(key: key, analyzer: "beats", version: 3) == nil)
        #expect(try lib.analysisCacheEntries().isEmpty)
    }

    @Test func jobsEnqueueUpdateList() throws {
        let created = Date(timeIntervalSince1970: 1_700_000_000.123)
        var export = JobRecord(kind: "export", title: "Export Short 1", payload: Data("{}".utf8), created: created)
        let analysis = JobRecord(kind: "analysis", title: "Analyze clip", created: created + 1)
        try lib.enqueueJob(export)
        try lib.enqueueJob(analysis)
        #expect(throws: (any Error).self) { try lib.enqueueJob(export) }
        #expect(try lib.jobs() == [export, analysis])
        #expect(try lib.jobs(status: .queued).count == 2)

        export.status = .running
        export.progress = 0.5
        export = try lib.updateJob(export)
        #expect(export.updated > created)
        #expect(try lib.job(export.id) == export)
        #expect(try lib.jobs(status: .running) == [export])

        export.status = .failed
        export.error = "disk full"
        try lib.updateJob(export)
        #expect(try lib.jobs(status: .failed).map(\.error) == ["disk full"])
        var ghost = analysis
        ghost.id = UUID()
        #expect(throws: LibraryError.jobNotFound(ghost.id)) { try lib.updateJob(ghost) }

        try lib.pruneFinishedJobs()
        #expect(try lib.jobs().map(\.id) == [analysis.id])
    }
}
