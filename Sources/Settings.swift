import AppKit
import Sparkle
import SwiftUI

// MARK: - Playback Preferences Notification & Keys

extension Notification.Name {
    static let xstreamPlaybackPreferencesChanged = Notification.Name("com.steingrimosa.xstream.playbackPreferencesChanged")
}

enum PlaybackPrefs {
    static let autoSubtitlesKey = "playerAutoSubtitles"
    static let subtitleLangKey = "playerSubLang"
    static let audioLangKey = "playerAudioLang"
    static let deinterlaceKey = "playerDeinterlace"
    static let aspectModeKey = "playerAspectMode"
    static let bufferProfileKey = "playerBufferProfile"

    static let languageOptions: [(code: String, label: String)] = [
        ("", "System Default"),
        ("en", "English (en)"),
        ("da", "Danish (da)"),
        ("fo", "Faroese (fo)"),
        ("no", "Norwegian (no)"),
        ("sv", "Swedish (sv)"),
        ("is", "Icelandic (is)"),
        ("de", "German (de)"),
        ("fr", "French (fr)"),
        ("es", "Spanish (es)"),
        ("nl", "Dutch (nl)"),
        ("pt", "Portuguese (pt)"),
        ("it", "Italian (it)"),
    ]

    static var autoSubtitles: Bool {
        if UserDefaults.standard.object(forKey: autoSubtitlesKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: autoSubtitlesKey)
    }

    static var subtitleLang: String {
        UserDefaults.standard.string(forKey: subtitleLangKey) ?? ""
    }

    static var audioLang: String {
        UserDefaults.standard.string(forKey: audioLangKey) ?? ""
    }
}

// MARK: - Customizable Keyboard Shortcuts

enum AppShortcutAction: String, CaseIterable, Identifiable, Codable {
    case togglePlayPause
    case stop
    case reloadStream
    case previousChannel
    case nextChannel
    case toggleMute
    case toggleMiniPlayer
    case toggleFullScreen
    case toggleDrawer
    case quickSwitcher
    case refreshSource

    var id: String { rawValue }

    var title: String {
        switch self {
        case .togglePlayPause: return "Play / Pause"
        case .stop: return "Stop"
        case .reloadStream: return "Reload Stream"
        case .previousChannel: return "Previous Channel"
        case .nextChannel: return "Next Channel"
        case .toggleMute: return "Mute / Unmute"
        case .toggleMiniPlayer: return "Floating Mini-Player"
        case .toggleFullScreen: return "Fullscreen"
        case .toggleDrawer: return "Channel Drawer (Fullscreen)"
        case .quickSwitcher: return "Quick Channel Switcher"
        case .refreshSource: return "Refresh Source"
        }
    }

    var defaultCombo: KeyCombo {
        switch self {
        case .togglePlayPause: return KeyCombo(key: "p", modifiers: .command)
        case .stop: return KeyCombo(key: ".", modifiers: .command)
        case .reloadStream: return KeyCombo(key: "r", modifiers: [.command, .shift])
        case .previousChannel: return KeyCombo(key: "[", modifiers: .command)
        case .nextChannel: return KeyCombo(key: "]", modifiers: .command)
        case .toggleMute: return KeyCombo(key: "m", modifiers: [.command, .shift])
        case .toggleMiniPlayer: return KeyCombo(key: "p", modifiers: [.command, .shift])
        case .toggleFullScreen: return KeyCombo(key: "f", modifiers: [.command, .shift])
        case .toggleDrawer: return KeyCombo(key: "l", modifiers: .command)
        case .quickSwitcher: return KeyCombo(key: "k", modifiers: .command)
        case .refreshSource: return KeyCombo(key: "r", modifiers: .command)
        }
    }
}

struct KeyCombo: Codable, Hashable, Equatable {
    var key: String
    var modifiersRaw: UInt

    init(key: String, modifiers: EventModifiers) {
        self.key = key.lowercased()
        self.modifiersRaw = UInt(modifiers.rawValue)
    }

    var modifiers: EventModifiers {
        EventModifiers(rawValue: Int(modifiersRaw))
    }

    var keyEquivalent: KeyEquivalent {
        switch key {
        case "space", " ": return .space
        case "return": return .return
        case "left": return .leftArrow
        case "right": return .rightArrow
        case "up": return .upArrow
        case "down": return .downArrow
        case "tab": return .tab
        default:
            return KeyEquivalent(key.first ?? "p")
        }
    }

