import Sparkle
import SwiftUI
import UniformTypeIdentifiers

@main
struct XstreamApp: App {
    // Sparkle checks the appcast on its own schedule; this also backs the menu item.
    private let updater = SPUStandardUpdaterController(startingUpdater: true,
                                                      updaterDelegate: nil,
                                                      userDriverDelegate: nil)

    init() {
        // Channel logos rarely carry cache headers, and the default cache is a few MB, so
        // without this every logo re-downloads each time its row scrolls back into view.
        URLCache.shared = URLCache(memoryCapacity: 50_000_000, diskCapacity: 200_000_000)
    }

    var body: some Scene {
        WindowGroup("Xstream") { ContentView() }
            .defaultSize(width: 1200, height: 720)
            .commands {
                CommandGroup(after: .appInfo) {
                    Button("Check for Updates…") { updater.updater.checkForUpdates() }
                }
            }
    }
}

struct ContentView: View {
    @State private var sources = Store.load()
    @State private var selected: Source.ID?
    @State private var channels: [Channel] = []
    @State private var loading = false
    @State private var error: String?
    @State private var query = ""
    @State private var group = "All"
    @State private var playing: Channel?
    @State private var addingServer = false
    @State private var draftName = ""
    @State private var draft = Server()
    @State private var importing = false
    @State private var playError: String?
    @State private var export: M3UFile?
    @State private var exportName = "channels"
    @State private var favorites = Favorites.load()
    @State private var guide = Guide()

    private static let favoritesGroup = "\u{2605} Favorites"

    private var groups: [String] {
        ["All", Self.favoritesGroup] + Set(channels.map(\.group)).sorted()
    }

    private var shown: [Channel] {
        channels.filter { c in
            let inGroup: Bool
            switch group {
            case "All": inGroup = true
            case Self.favoritesGroup: inGroup = isFavorite(c)
            default: inGroup = c.group == group
            }
            return inGroup && (query.isEmpty || c.name.localizedCaseInsensitiveContains(query))
        }
    }

    /// The Xtream server behind the selected source, if it is one — EPG needs it.
    private var currentServer: Server? {
        guard let kind = sources.first(where: { $0.id == selected })?.kind,
              case .xtream(let server) = kind else { return nil }
        return server
    }

    private var favoriteChannels: [Channel] { channels.filter(isFavorite) }

    private var sourceName: String {
        sources.first(where: { $0.id == selected })?.name ?? "channels"
    }

    /// The list's own search and category filters are the export picker — whatever you can
    /// see is what "Visible" writes out.
    private func beginExport(_ scope: String, _ list: [Channel]) {
        exportName = "\(sourceName) — \(scope)"
        export = M3UFile(text: exportM3U(list, note: "\(sourceName) (\(scope))"))
    }

    private func isFavorite(_ c: Channel) -> Bool {
        guard let selected else { return false }
        return favorites.contains(Favorites.key(selected, c))
    }

