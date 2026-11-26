import AppKit
import Libmpv
import OpenGL.GL
import OpenGL.GL3
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

// MARK: - OpenGL Video View (vo=libmpv)

/// Renders libmpv frames via mpv_render_context into an NSOpenGLView.
/// Unlike MPVKit's moltenvk context (which doesn't handle VO_EVENT_RESIZE), every draw
/// passes the exact current Retina backing dimensions to libmpv, so live window resizing
/// and fullscreen transitions scale smoothly at 60 fps.
final class MPVOpenGLView: NSOpenGLView {
    var onDoubleClick: (() -> Void)?
    private var renderContext: OpaquePointer?
    private var defaultFBO: GLint = 0

    override class func defaultPixelFormat() -> NSOpenGLPixelFormat {
        let attrs: [NSOpenGLPixelFormatAttribute] = [
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAOpenGLProfile),
            NSOpenGLPixelFormatAttribute(NSOpenGLProfileVersion3_2Core),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFADoubleBuffer),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAAccelerated),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAAllowOfflineRenderers),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAColorSize), NSOpenGLPixelFormatAttribute(32),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFADepthSize), NSOpenGLPixelFormatAttribute(24),
            NSOpenGLPixelFormatAttribute(0),
        ]
        return NSOpenGLPixelFormat(attributes: attrs) ?? super.defaultPixelFormat()
    }

    init() {
        super.init(frame: .zero, pixelFormat: Self.defaultPixelFormat())!
        wantsBestResolutionOpenGLSurface = true
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { true }

    override func reshape() {
        super.reshape()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        openGLContext?.update()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        openGLContext?.update()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        } else {
            super.mouseDown(with: event)
        }
    }

    func attachRenderContext(mpv: OpaquePointer) -> CInt {
        guard renderContext == nil, let ctx = openGLContext, let cgl = ctx.cglContextObj else { return 0 }
        CGLLockContext(cgl)
        defer { CGLUnlockContext(cgl) }
        ctx.makeCurrentContext()

        let api = UnsafeMutableRawPointer(mutating: (MPV_RENDER_API_TYPE_OPENGL as NSString).utf8String)
        var glInit = mpv_opengl_init_params(
            get_proc_address: { _, name in
                guard let name else { return nil }
                let sym = CFStringCreateWithCString(kCFAllocatorDefault, name, CFStringBuiltInEncodings.ASCII.rawValue)
                guard let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString) else { return nil }
                return CFBundleGetFunctionPointerForName(bundle, sym)
            },
            get_proc_address_ctx: nil
        )

        var created: OpaquePointer?
        let status: CInt = withUnsafeMutablePointer(to: &glInit) { glPtr in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: api),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: glPtr),
                mpv_render_param(),
            ]
            return mpv_render_context_create(&created, mpv, &params)
        }

        guard status >= 0, let created else { return status }
        renderContext = created

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        mpv_render_context_set_update_callback(created, { rawCtx in
            guard let rawCtx else { return }
            let view = Unmanaged<MPVOpenGLView>.fromOpaque(rawCtx).takeUnretainedValue()
            DispatchQueue.main.async {
                view.needsDisplay = true
            }
        }, selfPtr)

        return status
    }

    func detachRenderContext() {
        guard let rc = renderContext else { return }
        renderContext = nil
        mpv_render_context_set_update_callback(rc, nil, nil)
        if let ctx = openGLContext, let cgl = ctx.cglContextObj {
            CGLLockContext(cgl)
            ctx.makeCurrentContext()
            mpv_render_context_free(rc)
            CGLUnlockContext(cgl)
        } else {
            mpv_render_context_free(rc)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = openGLContext, let cgl = ctx.cglContextObj else { return }
        CGLLockContext(cgl)
        defer { CGLUnlockContext(cgl) }
        ctx.makeCurrentContext()

        let backing = convertToBacking(bounds)
        let w = Int32(max(backing.width.rounded(), 1))
        let h = Int32(max(backing.height.rounded(), 1))

        glViewport(0, 0, GLsizei(w), GLsizei(h))
        glClearColor(0, 0, 0, 1)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))

        if let rc = renderContext {
            glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &defaultFBO)
            var fbo = mpv_opengl_fbo(fbo: defaultFBO, w: w, h: h, internal_format: 0)
            var flip: CInt = 1
            withUnsafeMutablePointer(to: &fbo) { fboPtr in
                withUnsafeMutablePointer(to: &flip) { flipPtr in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: fboPtr),
                        mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flipPtr),
                        mpv_render_param(),
                    ]
                    mpv_render_context_render(rc, &params)
                }
            }
        }

        ctx.flushBuffer()
    }
}

/// Thin container owned by SwiftUI that reparents the single shared MPVOpenGLView so
/// toggling Theater Mode / Fullscreen never tears down the video context or interrupts playback.
final class MPVContainerView: NSView {
    private weak var videoView: MPVOpenGLView?

    func mount(_ view: MPVOpenGLView) {
        videoView = view
        if view.superview !== self {
            view.removeFromSuperview()
            view.frame = bounds
            addSubview(view)
            view.openGLContext?.update()
        }
        view.frame = bounds
        view.needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        videoView?.frame = bounds
        videoView?.needsDisplay = true
    }

