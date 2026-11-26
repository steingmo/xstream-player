import AppKit
import Libmpv
import QuartzCore
import SwiftUI

// MARK: - Preferences

enum PlaybackTarget: String, CaseIterable, Identifiable {
    case builtin
    case vlc

    var id: String { rawValue }
    var label: String {
        switch self {
        case .builtin: return "Built-in (MPV)"
        case .vlc: return "VLC"
        }
    }
}

struct MediaTrack: Identifiable, Hashable {
    let id: Int
    let title: String
    let selected: Bool
}

// MARK: - MoltenVK Metal Layer

/// CAMetalLayer with MoltenVK workarounds: ignore transient 1x1 drawableSize resets
/// (prevents flicker) and ensure EDR toggles happen on the main thread.
final class MPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }

    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread {
                super.wantsExtendedDynamicRangeContent = newValue
            } else {
                DispatchQueue.main.sync {
                    super.wantsExtendedDynamicRangeContent = newValue
                }
            }
        }
    }
}

// MARK: - MPV Player Controller

@MainActor
@Observable
final class PlayerController {
    private static let volumeKey = "playerVolume"
    private static let mutedKey = "playerMuted"

    private(set) var activeChannel: Channel?
    private(set) var isLoading = false
    private(set) var isBuffering = false
    private(set) var isPaused = false
    private(set) var isSeekable = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var videoInfo: String?
    private(set) var audioTracks: [MediaTrack] = []
    private(set) var subtitleTracks: [MediaTrack] = []
    private(set) var errorMessage: String?

    var volume: Double {
        didSet {
            let clamped = min(max(volume, 0), 100)
            if clamped != volume { volume = clamped; return }
            UserDefaults.standard.set(clamped, forKey: Self.volumeKey)
            setDouble("volume", clamped)
        }
    }

    var isMuted: Bool {
        didSet {
            UserDefaults.standard.set(isMuted, forKey: Self.mutedKey)
            setFlag("mute", isMuted)
        }
    }

    var isActive: Bool { activeChannel != nil }
    var isPlaying: Bool { isActive && !isPaused && !isLoading && errorMessage == nil }

    @ObservationIgnored private let mpvQueue = DispatchQueue(label: "com.steingrimosa.xstream.mpv", qos: .userInitiated)
    @ObservationIgnored private nonisolated(unsafe) var mpv: OpaquePointer?
    @ObservationIgnored private var attachedLayer: MPVMetalLayer?
    @ObservationIgnored private var pendingURL: URL?
    @ObservationIgnored private var lastPosUpdate: TimeInterval = 0
    @ObservationIgnored private var videoHeight: Int64 = 0
    @ObservationIgnored private var videoCodec: String?
    @ObservationIgnored private var lastErrorLog: String?

    init() {
        let savedVol = UserDefaults.standard.object(forKey: Self.volumeKey) as? Double ?? 80
        self.volume = min(max(savedVol, 0), 100)
        self.isMuted = UserDefaults.standard.bool(forKey: Self.mutedKey)
    }

    func attach(to layer: MPVMetalLayer) {
        if attachedLayer === layer && mpv != nil { return }
        attachedLayer = layer
        if mpv != nil {
            shutdown()
        }
        initializeMPV(layer: layer)
        if let url = pendingURL {
            pendingURL = nil
            sendLoadFile(url)
        }
    }

    func play(_ channel: Channel) {
        activeChannel = channel
        isLoading = true
        isBuffering = false
        isPaused = false
        isSeekable = false
        position = 0
        duration = 0
        videoInfo = nil
        videoHeight = 0
        videoCodec = nil
        audioTracks = []
        subtitleTracks = []
        errorMessage = nil
        lastErrorLog = nil

        if mpv != nil {
            sendLoadFile(channel.url)
        } else {
            pendingURL = channel.url
        }
    }

    func retry() {
        guard let ch = activeChannel else { return }
        play(ch)
    }

    func togglePlayPause() {
        guard isActive else { return }
        setFlag("pause", !isPaused)
    }

    func pause() {
        guard isActive else { return }
        setFlag("pause", true)
    }

    func stop() {
        activeChannel = nil
        pendingURL = nil
        isLoading = false
        isBuffering = false
        isPaused = false
        isSeekable = false
        position = 0
        duration = 0
        videoInfo = nil
        videoHeight = 0
        videoCodec = nil
        audioTracks = []
        subtitleTracks = []
        errorMessage = nil
        lastErrorLog = nil
        command("stop")
    }