    var keyboardShortcut: KeyboardShortcut {
        KeyboardShortcut(keyEquivalent, modifiers: modifiers)
    }

    var displayString: String {
        var out = ""
        if modifiers.contains(.control) { out += "⌃" }
        if modifiers.contains(.option) { out += "⌥" }
        if modifiers.contains(.shift) { out += "⇧" }
        if modifiers.contains(.command) { out += "⌘" }
        switch key {
        case "space", " ": out += "Space"
        case "return": out += "↩"
        case "left": out += "←"
        case "right": out += "→"
        case "up": out += "↑"
        case "down": out += "↓"
        case "tab": out += "⇥"
        default: out += key.uppercased()
        }
        return out
    }

    static func from(event: NSEvent) -> KeyCombo? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: EventModifiers = []
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }

        // Require at least ⌘, ⌥, or ⌃ so plain typing in search fields never conflicts.
        let hasPrimaryMod = mods.contains(.command) || mods.contains(.option) || mods.contains(.control)
        guard hasPrimaryMod else { return nil }

        switch event.keyCode {
        case 49: return KeyCombo(key: "space", modifiers: mods)
        case 36: return KeyCombo(key: "return", modifiers: mods)
        case 123: return KeyCombo(key: "left", modifiers: mods)
        case 124: return KeyCombo(key: "right", modifiers: mods)
        case 125: return KeyCombo(key: "down", modifiers: mods)
        case 126: return KeyCombo(key: "up", modifiers: mods)
        case 48: return KeyCombo(key: "tab", modifiers: mods)
        default:
            guard let chars = event.charactersIgnoringModifiers?.lowercased(),
                  let first = chars.first,
                  !first.isWhitespace,
                  first.isASCII else { return nil }
            return KeyCombo(key: String(first), modifiers: mods)
        }
    }
}

@MainActor
@Observable
final class ShortcutStore {
    static let shared = ShortcutStore()
    private static let storageKey = "customShortcuts"

    private(set) var overrides: [AppShortcutAction: KeyCombo] = [:]

    init() {
        load()
    }

    func combo(for action: AppShortcutAction) -> KeyCombo {
        overrides[action] ?? action.defaultCombo
    }

    func isCustomized(_ action: AppShortcutAction) -> Bool {
        if let custom = overrides[action] {
            return custom != action.defaultCombo
        }
        return false
    }

    var hasCustomShortcuts: Bool {
        AppShortcutAction.allCases.contains { isCustomized($0) }
    }

    func set(_ combo: KeyCombo, for action: AppShortcutAction) {
        if combo == action.defaultCombo {
            overrides.removeValue(forKey: action)
        } else {
            overrides[action] = combo
        }
        save()
    }

    func reset(_ action: AppShortcutAction) {
        overrides.removeValue(forKey: action)
        save()
    }

    func resetAll() {
        overrides.removeAll()
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([String: KeyCombo].self, from: data) else { return }
        var map: [AppShortcutAction: KeyCombo] = [:]
        for (raw, combo) in decoded {
            if let action = AppShortcutAction(rawValue: raw) {
                map[action] = combo
            }
        }
        overrides = map
    }

