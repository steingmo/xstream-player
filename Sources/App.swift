import ImageIO
import Sparkle
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class PlaybackMenuBridge {
    var hasActivePlayer = false
    var isPaused = false
    var isMuted = false
    var isTheaterMode = false
    var isMiniPlayer = false
    var canZap = false
    var canRefresh = false
    var canQuickSwitch = false

    var onTogglePlayPause: (() -> Void)?
    var onStop: (() -> Void)?
    var onReloadStream: (() -> Void)?
    var onToggleMute: (() -> Void)?
    var onPreviousChannel: (() -> Void)?
    var onNextChannel: (() -> Void)?
    var onToggleFullScreen: (() -> Void)?
    var onToggleMiniPlayer: (() -> Void)?
    var onToggleDrawer: (() -> Void)?
    var onQuickSwitch: (() -> Void)?
    var onRefresh: (() -> Void)?
}

@main
struct XstreamApp: App {
    // Sparkle checks the appcast on its own schedule; this also backs the menu item.
    private let updater = SPUStandardUpdaterController(startingUpdater: true,
                                                      updaterDelegate: nil,
                                                      userDriverDelegate: nil)
    @Environment(\.openWindow) private var openWindow
    @State private var bridge = PlaybackMenuBridge()
    @State private var shortcuts = ShortcutStore.shared

    init() {
        // Channel logos rarely carry cache headers, and the default cache is a few MB, so
        // without this every logo re-downloads each time its row scrolls back into view.
        URLCache.shared = URLCache(memoryCapacity: 50_000_000, diskCapacity: 200_000_000)
    }

    var body: some Scene {
        Window("Xstream", id: "main") { ContentView(bridge: bridge) }
            .defaultSize(width: 1200, height: 720)
            .commands {
                CommandGroup(after: .appInfo) {
                    Button("Check for Updates…") { updater.updater.checkForUpdates() }
                }
                CommandGroup(replacing: .help) {
                    Button("Xstream Help") { openWindow(id: "help") }
                        .keyboardShortcut("?", modifiers: .command)
                }
                CommandMenu("Playback") {
                    Button(bridge.isPaused ? "Play" : "Pause") { bridge.onTogglePlayPause?() }
                        .keyboardShortcut(shortcuts.combo(for: .togglePlayPause).keyboardShortcut)
                        .disabled(!bridge.hasActivePlayer)
                    Button("Stop") { bridge.onStop?() }
                        .keyboardShortcut(shortcuts.combo(for: .stop).keyboardShortcut)
                        .disabled(!bridge.hasActivePlayer)
                    Button("Reload Stream") { bridge.onReloadStream?() }
                        .keyboardShortcut(shortcuts.combo(for: .reloadStream).keyboardShortcut)
                        .disabled(!bridge.hasActivePlayer)
                    Divider()
                    Button("Previous Channel") { bridge.onPreviousChannel?() }
                        .keyboardShortcut(shortcuts.combo(for: .previousChannel).keyboardShortcut)
                        .disabled(!bridge.canZap)
                    Button("Next Channel") { bridge.onNextChannel?() }
                        .keyboardShortcut(shortcuts.combo(for: .nextChannel).keyboardShortcut)
                        .disabled(!bridge.canZap)
                    Divider()
                    Button(bridge.isMuted ? "Unmute" : "Mute") { bridge.onToggleMute?() }
                        .keyboardShortcut(shortcuts.combo(for: .toggleMute).keyboardShortcut)
                        .disabled(!bridge.hasActivePlayer)
                    Button(bridge.isMiniPlayer ? "Return to Window" : "Floating Mini-Player") {
                        bridge.onToggleMiniPlayer?()
                    }
                    .keyboardShortcut(shortcuts.combo(for: .toggleMiniPlayer).keyboardShortcut)
                    .disabled(!bridge.hasActivePlayer)
                    Button(bridge.isTheaterMode ? "Exit Fullscreen" : "Fullscreen") {
                        bridge.onToggleFullScreen?()
                    }
                    .keyboardShortcut(shortcuts.combo(for: .toggleFullScreen).keyboardShortcut)
                    .disabled(!bridge.hasActivePlayer)
                    Button("Channel Drawer") { bridge.onToggleDrawer?() }
                        .keyboardShortcut(shortcuts.combo(for: .toggleDrawer).keyboardShortcut)
                        .disabled(!bridge.isTheaterMode)
                    Button("Quick Channel Switcher…") { bridge.onQuickSwitch?() }
                        .keyboardShortcut(shortcuts.combo(for: .quickSwitcher).keyboardShortcut)
                        .disabled(!bridge.canQuickSwitch)
                    Divider()
                    Button("Refresh Source") { bridge.onRefresh?() }
                        .keyboardShortcut(shortcuts.combo(for: .refreshSource).keyboardShortcut)
                        .disabled(!bridge.canRefresh)
                }
            }

        Settings {
            SettingsView(updater: updater.updater, shortcuts: shortcuts)
        }

        Window("Xstream Help", id: "help") {
            HelpView(shortcuts: shortcuts)
        }
        .defaultSize(width: 640, height: 560)
    }
}