    func seek(to seconds: Double) {
        guard isSeekable else { return }
        let clamped = min(max(seconds, 0), max(duration, 0))
        position = clamped
        command("seek", args: [String(clamped), "absolute"])
    }

    func seek(by delta: Double) {
        guard isSeekable else { return }
        command("seek", args: [String(delta), "relative"])
    }

    func toggleMute() {
        isMuted.toggle()
    }

    func selectAudio(id: Int) {
        setString("aid", String(id))
    }

    func selectSubtitle(id: Int?) {
        setString("sid", id.map(String.init) ?? "no")
    }

    func shutdown() {
        let queue = mpvQueue
        queue.sync {
            guard let handle = self.mpv else { return }
            mpv_set_wakeup_callback(handle, nil, nil)
            mpv_terminate_destroy(handle)
            self.mpv = nil
        }
        attachedLayer = nil
    }

    // MARK: - libmpv Setup & Commands

    private func initializeMPV(layer: MPVMetalLayer) {
        guard let handle = mpv_create() else {
            errorMessage = "Failed to initialize video engine."
            return
        }

        // Capture errors so stream failures show real diagnostics instead of a black box.
        mpv_request_log_messages(handle, "error")

        // Disable libmpv's built-in LuaJIT scripts and user config: Xstream renders its own
        // SwiftUI HUD, and LuaJIT's runtime JIT compilation triggers SIGKILL (CODESIGNING
        // Invalid Page) under macOS Hardened Runtime.
        mpv_set_option_string(handle, "config", "no")
        mpv_set_option_string(handle, "load-scripts", "no")
        mpv_set_option_string(handle, "load-stats-overlay", "no")
        mpv_set_option_string(handle, "load-console", "no")
        mpv_set_option_string(handle, "load-osd-console", "no")
        mpv_set_option_string(handle, "load-auto-profiles", "no")
        mpv_set_option_string(handle, "load-commands", "no")
        mpv_set_option_string(handle, "load-context-menu", "no")
        mpv_set_option_string(handle, "load-positioning", "no")
        mpv_set_option_string(handle, "load-select", "no")
        mpv_set_option_string(handle, "osc", "no")
        mpv_set_option_string(handle, "ytdl", "no")

        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &wid)
        mpv_set_option_string(handle, "vo", "gpu-next")
        mpv_set_option_string(handle, "gpu-api", "vulkan")
        mpv_set_option_string(handle, "gpu-context", "moltenvk")
        mpv_set_option_string(handle, "hwdec", "videotoolbox")
        mpv_set_option_string(handle, "keep-open", "no")
        mpv_set_option_string(handle, "cache", "yes")
        mpv_set_option_string(handle, "demuxer-max-bytes", "64MiB")
        mpv_set_option_string(handle, "demuxer-readahead-secs", "20")
        mpv_set_option_string(handle, "network-timeout", "15")
        mpv_set_option_string(handle, "tls-verify", "no")
        mpv_set_option_string(handle, "user-agent", "VLC/3.0.21 LibVLC/3.0.21")
        mpv_set_option_string(handle, "subs-match-os-language", "yes")
        mpv_set_option_string(handle, "subs-fallback", "yes")
        mpv_set_option_string(handle, "input-media-keys", "no")
        mpv_set_option_string(handle, "volume", String(Int(volume)))
        mpv_set_option_string(handle, "mute", isMuted ? "yes" : "no")

        let status = mpv_initialize(handle)
        guard status >= 0 else {
            let err = String(cString: mpv_error_string(status))
            mpv_terminate_destroy(handle)
            errorMessage = "Video engine failed to start: \(err)"
            return
        }

        mpv_observe_property(handle, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 0, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 0, "seekable", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 0, "video-params/h", MPV_FORMAT_INT64)
        mpv_observe_property(handle, 0, "video-codec", MPV_FORMAT_STRING)
        mpv_observe_property(handle, 0, "track-list/count", MPV_FORMAT_INT64)
        mpv_observe_property(handle, 0, "aid", MPV_FORMAT_STRING)
        mpv_observe_property(handle, 0, "sid", MPV_FORMAT_STRING)

