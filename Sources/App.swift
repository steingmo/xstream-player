import SwiftUI
import AVKit

@main
struct XstreamApp: App {
    var body: some Scene {
        WindowGroup("Xstream") { ContentView() }
            .defaultSize(width: 1200, height: 720)
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
    @State private var player = AVPlayer()
    @State private var playerError: String?
    @State private var remuxing = false
    /// "" = built-in AVPlayer, otherwise an External.bundleID.
    @AppStorage("externalPlayer") private var externalPlayer = External.defaultChoice

    private var groups: [String] { ["All"] + Set(channels.map(\.group)).sorted() }

    private var shown: [Channel] {
        channels.filter {
            (group == "All" || $0.group == group)
                && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
        }
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
                HStack {
                    Picker("", selection: $group) {
                        ForEach(groups, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("", selection: $externalPlayer) {
                        Text("Built-in").tag("")
                        ForEach(External.installed) { Text($0.name).tag($0.id) }
                    }
                    .frame(width: 110)
                }
                .labelsHidden().padding(6)
                List(shown, selection: Binding(get: { playing?.id }, set: { id in
                    if let c = shown.first(where: { $0.id == id }) { play(c) }
                })) { c in
                    HStack {
                        AsyncImage(url: c.logo) { $0.resizable().scaledToFit() }
                            placeholder: { Image(systemName: "tv").foregroundStyle(.secondary) }
                            .frame(width: 32, height: 24)
                        Text(c.name).lineLimit(1)
                    }.tag(c.id)
                }
            }
            .searchable(text: $query, placement: .toolbar, prompt: "Search channels")
            .navigationSplitViewColumnWidth(min: 240, ideal: 320)
        } detail: {
            PlayerView(player: player)
                .background(.black)
                .safeAreaInset(edge: .bottom) {
                    if let playing {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(playing.name).font(.headline).lineLimit(1)
                                Spacer()
                                Menu("Open in") {
                                    ForEach(External.installed) { ext in
                                        Button(ext.name) { ext.play(playing.url) }
                                    }
                                }
                                .frame(width: 90)
                                Button("Copy URL") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(playing.url.absoluteString, forType: .string)
                                }
                            }
                            if let playerError {
                                Text(playerError).font(.caption).foregroundStyle(.red)
                                    .textSelection(.enabled)
                            }
                            Text(playing.url.absoluteString).font(.caption2)
                                .foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                        }
                        .padding(8)
                        .background(.bar)
                    }
                }
        }
        .onAppear { if selected == nil { selected = sources.first?.id } }
        .task(id: selected) { await loadSelected() }
        .task(id: playing?.id) { await watchPlayback() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.willTerminateNotification)) { _ in Remux.stop() }
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

    // Many IPTV panels 403 the default CFNetwork agent but serve any "player" UA.
    private static let userAgent = "VLC/3.0.20 LibVLC/3.0.20"

    private func play(_ c: Channel) {
        Remux.stop()
        playing = c
        playerError = nil
        remuxing = false
        // Raw MPEG-TS never plays natively, so don't waste a failed attempt on it.
        if let ext = External.installed.first(where: { $0.id == externalPlayer }) {
            ext.play(c.url)          // VLC/Infuse handle redirects and TS themselves
            return
        }
        Task {
            let url = await resolveStream(c.url, userAgent: Self.userAgent)
            guard playing?.id == c.id else { return }          // user moved on
            // Raw MPEG-TS never plays natively, so don't waste a failed attempt on it.
            if url.pathExtension.lowercased() == "ts" { await playViaRemux(url) } else { open(url) }
        }
    }

    private func open(_ url: URL) {
        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": Self.userAgent]
        ])
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        player.play()
    }

    private func playViaRemux(_ source: URL) async {
        remuxing = true
        playerError = "Remuxing MPEG-TS with ffmpeg…"
        do {
            open(try await Remux.start(source, userAgent: Self.userAgent))
            playerError = nil
        } catch {
            playerError = error.localizedDescription
        }
    }

    /// Poll the item instead of wiring up KVO — a stalled IPTV stream is the normal case
    /// here and the user needs to be told which way it failed.
    private func watchPlayback() async {
        guard let playing, externalPlayer.isEmpty else { return }
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(250))
            if remuxing { return }                                  // remux path reports itself
            if player.currentItem?.status == .readyToPlay { playerError = nil; return }
            if let e = player.currentItem?.error ?? player.error {
                await failed(playing, e.localizedDescription)
                return
            }
        }
        await failed(playing, "Stream never became ready (server stalled).")
    }

    /// HLS failed — on Xtream the same channel is also served as raw .ts, which ffmpeg can
    /// repackage. Try that once before giving up.
    private func failed(_ c: Channel, _ reason: String) async {
        if let ts = tsVariant(c.url) {
            await playViaRemux(ts)
            if playerError != nil { playerError = "\(reason) Retried as MPEG-TS: \(playerError!)" }
        } else {
            playerError = reason
        }
    }

    private func loadSelected() async {
        guard let source = sources.first(where: { $0.id == selected }) else { return }
        loading = true; error = nil; channels = []; group = "All"
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

/// SwiftUI's VideoPlayer sizes itself to the video and overflows the pane; AVPlayerView
/// lays out correctly and brings the full native controls (fullscreen, PiP, AirPlay).
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .floating
        v.showsFullScreenToggleButton = true
        v.allowsPictureInPicturePlayback = true
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) { v.player = player }
}
