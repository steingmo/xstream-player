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

enum DeinterlaceMode: String, CaseIterable, Identifiable {
    case auto = "auto"
    case on = "yes"
    case off = "no"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto"
        case .on: return "On"
        case .off: return "Off"
        }
    }
}

enum AspectMode: String, CaseIterable, Identifiable {
    case auto
    case widescreen
    case standard
    case fill

    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto"
        case .widescreen: return "16:9"
        case .standard: return "4:3"
        case .fill: return "Fill"
        }
    }
}

enum BufferProfile: String, CaseIterable, Identifiable {
    case fast
    case balanced
    case smooth

    var id: String { rawValue }
    var label: String {
        switch self {
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .smooth: return "Smooth"
        }
    }

    var summary: String {
        switch self {
        case .fast: return "Fastest zapping, minimal buffer"
        case .balanced: return "Default balance of speed & stability"
        case .smooth: return "Large buffer for 4K or unstable streams"
        }
    }

    var demuxerMaxBytes: String {
        switch self {
        case .fast: return "16MiB"
        case .balanced: return "64MiB"
        case .smooth: return "256MiB"
        }
    }

    var demuxerReadaheadSecs: String {
        switch self {
        case .fast: return "2"
        case .balanced: return "20"
        case .smooth: return "60"
        }
    }

    var cacheSecs: String {
        switch self {
        case .fast: return "2"
        case .balanced: return "15"
        case .smooth: return "45"
        }
    }

    var cachePauseInitial: String {
        switch self {
        case .fast: return "no"
        case .balanced: return "no"
        case .smooth: return "yes"
        }
    }

    var cachePauseWait: String {
        switch self {
        case .fast: return "1"
        case .balanced: return "1"
        case .smooth: return "3"
        }
    }

    var networkTimeout: String {
        switch self {
        case .fast: return "10"
        case .balanced: return "15"
        case .smooth: return "25"
        }
    }
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

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Let SwiftUI's ZStack HUD buttons, sliders, and double-tap gesture handle all clicks;
        // an NSOpenGLView subview would otherwise intercept clicks before .plain SwiftUI buttons.
        nil
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

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
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
    private static let bufferProfileKey = "playerBufferProfile"
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
    private(set) var osdMessage: String?
    private(set) var videoWidth: Int64 = 0
    private(set) var videoHeightValue: Int64 = 0
    private(set) var videoFPS: Double = 0
    private(set) var droppedFrames: Int64 = 0
    private(set) var audioCodec: String?
    private(set) var audioChannels: Int64 = 0
    private(set) var bufferSeconds: Double = 0
    private(set) var videoBitrate: Double = 0
    private(set) var audioBitrate: Double = 0
    private(set) var downloadSpeedBytesPerSec: Double = 0

    enum StreamHealth {
        case good, fair, poor
    }

    var streamHealth: StreamHealth {
        if isBuffering || reconnectAttempt > 0 { return .poor }
        let lowThreshold = bufferProfile == .fast ? 0.6 : 1.5
        if bufferSeconds > 0 && bufferSeconds < lowThreshold { return .fair }
        return .good
    }

    var showStats = false

    var deinterlace: DeinterlaceMode = .auto {
        didSet {
            guard deinterlace != oldValue else { return }
            UserDefaults.standard.set(deinterlace.rawValue, forKey: PlaybackPrefs.deinterlaceKey)
            setString("deinterlace", deinterlace.rawValue)
            flashOSD("Deinterlace: \(deinterlace.label)")
        }
    }

    var aspectMode: AspectMode = .auto {
        didSet {
            guard aspectMode != oldValue else { return }
            UserDefaults.standard.set(aspectMode.rawValue, forKey: PlaybackPrefs.aspectModeKey)
            applyAspectMode()
            flashOSD("Aspect: \(aspectMode.label)")
        }
    }

    var playbackSpeed: Double = 1.0 {
        didSet {
            setDouble("speed", playbackSpeed)
            flashOSD(String(format: "Speed: %.2g×", playbackSpeed))
        }
    }

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

    var bufferProfile: BufferProfile {
        didSet {
            guard bufferProfile != oldValue else { return }
            UserDefaults.standard.set(bufferProfile.rawValue, forKey: Self.bufferProfileKey)
            applyBufferProfile()
            flashOSD("Buffer: \(bufferProfile.label)")
        }
    }