        mpv = handle

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        mpv_set_wakeup_callback(handle, { rawCtx in
            guard let rawCtx else { return }
            let controller = Unmanaged<PlayerController>.fromOpaque(rawCtx).takeUnretainedValue()
            controller.drainEvents()
        }, ctx)
    }

    private func sendLoadFile(_ url: URL) {
        setFlag("pause", false)
        command("loadfile", args: [url.absoluteString, "replace"])
    }

    private func setFlag(_ name: String, _ value: Bool) {
        mpvQueue.async { [weak self] in
            guard let handle = self?.mpv else { return }
            var flag: CInt = value ? 1 : 0
            mpv_set_property(handle, name, MPV_FORMAT_FLAG, &flag)
        }
    }

    private func setDouble(_ name: String, _ value: Double) {
        mpvQueue.async { [weak self] in
            guard let handle = self?.mpv else { return }
            var v = value
            mpv_set_property(handle, name, MPV_FORMAT_DOUBLE, &v)
        }
    }

    private func setString(_ name: String, _ value: String) {
        mpvQueue.async { [weak self] in
            guard let handle = self?.mpv else { return }
            mpv_set_property_string(handle, name, value)
        }
    }

    private func command(_ name: String, args: [String] = []) {
        mpvQueue.async { [weak self] in
            guard let handle = self?.mpv else { return }
            var cStrings: [UnsafeMutablePointer<CChar>?] = ([name] + args).map { strdup($0) }
            cStrings.append(nil)
            defer {
                for p in cStrings where p != nil { free(p) }
            }
            var constPtrs = cStrings.map { UnsafePointer<CChar>($0) }
            mpv_command(handle, &constPtrs)
        }
    }

    // MARK: - Event Loop

    private nonisolated func drainEvents() {
        mpvQueue.async { [weak self] in
            guard let self else { return }
            while let handle = self.mpv {
                guard let event = mpv_wait_event(handle, 0) else { break }
                let id = event.pointee.event_id
                if id == MPV_EVENT_NONE { break }

                switch id {
                case MPV_EVENT_START_FILE:
                    Task { @MainActor [weak self] in
                        guard let self, self.isActive else { return }
                        self.isLoading = true
                        self.errorMessage = nil
                    }

                case MPV_EVENT_FILE_LOADED:
                    let tracks = Self.readTracks(handle)
                    Task { @MainActor [weak self] in
                        guard let self, self.isActive else { return }
                        self.isLoading = false
                        self.audioTracks = tracks.audio
                        self.subtitleTracks = tracks.subtitles
                    }

                case MPV_EVENT_PLAYBACK_RESTART:
                    Task { @MainActor [weak self] in
                        guard let self, self.isActive else { return }
                        self.isLoading = false
                        self.isBuffering = false
                    }

                case MPV_EVENT_END_FILE:
                    if let data = event.pointee.data {
                        let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                        if end.reason == MPV_END_FILE_REASON_ERROR {
                            let errText = String(cString: mpv_error_string(end.error))
                            Task { @MainActor [weak self] in
                                guard let self, self.isActive else { return }
                                self.isLoading = false
                                self.isBuffering = false
                                if let detail = self.lastErrorLog, !detail.isEmpty {
                                    self.errorMessage = "\(errText) — \(detail)"
                                } else {
                                    self.errorMessage = "Could not play stream (\(errText))."
                                }
                            }
                        } else if end.reason == MPV_END_FILE_REASON_EOF {
                            Task { @MainActor [weak self] in
                                guard let self, self.isActive else { return }
                                self.isLoading = false
                                self.isBuffering = false
                                self.isPaused = true
                            }
                        }
                    }

                case MPV_EVENT_LOG_MESSAGE:
                    if let data = event.pointee.data {
                        let msg = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                        if let textPtr = msg.text {
                            let line = String(cString: textPtr).trimmingCharacters(in: .whitespacesAndNewlines)
                            if !line.isEmpty {
                                Task { @MainActor [weak self] in self?.lastErrorLog = line }
                            }
                        }
                    }

                case MPV_EVENT_PROPERTY_CHANGE:
                    guard let data = event.pointee.data else { break }
                    let prop = data.assumingMemoryBound(to: mpv_event_property.self).pointee
                    let name = String(cString: prop.name)
                    self.handleProperty(name: name, prop: prop, handle: handle)

                case MPV_EVENT_SHUTDOWN:
                    mpv_terminate_destroy(handle)
                    self.mpv = nil
                    return

                default:
                    break
                }
            }
        }
    }

    private nonisolated func handleProperty(name: String, prop: mpv_event_property, handle: OpaquePointer) {
        switch name {
        case "pause":
            guard prop.format == MPV_FORMAT_FLAG, let ptr = prop.data else { return }
            let val = ptr.assumingMemoryBound(to: CInt.self).pointee != 0
            Task { @MainActor [weak self] in self?.isPaused = val }

        case "paused-for-cache":
            guard prop.format == MPV_FORMAT_FLAG, let ptr = prop.data else { return }
            let val = ptr.assumingMemoryBound(to: CInt.self).pointee != 0
            Task { @MainActor [weak self] in self?.isBuffering = val }

        case "seekable":
            guard prop.format == MPV_FORMAT_FLAG, let ptr = prop.data else { return }
            let val = ptr.assumingMemoryBound(to: CInt.self).pointee != 0
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isSeekable = val && self.duration > 10
            }

        case "duration":
            let val: Double = (prop.format == MPV_FORMAT_DOUBLE && prop.data != nil)
                ? prop.data!.assumingMemoryBound(to: Double.self).pointee
                : 0
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.duration = val.isFinite && val > 0 ? val : 0
                if self.duration <= 10 { self.isSeekable = false }
            }

        case "time-pos":
            guard prop.format == MPV_FORMAT_DOUBLE, let ptr = prop.data else { return }
            let val = ptr.assumingMemoryBound(to: Double.self).pointee
            guard val.isFinite && val >= 0 else { return }
            let now = Date.timeIntervalSinceReferenceDate
            Task { @MainActor [weak self] in
                guard let self else { return }
                if now - self.lastPosUpdate >= 0.4 {
                    self.lastPosUpdate = now
                    self.position = val
                }
            }

        case "video-params/h":
            guard prop.format == MPV_FORMAT_INT64, let ptr = prop.data else { return }
            let h = ptr.assumingMemoryBound(to: Int64.self).pointee
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.videoHeight = h
                self.updateVideoInfo()
            }

        case "video-codec":
            guard prop.format == MPV_FORMAT_STRING, let ptr = prop.data,
                  let cstr = ptr.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee else { return }
            let raw = String(cString: cstr)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.videoCodec = Self.shortCodec(raw)
                self.updateVideoInfo()
            }

        case "track-list/count", "aid", "sid":
            let tracks = Self.readTracks(handle)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.audioTracks = tracks.audio
                self.subtitleTracks = tracks.subtitles
            }

        default:
            break
        }
    }

    private func updateVideoInfo() {
        var parts: [String] = []
        if videoHeight > 0 { parts.append("\(videoHeight)p") }
        if let videoCodec, !videoCodec.isEmpty { parts.append(videoCodec) }
        videoInfo = parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private nonisolated static func shortCodec(_ raw: String) -> String? {
        let lower = raw.lowercased()
        if lower.contains("hevc") || lower.contains("h265") || lower.contains("h.265") { return "HEVC" }
        if lower.contains("h264") || lower.contains("h.264") || lower.contains("avc") { return "H.264" }
        if lower.contains("av1") { return "AV1" }
        if lower.contains("vp9") { return "VP9" }
        if lower.contains("mpeg2") { return "MPEG-2" }
        return raw.split(separator: " ").first.map(String.init)
    }

    private nonisolated static func getString(_ handle: OpaquePointer, _ name: String) -> String? {
        guard let cstr = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(cstr) }
        return String(cString: cstr)
    }

    private nonisolated static func readTracks(_ handle: OpaquePointer) -> (audio: [MediaTrack], subtitles: [MediaTrack]) {
        var count: Int64 = 0
        guard mpv_get_property(handle, "track-list/count", MPV_FORMAT_INT64, &count) >= 0, count > 0 else {
            return ([], [])
        }
        var audio: [MediaTrack] = []
        var subs: [MediaTrack] = []
        for i in 0..<Int(count) {
            guard let type = getString(handle, "track-list/\(i)/type"),
                  type == "audio" || type == "sub" else { continue }
            var id: Int64 = 0
            mpv_get_property(handle, "track-list/\(i)/id", MPV_FORMAT_INT64, &id)
            var sel: CInt = 0
            mpv_get_property(handle, "track-list/\(i)/selected", MPV_FORMAT_FLAG, &sel)
            let title = getString(handle, "track-list/\(i)/title")
            let lang = getString(handle, "track-list/\(i)/lang")
            let codec = getString(handle, "track-list/\(i)/codec")

            var parts: [String] = []
            if let title, !title.isEmpty { parts.append(title) }
            if let lang, !lang.isEmpty, !(title?.localizedCaseInsensitiveContains(lang) ?? false) {
                parts.append(lang.uppercased())
            }
            if parts.isEmpty { parts.append("Track \(id)") }
            if let codec, !codec.isEmpty { parts.append("(\(codec.uppercased()))") }

            let track = MediaTrack(id: Int(id), title: parts.joined(separator: " "), selected: sel != 0)
            if type == "audio" { audio.append(track) } else { subs.append(track) }
        }
        return (audio, subs)
    }
}