    private func toggleFavorite(_ c: Channel) {
        guard let selected else { return }
        let key = Favorites.key(selected, c)
        if favorites.contains(key) { favorites.remove(key) } else { favorites.insert(key) }
        Favorites.save(favorites)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selected) {
                ForEach(sources) { s in
                    Label(s.name, systemImage: {
                        if case .xtream = s.kind { return "antenna.radiowaves.left.and.right" } else { return "doc.text" }
                    }()).tag(s.id)
                }
            }
            .contextMenu(forSelectionType: Source.ID.self) { ids in
                Button("Remove", role: .destructive) {
                    sources.removeAll { ids.contains($0.id) }
                    Store.save(sources)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            .toolbar {
                Menu {
                    Button("Xtream Server…") { draft = Server(); draftName = ""; addingServer = true }
                    Button("M3U File…") { importing = true }
                } label: { Image(systemName: "plus") }
            }
        } content: {
            VStack(spacing: 0) {
                if loading { ProgressView().padding() }
                if let error { Text(error).foregroundStyle(.red).padding(.horizontal).textSelection(.enabled) }
                Picker("", selection: $group) {
                    ForEach(groups, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().padding(6)
                // Selecting only shows the channel; double-click or Return plays it. Playing on
                // select sent every channel the arrow keys passed over to VLC.
                List(shown, selection: Binding(get: { playing?.id }, set: { id in
                    // Deferred: the setter runs inside the table's selection delegate, and
                    // mutating @State there is reentrant.
                    let c = shown.first(where: { $0.id == id })
                    Task { playing = c; playError = nil }
                })) { c in
                    ChannelRow(channel: c, guide: guide, server: currentServer,
                               isFavorite: isFavorite(c))
                        .tag(c.id)
                }
                .contextMenu(forSelectionType: Channel.ID.self) { ids in
                    if let c = channels.first(where: { ids.contains($0.id) }) {
                        Button(isFavorite(c) ? "Remove from Favorites" : "Add to Favorites") {
                            toggleFavorite(c)
                        }
                    }
                } primaryAction: { ids in
                    if let c = channels.first(where: { ids.contains($0.id) }) { play(c) }
                }
            }
            .searchable(text: $query, placement: .toolbar, prompt: "Search channels")
            .navigationSplitViewColumnWidth(min: 240, ideal: 320)
            .toolbar {
                Menu {
                    Section("URLs include your portal password") {
                        Button("Visible Channels… (\(shown.count))") {
                            beginExport("visible", shown)
                        }
                        Button("Favorites… (\(favoriteChannels.count))") {
                            beginExport("favorites", favoriteChannels)
                        }
                        .disabled(favoriteChannels.isEmpty)
                        Button("All Channels… (\(channels.count))") {
                            beginExport("all", channels)
                        }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(channels.isEmpty)
                .help("Export as an M3U playlist")
            }
        } detail: {
            if let playing {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        AsyncImage(url: playing.logo) { $0.resizable().scaledToFit() }
                            placeholder: { Image(systemName: "tv").font(.largeTitle)
                                .foregroundStyle(.secondary) }
                            .frame(width: 96, height: 72)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(playing.name).font(.title2).bold().textSelection(.enabled)
                            Text(playing.group).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let playError {
                        Text(playError).foregroundStyle(.red).textSelection(.enabled)
                    }
                    GuideView(guide: guide, channel: playing)
                    HStack {
                        Button("Play in VLC") { play(playing) }
                            .keyboardShortcut(.defaultAction)
                        Button("Copy URL") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(playing.url.absoluteString, forType: .string)
                        }
                    }
                    Text(playing.url.absoluteString).font(.caption2)
                        .foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer()
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ContentUnavailableView("No channel selected", systemImage: "play.rectangle",
                                       description: Text("Double-click a channel to open it in VLC."))
            }
        }
        .onAppear {
            // Deferred: setting selection inside the table's first update is reentrant.
            if selected == nil { Task { selected = sources.first?.id } }
        }
        .task(id: selected) { await loadSelected() }
        .task(id: playing?.id) { await loadEPG() }
        .fileExporter(isPresented: Binding(get: { export != nil }, set: { if !$0 { export = nil } }),
                      document: export, contentType: .m3uPlaylist, defaultFilename: exportName) { _ in
            export = nil
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            guard let url = try? result.get() else { return }
            add(Source(name: url.lastPathComponent, kind: .m3u(path: url.path)))
        }
        .sheet(isPresented: $addingServer) {
            Form {
                TextField("Name", text: $draftName, prompt: Text("My provider"))
                TextField("Server", text: $draft.host, prompt: Text("http://host:port"))
                TextField("Username", text: $draft.username)
                SecureField("Password", text: $draft.password)
                HStack {
                    Spacer()
                    Button("Cancel") { addingServer = false }
                    Button("Add") {
                        add(Source(name: draftName.isEmpty ? draft.host : draftName, kind: .xtream(draft)))
                        addingServer = false
                    }.keyboardShortcut(.defaultAction).disabled(draft.host.isEmpty)
                }
            }
            .padding().frame(width: 380)
        }
    }

    private func add(_ s: Source) {
        sources.append(s)
        Store.save(sources)
        selected = s.id
    }

    private func play(_ c: Channel) {
        playing = c
        playError = nil
        do { try VLC.play(c.url) } catch { playError = error.localizedDescription }
    }

    private func loadEPG() async {
        guard let playing, let server = currentServer else { return }
        await guide.load(playing, from: server)      // no debounce: the user picked this one
    }

    private func loadSelected() async {
        // Reset before the guard: removing the selected source must empty the list too.
        error = nil; channels = []; group = "All"; playing = nil; guide.clear()
        guard let source = sources.first(where: { $0.id == selected }) else { return }
        loading = true
        defer { loading = false }
        do {
            switch source.kind {
            case .xtream(let s):
                channels = try await Xtream.channels(s)
            case .m3u(let path):
                let url = URL(fileURLWithPath: path)
                channels = parseM3U(try String(contentsOf: url, encoding: .utf8), base: url)
            }
            if channels.isEmpty, !Task.isCancelled { error = "No channels found." }
        } catch {
            // A superseded load cancels its URLSession tasks; that is not a failure to report.
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}

/// Its own view so guide updates re-render one row, not ContentView: reading `guide` in
/// ContentView's body re-ran the whole channel filter for every EPG reply.
struct ChannelRow: View {
    let channel: Channel
    let guide: Guide
    let server: Server?
    let isFavorite: Bool

    var body: some View {
        let now = guide.now(channel)
        HStack {
            AsyncImage(url: channel.logo) { $0.resizable().scaledToFit() }
                placeholder: { Image(systemName: "tv").foregroundStyle(.secondary) }
                .frame(width: 32, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(channel.name).lineLimit(1)
                if let now {
                    Text(now.title).font(.caption2)
                        .foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if isFavorite {
                Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption)
            }
        }
        .task(id: channel.id) {
            guard let server else { return }
            await guide.load(channel, from: server, debounce: .milliseconds(400))
        }
        .help(now.map { "\($0.title)\n\($0.summary)" } ?? "")
    }
}

/// Now and next, from the channel's short EPG. Live TV needs the current programme's
/// progress more than it needs a full grid, so that is all this shows. It reads the guide
/// itself, like ChannelRow, so ContentView never observes `listings`.
// ponytail: the app logs "reentrant operation in its NSTableView delegate" at startup.
// Verified it is not ours — it still fires with the row EPG task and the deferred
// selection writes removed, so it comes from SwiftUI's own List bookkeeping. Harmless
// today; revisit if a future macOS turns it into the promised assert.
struct GuideView: View {
    let guide: Guide
    let channel: Channel

    var body: some View {
        // Re-renders every 30s so "now" and the progress bar don't go stale while watching.
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            let programmes = guide.programmes(channel)
            if !programmes.isEmpty { content(programmes) }
        }
    }

    private func content(_ programmes: [Programme]) -> some View {
        let now = programmes.first(where: \.isNow) ?? programmes.first
        return VStack(alignment: .leading, spacing: 2) {
            if let now {
                HStack(spacing: 6) {
                    Text(span(now)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Text(now.title).font(.caption).bold().lineLimit(1)
                }
                if now.isNow {
                    ProgressView(value: Date().timeIntervalSince(now.start),
                                 total: max(now.stop.timeIntervalSince(now.start), 1))
                        .controlSize(.small)
                }
            }
            ForEach(programmes.filter { $0.start > (now?.start ?? .distantPast) }.prefix(2)) { p in
                HStack(spacing: 6) {
                    Text(span(p)).font(.caption2).monospacedDigit()
                    Text(p.title).font(.caption2).lineLimit(1)
                }
                .foregroundStyle(.secondary)
            }
        }
        .help(now?.summary ?? "")
    }

    private func span(_ p: Programme) -> String {
        "\(p.start.formatted(date: .omitted, time: .shortened))–\(p.stop.formatted(date: .omitted, time: .shortened))"
    }
}

extension UTType {
    /// public.m3u-playlist exists on macOS, but fall back rather than crash if it ever moves.
    static let m3uPlaylist = UTType(filenameExtension: "m3u") ?? .plainText
}

struct M3UFile: FileDocument {
    static var readableContentTypes: [UTType] { [.m3uPlaylist] }

    let text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        guard let d = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        text = String(decoding: d, as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