    override func layout() {
        super.layout()
        videoView?.frame = bounds
        videoView?.needsDisplay = true
    }
}

struct MPVVideoSurface: NSViewRepresentable {
    let controller: PlayerController
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> MPVContainerView {
        let container = MPVContainerView()
        let video = controller.ensureVideoView()
        video.onDoubleClick = onDoubleClick
        container.mount(video)
        return container
    }

    func updateNSView(_ nsView: MPVContainerView, context: Context) {
        let video = controller.ensureVideoView()
        video.onDoubleClick = onDoubleClick
        nsView.mount(video)
    }
}

// MARK: - MPV Player Controller

@MainActor
@Observable
final class PlayerController {
    private static let volumeKey = "playerVolume"
    private static let mutedKey = "playerMuted"
    private static let reconnectDelays: [Double] = [1.5, 3.0, 5.0]

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
    private(set) var reconnectAttempt = 0

    static var maxReconnectAttempts: Int { reconnectDelays.count }

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
    @ObservationIgnored private var videoView: MPVOpenGLView?
    @ObservationIgnored private var pendingURL: URL?
    @ObservationIgnored private var lastPosUpdate: TimeInterval = 0
    @ObservationIgnored private var videoHeight: Int64 = 0
    @ObservationIgnored private var videoCodec: String?
    @ObservationIgnored private var lastErrorLog: String?
    @ObservationIgnored private var sleepActivity: NSObjectProtocol?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?

    init() {
        let savedVol = UserDefaults.standard.object(forKey: Self.volumeKey) as? Double ?? 80
        self.volume = min(max(savedVol, 0), 100)
        self.isMuted = UserDefaults.standard.bool(forKey: Self.mutedKey)
    }

    func ensureVideoView() -> MPVOpenGLView {
        if let existing = videoView {
            if mpv == nil { initializeMPV(view: existing) }
            return existing
        }
        let view = MPVOpenGLView()
        videoView = view
        initializeMPV(view: view)
        if let url = pendingURL {
            pendingURL = nil
            sendLoadFile(url)
        }
        return view
    }

    func play(_ channel: Channel) {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
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
        updateSleepAssertion()

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
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        setFlag("pause", true)
    }