// MARK: - NSView Video Surface

final class MPVHostView: NSView {
    let metalLayer = MPVMetalLayer()
    var onDoubleClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = NSColor.black.cgColor
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        layer = metalLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        } else {
            super.mouseDown(with: event)
        }
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        metalLayer.contentsScale = scale
        metalLayer.frame = bounds
        let w = bounds.width * scale
        let h = bounds.height * scale
        if w > 1 && h > 1 {
            metalLayer.drawableSize = CGSize(width: w, height: h)
        }
    }
}

struct MPVVideoSurface: NSViewRepresentable {
    let controller: PlayerController
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> MPVHostView {
        let view = MPVHostView()
        view.onDoubleClick = onDoubleClick
        controller.attach(to: view.metalLayer)
        return view
    }

    func updateNSView(_ nsView: MPVHostView, context: Context) {
        nsView.onDoubleClick = onDoubleClick
    }
}

// MARK: - Embedded Player Stage & HUD

struct EmbeddedPlayerView: View {
    let controller: PlayerController
    let channel: Channel
    @Binding var theaterMode: Bool
    let onOpenInVLC: () -> Void

    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var isScrubbing = false
    @State private var scrubPosition: Double = 0

    private var controlsVisible: Bool {
        showControls || !controller.isPlaying || controller.isLoading || controller.isBuffering || controller.errorMessage != nil
    }