    var isActive: Bool { activeChannel != nil }
    var isPlaying: Bool { isActive && !isPaused && !isLoading && errorMessage == nil }

    @ObservationIgnored private let mpvQueue = DispatchQueue(label: "com.steingrimosa.xstream.mpv", qos: .userInitiated)
    @ObservationIgnored private nonisolated(unsafe) var mpv: OpaquePointer?
    @ObservationIgnored private var videoView: MPVOpenGLView?
    @ObservationIgnored private var pendingURL: URL?
    @ObservationIgnored private var lastPosUpdate: TimeInterval = 0
    @ObservationIgnored private var lastBufferUpdate: TimeInterval = 0
    @ObservationIgnored private var lastVideoBitrateUpdate: TimeInterval = 0
    @ObservationIgnored private var lastAudioBitrateUpdate: TimeInterval = 0
    @ObservationIgnored private var lastCacheSpeedUpdate: TimeInterval = 0
    @ObservationIgnored private var videoHeight: Int64 = 0
    @ObservationIgnored private var videoCodec: String?
    @ObservationIgnored private var lastErrorLog: String?
    @ObservationIgnored private var sleepActivity: NSObjectProtocol?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var osdTask: Task<Void, Never>?

    init() {
        let savedVol = UserDefaults.standard.object(forKey: Self.volumeKey) as? Double ?? 80
        self.volume = min(max(savedVol, 0), 100)
        self.isMuted = UserDefaults.standard.bool(forKey: Self.mutedKey)
        if let raw = UserDefaults.standard.string(forKey: Self.bufferProfileKey),
           let saved = BufferProfile(rawValue: raw) {
            self.bufferProfile = saved
        } else {
            self.bufferProfile = .balanced
        }
        if let raw = UserDefaults.standard.string(forKey: PlaybackPrefs.deinterlaceKey),
           let saved = DeinterlaceMode(rawValue: raw) {
            self.deinterlace = saved
        }
        if let raw = UserDefaults.standard.string(forKey: PlaybackPrefs.aspectModeKey),
           let saved = AspectMode(rawValue: raw) {
            self.aspectMode = saved
        }
    }

    /// Re-reads user preferences changed in the Settings window and applies them live to libmpv.
    func syncPreferencesFromDefaults() {
        if let raw = UserDefaults.standard.string(forKey: Self.bufferProfileKey),
           let saved = BufferProfile(rawValue: raw), saved != bufferProfile {
            bufferProfile = saved
        }
        if let raw = UserDefaults.standard.string(forKey: PlaybackPrefs.deinterlaceKey),
           let saved = DeinterlaceMode(rawValue: raw), saved != deinterlace {
            deinterlace = saved
        }
        if let raw = UserDefaults.standard.string(forKey: PlaybackPrefs.aspectModeKey),
           let saved = AspectMode(rawValue: raw), saved != aspectMode {
            aspectMode = saved
        }
        applyLanguageAndSubtitlePreferences()
    }

    private func applyLanguageAndSubtitlePreferences() {
        let autoSubs = PlaybackPrefs.autoSubtitles
        let subLang = PlaybackPrefs.subtitleLang
        let audioLang = PlaybackPrefs.audioLang
        setString("subs-fallback", autoSubs ? "yes" : "no")
        setString("subs-match-os-language", (autoSubs && subLang.isEmpty) ? "yes" : "no")
        setString("slang", subLang)
        setString("alang", audioLang)
        setString("sid", autoSubs ? "auto" : "no")
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
        videoWidth = 0
        videoHeight = 0
        videoHeightValue = 0
        videoFPS = 0
        droppedFrames = 0
        videoCodec = nil
        audioCodec = nil
        audioChannels = 0
        bufferSeconds = 0
        videoBitrate = 0
        audioBitrate = 0
        downloadSpeedBytesPerSec = 0
        if channel.streamID != nil && playbackSpeed != 1.0 {
            playbackSpeed = 1.0
        }
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

    func reload() {
        guard let ch = activeChannel else { return }
        flashOSD("Reloading stream…")
        play(ch)
    }

    func cancelReconnect() {
        stop()
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
        videoWidth = 0
        videoHeight = 0
        videoHeightValue = 0
        videoFPS = 0
        droppedFrames = 0
        videoCodec = nil
        audioCodec = nil
        audioChannels = 0
        bufferSeconds = 0
        videoBitrate = 0
        audioBitrate = 0
        downloadSpeedBytesPerSec = 0
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
        flashOSD(isMuted ? "Muted" : "Volume \(Int(volume))%")
    }

    func selectAudio(id: Int) {
        setString("aid", String(id))
        if let t = audioTracks.first(where: { $0.id == id }) {
            flashOSD("Audio: \(t.title)")
        }
    }

    func selectSubtitle(id: Int?) {
        setString("sid", id.map(String.init) ?? "no")
        if let id, let t = subtitleTracks.first(where: { $0.id == id }) {
            flashOSD("Subtitles: \(t.title)")
        } else {
            flashOSD("Subtitles: Off")
        }
    }

    func flashOSD(_ message: String) {
        osdMessage = message
        osdTask?.cancel()
        osdTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, !Task.isCancelled else { return }
            self.osdMessage = nil
        }
    }

