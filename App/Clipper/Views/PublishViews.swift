import AppKit
import ClipperCore
import ClipperPublish
import SwiftUI

/// Publish or schedule the open timeline.
struct PublishSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var connected: Set<Platform> = []
    @State private var selected: Set<Platform> = []
    @State private var title = ""
    @State private var description = ""
    @State private var tags = ""
    @State private var visibility: ClipperPublish.Visibility = .private
    @State private var when: Date = Date().addingTimeInterval(3600)
    @State private var later = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Publish").font(.title2.bold())
            HStack {
                ForEach(Platform.allCases, id: \.self) { p in
                    Toggle(p.displayName, isOn: Binding(get: { selected.contains(p) }, set: { if $0 { selected.insert(p) } else { selected.remove(p) } }))
                        .disabled(!connected.contains(p))
                        .help(connected.contains(p) ? "" : "Connect \(p.displayName) in Settings ▸ Accounts first")
                }
            }
            if connected.isEmpty {
                Text("No accounts connected yet — open Settings ▸ Accounts. You use your own developer apps; keys stay in your Keychain.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Form {
                TextField("Title", text: $title)
                TextField("Description", text: $description, axis: .vertical).lineLimit(2...5)
                TextField("Tags (comma-separated)", text: $tags)
                Picker("Visibility", selection: $visibility) {
                    Text("Private").tag(ClipperPublish.Visibility.private); Text("Unlisted").tag(ClipperPublish.Visibility.unlisted); Text("Public").tag(ClipperPublish.Visibility.public)
                }
                if selected.contains(.instagram) { Text("Instagram Reels are always public.").font(.caption).foregroundStyle(.secondary) }
                if selected.contains(.tiktok) { Text("TikTok receives a draft in your inbox; you finish the post in the TikTok app.").font(.caption).foregroundStyle(.secondary) }
                Toggle("Schedule for later", isOn: $later)
                if later { DatePicker("When", selection: $when, in: Date()...) }
                if let credits = model.editor?.timeline.attributions, !credits.isEmpty {
                    LabeledContent("Credits (added automatically)") { Text(credits.joined(separator: "\n")).font(.caption) }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(later ? "Schedule" : "Publish Now") {
                    guard let editor = model.editor else { return }
                    let post = ScheduledPost(projectID: editor.project.id, timelineIndex: editor.timelineIndex,
                                             platforms: Platform.allCases.filter { selected.contains($0) }, title: title,
                                             description: description,
                                             tags: tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                                             visibility: visibility, scheduledAt: later ? when : Date(),
                                             presetID: editor.timeline.provenance.flatMap { p in model.templates.first { $0.id == p.template }?.exportPreset } ?? model.settings.export.defaultPreset)
                    model.schedule(post)
                    dismiss()
                    if !later { Task { await model.execute(post) } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 560)
        .task {
            title = model.editor?.timeline.name ?? ""
            for p in Platform.allCases where await model.isConnected(p) { connected.insert(p) }
            selected = connected
        }
    }
}

/// The publishing queue.
struct PublishingView: View {
    @Bindable var model: AppModel
    @State private var posts: [ScheduledPost] = []

    var body: some View {
        Table(posts) {
            TableColumn("When") { Text($0.scheduledAt.formatted(date: .abbreviated, time: .shortened)) }.width(150)
            TableColumn("Title", value: \.title)
            TableColumn("Platforms") { Text($0.platforms.map(\.displayName).joined(separator: ", ")) }.width(160)
            TableColumn("Status") { p in Text(p.status.rawValue).foregroundStyle(p.status == .failed ? .red : p.status == .posted ? .green : .primary) }.width(80)
            TableColumn("Result") { p in
                Text((p.results.map { "\($0.platform.displayName): \($0.url?.absoluteString ?? $0.remoteID)" }
                      + p.errors.map { "\($0.key): \($0.value)" }).joined(separator: "  ·  "))
                    .font(.caption).lineLimit(2).textSelection(.enabled)
            }
        }
        .contextMenu(forSelectionType: ScheduledPost.ID.self) { ids in
            Button("Publish Now") { for id in ids { if let p = posts.first(where: { $0.id == id }) { Task { await model.execute(p); reload() } } } }
            Button("Cancel", role: .destructive) { for id in ids { try? model.publishQueue?.update(id) { $0.status = .cancelled } }; reload() }
        }
        .overlay { if posts.isEmpty { ContentUnavailableView("Nothing scheduled", systemImage: "calendar", description: Text("Open a project and choose Publish… to post now or schedule.")) } }
        .toolbar {
            ToolbarItem { Button { Task { await model.runDuePosts(); reload() } } label: { Label("Run Due Posts", systemImage: "paperplane") } }
            ToolbarItem {
                Button {
                    model.writeCalendar()
                    if let url = model.publishQueue?.url.deletingLastPathComponent().appendingPathComponent("clipper.ics") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } label: { Label("Calendar Feed", systemImage: "calendar.badge.plus") }
                .help("Reveal clipper.ics — subscribe to it from Calendar (File ▸ New Calendar Subscription)")
            }
        }
        .navigationTitle("Publishing")
        .task { reload() }
    }

    private func reload() { posts = ((try? model.publishQueue?.posts()) ?? []).reversed() }
}

/// Settings ▸ Accounts.
struct AccountsSettings: View {
    @Bindable var model: AppModel
    @State private var status: [Platform: Bool] = [:]
    @State private var values: [String: String] = [:]
    @State private var guide: Platform?
    @State private var instagramState: String?
    @State private var pasted = ""
    @State private var s3 = (endpoint: "", bucket: "", key: "", secret: "", region: "auto")

    var body: some View {
        Form {
            ForEach(Platform.allCases, id: \.self) { p in
                Section {
                    ForEach(PlatformCredentials.fields(for: p), id: \.key) { f in
                        if f.isSecret {
                            SecureField(f.label, text: binding(f.key))
                        } else {
                            TextField(f.label, text: binding(f.key))
                        }
                    }
                    if p == .instagram {
                        TextField("Storage endpoint (R2/S3)", text: $s3.endpoint)
                        TextField("Bucket", text: $s3.bucket)
                        TextField("Access key ID", text: $s3.key)
                        SecureField("Secret access key", text: $s3.secret)
                    }
                    HStack {
                        Button("Save Keys") { save(p) }
                        Button("Setup Guide…") { guide = p }
                        Spacer()
                        if status[p] == true {
                            Button("Disconnect") { model.disconnect(p); refresh() }
                        } else if p == .instagram {
                            Button("Sign In…") {
                                save(p)
                                if let (url, state) = model.instagramAuthorizeURL() { instagramState = state; NSWorkspace.shared.open(url) }
                            }
                        } else {
                            Button("Connect…") { save(p); Task { await model.connect(p); refresh() } }
                        }
                    }
                    if p == .instagram, let state = instagramState {
                        HStack {
                            TextField("Paste the redirected URL", text: $pasted)
                            Button("Finish") { Task { await model.finishInstagram(pasted: pasted, state: state); instagramState = nil; refresh() } }
                        }
                    }
                } header: {
                    HStack {
                        Text(p.displayName)
                        Text(status[p] == true ? "connected" : "not connected").font(.caption).foregroundStyle(status[p] == true ? .green : .secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: Binding(get: { guide.map(GuideItem.init) }, set: { guide = $0?.platform })) { item in
            VStack(alignment: .leading) {
                ScrollView { Text(PublisherFactory.setupInstructions(for: item.platform)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack { Spacer(); Button("Done") { guide = nil }.keyboardShortcut(.defaultAction) }
            }
            .padding(20).frame(width: 640, height: 460)
        }
        .task { load(); refresh() }
    }

    struct GuideItem: Identifiable { let platform: Platform; var id: String { platform.rawValue } }

    private func binding(_ key: String) -> Binding<String> { Binding(get: { values[key] ?? "" }, set: { values[key] = $0 }) }

    private func load() {
        let store = model.credentialStore
        for p in Platform.allCases { for f in PlatformCredentials.fields(for: p) { values[f.key] = (try? store.string(f.key)) ?? "" } }
        if let c = try? store.decode(S3Config.self, S3Config.credentialKey) {
            s3 = (c.endpoint.absoluteString, c.bucket, c.accessKeyID, c.secretAccessKey, c.region)
        }
    }

    private func save(_ p: Platform) {
        let store = model.credentialStore
        for f in PlatformCredentials.fields(for: p) {
            let v = (values[f.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            try? store.setString(v.isEmpty ? nil : v, for: f.key)
        }
        if p == .instagram, let url = URL(string: s3.endpoint), !s3.bucket.isEmpty, !s3.key.isEmpty, !s3.secret.isEmpty {
            try? store.encode(S3Config(endpoint: url, region: s3.region, bucket: s3.bucket, accessKeyID: s3.key, secretAccessKey: s3.secret),
                              for: S3Config.credentialKey)
        }
    }

    private func refresh() {
        Task { for p in Platform.allCases { status[p] = await model.isConnected(p) } }
    }
}