    var body: some View {
        ZStack {
            Color.black
            MPVVideoSurface(controller: controller) {
                withAnimation(.easeInOut(duration: 0.2)) { theaterMode.toggle() }
            }

            // Center state overlay (loading, buffering, or error)
            if let error = controller.errorMessage {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title)
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .frame(maxWidth: 420)
                    HStack(spacing: 10) {
                        Button("Retry") { controller.retry() }
                            .buttonStyle(.borderedProminent)
                        Button("Open in VLC") { onOpenInVLC() }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(20)
                .background(.ultraThinMaterial.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
            } else if controller.isLoading || controller.isBuffering {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(controller.isLoading ? "Connecting…" : "Buffering…")
                        .font(.callout)
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.black.opacity(0.65), in: Capsule())
            }

            // Auto-hiding HUD
            if controlsVisible {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    bottomBar
                }
                .transition(.opacity)
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                revealControls()
            case .ended:
                scheduleHide()
            }
        }
        .onChange(of: controller.isPlaying) { _, playing in
            if playing { scheduleHide() } else { showControls = true; hideTask?.cancel() }
        }
        .onDisappear { hideTask?.cancel() }
        .onKeyPress(.escape) {
            guard theaterMode else { return .ignored }
            withAnimation(.easeInOut(duration: 0.2)) { theaterMode = false }
            return .handled
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Text(channel.name)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)

            if channel.streamID != nil {
                HStack(spacing: 4) {
                    Circle().fill(.red).frame(width: 6, height: 6)
                    Text("LIVE").font(.caption2).bold()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.black.opacity(0.5), in: Capsule())
            }