    private func applyAspectMode() {
        switch aspectMode {
        case .auto:
            setString("video-aspect-override", "-1")
            setDouble("panscan", 0)
        case .widescreen:
            setString("video-aspect-override", "16:9")
            setDouble("panscan", 0)
        case .standard:
            setString("video-aspect-override", "4:3")
            setDouble("panscan", 0)
        case .fill:
            setString("video-aspect-override", "-1")
            setDouble("panscan", 1)
        }
    }

    private func applyBufferProfile() {
        setString("demuxer-max-bytes", bufferProfile.demuxerMaxBytes)
        setString("demuxer-readahead-secs", bufferProfile.demuxerReadaheadSecs)
        setString("cache-secs", bufferProfile.cacheSecs)
        setString("cache-pause-initial", bufferProfile.cachePauseInitial)
        setString("cache-pause-wait", bufferProfile.cachePauseWait)
        setString("network-timeout", bufferProfile.networkTimeout)
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
        // Use AVFoundation audio output instead of CoreAudio: libmpv's ao_coreaudio has a
        // use-after-free on macOS HALC_ProxyNotification Call Listener Queue when audio
        // devices change (AirPods, Bluetooth, external monitors) or tear down.
        mpv_set_option_string(handle, "ao", "avfoundation")
        mpv_set_option_string(handle, "hwdec", "auto-safe")
        mpv_set_option_string(handle, "keep-open", "no")
        mpv_set_option_string(handle, "cache", "yes")
        mpv_set_option_string(handle, "demuxer-max-bytes", bufferProfile.demuxerMaxBytes)
        mpv_set_option_string(handle, "demuxer-readahead-secs", bufferProfile.demuxerReadaheadSecs)
        mpv_set_option_string(handle, "cache-secs", bufferProfile.cacheSecs)
        mpv_set_option_string(handle, "cache-pause-initial", bufferProfile.cachePauseInitial)
        mpv_set_option_string(handle, "cache-pause-wait", bufferProfile.cachePauseWait)
        mpv_set_option_string(handle, "network-timeout", bufferProfile.networkTimeout)
        mpv_set_option_string(handle, "tls-verify", "no")
        mpv_set_option_string(handle, "user-agent", "VLC/3.0.21 LibVLC/3.0.21")
        let autoSubs = PlaybackPrefs.autoSubtitles
        let subLang = PlaybackPrefs.subtitleLang
        let audioLang = PlaybackPrefs.audioLang
        mpv_set_option_string(handle, "subs-match-os-language", (autoSubs && subLang.isEmpty) ? "yes" : "no")
        mpv_set_option_string(handle, "subs-fallback", autoSubs ? "yes" : "no")
        if !subLang.isEmpty { mpv_set_option_string(handle, "slang", subLang) }
        if !audioLang.isEmpty { mpv_set_option_string(handle, "alang", audioLang) }
        mpv_set_option_string(handle, "sid", autoSubs ? "auto" : "no")
        mpv_set_option_string(handle, "input-media-keys", "no")
        mpv_set_option_string(handle, "volume", String(Int(volume)))
        mpv_set_option_string(handle, "mute", isMuted ? "yes" : "no")
        mpv_set_option_string(handle, "deinterlace", deinterlace.rawValue)

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
        mpv_observe_property(handle, 0, "video-params/w", MPV_FORMAT_INT64)
        mpv_observe_property(handle, 0, "video-params/h", MPV_FORMAT_INT64)
        mpv_observe_property(handle, 0, "video-codec", MPV_FORMAT_STRING)
        mpv_observe_property(handle, 0, "container-fps", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 0, "frame-drop-count", MPV_FORMAT_INT64)
        mpv_observe_property(handle, 0, "audio-codec-name", MPV_FORMAT_STRING)
        mpv_observe_property(handle, 0, "audio-params/channel-count", MPV_FORMAT_INT64)
        mpv_observe_property(handle, 0, "demuxer-cache-duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 0, "video-bitrate", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 0, "audio-bitrate", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 0, "cache-speed", MPV_FORMAT_INT64)
        mpv_observe_property(handle, 0, "track-list/count", MPV_FORMAT_INT64)
        mpv_observe_property(handle, 0, "aid", MPV_FORMAT_STRING)
        mpv_observe_property(handle, 0, "sid", MPV_FORMAT_STRING)

        mpv = handle
        if aspectMode != .auto { applyAspectMode() }

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

        case "video-params/w":
            guard prop.format == MPV_FORMAT_INT64, let ptr = prop.data else { return }
            let w = ptr.assumingMemoryBound(to: Int64.self).pointee
            Task { @MainActor [weak self] in self?.videoWidth = w }

        case "video-params/h":
            guard prop.format == MPV_FORMAT_INT64, let ptr = prop.data else { return }
            let h = ptr.assumingMemoryBound(to: Int64.self).pointee
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.videoHeight = h
                self.videoHeightValue = h
                self.updateVideoInfo()
            }

        case "container-fps":
            guard prop.format == MPV_FORMAT_DOUBLE, let ptr = prop.data else { return }
            let fps = ptr.assumingMemoryBound(to: Double.self).pointee
            if fps.isFinite && fps > 0 {
                Task { @MainActor [weak self] in self?.videoFPS = fps }
            }

        case "frame-drop-count":
            guard prop.format == MPV_FORMAT_INT64, let ptr = prop.data else { return }
            let drops = ptr.assumingMemoryBound(to: Int64.self).pointee
            Task { @MainActor [weak self] in self?.droppedFrames = drops }

        case "audio-codec-name":
            guard prop.format == MPV_FORMAT_STRING, let ptr = prop.data,
                  let cstr = ptr.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee else { return }
            let raw = String(cString: cstr).uppercased()
            Task { @MainActor [weak self] in self?.audioCodec = raw }

        case "audio-params/channel-count":
            guard prop.format == MPV_FORMAT_INT64, let ptr = prop.data else { return }
            let ch = ptr.assumingMemoryBound(to: Int64.self).pointee
            Task { @MainActor [weak self] in self?.audioChannels = ch }

        case "demuxer-cache-duration":
            let val: Double = (prop.format == MPV_FORMAT_DOUBLE && prop.data != nil)
                ? prop.data!.assumingMemoryBound(to: Double.self).pointee
                : 0
            let clean = val.isFinite && val >= 0 ? val : 0
            let now = Date.timeIntervalSinceReferenceDate
            Task { @MainActor [weak self] in
                guard let self else { return }
                if now - self.lastBufferUpdate >= 0.5 || clean == 0 {
                    self.lastBufferUpdate = now
                    self.bufferSeconds = clean
                }
            }

        case "video-bitrate":
            let val: Double = (prop.format == MPV_FORMAT_DOUBLE && prop.data != nil)
                ? prop.data!.assumingMemoryBound(to: Double.self).pointee
                : 0
            let clean = val.isFinite && val > 0 ? val : 0
            let now = Date.timeIntervalSinceReferenceDate
            Task { @MainActor [weak self] in
                guard let self else { return }
                if now - self.lastVideoBitrateUpdate >= 0.5 || self.videoBitrate == 0 {
                    self.lastVideoBitrateUpdate = now
                    self.videoBitrate = clean
                }
            }

        case "audio-bitrate":
            let val: Double = (prop.format == MPV_FORMAT_DOUBLE && prop.data != nil)
                ? prop.data!.assumingMemoryBound(to: Double.self).pointee
                : 0
            let clean = val.isFinite && val > 0 ? val : 0
            let now = Date.timeIntervalSinceReferenceDate
            Task { @MainActor [weak self] in
                guard let self else { return }
                if now - self.lastAudioBitrateUpdate >= 0.5 || self.audioBitrate == 0 {
                    self.lastAudioBitrateUpdate = now
                    self.audioBitrate = clean
                }
            }

        case "cache-speed":
            let val: Int64 = (prop.format == MPV_FORMAT_INT64 && prop.data != nil)
                ? prop.data!.assumingMemoryBound(to: Int64.self).pointee
                : 0
            let clean = val > 0 ? Double(val) : 0
            let now = Date.timeIntervalSinceReferenceDate
            Task { @MainActor [weak self] in
                guard let self else { return }
                if now - self.lastCacheSpeedUpdate >= 0.5 || self.downloadSpeedBytesPerSec == 0 {
                    self.lastCacheSpeedUpdate = now
                    self.downloadSpeedBytesPerSec = clean
                }
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
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
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
    var onPreviousChannel: (() -> Void)? = nil
    var onNextChannel: (() -> Void)? = nil
    var onToggleDrawer: (() -> Void)? = nil
    var onQuickSwitch: (() -> Void)? = nil

    @State private var showControls = true
    @State private var showSettings = false
    @State private var hideTask: Task<Void, Never>?
    @State private var isScrubbing = false
    @State private var scrubPosition: Double = 0

    private var controlsVisible: Bool {
        showControls || showSettings || !controller.isPlaying || controller.isLoading || controller.isBuffering || controller.errorMessage != nil
    }

    var body: some View {
        ZStack {
            Color.black
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    if isMiniPlayer { onToggleMiniPlayer() } else { onToggleFullScreen() }
                }
                .ignoresSafeArea()
            MPVVideoSurface(controller: controller) {
                if isMiniPlayer { onToggleMiniPlayer() } else { onToggleFullScreen() }
            }
            .allowsHitTesting(false)
            .ignoresSafeArea()

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
            } else if controller.isLoading || controller.isBuffering || controller.reconnectAttempt > 0 {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(statusText)
                        .font(.callout)
                        .foregroundStyle(.white)
                    if controller.reconnectAttempt > 0 {
                        Button("Now") { controller.retry() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                        Button("Cancel") { controller.cancelReconnect() }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .environment(\.colorScheme, .dark)
                .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))
            }

            // Stream stats overlay (optional, toggled from Video Settings)
            if controller.showStats && !isMiniPlayer {
                VStack {
                    HStack {
                        statsOverlay
                        Spacer()
                    }
                    Spacer()
                }
                .padding(.top, controlsVisible ? 52 : 14)
                .padding(.leading, 14)
                .allowsHitTesting(false)
            }

            // Transient OSD feedback toast (volume, mute, track change, zap)
            if let osd = controller.osdMessage {
                VStack {
                    Spacer().frame(height: 54)
                    Text(osd)
                        .font(.callout).fontWeight(.medium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                        .environment(\.colorScheme, .dark)
                        .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))
                    Spacer()
                }
                .allowsHitTesting(false)
                .transition(.opacity)
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
            if theaterMode {
                NSCursor.setHiddenUntilMouseMoves(!visible)
            }
        }
        .onChange(of: theaterMode) { _, entering in
            if entering {
                if controller.isPlaying { scheduleHide() }
                if !controlsVisible { NSCursor.setHiddenUntilMouseMoves(true) }
            } else {
                NSCursor.setHiddenUntilMouseMoves(false)
            }
        }
        .onDisappear {
            hideTask?.cancel()
            NSCursor.setHiddenUntilMouseMoves(false)
        }
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

    private var statsOverlay: some View {
        VStack(alignment: .leading, spacing: 3) {
            if controller.videoWidth > 0 && controller.videoHeightValue > 0 {
                let fpsStr = controller.videoFPS > 0 ? String(format: " @ %.1f fps", controller.videoFPS) : ""
                Text("Video: \(controller.videoWidth)×\(controller.videoHeightValue)\(fpsStr)")
            }
            if let info = controller.videoInfo {
                let brStr = controller.videoBitrate > 0 ? " · \(formatBitrate(controller.videoBitrate))" : ""
                Text("Codec: \(info)\(brStr)")
            }
            if let ac = controller.audioCodec {
                let chStr = controller.audioChannels > 0 ? " (\(controller.audioChannels)ch)" : ""
                let abrStr = controller.audioBitrate > 0 ? " · \(formatBitrate(controller.audioBitrate))" : ""
                Text("Audio: \(ac)\(chStr)\(abrStr)")
            }
            Text(String(format: "Buffer: %.1fs (%@)", controller.bufferSeconds, controller.bufferProfile.label))
            if controller.downloadSpeedBytesPerSec > 0 {
                Text("Download: \(formatBitrate(controller.downloadSpeedBytesPerSec * 8))")
            }
            Text("Dropped frames: \(controller.droppedFrames)")
        }
        .font(.caption2).monospaced()
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }

    private func formatBitrate(_ bitsPerSecond: Double) -> String {
        if bitsPerSecond >= 1_000_000 {
            return String(format: "%.1f Mbps", bitsPerSecond / 1_000_000)
        }
        return String(format: "%.0f kbps", bitsPerSecond / 1_000)
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

            if !isMiniPlayer && controller.isPlaying {
                let healthColor: Color = {
                    switch controller.streamHealth {
                    case .good: return .green
                    case .fair: return .orange
                    case .poor: return .red
                    }
                }()
                let speedStr = controller.downloadSpeedBytesPerSec > 0
                    ? formatBitrate(controller.downloadSpeedBytesPerSec * 8)
                    : String(format: "%.1fs buf", controller.bufferSeconds)
                HStack(spacing: 4) {
                    Circle().fill(healthColor).frame(width: 6, height: 6)
                    Text(speedStr)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.black.opacity(0.45), in: Capsule())
                .help(String(format: "Stream health · Buffer %.1fs (%@)", controller.bufferSeconds, controller.bufferProfile.label))
            }

            Spacer()

            if !isMiniPlayer, let onQuickSwitch {
                Button {
                    onQuickSwitch()
                } label: {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(.black.opacity(0.5), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Quick Channel Switcher (⌘K)")
            }

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
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(.black.opacity(0.5), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(isMiniPlayer ? "Return to main window" : "Floating Mini-Player")

            if !isMiniPlayer {
                Button {
                    onToggleFullScreen()
                } label: {
                    Image(systemName: theaterMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(.black.opacity(0.5), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
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
                if theaterMode, let onToggleDrawer {
                    Button(action: onToggleDrawer) {
                        HStack(spacing: 5) {
                            Image(systemName: "list.bullet")
                            Text("Channels").font(.caption).fontWeight(.medium)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.white.opacity(0.14), in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Channel Drawer (⌘L)")
                }

                if let onPreviousChannel {
                    Button(action: onPreviousChannel) {
                        Image(systemName: "backward.end.fill").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.85))
                    .help("Previous channel (⌘[)")
                }

                Button {
                    controller.togglePlayPause()
                } label: {
                    Image(systemName: controller.isPaused ? "play.fill" : "pause.fill")
                        .font(.title3)
                        .frame(width: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .help(controller.isPaused ? "Play (⌘P)" : "Pause (⌘P)")

                if let onNextChannel {
                    Button(action: onNextChannel) {
                        Image(systemName: "forward.end.fill").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.85))
                    .help("Next channel (⌘])")
                }

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

                if !isMiniPlayer {
                    Button {
                        showSettings.toggle()
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .help("Video settings & stats")
                    .popover(isPresented: $showSettings, arrowEdge: .top) {
                        videoSettingsPopover
                    }
                }

                Button {
                    if theaterMode { onToggleFullScreen() }
                    controller.stop()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.85))
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

    private var videoSettingsPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Deinterlace").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: Binding(
                    get: { controller.deinterlace },
                    set: { controller.deinterlace = $0 }
                )) {
                    ForEach(DeinterlaceMode.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 140)
            }

            HStack {
                Text("Aspect").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: Binding(
                    get: { controller.aspectMode },
                    set: { controller.aspectMode = $0 }
                )) {
                    ForEach(AspectMode.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 175)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Buffer").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { controller.bufferProfile },
                        set: { controller.bufferProfile = $0 }
                    )) {
                        ForEach(BufferProfile.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 175)
                }
                Text(controller.bufferProfile.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if controller.isSeekable {
                HStack {
                    Text("Speed").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { controller.playbackSpeed },
                        set: { controller.playbackSpeed = $0 }
                    )) {
                        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { s in
                            Text(String(format: "%.2g×", s)).tag(s)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                }
            }

            Divider()

            Toggle("Show Stream Stats", isOn: Binding(
                get: { controller.showStats },
                set: { controller.showStats = $0 }
            ))
            .font(.caption)
        }
        .padding(12)
        .frame(width: 275)
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
