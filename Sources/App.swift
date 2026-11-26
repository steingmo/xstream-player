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
    /// Everything the server sent; `index` holds this after the source's filter.
    @State private var allChannels: [Channel] = []
    @State private var index = ChannelIndex.empty
    @State private var shown: [Channel] = []
    @State private var favoriteNames: Set<String> = []
    @State private var favoriteChannels: [Channel] = []
    @State private var searchGeneration = 0
    @State private var lastSearchedQuery = ""
    @State private var loading = false
    @State private var error: String?
    @State private var query = ""
    @State private var group = ChannelIndex.allGroup
    @State private var playing: Channel?
    @State private var player = PlayerController()
    @State private var theaterMode = false
    @AppStorage("defaultPlayer") private var defaultPlayer = PlaybackTarget.builtin
    /// The source in the add/edit sheet. New sources are not in `sources` until saved.
    @State private var editing: Source?
    @State private var importing = false
    @State private var playError: String?
    @State private var export: M3UFile?
    @State private var exportName = "channels"
    @State private var favorites = Favorites.load()
    @State private var guide = Guide()
    @State private var accountInfo: AccountInfo?
    @State private var loadingAccount = false
    @State private var refreshGeneration = 0

    private var currentSource: Source? { sources.first(where: { $0.id == selected }) }

    private var currentFilter: SourceFilter { currentSource?.filter ?? SourceFilter() }

    /// What forces a re-download: another source, new credentials, or a section switched
    /// on or off. Hiding or reordering categories only re-filters what is already loaded.
    private struct LoadKey: Hashable {
        let id: Source.ID?
        let kind: SourceKind?
        let live: Bool
        let movies: Bool
        let refresh: Int
    }

    private var loadKey: LoadKey {
        LoadKey(id: selected, kind: currentSource?.kind,
                live: currentFilter.live, movies: currentFilter.movies,
                refresh: refreshGeneration)
    }

    /// Drives cached `shown` updates so body renders (selection, play errors, sheets) never
    /// rescan tens of thousands of channels.
    private struct SearchKey: Hashable {
        let generation: Int
        let group: String
        let query: String
    }

    private var searchKey: SearchKey {
        SearchKey(generation: searchGeneration, group: group, query: query)
    }

    /// The Xtream server behind the selected source, if it is one — EPG needs it.
    private var currentServer: Server? {
        guard let kind = sources.first(where: { $0.id == selected })?.kind,
              case .xtream(let server) = kind else { return nil }
        return server
    }

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
        favoriteNames.contains(c.name)
    }

    private func rebuildFavorites() {
        guard let selected else {
            favoriteNames = []
            favoriteChannels = []
            return
        }
        let prefix = "\(selected.uuidString)|"
        let names = Set(favorites.compactMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil })
        favoriteNames = names
        favoriteChannels = names.isEmpty ? [] : index.channels.filter { names.contains($0.name) }
    }

    private func toggleFavorite(_ c: Channel) {
        guard let selected else { return }
        let key = Favorites.key(selected, c)
        if favorites.contains(key) { favorites.remove(key) } else { favorites.insert(key) }
        Favorites.save(favorites)
        rebuildFavorites()
        if group == ChannelIndex.favoritesGroup {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                shown = favoriteChannels
            }
            searchGeneration += 1
        }
    }

    var body: some View {
        ZStack {
            NavigationSplitView {
                VStack(spacing: 0) {
                    List(selection: $selected) {
                        ForEach(sources) { s in
                            Label(s.name, systemImage: {
                                if case .xtream = s.kind { return "antenna.radiowaves.left.and.right" } else { return "doc.text" }
                            }()).tag(s.id)
                        }
                    }
                    .contextMenu(forSelectionType: Source.ID.self) { ids in
                        if ids.count == 1, let s = sources.first(where: { ids.contains($0.id) }) {
                            Button("Edit…") { editing = s }
                        }
                        Button("Remove", role: .destructive) {
                            if let selected, ids.contains(selected) { player.stop() }
                            sources.removeAll { ids.contains($0.id) }
                            Store.save(sources)
                        }
                    }
                    if currentServer != nil {
                        AccountFooterView(
                            info: accountInfo,
                            loading: loadingAccount,
                            onRefresh: { Task { await loadAccountInfo() } }
                        )
                    }
                }
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
                .toolbar {
                    Menu {
                        Button("Xtream Server…") { editing = Source(name: "", kind: .xtream(Server())) }
                        Button("M3U File…") { importing = true }
                    } label: { Image(systemName: "plus") }
                }
        } content: {
            VStack(spacing: 0) {
                if loading { ProgressView().padding() }
                if let error { Text(error).foregroundStyle(.red).padding(.horizontal).textSelection(.enabled) }
                Picker("", selection: $group) {
                    ForEach(index.groups, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().padding(6)
                // Selecting only shows the channel; double-click or Return plays it. Playing on
                // select sent every channel the arrow keys passed over to the player.
                List(shown, selection: Binding(get: { playing?.id }, set: { id in
                    // Deferred: the setter runs inside the table's selection delegate, and
                    // mutating @State there is reentrant.
                    let c = id.flatMap { index.byID[$0] }
                    Task { playing = c; playError = nil }
                })) { c in
                    ChannelRow(channel: c, guide: guide, server: currentServer,
                               isFavorite: isFavorite(c),
                               isPlaying: player.activeChannel?.id == c.id)
                        .tag(c.id)
                }
                .contextMenu(forSelectionType: Channel.ID.self) { ids in
                    if let id = ids.first, let c = index.byID[id] {
                        Button("Play in Xstream") { playInBuiltIn(c) }
                        Button("Open in VLC") { playInVLC(c) }
                        Divider()
                        Button(isFavorite(c) ? "Remove from Favorites" : "Add to Favorites") {
                            toggleFavorite(c)
                        }
                    }
                } primaryAction: { ids in
                    if let id = ids.first, let c = index.byID[id] { play(c) }
                }
            }
            .searchable(text: $query, placement: .toolbar, prompt: "Search channels")
            .navigationSplitViewColumnWidth(min: 240, ideal: 320)
            .toolbar {
                Button { refreshGeneration += 1 } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(currentSource == nil || loading)
                .keyboardShortcut("r", modifiers: .command)
                .help("Reload channels, guide, and account info (⌘R)")
                Menu {
                    Picker("Default Player", selection: $defaultPlayer) {
                        ForEach(PlaybackTarget.allCases) { target in
                            Text(target.label).tag(target)
                        }
                    }
                } label: {
                    Image(systemName: defaultPlayer == .builtin ? "play.rectangle" : "arrow.up.forward.app")
                }
                .help("Default player: \(defaultPlayer.label)")
                Button { editing = currentSource } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .disabled(currentSource == nil)
                .help("Choose which sections and categories to show")
                Menu {
                    Section("URLs include your portal password") {
                        Button("Visible Channels… (\(shown.count))") {
                            beginExport("visible", shown)
                        }
                        Button("Favorites… (\(favoriteChannels.count))") {
                            beginExport("favorites", favoriteChannels)
                        }
                        .disabled(favoriteChannels.isEmpty)
                        Button("All Channels… (\(index.channels.count))") {
                            beginExport("all", index.channels)
                        }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(index.channels.isEmpty)
                .help("Export as an M3U playlist")
            }
        } detail: {
            detailPane
        }
        .opacity(theaterMode ? 0 : 1)
        .toolbar(theaterMode ? .hidden : .visible, for: .windowToolbar)

        if theaterMode, let active = player.activeChannel {
            EmbeddedPlayerView(
                controller: player,
                channel: active,
                theaterMode: $theaterMode,
                onOpenInVLC: { playInVLC(active) },
                onToggleFullScreen: toggleFullScreen
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
        }
        }
        .onAppear {
            // Deferred: setting selection inside the table's first update is reentrant.
            if selected == nil { Task { selected = sources.first?.id } }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { note in
            if theaterMode {
                theaterMode = false
                (note.object as? NSWindow)?.toolbar?.isVisible = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            player.shutdown()
        }
        .task(id: loadKey) { await loadSelected() }
        .onChange(of: currentFilter) { applyFilter() }
        .onChange(of: group) {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                shown = index.base(group: group, favorites: favoriteChannels)
            }
        }
        .task(id: searchKey) { await updateShown() }
        .task(id: playing?.id) { await loadEPG() }
        .fileExporter(isPresented: Binding(get: { export != nil }, set: { if !$0 { export = nil } }),
                      document: export, contentType: .m3uPlaylist, defaultFilename: exportName) { _ in
            export = nil
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            guard let url = try? result.get() else { return }
            add(Source(name: url.lastPathComponent, kind: .m3u(path: url.path)))
        }
        .sheet(item: $editing) { source in
            SourceEditor(source: source) { save($0) }
        }
    }

    private func add(_ s: Source) {
        sources.append(s)
        Store.save(sources)
        selected = s.id
    }

    private func save(_ s: Source) {
        guard let i = sources.firstIndex(where: { $0.id == s.id }) else { return add(s) }
        sources[i] = s
        Store.save(sources)
    }

    private func applyFilter() {
        let filtered = currentFilter.apply(allChannels)
        index = ChannelIndex(channels: filtered, filter: currentFilter)
        rebuildFavorites()
        if !index.groups.contains(group) { group = ChannelIndex.allGroup }
        if let playing, index.byID[playing.id] != playing { self.playing = nil }
        if error == nil || error == Self.allHidden {
            error = !allChannels.isEmpty && index.channels.isEmpty ? Self.allHidden : nil
        }
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            shown = index.base(group: group, favorites: favoriteChannels)
        }
        searchGeneration += 1
    }

    private func updateShown() async {
        let pool = index.base(group: group, favorites: favoriteChannels)
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !pool.isEmpty else {
            shown = pool
            lastSearchedQuery = query
            return
        }
        // Small categories filter in under a millisecond; large lists debounce keystrokes
        // and filter off the main thread so typing stays smooth at 20k–50k channels.
        if pool.count <= 2_000 {
            shown = ChannelIndex.filter(pool, query: trimmed)
            lastSearchedQuery = query
            return
        }
        if query != lastSearchedQuery {
            try? await Task.sleep(for: .milliseconds(120))
            if Task.isCancelled { return }
        }
        let task = Task.detached(priority: .userInitiated) {
            ChannelIndex.filter(pool, query: trimmed)
        }
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard !Task.isCancelled else { return }
        shown = result
        lastSearchedQuery = query
    }

    private static let allHidden = "Every category is hidden. Use the filter button to show some."

    @ViewBuilder
    private var detailPane: some View {
        let inspected = playing ?? player.activeChannel
        if let active = player.activeChannel {
            VStack(spacing: 0) {
                if !theaterMode {
                    EmbeddedPlayerView(
                        controller: player,
                        channel: active,
                        theaterMode: $theaterMode,
                        onOpenInVLC: { playInVLC(active) },
                        onToggleFullScreen: toggleFullScreen
                    )
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(12)

                    if let shownChannel = inspected {
                        ScrollView {
                            channelDetails(shownChannel, isCurrentlyPlaying: shownChannel.id == active.id)
                                .padding([.horizontal, .bottom])
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if let playing {
            ScrollView {
                channelDetails(playing, isCurrentlyPlaying: false)
                    .padding()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ContentUnavailableView(
                "No channel selected",
                systemImage: "play.rectangle",
                description: Text(defaultPlayer == .builtin
                    ? "Double-click a channel to watch it here, or right-click to open in VLC."
                    : "Double-click a channel to open it in VLC, or right-click to play in Xstream.")
            )
        }
    }

    @ViewBuilder
    private func channelDetails(_ c: Channel, isCurrentlyPlaying: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AsyncImage(url: c.logo) { $0.resizable().scaledToFit() }
                    placeholder: { Image(systemName: "tv").font(.largeTitle)
                        .foregroundStyle(.secondary) }
                    .frame(width: 72, height: 54)
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.name).font(.title3).bold().textSelection(.enabled)
                    Text(c.group).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { toggleFavorite(c) } label: {
                    Image(systemName: isFavorite(c) ? "star.fill" : "star")
                        .foregroundStyle(isFavorite(c) ? .yellow : .secondary)
                }
                .buttonStyle(.borderless)
                .help(isFavorite(c) ? "Remove from Favorites" : "Add to Favorites")
            }

            if let playError {
                Text(playError).foregroundStyle(.red).textSelection(.enabled)
            }

            GuideView(
                guide: guide,
                channel: c,
                onRefresh: currentServer != nil ? {
                    guard let server = currentServer else { return }
                    Task { await guide.load(c, from: server, force: true) }
                } : nil
            )

            HStack(spacing: 8) {
                if defaultPlayer == .builtin {
                    Button(isCurrentlyPlaying ? "Reload" : "Play") { playInBuiltIn(c) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                    Button("Open in VLC") { playInVLC(c) }
                } else {
                    Button("Play in VLC") { playInVLC(c) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                    Button(isCurrentlyPlaying ? "Reload in Xstream" : "Play in Xstream") { playInBuiltIn(c) }
                }
                Button("Copy URL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(c.url.absoluteString, forType: .string)
                }
            }

            Text(c.url.absoluteString).font(.caption2)
                .foregroundStyle(.secondary).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func play(_ c: Channel) {
        switch defaultPlayer {
        case .builtin: playInBuiltIn(c)
        case .vlc: playInVLC(c)
        }
    }

    private func playInBuiltIn(_ c: Channel) {
        playing = c
        playError = nil
        player.play(c)
    }

    private func toggleFullScreen() {
        let entering = !theaterMode
        let window = NSApp.keyWindow
        theaterMode = entering
        window?.toolbar?.isVisible = !entering
        if let window {
            let isNativeFS = window.styleMask.contains(.fullScreen)
            if entering != isNativeFS {
                // Defer one tick so the reparented OpenGL view updates before the fullscreen snapshot.
                DispatchQueue.main.async {
                    window.toggleFullScreen(nil)
                }
            }
        }
    }

    private func playInVLC(_ c: Channel) {
        playing = c
        playError = nil
        if theaterMode { toggleFullScreen() }
        if player.isActive { player.stop() }
        do { try VLC.play(c.url) } catch { playError = error.localizedDescription }
    }

    private func loadEPG() async {
        guard let playing, let server = currentServer else { return }
        await guide.load(playing, from: server)      // no debounce: the user picked this one
    }

    private func loadAccountInfo() async {
        guard let server = currentServer else { accountInfo = nil; return }
        loadingAccount = true
        defer { loadingAccount = false }
        if let info = try? await Xtream.accountInfo(server) {
            if !Task.isCancelled { accountInfo = info }
        }
    }

    private func loadSelected() async {
        // Reset before the guard: removing the selected source must empty the list too.
        theaterMode = false; player.stop()
        error = nil; allChannels = []; index = .empty; favoriteNames = []; favoriteChannels = []
        shown = []; group = ChannelIndex.allGroup; playing = nil; guide.clear(); accountInfo = nil; searchGeneration += 1
        guard let source = currentSource else { return }
        let filter = source.filter ?? SourceFilter()
        loading = true
        defer { loading = false }
        do {
            switch source.kind {
            case .xtream(let s):
                async let channelsTask = Xtream.channels(s, live: filter.live, movies: filter.movies)
                async let accountTask: AccountInfo? = try? await Xtream.accountInfo(s)
                allChannels = try await channelsTask
                accountInfo = await accountTask
            case .m3u(let path):
                allChannels = try await loadM3U(path: path)
            }
            if Task.isCancelled { return }
            if allChannels.isEmpty {
                error = filter.live || filter.movies ? "No channels found."
                    : "Live TV and Movies are both switched off. Use the filter button to turn one on."
            } else {
                applyFilter()
            }
        } catch {
            // A superseded load cancels its URLSession tasks; that is not a failure to report.
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}

/// Add or edit a source: credentials for an Xtream server, then which sections and
/// categories the channel list shows and in what order. Everything saves with the source.
struct SourceEditor: View {
    let onSave: (Source) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var source: Source
    @State private var server: Server
    @State private var filter: SourceFilter
    private let isXtream: Bool
    /// Fixed at open, so the button doesn't flip from Add to Save while typing.
    private let isNew: Bool

    /// Every category the source has, in display order. Empty until loaded.
    @State private var ordered: [String] = []
    /// The provider's own order, for the "Provider order" sort.
    @State private var provider: [String] = []
    @State private var orderChanged = false
    @State private var loadingCategories = false
    @State private var categoryError: String?
    @State private var categoryQuery = ""
    @State private var accountInfo: AccountInfo?

    init(source: Source, onSave: @escaping (Source) -> Void) {
        self.onSave = onSave
        _source = State(initialValue: source)
        _filter = State(initialValue: source.filter ?? SourceFilter())
        if case .xtream(let s) = source.kind {
            _server = State(initialValue: s); isXtream = true; isNew = s.host.isEmpty
        } else {
            _server = State(initialValue: Server()); isXtream = false; isNew = false
        }
    }

    private func isMovie(_ g: String) -> Bool { g.hasPrefix(SourceFilter.moviePrefix) }

    /// Categories in the list right now: switched-off sections and the search filter out.
    private var listed: [String] {
        ordered.filter { g in
            (!isXtream || (isMovie(g) ? filter.movies : filter.live))
                && (categoryQuery.isEmpty || g.localizedCaseInsensitiveContains(categoryQuery))
        }
    }

    private func shown(_ g: String) -> Binding<Bool> {
        Binding(get: { !filter.hidden.contains(g) }, set: { on in
            if on { filter.hidden.remove(g) } else { filter.hidden.insert(g) }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                TextField("Name", text: $source.name, prompt: Text(isXtream ? "My provider" : "Playlist"))
                if isXtream {
                    TextField("Server", text: $server.host, prompt: Text("http://host:port"))
                    TextField("Username", text: $server.username)
                    SecureField("Password", text: $server.password)
                }
            }

            if isXtream, let info = accountInfo {
                GroupBox("Subscription") {
                    AccountDetailsGrid(info: info)
                        .padding(4)
                }
            }

            if isXtream {
                GroupBox("Sections") {
                    HStack(spacing: 16) {
                        Toggle("Live TV", isOn: $filter.live)
                        Toggle("Movies", isOn: $filter.movies)
                        // Series are never downloaded (each needs its own episode fetch),
                        // so this is always off. It is here so nobody hunts for it.
                        Toggle("TV Series", isOn: .constant(false)).disabled(true)
                            .help("Xstream doesn't load TV series yet, so they never fill the list.")
                        Spacer()
                    }
                    .padding(4)
                }
            }

            GroupBox("Categories") {
                VStack(alignment: .leading, spacing: 8) {
                    if ordered.isEmpty {
                        HStack {
                            Button(loadingCategories ? "Loading…" : "Load Categories") {
                                Task { await loadCategories() }
                            }
                            .disabled(loadingCategories || (isXtream && server.host.isEmpty))
                            if loadingCategories { ProgressView().controlSize(.small) }
                            Spacer()
                        }
                        if let categoryError {
                            Text(categoryError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        } else {
                            Text("Untick categories you don't want, and drag to reorder them.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        HStack {
                            TextField("Search categories", text: $categoryQuery)
                                .textFieldStyle(.roundedBorder)
                            Button("Show All") { filter.hidden.subtract(listed) }
                            Button("Hide All") { filter.hidden.formUnion(listed) }
                            Menu("Sort") {
                                Button("A to Z") {
                                    ordered = SourceFilter().sorted(ordered)
                                    filter.order = []; orderChanged = false
                                }
                                Button("Provider Order") { ordered = provider; orderChanged = true }
                            }
                            .fixedSize()
                        }
                        List {
                            ForEach(listed, id: \.self) { g in
                                Toggle(g, isOn: shown(g))
                            }
                            .onMove(perform: move)
                        }
                        .frame(minHeight: 240)
                        HStack {
                            Text("\(listed.filter { !filter.hidden.contains($0) }.count) of \(listed.count) shown")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Toggle("Show new categories automatically", isOn: $filter.showNew)
                                .font(.caption)
                                .help("Off: categories the provider adds later stay hidden until you tick them here.")
                        }
                    }
                }
                .padding(4)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isXtream && server.host.isEmpty)
            }
        }
        .padding()
        .frame(width: 500)
        .task {
            // An existing source can show its categories straight away; a new server
            // waits for the button, since its address is still being typed.
            if !isXtream || !server.host.isEmpty { await loadCategories() }
        }
    }

    /// Dragging works on the filtered list, so permute those entries within the slots
    /// they already hold in the full list; hidden-by-search categories stay put.
    private func move(from: IndexSet, to: Int) {
        var moved = listed
        moved.move(fromOffsets: from, toOffset: to)
        let members = Set(moved)
        let slots = ordered.indices.filter { members.contains(ordered[$0]) }
        for (i, g) in zip(slots, moved) { ordered[i] = g }
        orderChanged = true
    }

    private func loadCategories() async {
        loadingCategories = true
        categoryError = nil
        defer { loadingCategories = false }
        do {
            var found: [String]
            switch source.kind {
            case .xtream:
                async let catsTask = Xtream.categories(server)
                async let infoTask: AccountInfo? = try? await Xtream.accountInfo(server)
                found = try await catsTask
                accountInfo = await infoTask
            case .m3u(let path):
                found = try await loadM3U(path: path).map(\.group)
            }
            var seen = Set<String>()
            found = found.filter { seen.insert($0).inserted }
            if found.isEmpty { categoryError = "No categories found."; return }
            provider = found
            ordered = filter.sorted(found)
        } catch {
            if !Task.isCancelled { categoryError = error.localizedDescription }
        }
    }

    private func save() {
        if orderChanged { filter.order = ordered }
        if !ordered.isEmpty {
            // What the server has now becomes "known"; ticks for categories it dropped go.
            filter.known = Set(ordered)
            filter.hidden.formIntersection(filter.known)
        }
        if isXtream {
            source.kind = .xtream(server)
            if source.name.isEmpty { source.name = server.host }
        }
        source.filter = filter
        onSave(source)
        dismiss()
    }
}

/// Its own view so guide updates re-render one row, not ContentView: reading `guide` in
/// ContentView's body re-ran the whole channel filter for every EPG reply.
struct ChannelRow: View {
    let channel: Channel
    let guide: Guide
    let server: Server?
    let isFavorite: Bool
    var isPlaying = false

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
            if isPlaying {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint).font(.caption)
            }
            if isFavorite {
                Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption)
            }
        }
        .task(id: "\(channel.id)|\(guide.needsRefresh(channel))") {
            guard let server, guide.needsRefresh(channel) else { return }
            await guide.load(channel, from: server, debounce: .milliseconds(400))
        }
        .help(now.map { "\($0.title)\n\($0.summary)" } ?? "")
    }
}

/// Now and next, from the channel's short EPG, with full description and expandable upcoming
/// schedule. Reads the guide itself, like ChannelRow, so ContentView never observes entries.
// ponytail: the app logs "reentrant operation in its NSTableView delegate" at startup.
// Verified it is not ours — it still fires with the row EPG task and the deferred
// selection writes removed, so it comes from SwiftUI's own List bookkeeping. Harmless
// today; revisit if a future macOS turns it into the promised assert.
struct GuideView: View {
    let guide: Guide
    let channel: Channel
    var onRefresh: (() -> Void)? = nil

    @State private var showAllUpcoming = false

    var body: some View {
        // Re-renders every 30s so "now", remaining time, and the progress bar stay fresh.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let programmes = guide.programmes(channel)
            if !programmes.isEmpty {
                content(programmes, at: context.date)
            }
        }
        .onChange(of: channel.id) { showAllUpcoming = false }
    }

    private func content(_ programmes: [Programme], at date: Date) -> some View {
        let now = programmes.first { date >= $0.start && date < $0.stop } ?? programmes.first
        let upcoming = programmes.filter { $0.start > (now?.start ?? .distantPast) }
        let shownUpcoming = showAllUpcoming ? upcoming : Array(upcoming.prefix(2))

        return VStack(alignment: .leading, spacing: 6) {
            if let now {
                HStack(spacing: 6) {
                    Text(span(now)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Text(now.title).font(.callout).bold().lineLimit(2)
                    Spacer()
                    if date >= now.start && date < now.stop {
                        let minsLeft = max(1, Int(ceil(now.stop.timeIntervalSince(date) / 60)))
                        Text("\(minsLeft)m left")
                            .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    }
                    if let onRefresh {
                        Button(action: onRefresh) {
                            Image(systemName: "arrow.clockwise").font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Refresh guide for this channel")
                    }
                }
                if date >= now.start && date < now.stop {
                    ProgressView(value: min(max(date.timeIntervalSince(now.start), 0), max(now.stop.timeIntervalSince(now.start), 1)),
                                 total: max(now.stop.timeIntervalSince(now.start), 1))
                        .controlSize(.small)
                }
                if !now.summary.isEmpty {
                    Text(now.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !shownUpcoming.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(shownUpcoming) { p in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(span(p)).font(.caption2).monospacedDigit()
                            Text(p.title).font(.caption2).lineLimit(1)
                        }
                        .foregroundStyle(.secondary)
                        .help(p.summary)
                    }
                    if upcoming.count > 2 {
                        Button(showAllUpcoming ? "Show less" : "More upcoming (\(upcoming.count - 2))") {
                            showAllUpcoming.toggle()
                        }
                        .buttonStyle(.link)
                        .font(.caption2)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private func span(_ p: Programme) -> String {
        "\(p.start.formatted(date: .omitted, time: .shortened))–\(p.stop.formatted(date: .omitted, time: .shortened))"
    }
}

/// Compact Xtream subscription summary pinned at the bottom of the Sources sidebar.
struct AccountFooterView: View {
    let info: AccountInfo?
    let loading: Bool
    let onRefresh: () -> Void

    private var statusColor: Color {
        guard let info else { return .secondary }
        if !info.isActive { return .red }
        if let days = info.daysRemaining(), days <= 7 { return days < 0 ? .red : .orange }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                if let info {
                    Text(info.isTrial ? "\(info.status) · Trial" : info.status)
                        .font(.caption).bold()
                } else {
                    Text(loading ? "Checking account…" : "Account")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if loading {
                    ProgressView().controlSize(.mini)
                } else {
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise").font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Refresh subscription status")
                }
            }
            if let info {
                if let exp = info.expiresAt {
                    let days = info.daysRemaining()
                    let suffix: String = {
                        guard let days else { return "" }
                        if days < 0 { return " (expired)" }
                        if days == 0 { return " (today)" }
                        return " (\(days)d)"
                    }()
                    Text("Expires \(exp.formatted(date: .abbreviated, time: .omitted))\(suffix)")
                        .font(.caption2)
                        .foregroundStyle((days ?? 99) <= 7 ? statusColor : .secondary)
                } else {
                    Text("No expiry")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let cons = info.connectionsSummary {
                    Text("Connections: \(cons)")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Detailed subscription block shown inside the Xtream Source Editor sheet.
struct AccountDetailsGrid: View {
    let info: AccountInfo

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            GridRow {
                Text("Status").foregroundStyle(.secondary)
                Text(info.isTrial ? "\(info.status) (Trial)" : info.status)
                    .foregroundStyle(info.isActive ? Color.primary : Color.red)
            }
            GridRow {
                Text("Expires").foregroundStyle(.secondary)
                if let exp = info.expiresAt {
                    let days = info.daysRemaining()
                    Text("\(exp.formatted(date: .abbreviated, time: .shortened))" + (days.map { $0 >= 0 ? " (\($0)d left)" : " (expired)" } ?? ""))
                } else {
                    Text("Unlimited")
                }
            }
            if let cons = info.connectionsSummary {
                GridRow {
                    Text("Connections").foregroundStyle(.secondary)
                    Text(cons).monospacedDigit()
                }
            }
            if !info.allowedFormats.isEmpty {
                GridRow {
                    Text("Formats").foregroundStyle(.secondary)
                    Text(info.allowedFormats.joined(separator: ", "))
                }
            }
            if let tz = info.timezone {
                GridRow {
                    Text("Server TZ").foregroundStyle(.secondary)
                    Text(tz)
                }
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
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