            if let info = controller.videoInfo {
                Text(info)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.45), in: Capsule())
            }

            Spacer()

            Button {
                onOpenInVLC()
            } label: {
                Label("VLC", systemImage: "arrow.up.forward.app")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .help("Hand off this stream to VLC")

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { theaterMode.toggle() }
            } label: {
                Image(systemName: theaterMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding(6)
            .background(.black.opacity(0.45), in: Circle())
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .help(theaterMode ? "Exit Theater Mode (⇧⌘F)" : "Theater Mode (⇧⌘F or double-click video)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            LinearGradient(colors: [.black.opacity(0.72), .clear], startPoint: .top, endPoint: .bottom)
        )
    }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            if controller.isSeekable && controller.duration > 10 {
                HStack(spacing: 8) {
                    Text(formatTime(isScrubbing ? scrubPosition : controller.position))
                        .font(.caption2).monospacedDigit().foregroundStyle(.white.opacity(0.9))
                    Slider(
                        value: Binding(
                            get: { isScrubbing ? scrubPosition : controller.position },
                            set: { scrubPosition = $0 }
                        ),
                        in: 0...max(controller.duration, 1),
                        onEditingChanged: { editing in
                            isScrubbing = editing
                            if !editing { controller.seek(to: scrubPosition) }
                        }
                    )
                    .controlSize(.small)
                    Text(formatTime(controller.duration))
                        .font(.caption2).monospacedDigit().foregroundStyle(.white.opacity(0.9))
                }
            }

            HStack(spacing: 12) {
                Button {
                    controller.togglePlayPause()
                } label: {
                    Image(systemName: controller.isPaused ? "play.fill" : "pause.fill")
                        .font(.title3)
                        .frame(width: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .keyboardShortcut("p", modifiers: .command)
                .help(controller.isPaused ? "Play (⌘P)" : "Pause (⌘P)")

                if controller.isSeekable {
                    Button { controller.seek(by: -10) } label: {
                        Image(systemName: "gobackward.10")
                    }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.9))
                    .help("Back 10 seconds")

                    Button { controller.seek(by: 10) } label: {
                        Image(systemName: "goforward.10")
                    }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.9))
                    .help("Forward 10 seconds")
                }

                // Volume
                HStack(spacing: 6) {
                    Button { controller.toggleMute() } label: {
                        Image(systemName: volumeIcon)
                            .frame(width: 18)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .help(controller.isMuted ? "Unmute" : "Mute")

                    Slider(
                        value: Binding(
                            get: { controller.isMuted ? 0 : controller.volume },
                            set: { v in
                                if controller.isMuted && v > 0 { controller.isMuted = false }
                                controller.volume = v
                            }
                        ),
                        in: 0...100
                    )
                    .controlSize(.mini)
                    .frame(width: 80)
                }

                Spacer()

                // Audio tracks
                if !controller.audioTracks.isEmpty {
                    Menu {
                        ForEach(controller.audioTracks) { track in
                            Button {
                                controller.selectAudio(id: track.id)
                            } label: {
                                if track.selected {
                                    Label(track.title, systemImage: "checkmark")
                                } else {
                                    Text(track.title)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "waveform")
                            .foregroundStyle(.white)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Audio track")
                }

                // Subtitles
                if !controller.subtitleTracks.isEmpty {
                    Menu {
                        Button {
                            controller.selectSubtitle(id: nil)
                        } label: {
                            if !controller.subtitleTracks.contains(where: \.selected) {
                                Label("Off", systemImage: "checkmark")
                            } else {
                                Text("Off")
                            }
                        }
                        Divider()
                        ForEach(controller.subtitleTracks) { track in
                            Button {
                                controller.selectSubtitle(id: track.id)
                            } label: {
                                if track.selected {
                                    Label(track.title, systemImage: "checkmark")
                                } else {
                                    Text(track.title)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "captions.bubble")
                            .foregroundStyle(.white)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Subtitles")
                }

                Button {
                    theaterMode = false
                    controller.stop()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.85))
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop playback (⌘.)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .top, endPoint: .bottom)
        )
    }

    private var volumeIcon: String {
        if controller.isMuted || controller.volume == 0 { return "speaker.slash.fill" }
        if controller.volume < 35 { return "speaker.wave.1.fill" }
        if controller.volume < 70 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private func revealControls() {
        if !showControls {
            withAnimation(.easeOut(duration: 0.15)) { showControls = true }
        }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard controller.isPlaying else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled && controller.isPlaying && !isScrubbing {
                withAnimation(.easeIn(duration: 0.25)) { showControls = false }
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = max(Int(seconds), 0)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