    private func save() {
        var raw: [String: KeyCombo] = [:]
        for (action, combo) in overrides {
            raw[action.rawValue] = combo
        }
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

// MARK: - Settings Window

struct SettingsView: View {
    let updater: SPUUpdater
    let shortcuts: ShortcutStore

    var body: some View {
        TabView {
            GeneralSettingsTab(updater: updater)
                .tabItem { Label("General", systemImage: "gearshape") }

            PlaybackSettingsTab()
                .tabItem { Label("Playback", systemImage: "play.tv") }

            ShortcutsSettingsTab(shortcuts: shortcuts)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 500, height: 390)
    }
}

private struct GeneralSettingsTab: View {
    let updater: SPUUpdater
    @AppStorage("defaultPlayer") private var defaultPlayer = PlaybackTarget.builtin
    @State private var autoCheck = true
    @State private var autoDownload = false

    var body: some View {
        Form {
            Section("Player") {
                Picker("Default Player", selection: $defaultPlayer) {
                    ForEach(PlaybackTarget.allCases) { target in
                        Text(target.label).tag(target)
                    }
                }
                Text("Choose whether double-clicking a channel plays inside Xstream or hands off to VLC.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $autoCheck)
                    .onChange(of: autoCheck) { _, val in
                        updater.automaticallyChecksForUpdates = val
                    }
                Toggle("Automatically download updates", isOn: $autoDownload)
                    .disabled(!autoCheck)
                    .onChange(of: autoDownload) { _, val in
                        updater.automaticallyDownloadsUpdates = val
                    }
                HStack {
                    Spacer()
                    Button("Check for Updates Now…") {
                        updater.checkForUpdates()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            autoCheck = updater.automaticallyChecksForUpdates
            autoDownload = updater.automaticallyDownloadsUpdates
        }
    }
}

private struct PlaybackSettingsTab: View {
    @AppStorage(PlaybackPrefs.autoSubtitlesKey) private var autoSubtitles = true
    @AppStorage(PlaybackPrefs.subtitleLangKey) private var subtitleLang = ""
    @AppStorage(PlaybackPrefs.audioLangKey) private var audioLang = ""
    @AppStorage(PlaybackPrefs.bufferProfileKey) private var bufferProfileRaw = BufferProfile.balanced.rawValue
    @AppStorage(PlaybackPrefs.deinterlaceKey) private var deinterlaceRaw = DeinterlaceMode.auto.rawValue
    @AppStorage(PlaybackPrefs.aspectModeKey) private var aspectModeRaw = AspectMode.auto.rawValue

    private var bufferProfile: BufferProfile {
        BufferProfile(rawValue: bufferProfileRaw) ?? .balanced
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .xstreamPlaybackPreferencesChanged, object: nil)
    }

    var body: some View {
        Form {
            Section("Subtitles & Audio") {
                Toggle("Auto-enable subtitles", isOn: $autoSubtitles)
                    .onChange(of: autoSubtitles) { notifyChanged() }

                Picker("Subtitle Language", selection: $subtitleLang) {
                    ForEach(PlaybackPrefs.languageOptions, id: \.code) { opt in
                        Text(opt.label).tag(opt.code)
                    }
                }
                .disabled(!autoSubtitles)
                .onChange(of: subtitleLang) { notifyChanged() }

                Picker("Audio Language", selection: $audioLang) {
                    ForEach(PlaybackPrefs.languageOptions, id: \.code) { opt in
                        Text(opt.label).tag(opt.code)
                    }
                }
                .onChange(of: audioLang) { notifyChanged() }
            }

            Section("Video & Buffer") {
                Picker("Buffer Profile", selection: $bufferProfileRaw) {
                    ForEach(BufferProfile.allCases) { p in
                        Text(p.label).tag(p.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: bufferProfileRaw) { notifyChanged() }

                Text(bufferProfile.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Deinterlace", selection: $deinterlaceRaw) {
                    ForEach(DeinterlaceMode.allCases) { m in
                        Text(m.label).tag(m.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: deinterlaceRaw) { notifyChanged() }

                Picker("Aspect Ratio", selection: $aspectModeRaw) {
                    ForEach(AspectMode.allCases) { m in
                        Text(m.label).tag(m.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: aspectModeRaw) { notifyChanged() }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutsSettingsTab: View {
    let shortcuts: ShortcutStore
    @State private var recordingAction: AppShortcutAction?

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(AppShortcutAction.allCases) { action in
                    HStack {
                        Text(action.title)
                        Spacer()
                        if shortcuts.isCustomized(action) {
                            Button {
                                shortcuts.reset(action)
                            } label: {
                                Image(systemName: "arrow.uturn.backward.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Reset to \(action.defaultCombo.displayString)")
                        }
                        ShortcutRecorderButton(
                            combo: shortcuts.combo(for: action),
                            isRecording: recordingAction == action,
                            onStartRecording: { recordingAction = action },
                            onRecord: { combo in
                                shortcuts.set(combo, for: action)
                                recordingAction = nil
                            },
                            onCancel: { recordingAction = nil }
                        )
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.inset)

            Divider()

            HStack {
                Text(recordingAction == nil
                     ? "Click a shortcut to change it (include ⌘, ⌥, or ⌃)."
                     : "Press new key combination… (Esc to cancel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset All to Defaults") {
                    recordingAction = nil
                    shortcuts.resetAll()
                }
                .disabled(!shortcuts.hasCustomShortcuts)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}

private struct ShortcutRecorderButton: View {
    let combo: KeyCombo
    let isRecording: Bool
    let onStartRecording: () -> Void
    let onRecord: (KeyCombo) -> Void
    let onCancel: () -> Void

    @State private var monitor: Any?

    var body: some View {
        Button {
            if isRecording { onCancel() } else { onStartRecording() }
        } label: {
            Text(isRecording ? "Press keys…" : combo.displayString)
                .font(.caption.monospaced())
                .fontWeight(.medium)
                .frame(minWidth: 82)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    isRecording ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isRecording ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onChange(of: isRecording) { _, recording in
            if recording { startMonitoring() } else { stopMonitoring() }
        }
        .onDisappear { stopMonitoring() }
    }

    private func startMonitoring() {
        stopMonitoring()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape
                onCancel()
                return nil
            }
            if let captured = KeyCombo.from(event: event) {
                onRecord(captured)
                return nil
            }
            NSSound.beep()
            return nil
        }
    }

    private func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

// MARK: - Xstream Help Window

struct HelpView: View {
    let shortcuts: ShortcutStore

    private var versionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return short.isEmpty ? "Xstream" : "Version \(short) (\(build))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Xstream Help")
                            .font(.title2).bold()
                        Text(versionString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                Divider()

                helpSection("Getting Started", icon: "antenna.radiowaves.left.and.right") {
                    helpBullet("Add a Source", "Click the + button in the sidebar to connect an Xtream Codes server or import a local M3U playlist.")
                    helpBullet("Organize Categories", "Right-click any source and choose Edit… (or click the filter icon in the toolbar) to hide unwanted categories, toggle Live TV / Movies, or drag categories into your preferred order.")
                    helpBullet("Quality Badges & HD+", "Xstream automatically detects 4K, RAW, FHD, HD, and SD tags in channel names. Click the HD+ pill to show only HD and higher streams.")
                }

                helpSection("Watching & Controls", icon: "play.tv") {
                    helpBullet("Quick Channel Switcher", "Click the magnifying-glass icon in the top-right corner or press \(shortcuts.combo(for: .quickSwitcher).displayString) anywhere (including fullscreen) to jump to any channel across all categories.")
                    helpBullet("Fullscreen & Channel Drawer", "Double-click the video or press \(shortcuts.combo(for: .toggleFullScreen).displayString) for edge-to-edge fullscreen. Press \(shortcuts.combo(for: .toggleDrawer).displayString) or click Channels in the bottom HUD to browse categories without leaving fullscreen.")
                    helpBullet("Floating Mini-Player", "Pop out the active stream into an always-on-top picture-in-picture window with \(shortcuts.combo(for: .toggleMiniPlayer).displayString).")
                    helpBullet("Subtitles, Audio & Buffer", "Open Xstream → Settings… (⌘,) to toggle auto-subtitles, pick preferred audio/subtitle languages, or choose a Buffer Profile (Fast, Balanced, or Smooth).")
                }

                helpSection("Keyboard Shortcuts", icon: "keyboard") {
                    VStack(spacing: 6) {
                        ForEach(AppShortcutAction.allCases) { action in
                            HStack {
                                Text(action.title)
                                    .font(.callout)
                                Spacer()
                                Text(shortcuts.combo(for: action).displayString)
                                    .font(.caption.monospaced())
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            }
                        }
                        HStack {
                            Text("Settings")
                                .font(.callout)
                            Spacer()
                            Text("⌘,")
                                .font(.caption.monospaced())
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                    }
                    Text("You can customize any playback shortcut in Xstream → Settings… → Shortcuts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }

                helpSection("Troubleshooting", icon: "wrench.and.screwdriver") {
                    helpBullet("Stuttering or Buffering", "Open Video Settings (slider icon in the player HUD) or Settings → Playback and switch Buffer Profile to Smooth. Enable Show Stream Stats to inspect live buffer seconds and bitrate.")
                    helpBullet("Frozen Live Stream", "Press \(shortcuts.combo(for: .reloadStream).displayString) to reload the active stream without leaving the channel, or click VLC in the top-right HUD to hand off the stream to VLC.")
                    helpBullet("Account & Guide Info", "Press \(shortcuts.combo(for: .refreshSource).displayString) to refresh your portal's channel list, EPG guide, and subscription status.")
                }
            }
            .padding(22)
        }
        .frame(minWidth: 520, minHeight: 460)
    }

    @ViewBuilder
    private func helpSection<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    @ViewBuilder
    private func helpBullet(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout).fontWeight(.semibold)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}