    func stop() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
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
        updateSleepAssertion()
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
        reconnectTask?.cancel()
        reconnectTask = nil
        endSleepAssertion()
        // Detach the OpenGL render context on the main thread before destroying mpv.
        videoView?.detachRenderContext()
        mpvQueue.sync {
            guard let handle = self.mpv else { return }
            mpv_set_wakeup_callback(handle, nil, nil)
            mpv_terminate_destroy(handle)
            self.mpv = nil
        }
        videoView = nil
    }

    /// Keeps the display awake while video is actively playing; releases as soon as paused,
    /// stopped, or errored so the Mac sleeps normally when idle.
    private func updateSleepAssertion() {
        if isPlaying {
            if sleepActivity == nil {
                sleepActivity = ProcessInfo.processInfo.beginActivity(
                    options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled, .userInitiated],
                    reason: "Xstream video playback"
                )
            }
        } else {
            endSleepAssertion()
        }
    }

    private func endSleepAssertion() {
        if let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
    }

    private func scheduleLiveReconnect(fallbackError: String) {
        guard let channel = activeChannel,
              channel.streamID != nil,
              !isPaused,
              reconnectAttempt < Self.reconnectDelays.count else {
            isLoading = false
            isBuffering = false
            reconnectAttempt = 0
            errorMessage = fallbackError
            updateSleepAssertion()
            return
        }

        let delay = Self.reconnectDelays[reconnectAttempt]
        reconnectAttempt += 1
        isLoading = true
        isBuffering = false
        errorMessage = nil
        updateSleepAssertion()

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.activeChannel?.id == channel.id else { return }
            self.sendLoadFile(channel.url)
        }
    }

    // MARK: - libmpv Setup & Commands

    private func initializeMPV(view: MPVOpenGLView) {
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

        mpv_set_option_string(handle, "vo", "libmpv")
        mpv_set_option_string(handle, "hwdec", "auto-safe")
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

        let glStatus = view.attachRenderContext(mpv: handle)
        guard glStatus >= 0 else {
            let err = String(cString: mpv_error_string(glStatus))
            mpv_terminate_destroy(handle)
            errorMessage = "Video renderer failed to start: \(err)"
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
                        self.updateSleepAssertion()
                    }

                case MPV_EVENT_PLAYBACK_RESTART:
                    Task { @MainActor [weak self] in
                        guard let self, self.isActive else { return }
                        self.isLoading = false
                        self.isBuffering = false
                        self.reconnectAttempt = 0
                        self.errorMessage = nil
                        self.updateSleepAssertion()
                    }

                case MPV_EVENT_END_FILE:
                    if let data = event.pointee.data {
                        let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                        if end.reason == MPV_END_FILE_REASON_ERROR {
                            let errText = String(cString: mpv_error_string(end.error))
                            Task { @MainActor [weak self] in
                                guard let self, self.isActive else { return }
                                let msg = (self.lastErrorLog.map { !$0.isEmpty } ?? false)
                                    ? "\(errText) — \(self.lastErrorLog!)"
                                    : "Could not play stream (\(errText))."
                                self.scheduleLiveReconnect(fallbackError: msg)
                            }
                        } else if end.reason == MPV_END_FILE_REASON_EOF {
                            Task { @MainActor [weak self] in
                                guard let self, self.isActive else { return }
                                if self.activeChannel?.streamID != nil {
                                    // Live IPTV streams occasionally close cleanly on CDN hiccups.
                                    self.scheduleLiveReconnect(fallbackError: "Live stream ended unexpectedly.")
                                } else {
                                    self.isLoading = false
                                    self.isBuffering = false
                                    self.isPaused = true
                                    self.updateSleepAssertion()
                                }
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
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPaused = val
                self.updateSleepAssertion()
            }

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

// MARK: - Floating Mini-Player Window

/// Always-on-top 16:9 floating panel that hosts the shared MPVOpenGLView so you can pop out
/// video while working in other apps without interrupting playback.
@MainActor
final class MiniPlayerWindowController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var onClose: (() -> Void)?

    func show<Content: View>(@ViewBuilder content: () -> Content, onClose: @escaping () -> Void) {
        self.onClose = onClose
        if let existing = panel {
            existing.contentView = NSHostingView(rootView: content())
            existing.orderFrontRegardless()
            return
        }

        let initialWidth: CGFloat = 480
        let initialHeight: CGFloat = 270
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let origin = NSPoint(
            x: screenFrame.maxX - initialWidth - 24,
            y: screenFrame.minY + 24
        )
        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: NSSize(width: initialWidth, height: initialHeight)),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .black
        panel.contentAspectRatio = NSSize(width: 16, height: 9)
        panel.minSize = NSSize(width: 320, height: 180)
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isReleasedWhenClosed = false
        panel.setFrameAutosaveName("XstreamMiniPlayer")
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: content())
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func update<Content: View>(@ViewBuilder content: () -> Content) {
        guard let panel else { return }
        panel.contentView = NSHostingView(rootView: content())
    }

    func close() {
        onClose = nil
        panel?.delegate = nil
        panel?.close()
        panel = nil
    }

    func windowWillClose(_ notification: Notification) {
        let cb = onClose
        onClose = nil
        panel = nil
        cb?()
    }
}

// MARK: - Embedded Player Stage & HUD

struct EmbeddedPlayerView: View {
    let controller: PlayerController
    let channel: Channel
    @Binding var theaterMode: Bool
    var isMiniPlayer = false
    let onOpenInVLC: () -> Void
    let onToggleFullScreen: () -> Void
    let onToggleMiniPlayer: () -> Void

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
                if isMiniPlayer { onToggleMiniPlayer() } else { onToggleFullScreen() }
            }

            // Center state overlay (loading, reconnecting, buffering, or error)
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
                    Text(statusText)
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
        .onChange(of: controlsVisible) { _, visible in
            if theaterMode && !visible {
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
        .onDisappear { hideTask?.cancel() }
        .onKeyPress(.escape) {
            guard theaterMode else { return .ignored }
            onToggleFullScreen()
            return .handled
        }
    }

    private var statusText: String {
        if controller.reconnectAttempt > 0 {
            return "Reconnecting (\(controller.reconnectAttempt)/\(PlayerController.maxReconnectAttempts))…"
        }
        return controller.isLoading ? "Connecting…" : "Buffering…"
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            if isMiniPlayer {
                // Leave room for the traffic-light close button in the floating panel.
                Spacer().frame(width: 18)
            }
            Text(channel.name)
                .font(isMiniPlayer ? .subheadline : .headline)
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

            if !isMiniPlayer, let info = controller.videoInfo {
                Text(info)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.45), in: Capsule())
            }

            Spacer()

            if !isMiniPlayer {
                Button {
                    onOpenInVLC()
                } label: {
                    Label("VLC", systemImage: "arrow.up.forward.app")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .help("Hand off this stream to VLC")
            }

            Button {
                onToggleMiniPlayer()
            } label: {
                Image(systemName: isMiniPlayer ? "pip.exit" : "pip.enter")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding(6)
            .background(.black.opacity(0.45), in: Circle())
            .help(isMiniPlayer ? "Return to main window" : "Floating Mini-Player")

            if !isMiniPlayer {
                Button {
                    onToggleFullScreen()
                } label: {
                    Image(systemName: theaterMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .padding(6)
                .background(.black.opacity(0.45), in: Circle())
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .help(theaterMode ? "Exit Fullscreen (⇧⌘F or Esc)" : "Fullscreen (⇧⌘F or double-click video)")
            }
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
                    if theaterMode { onToggleFullScreen() }
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
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .environment(\.colorScheme, .dark)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
        .padding(.horizontal, isMiniPlayer ? 8 : 14)
        .padding(.bottom, isMiniPlayer ? 8 : 12)
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