struct ContentView: View {
    let bridge: PlaybackMenuBridge
    @State private var sources = Store.load()
    @State private var selected: Source.ID?
    /// Everything the server sent; `index` holds this after the source's filter.
    @State private var allChannels: [Channel] = []
    @State private var index = ChannelIndex.empty
    @State private var shown: [Channel] = []
    @State private var favoriteNames: Set<String> = []
    @State private var favoriteChannels: [Channel] = []
    @State private var recentsStore = Recents.load()
    @State private var recentChannels: [Channel] = []
    @State private var copiedChannelID: Channel.ID?
    @State private var copiedResetTask: Task<Void, Never>?
    @State private var searchGeneration = 0
    @State private var lastSearchedQuery = ""
    @State private var loading = false
    @State private var error: String?
    @State private var query = ""
    @State private var group = ChannelIndex.allGroup
    @State private var hdOnly = false
    @State private var playing: Channel?
    @State private var player = PlayerController()
    @State private var theaterMode = false
    @State private var showFullscreenDrawer = false
    @State private var showQuickSwitcher = false
    @State private var miniPlayer = false
    @State private var miniWindow = MiniPlayerWindowController()
    @State private var hostWindow = WeakWindowBox()
    @State private var loadedSourceID: Source.ID?
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
    @State private var probeResult: StreamProbeResult?
    @State private var probeError: String?
    @State private var probingStream = false
    @State private var probeTask: Task<Void, Never>?
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
        let hdOnly: Bool
    }

    private var searchKey: SearchKey {
        SearchKey(generation: searchGeneration, group: group, query: query, hdOnly: hdOnly)
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

    private func rebuildRecents() {
        guard let selected else { recentChannels = []; return }
        recentChannels = Recents.resolve(selected, from: recentsStore, in: index.channels)
    }

    private func recordRecent(_ c: Channel) {
        guard let selected else { return }
        Recents.record(selected, channelName: c.name, in: &recentsStore)
        Recents.save(recentsStore)
        rebuildRecents()
        if group == ChannelIndex.recentsGroup {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                shown = recentChannels
            }
            searchGeneration += 1
        }
    }

    private func copyURL(_ c: Channel) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(c.url.absoluteString, forType: .string)
        copiedChannelID = c.id
        copiedResetTask?.cancel()
        copiedResetTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled && copiedChannelID == c.id { copiedChannelID = nil }
        }
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
                        Section("Sources") {
                            ForEach(sources) { s in
                                HStack {
                                    Label(s.name, systemImage: {
                                        if case .xtream = s.kind { return "antenna.radiowaves.left.and.right" } else { return "doc.text" }
                                    }())
                                    Spacer()
                                    if s.id == selected && !index.channels.isEmpty {
                                        Text("\(index.channels.count)")
                                            .font(.caption2)
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .tag(s.id)
                            }
                        }
                    }
                    .contextMenu(forSelectionType: Source.ID.self) { ids in
                        if ids.count == 1, let s = sources.first(where: { ids.contains($0.id) }) {
                            Button("Edit…") { editing = s }
                        }
                        Button("Remove", role: .destructive) {
                            if let selected, ids.contains(selected) {
                                closeMiniPlayer()
                                player.stop()
                            }
                            for id in ids { ChannelCache.remove(sourceID: id) }
                            sources.removeAll { ids.contains($0.id) }
                            Store.save(sources)
                        }
                    }
                    if currentServer != nil || !index.channels.isEmpty {
                        AccountFooterView(
                            showAccount: currentServer != nil,
                            info: accountInfo,
                            loading: loadingAccount,
                            onRefresh: { Task { await loadAccountInfo() } },
                            probeResult: probeResult,
                            probeError: probeError,
                            probingStream: probingStream,
                            canProbe: !index.channels.isEmpty,
                            probeBlockedByLimit: probeBlockedByConnectionLimit,
                            onProbe: { runStreamProbe() }
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
                if loading && shown.isEmpty { ProgressView().padding() }
                if let error { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 10).padding(.vertical, 6).textSelection(.enabled) }
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        quickFilterPill("All", target: ChannelIndex.allGroup)
                        quickFilterPill("Favorites", icon: "star.fill", count: favoriteChannels.count, target: ChannelIndex.favoritesGroup)
                        quickFilterPill("Recent", icon: "clock", count: recentChannels.count, target: ChannelIndex.recentsGroup)
                        Spacer(minLength: 0)
                        hdFilterPill
                    }
                    HStack(spacing: 6) {
                        Picker("", selection: Binding(
                            get: { index.categoryGroups.contains(group) ? group : ChannelIndex.allGroup },
                            set: { group = $0 }
                        )) {
                            Text("All Categories").tag(ChannelIndex.allGroup)
                            if !index.categoryGroups.isEmpty {
                                Divider()
                                ForEach(index.categoryGroups, id: \.self) { Text($0).tag($0) }
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)

                        Text(query.trimmingCharacters(in: .whitespaces).isEmpty
                             ? "\(shown.count)"
                             : "\(shown.count) match\(shown.count == 1 ? "" : "es")")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                Divider()
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
                               isPlaying: player.activeChannel?.id == c.id,
                               onPlay: { play(c) },
                               onToggleFavorite: { toggleFavorite(c) })
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
                        Button("Test Stream Speed") {
                            runStreamProbe(for: c)
                        }
                        .disabled(probingStream || probeBlockedByConnectionLimit)
                    }
                } primaryAction: { ids in
                    if let id = ids.first, let c = index.byID[id] { play(c) }
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 320)
            .toolbar {
                Button { refreshGeneration += 1 } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(currentSource == nil || loading)
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
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            guard !index.channels.isEmpty else { return }
                            withAnimation(.easeOut(duration: 0.14)) { showQuickSwitcher.toggle() }
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .disabled(index.channels.isEmpty)
                        .help("Quick Channel Switcher (⌘K)")
                    }
                }
        }
        .opacity(theaterMode ? 0 : 1)
        .allowsHitTesting(!theaterMode)
        .toolbar(theaterMode ? .hidden : .visible, for: .windowToolbar)

        if theaterMode, let active = player.activeChannel {
            ZStack(alignment: .leading) {
                EmbeddedPlayerView(
                    controller: player,
                    channel: active,
                    theaterMode: $theaterMode,
                    onOpenInVLC: { playInVLC(active) },
                    onToggleFullScreen: toggleFullScreen,
                    onToggleMiniPlayer: toggleMiniPlayer,
                    onPreviousChannel: shown.count > 1 ? { zapChannel(offset: -1) } : nil,
                    onNextChannel: shown.count > 1 ? { zapChannel(offset: 1) } : nil,
                    onToggleDrawer: {
                        withAnimation(.easeInOut(duration: 0.2)) { showFullscreenDrawer.toggle() }
                    },
                    onQuickSwitch: {
                        guard !index.channels.isEmpty else { return }
                        withAnimation(.easeOut(duration: 0.14)) { showQuickSwitcher.toggle() }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if showFullscreenDrawer {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) { showFullscreenDrawer = false }
                        }
                    fullscreenChannelDrawer
                        .transition(.move(edge: .leading))
                }
            }
        }

        if showQuickSwitcher {
            QuickChannelSwitcher(
                channels: index.channels,
                recents: recentChannels,
                favorites: favoriteChannels,
                favoriteNames: favoriteNames,
                activeChannelID: player.activeChannel?.id,
                guide: guide,
                onSelect: { channel in
                    withAnimation(.easeOut(duration: 0.12)) { showQuickSwitcher = false }
                    playInBuiltIn(channel)
                    player.flashOSD(channel.name)
                },
                onDismiss: {
                    withAnimation(.easeOut(duration: 0.12)) { showQuickSwitcher = false }
                }
            )
            .transition(.opacity)
            .zIndex(20)
        }
        }
        .onAppear {
            // Deferred: setting selection inside the table's first update is reentrant.
            if selected == nil { Task { selected = sources.first?.id } }
            wireMenuBridge()
            syncMenuBridge()
        }
        .onChange(of: player.activeChannel) { _, active in
            if active == nil {
                closeMiniPlayer()
                showFullscreenDrawer = false
            } else if miniPlayer, let active {
                miniWindow.update { miniPlayerContent(for: active) }
            }
            syncMenuBridge()
        }
        .onChange(of: player.isPaused) { syncMenuBridge() }
        .onChange(of: player.isMuted) { syncMenuBridge() }
        .onChange(of: theaterMode) { _, on in
            if !on { showFullscreenDrawer = false }
            syncMenuBridge()
        }
        .onChange(of: miniPlayer) { syncMenuBridge() }
        .onChange(of: shown.count) { syncMenuBridge() }
        .onChange(of: loading) { syncMenuBridge() }
        .onChange(of: selected) {
            probeTask?.cancel()
            probingStream = false
            probeResult = nil
            probeError = nil
            syncMenuBridge()
        }
        .background(WindowAccessor { window in
            if let window { hostWindow.window = window }
        })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { note in
            if theaterMode {
                theaterMode = false
                (note.object as? NSWindow)?.toolbar?.isVisible = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            guard let closed = note.object as? NSWindow, closed === hostWindow.window else { return }
            if theaterMode {
                theaterMode = false
                closed.toolbar?.isVisible = true
            }
            showFullscreenDrawer = false
            showQuickSwitcher = false
            closeMiniPlayer()
            player.stop()
        }
        .onDisappear {
            closeMiniPlayer()
            if player.isActive { player.stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .xstreamPlaybackPreferencesChanged)) { _ in
            player.syncPreferencesFromDefaults()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            closeMiniPlayer()
            player.shutdown()
        }
        .task(id: loadKey) { await loadSelected() }
        .onChange(of: currentFilter) { applyFilter() }
        .onChange(of: group) {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                shown = currentBasePool()
            }
        }
        .onChange(of: hdOnly) {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                shown = currentBasePool()
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
        rebuildRecents()
        if group != ChannelIndex.recentsGroup && !index.groups.contains(group) { group = ChannelIndex.allGroup }
        if let playing, index.byID[playing.id] != playing { self.playing = nil }
        if error == nil || error == Self.allHidden {
            error = !allChannels.isEmpty && index.channels.isEmpty ? Self.allHidden : nil
        }
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            shown = currentBasePool()
        }
        searchGeneration += 1
    }

    private func currentBasePool() -> [Channel] {
        let base = index.base(group: group, favorites: favoriteChannels, recents: recentChannels)
        return hdOnly ? base.filter { $0.quality?.isHighDefinition == true } : base
    }

    private func updateShown() async {
        let pool = currentBasePool()
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

    private var hdFilterPill: some View {
        Button {
            hdOnly.toggle()
        } label: {
            Text("HD+")
                .font(.caption2).fontWeight(.semibold)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    hdOnly ? Color.accentColor : Color.primary.opacity(0.08),
                    in: Capsule()
                )
                .foregroundStyle(hdOnly ? .white : .secondary)
        }
        .buttonStyle(.plain)
        .help(hdOnly ? "Showing HD, FHD, RAW & 4K channels only" : "Filter to HD, FHD, RAW & 4K channels")
    }

    @ViewBuilder
    private func quickFilterPill(_ label: String, icon: String? = nil, count: Int? = nil, target: String) -> some View {
        let active = group == target
        Button {
            group = target
        } label: {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.caption2)
                        .foregroundStyle(active ? .white : (target == ChannelIndex.favoritesGroup ? .yellow : .secondary))
                }
                Text(label).font(.caption).fontWeight(active ? .semibold : .regular)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.caption2)
                        .monospacedDigit()
                        .opacity(active ? 0.85 : 0.65)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary.opacity(0.6)),
                in: Capsule()
            )
            .foregroundStyle(active ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var detailPane: some View {
        let inspected = playing ?? player.activeChannel
        if let active = player.activeChannel {
            VStack(spacing: 0) {
                if miniPlayer {
                    HStack(spacing: 10) {
                        Image(systemName: "pip").foregroundStyle(.secondary)
                        Text("Playing **\(active.name)** in Floating Mini-Player")
                            .font(.callout)
                            .lineLimit(1)
                        Spacer()
                        Button("Return to Window") { closeMiniPlayer() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        Button("Stop") {
                            closeMiniPlayer()
                            player.stop()
                        }
                        .controlSize(.small)
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                    .padding(14)

                    if let shownChannel = inspected {
                        ScrollView {
                            channelDetails(shownChannel, isCurrentlyPlaying: shownChannel.id == active.id)
                                .padding([.horizontal, .bottom], 14)
                        }
                    }
                } else if !theaterMode {
                    EmbeddedPlayerView(
                        controller: player,
                        channel: active,
                        theaterMode: $theaterMode,
                        onOpenInVLC: { playInVLC(active) },
                        onToggleFullScreen: toggleFullScreen,
                        onToggleMiniPlayer: toggleMiniPlayer,
                        onPreviousChannel: shown.count > 1 ? { zapChannel(offset: -1) } : nil,
                        onNextChannel: shown.count > 1 ? { zapChannel(offset: 1) } : nil
                    )
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                    .padding(14)

                    if let shownChannel = inspected {
                        ScrollView {
                            channelDetails(shownChannel, isCurrentlyPlaying: shownChannel.id == active.id)
                                .padding([.horizontal, .bottom], 14)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if let playing {
            VStack(spacing: 0) {
                idlePlayerStage(for: playing)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
                    .padding(14)

                ScrollView {
                    channelDetails(playing, isCurrentlyPlaying: false)
                        .padding([.horizontal, .bottom], 14)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if sources.isEmpty {
            welcomeView
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

    private var welcomeView: some View {
        VStack(spacing: 18) {
            Image(systemName: "play.tv")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            VStack(spacing: 6) {
                Text("Welcome to Xstream")
                    .font(.title2).bold()
                Text("Add an Xtream Codes portal or open an M3U playlist to start watching.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
            HStack(spacing: 12) {
                Button {
                    editing = Source(name: "", kind: .xtream(Server()))
                } label: {
                    Label("Add Xtream Server…", systemImage: "antenna.radiowaves.left.and.right")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    importing = true
                } label: {
                    Label("Open M3U Playlist…", systemImage: "doc.text")
                }
                .controlSize(.large)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fullscreenChannelDrawer: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Channels")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showFullscreenDrawer = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)

            HStack(spacing: 6) {
                quickFilterPill("All", target: ChannelIndex.allGroup)
                quickFilterPill("Favorites", icon: "star.fill", count: favoriteChannels.count, target: ChannelIndex.favoritesGroup)
                quickFilterPill("Recent", icon: "clock", count: recentChannels.count, target: ChannelIndex.recentsGroup)
                Spacer(minLength: 0)
                hdFilterPill
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)

            if !index.categoryGroups.isEmpty {
                HStack(spacing: 6) {
                    Picker("", selection: Binding(
                        get: { index.categoryGroups.contains(group) ? group : ChannelIndex.allGroup },
                        set: { group = $0 }
                    )) {
                        Text("All Categories").tag(ChannelIndex.allGroup)
                        Divider()
                        ForEach(index.categoryGroups, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .controlSize(.small)

                    Text(query.trimmingCharacters(in: .whitespaces).isEmpty
                         ? "\(shown.count)"
                         : "\(shown.count) match\(shown.count == 1 ? "" : "es")")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            TextField("Filter channels…", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            Divider()

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(shown) { c in
                        let isCurrent = player.activeChannel?.id == c.id
                        Button {
                            playInBuiltIn(c)
                            player.flashOSD(c.name)
                        } label: {
                            HStack(spacing: 10) {
                                LogoImage(url: c.logo, width: 30, height: 22)
                                    .padding(3)
                                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 5) {
                                        Text(c.name)
                                            .font(.callout)
                                            .fontWeight(isCurrent ? .semibold : .regular)
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                        if let q = c.quality {
                                            QualityBadge(quality: q)
                                        }
                                    }
                                    if let now = guide.now(c) {
                                        Text(now.title)
                                            .font(.caption2)
                                            .foregroundStyle(.white.opacity(0.6))
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 4)
                                if isCurrent {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .font(.caption)
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                isCurrent ? Color.accentColor.opacity(0.25) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 310)
        .frame(maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
        .overlay(alignment: .trailing) {
            Rectangle().fill(.white.opacity(0.12)).frame(width: 1)
        }
    }

    @ViewBuilder
    private func idlePlayerStage(for c: Channel) -> some View {
        let now = guide.now(c)
        ZStack {
            RadialGradient(
                colors: [Color(white: 0.14), Color(white: 0.05)],
                center: .center,
                startRadius: 20,
                endRadius: 500
            )

            VStack(spacing: 14) {
                LogoImage(url: c.logo, width: 72, height: 52, placeholderFont: .largeTitle)
                    .padding(10)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(spacing: 4) {
                    Text(c.name)
                        .font(.title3).bold()
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let now {
                        Text(now.title)
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                    } else {
                        Text(c.group)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        play(c)
                    } label: {
                        Label(defaultPlayer == .builtin ? "Play" : "Play in VLC", systemImage: "play.fill")
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)

                    Button {
                        if defaultPlayer == .builtin { playInVLC(c) } else { playInBuiltIn(c) }
                    } label: {
                        Label(defaultPlayer == .builtin ? "Open in VLC" : "Play in Xstream",
                              systemImage: defaultPlayer == .builtin ? "arrow.up.forward.app" : "play.rectangle")
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .controlSize(.large)
                }
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private func channelDetails(_ c: Channel, isCurrentlyPlaying: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                LogoImage(url: c.logo, width: 48, height: 36, placeholderFont: .title3)
                    .padding(6)
                    .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(c.name).font(.headline).textSelection(.enabled)
                    Text(c.group)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                }

                Spacer()

                HStack(spacing: 8) {
                    if player.activeChannel != nil {
                        Button(isCurrentlyPlaying ? "Reload" : "Play") { playInBuiltIn(c) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .keyboardShortcut(.defaultAction)
                        Button("VLC") { playInVLC(c) }
                            .controlSize(.small)
                    }

                    Button { copyURL(c) } label: {
                        Label(copiedChannelID == c.id ? "Copied" : "Copy URL",
                              systemImage: copiedChannelID == c.id ? "checkmark" : "link")
                    }
                    .controlSize(.small)
                    .help("Copy stream URL (includes portal credentials)")

                    Button { toggleFavorite(c) } label: {
                        Image(systemName: isFavorite(c) ? "star.fill" : "star")
                            .foregroundStyle(isFavorite(c) ? .yellow : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(isFavorite(c) ? "Remove from Favorites" : "Add to Favorites")
                }
            }

            if let playError {
                Text(playError).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }

            GuideView(
                guide: guide,
                channel: c,
                onRefresh: currentServer != nil ? {
                    guard let server = currentServer else { return }
                    Task { await guide.load(c, from: server, force: true) }
                } : nil
            )
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
        recordRecent(c)
        player.play(c)
    }

    private func toggleFullScreen() {
        let entering = !theaterMode
        if entering && miniPlayer { closeMiniPlayer() }
        let window = hostWindow.window ?? NSApp.keyWindow
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

    private func toggleMiniPlayer() {
        if miniPlayer {
            closeMiniPlayer()
            return
        }
        guard let active = player.activeChannel else { return }
        if theaterMode { toggleFullScreen() }
        miniPlayer = true
        miniWindow.show(content: { miniPlayerContent(for: active) }, onClose: {
            miniPlayer = false
        })
    }

    private func closeMiniPlayer() {
        guard miniPlayer else { return }
        miniPlayer = false
        miniWindow.close()
    }

    private func zapChannel(offset: Int) {
        guard !shown.isEmpty else { return }
        let currentID = player.activeChannel?.id ?? playing?.id
        let next: Channel
        if let currentID, let idx = shown.firstIndex(where: { $0.id == currentID }) {
            let target = (idx + offset + shown.count) % shown.count
            next = shown[target]
        } else {
            next = shown[0]
        }
        playInBuiltIn(next)
        player.flashOSD(next.name)
    }

    private func wireMenuBridge() {
        bridge.onTogglePlayPause = { player.togglePlayPause() }
        bridge.onStop = {
            if theaterMode { toggleFullScreen() }
            closeMiniPlayer()
            player.stop()
        }
        bridge.onReloadStream = { player.reload() }
        bridge.onToggleMute = { player.toggleMute() }
        bridge.onPreviousChannel = { zapChannel(offset: -1) }
        bridge.onNextChannel = { zapChannel(offset: 1) }
        bridge.onToggleFullScreen = { toggleFullScreen() }
        bridge.onToggleMiniPlayer = { toggleMiniPlayer() }
        bridge.onToggleDrawer = {
            if theaterMode {
                withAnimation(.easeInOut(duration: 0.2)) { showFullscreenDrawer.toggle() }
            }
        }
        bridge.onQuickSwitch = {
            guard !index.channels.isEmpty else { return }
            withAnimation(.easeOut(duration: 0.14)) { showQuickSwitcher.toggle() }
        }
        bridge.onRefresh = { refreshGeneration += 1 }
    }

    private func syncMenuBridge() {
        bridge.hasActivePlayer = player.isActive
        bridge.isPaused = player.isPaused
        bridge.isMuted = player.isMuted
        bridge.isTheaterMode = theaterMode
        bridge.isMiniPlayer = miniPlayer
        bridge.canZap = player.isActive && shown.count > 1
        bridge.canRefresh = currentSource != nil && !loading
        bridge.canQuickSwitch = !index.channels.isEmpty
    }

    @ViewBuilder
    private func miniPlayerContent(for channel: Channel) -> some View {
        EmbeddedPlayerView(
            controller: player,
            channel: channel,
            theaterMode: .constant(false),
            isMiniPlayer: true,
            onOpenInVLC: { playInVLC(channel) },
            onToggleFullScreen: toggleFullScreen,
            onToggleMiniPlayer: toggleMiniPlayer,
            onPreviousChannel: shown.count > 1 ? { zapChannel(offset: -1) } : nil,
            onNextChannel: shown.count > 1 ? { zapChannel(offset: 1) } : nil
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func playInVLC(_ c: Channel) {
        playing = c
        playError = nil
        recordRecent(c)
        if theaterMode { toggleFullScreen() }
        closeMiniPlayer()
        if player.isActive { player.stop() }
        do { try VLC.play(c.url) } catch { playError = error.localizedDescription }
    }

    private func loadEPG() async {
        guard let playing, let server = currentServer else { return }
        await guide.load(playing, from: server)      // no debounce: the user picked this one
    }

    private var probeBlockedByConnectionLimit: Bool {
        player.isActive && (accountInfo?.maxConnections ?? 2) <= 1
    }

    private func runStreamProbe(for target: Channel? = nil) {
        guard !probeBlockedByConnectionLimit else { return }
        let channel = target
            ?? playing
            ?? index.channels.first(where: { $0.streamID != nil })
            ?? index.channels.first
        guard let channel else { return }

        probeTask?.cancel()
        probingStream = true
        probeError = nil
        probeTask = Task {
            do {
                let result = try await StreamProbe.measure(channel: channel)
                if !Task.isCancelled {
                    probeResult = result
                    probeError = nil
                    probingStream = false
                }
            } catch is CancellationError {
                probingStream = false
            } catch {
                if !Task.isCancelled {
                    probeError = error.localizedDescription
                    probingStream = false
                }
            }
        }
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
        let switchedSource = loadedSourceID != selected
        loadedSourceID = selected
        if switchedSource {
            if theaterMode { toggleFullScreen() }
            closeMiniPlayer()
            player.stop()
            allChannels = []; index = .empty; favoriteNames = []; favoriteChannels = []
            shown = []; group = ChannelIndex.allGroup; playing = nil; accountInfo = nil
            searchGeneration += 1
        }
        error = nil
        guide.clear()
        guard let source = currentSource else {
            allChannels = []; index = .empty; favoriteNames = []; favoriteChannels = []
            shown = []; playing = nil; accountInfo = nil
            return
        }
        let filter = source.filter ?? SourceFilter()

        // Show the last cached channel list immediately so large portals feel instant on launch,
        // then refresh in the background.
        var usedCache = false
        if switchedSource,
           let cached = await ChannelCache.load(sourceID: source.id, live: filter.live, movies: filter.movies),
           !cached.isEmpty, !Task.isCancelled {
            allChannels = cached
            applyFilter()
            usedCache = true
        }

        loading = true
        defer { loading = false }
        do {
            let fresh: [Channel]
            switch source.kind {
            case .xtream(let s):
                async let channelsTask = Xtream.channels(s, live: filter.live, movies: filter.movies)
                async let accountTask: AccountInfo? = try? await Xtream.accountInfo(s)
                fresh = try await channelsTask
                accountInfo = await accountTask
            case .m3u(let path):
                fresh = try await loadM3U(path: path)
            }
            if Task.isCancelled { return }
            allChannels = fresh
            if !fresh.isEmpty {
                ChannelCache.save(fresh, sourceID: source.id, live: filter.live, movies: filter.movies)
                applyFilter()
            } else {
                index = .empty; shown = []; favoriteNames = []; favoriteChannels = []
                error = filter.live || filter.movies ? "No channels found."
                    : "Live TV and Movies are both switched off. Use the filter button to turn one on."
            }
        } catch {
            // A superseded load cancels its URLSession tasks; that is not a failure to report.
            if !Task.isCancelled {
                self.error = usedCache ? "Using cached list — refresh failed: \(error.localizedDescription)"
                    : error.localizedDescription
            }
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
struct QualityBadge: View {
    let quality: ChannelQuality

    private var tint: Color {
        switch quality {
        case .uhd4K: return .purple
        case .raw: return .orange
        case .fhd: return .blue
        case .hd: return .green
        case .sd: return .secondary
        }
    }

    var body: some View {
        Text(quality.rawValue)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .foregroundStyle(tint)
            .fixedSize()
    }
}

/// ContentView's body re-ran the whole channel filter for every EPG reply.
struct ChannelRow: View {
    let channel: Channel
    let guide: Guide
    let server: Server?
    let isFavorite: Bool
    var isPlaying = false
    var onPlay: (() -> Void)? = nil
    var onToggleFavorite: (() -> Void)? = nil

    @State private var hovered = false

    var body: some View {
        let now = guide.now(channel)
        HStack(spacing: 10) {
            LogoImage(url: channel.logo, width: 32, height: 22)
                .padding(3)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(channel.name).lineLimit(1)
                    if let q = channel.quality {
                        QualityBadge(quality: q)
                    }
                }
                if let now {
                    Text(now.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    let total = max(now.stop.timeIntervalSince(now.start), 1)
                    let frac = min(max(guide.clock.timeIntervalSince(now.start) / total, 0), 1)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule().fill(Color.accentColor.opacity(0.75))
                                .frame(width: geo.size.width * frac)
                        }
                    }
                    .frame(height: 2)
                    .padding(.top, 1)
                }
            }
            Spacer(minLength: 4)
            if hovered {
                if let onPlay {
                    Button(action: onPlay) {
                        Image(systemName: "play.fill").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Play")
                }
                if let onToggleFavorite {
                    Button(action: onToggleFavorite) {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .font(.caption)
                            .foregroundStyle(isFavorite ? .yellow : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isFavorite ? "Remove from Favorites" : "Add to Favorites")
                }
            } else {
                if isPlaying {
                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint).font(.caption)
                }
                if isFavorite {
                    Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
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
                Divider().padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("UP NEXT")
                        .font(.caption2).bold()
                        .foregroundStyle(.tertiary)
                    ForEach(shownUpcoming) { p in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(span(p)).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                            Text(p.title).font(.caption).lineLimit(1).foregroundStyle(.primary.opacity(0.85))
                        }
                        .help(p.summary)
                    }
                    if upcoming.count > 2 {
                        Button(showAllUpcoming ? "Show less" : "More upcoming (\(upcoming.count - 2))") {
                            showAllUpcoming.toggle()
                        }
                        .buttonStyle(.link)
                        .font(.caption2)
                        .padding(.top, 2)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func span(_ p: Programme) -> String {
        "\(p.start.formatted(date: .omitted, time: .shortened))–\(p.stop.formatted(date: .omitted, time: .shortened))"
    }
}

/// Compact Xtream subscription summary & stream connection probe pinned at the bottom of the Sources sidebar.
struct AccountFooterView: View {
    let showAccount: Bool
    let info: AccountInfo?
    let loading: Bool
    let onRefresh: () -> Void
    let probeResult: StreamProbeResult?
    let probeError: String?
    let probingStream: Bool
    let canProbe: Bool
    let probeBlockedByLimit: Bool
    let onProbe: () -> Void

    private var statusColor: Color {
        guard let info else { return .secondary }
        if !info.isActive { return .red }
        if let days = info.daysRemaining(), days <= 7 { return days < 0 ? .red : .orange }
        return .green
    }

    private var probeColor: Color {
        guard let probeResult else { return probeError != nil ? .red : .secondary }
        switch probeResult.quality {
        case .good: return .green
        case .fair: return .orange
        case .poor: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showAccount {
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

            if canProbe {
                if showAccount {
                    Divider().padding(.vertical, 3)
                }
                HStack(spacing: 6) {
                    Circle().fill(probeColor).frame(width: 7, height: 7)
                    Text("Stream Server")
                        .font(.caption).bold()
                    Spacer()
                    if probingStream {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button("Test", action: onProbe)
                            .buttonStyle(.link)
                            .font(.caption2)
                            .disabled(probeBlockedByLimit)
                            .help(probeBlockedByLimit
                                  ? "Stop playback first — your account allows 1 active connection"
                                  : "Measure ping & throughput to the actual stream server")
                    }
                }
                if probeBlockedByLimit {
                    Text("Stop playback to test (1-conn limit)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let r = probeResult {
                    let jitterStr = r.jitterMs > 0 ? " (±\(r.jitterMs))" : ""
                    Text(String(format: "%.1f Mbps · %d ms%@", r.throughputMbps, r.pingMs, jitterStr))
                        .font(.caption2).monospacedDigit()
                        .foregroundStyle(.primary.opacity(0.9))
                    Text(r.resolvedHost)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help("Tested via \(r.channelName) · TTFB \(r.ttfbMs) ms")
                } else if let probeError {
                    Text(probeError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else {
                    Text(probingStream ? "Measuring stream throughput…" : "Tap Test to check stream speed")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.primary.opacity(0.06), lineWidth: 1)
        )
        .padding(8)
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

/// Downsamples channel logos to thumbnail pixel size off the main thread and keeps a bounded
/// in-memory cache so scrolling 30k-channel lists doesn't decode full-res PNGs on every row.
final class LogoCache: @unchecked Sendable {
    static let shared = LogoCache()

    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 500
        c.totalCostLimit = 30_000_000
        return c
    }()

    private func key(_ url: URL, _ maxPixelSize: Int) -> NSString {
        "\(maxPixelSize)|\(url.absoluteString)" as NSString
    }

    func cached(for url: URL, maxPixelSize: Int) -> NSImage? {
        cache.object(forKey: key(url, maxPixelSize))
    }

    func image(for url: URL, maxPixelSize: Int) async -> NSImage? {
        let k = key(url, maxPixelSize)
        if let hit = cache.object(forKey: k) { return hit }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
              !Task.isCancelled else { return nil }

        let downsampled: (NSImage, Int)? = await Task.detached(priority: .utility) {
            Self.downsample(data: data, maxPixelSize: maxPixelSize)
        }.value
        guard let (img, cost) = downsampled, !Task.isCancelled else { return nil }
        cache.setObject(img, forKey: k, cost: cost)
        return img
    }

    private static func downsample(data: Data, maxPixelSize: Int) -> (NSImage, Int)? {
        let sourceOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, sourceOpts) else { return nil }
        let thumbOpts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        return (img, cg.width * cg.height * 4)
    }
}

struct LogoImage: View {
    let url: URL?
    let width: CGFloat
    let height: CGFloat
    var placeholderFont: Font = .body

    @State private var image: NSImage?

    private var maxPixelSize: Int { Int(max(width, height) * 2) }

    var body: some View {
        Group {
            if let image = image ?? url.flatMap({ LogoCache.shared.cached(for: $0, maxPixelSize: maxPixelSize) }) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "tv")
                    .font(placeholderFont)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: width, height: height)
        .task(id: url) {
            guard let url else { image = nil; return }
            if let hit = LogoCache.shared.cached(for: url, maxPixelSize: maxPixelSize) {
                image = hit
                return
            }
            image = nil
            image = await LogoCache.shared.image(for: url, maxPixelSize: maxPixelSize)
        }
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

/// Non-owning box for the main NSWindow so ContentView can match its own close notification
/// without retaining the window or triggering SwiftUI view updates.
private final class WeakWindowBox {
    weak var window: NSWindow?
}

/// Captures the hosting NSWindow so ContentView can distinguish its own close events
/// from sheets, alerts, or the floating mini-player panel.
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    final class ProbeView: NSView {
        var onResolve: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onResolve?(window)
        }
    }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onResolve = onResolve
        if let window = nsView.window { onResolve(window) }
    }
}

/// Spotlight-style floating channel switcher (⌘K) that searches across all categories
/// in both windowed mode and fullscreen.
struct QuickChannelSwitcher: View {
    let channels: [Channel]
    let recents: [Channel]
    let favorites: [Channel]
    let favoriteNames: Set<String>
    let activeChannelID: Channel.ID?
    let guide: Guide
    let onSelect: (Channel) -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var results: [Channel] = []
    @State private var highlightedIndex = 0
    @FocusState private var searchFocused: Bool

    private static let maxResults = 40

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.65))
                    TextField("Jump to channel…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .foregroundStyle(.white)
                        .focused($searchFocused)
                        .onSubmit { selectHighlighted() }
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        .buttonStyle(.plain)
                    }
                    Text("⌘K")
                        .font(.caption2).fontWeight(.medium)
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)

                Divider().overlay(.white.opacity(0.12))

                if results.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "tv.slash")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.4))
                        Text("No matching channels")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(results.enumerated()), id: \.element.id) { idx, c in
                                    let isSelected = idx == highlightedIndex
                                    let isCurrent = c.id == activeChannelID
                                    let isFav = favoriteNames.contains(c.name)
                                    Button {
                                        onSelect(c)
                                    } label: {
                                        HStack(spacing: 10) {
                                            LogoImage(url: c.logo, width: 32, height: 22)
                                                .padding(3)
                                                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                                            VStack(alignment: .leading, spacing: 2) {
                                                HStack(spacing: 5) {
                                                    Text(c.name)
                                                        .font(.callout)
                                                        .fontWeight(isSelected || isCurrent ? .semibold : .regular)
                                                        .foregroundStyle(.white)
                                                        .lineLimit(1)
                                                    if let q = c.quality {
                                                        QualityBadge(quality: q)
                                                    }
                                                }
                                                HStack(spacing: 5) {
                                                    Text(c.group)
                                                        .font(.caption2)
                                                        .foregroundStyle(.white.opacity(0.55))
                                                        .lineLimit(1)
                                                    if let now = guide.now(c) {
                                                        Text("· \(now.title)")
                                                            .font(.caption2)
                                                            .foregroundStyle(.white.opacity(0.7))
                                                            .lineLimit(1)
                                                    }
                                                }
                                            }
                                            Spacer(minLength: 4)
                                            if isCurrent {
                                                Image(systemName: "speaker.wave.2.fill")
                                                    .font(.caption)
                                                    .foregroundStyle(Color.accentColor)
                                            }
                                            if isFav {
                                                Image(systemName: "star.fill")
                                                    .font(.caption2)
                                                    .foregroundStyle(.yellow)
                                            }
                                            if isSelected {
                                                Image(systemName: "return")
                                                    .font(.caption2)
                                                    .foregroundStyle(.white.opacity(0.65))
                                            }
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 7)
                                        .background(
                                            isSelected ? Color.accentColor.opacity(0.32) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        )
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .id(c.id)
                                    .onHover { over in
                                        if over { highlightedIndex = idx }
                                    }
                                }
                            }
                            .padding(8)
                        }
                        .frame(maxHeight: 360)
                        .onChange(of: highlightedIndex) { _, idx in
                            guard results.indices.contains(idx) else { return }
                            proxy.scrollTo(results[idx].id, anchor: .center)
                        }
                    }
                }

                Divider().overlay(.white.opacity(0.12))

                HStack {
                    Text(query.trimmingCharacters(in: .whitespaces).isEmpty
                         ? (recents.isEmpty && favorites.isEmpty ? "All Channels" : "Recent & Favorites")
                         : "\(results.count)\(results.count == Self.maxResults ? "+" : "") matches")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                    Spacer()
                    Text("↑↓ Navigate  ·  ↩ Play  ·  ⎋ Close")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.45))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
            }
            .frame(width: 440)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .environment(\.colorScheme, .dark)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.16), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.55), radius: 28, y: 12)
            .padding(.top, 12)
            .padding(.trailing, 14)
        }
        .onAppear {
            searchFocused = true
            results = defaultResults()
            highlightedIndex = 0
        }
        .task(id: query) {
            await runSearch()
        }
        .onKeyPress(.downArrow) {
            guard !results.isEmpty else { return .ignored }
            highlightedIndex = (highlightedIndex + 1) % results.count
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard !results.isEmpty else { return .ignored }
            highlightedIndex = (highlightedIndex - 1 + results.count) % results.count
            return .handled
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
    }

    private func selectHighlighted() {
        guard results.indices.contains(highlightedIndex) else { return }
        onSelect(results[highlightedIndex])
    }

    private func defaultResults() -> [Channel] {
        var seen = Set<Channel.ID>()
        var combined: [Channel] = []
        for c in recents where seen.insert(c.id).inserted {
            combined.append(c)
            if combined.count >= Self.maxResults { return combined }
        }
        for c in favorites where seen.insert(c.id).inserted {
            combined.append(c)
            if combined.count >= Self.maxResults { return combined }
        }
        if combined.isEmpty {
            return Array(channels.prefix(Self.maxResults))
        }
        return combined
    }

    private func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = defaultResults()
            highlightedIndex = 0
            return
        }
        let all = channels
        let favs = favoriteNames
        let limit = Self.maxResults
        if all.count > 2_000 {
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return }
        }
        let task = Task.detached(priority: .userInitiated) {
            Self.rankMatches(in: all, query: trimmed, favoriteNames: favs, limit: limit)
        }
        let found = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard !Task.isCancelled else { return }
        results = found
        highlightedIndex = 0
    }

    private nonisolated static func rankMatches(in channels: [Channel],
                                              query: String,
                                              favoriteNames: Set<String>,
                                              limit: Int) -> [Channel] {
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }
        let firstToken = tokens[0]
        var prefixFav: [Channel] = []
        var prefixOther: [Channel] = []
        var nameFav: [Channel] = []
        var nameOther: [Channel] = []
        var groupOnly: [Channel] = []

        for c in channels {
            if Task.isCancelled { return [] }
            let matchesAll = tokens.allSatisfy { tok in
                c.name.localizedCaseInsensitiveContains(tok) || c.group.localizedCaseInsensitiveContains(tok)
            }
            guard matchesAll else { continue }
            let isFav = favoriteNames.contains(c.name)
            if c.name.range(of: firstToken, options: [.caseInsensitive, .anchored]) != nil {
                if isFav { prefixFav.append(c) } else { prefixOther.append(c) }
            } else if c.name.localizedCaseInsensitiveContains(firstToken) {
                if isFav { nameFav.append(c) } else { nameOther.append(c) }
            } else {
                groupOnly.append(c)
            }
        }

        var out: [Channel] = []
        out.reserveCapacity(limit)
        for bucket in [prefixFav, prefixOther, nameFav, nameOther, groupOnly] {
            for c in bucket {
                out.append(c)
                if out.count >= limit { return out }
            }
        }
        return out
    }
}
