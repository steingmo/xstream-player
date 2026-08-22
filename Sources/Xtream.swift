import Foundation

// MARK: - Model

struct Channel: Identifiable, Hashable {
    let id: String
    let name: String
    let group: String
    let logo: URL?
    let url: URL
    /// Xtream live stream id — nil for VOD and for M3U entries, which have no EPG.
    var streamID: String? = nil
}

struct Programme: Identifiable, Hashable {
    let id: String
    let title: String
    let summary: String
    let start: Date
    let stop: Date

    var isNow: Bool { let t = Date(); return t >= start && t < stop }
}

struct Server: Codable, Hashable {
    var host = ""          // http://host:port
    var username = ""
    var password = ""
}

enum SourceKind: Codable, Hashable {
    case xtream(Server)
    case m3u(path: String)
}

struct Source: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var kind: SourceKind
}

/// Xtream panels base64-encode EPG text, but not all of them do it consistently —
/// fall back to the raw string when it isn't valid base64.
func decodeEPGText(_ raw: String) -> String {
    guard let d = Data(base64Encoded: raw, options: .ignoreUnknownCharacters),
          let s = String(data: d, encoding: .utf8), !s.isEmpty else { return raw }
    return s
}

struct Err: LocalizedError {
    let m: String
    init(_ m: String) { self.m = m }
    var errorDescription: String? { m }
}

// MARK: - Config
// ponytail: sources (incl. Xtream password) live in a 0600 JSON file, not the Keychain.
// The Xtream stream URLs embed the same password, so the file is the weakest link either
// way. Move to Keychain if this app ever ships to someone else's Mac.

enum Store {
    static let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Xstream", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sources.json")
    }()

    static func load() -> [Source] {
        guard let d = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([Source].self, from: d)) ?? []
    }

    static func save(_ sources: [Source]) {
        guard let d = try? JSONEncoder().encode(sources) else { return }
        try? d.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

// MARK: - Xtream Codes API

enum Xtream {
    static func base(_ s: Server) -> String {
        var h = s.host.trimmingCharacters(in: .whitespaces)
        while h.hasSuffix("/") { h.removeLast() }
        if !h.lowercased().hasPrefix("http") { h = "http://" + h }
        return h
    }

    private static func esc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }

    /// Providers are inconsistent about numbers vs strings, so read every field loosely.
    static func string(_ d: [String: Any], _ k: String) -> String? {
        if let s = d[k] as? String, !s.isEmpty { return s }
        if let n = d[k] as? NSNumber { return n.stringValue }
        return nil
    }

    private static func rows(_ s: Server, _ action: String, _ extra: String = "") async throws -> [[String: Any]] {
        let str = "\(base(s))/player_api.php?username=\(esc(s.username))&password=\(esc(s.password))&action=\(action)\(extra)"
        guard let u = URL(string: str) else { throw Err("Bad server address") }
        let (d, r) = try await URLSession.shared.data(from: u)
        if let h = r as? HTTPURLResponse, h.statusCode != 200 { throw Err("HTTP \(h.statusCode) on \(action)") }
        let json = try? JSONSerialization.jsonObject(with: d)
        // Stream lists come back as a bare array; get_short_epg wraps its array in an object.
        if let a = json as? [[String: Any]] { return a }
        if let o = json as? [String: Any],
           let a = o.values.compactMap({ $0 as? [[String: Any]] }).first { return a }
        throw Err("Unexpected reply to \(action) — wrong credentials or not an Xtream server?")
    }

    /// Live channels + VOD movies. Series are skipped: each one needs its own episode fetch.
    static func channels(_ s: Server) async throws -> [Channel] {
        async let liveCats = rows(s, "get_live_categories")
        async let live = rows(s, "get_live_streams")
        async let vodCats = rows(s, "get_vod_categories")
        async let vod = rows(s, "get_vod_streams")

        func names(_ rs: [[String: Any]]) -> [String: String] {
            Dictionary(rs.compactMap { r -> (String, String)? in
                guard let i = string(r, "category_id"), let n = string(r, "category_name") else { return nil }
                return (i, n)
            }, uniquingKeysWith: { a, _ in a })
        }

        let b = base(s), u = esc(s.username), p = esc(s.password)
        var out: [Channel] = []

        let lc = names(try await liveCats)
        for r in try await live {
            guard let id = string(r, "stream_id"), let name = string(r, "name"),
                  // .m3u8 (HLS), not .ts — AVPlayer can't demux raw MPEG-TS.
                  let url = URL(string: "\(b)/live/\(u)/\(p)/\(id).m3u8") else { continue }
            out.append(Channel(id: "live-\(id)", name: name,
                               group: lc[string(r, "category_id") ?? ""] ?? "Live",
                               logo: URL(string: string(r, "stream_icon") ?? ""), url: url,
                               streamID: id))
        }

        let vc = names(try await vodCats)
        for r in try await vod {
            guard let id = string(r, "stream_id"), let name = string(r, "name") else { continue }
            let ext = string(r, "container_extension") ?? "mp4"
            guard let url = URL(string: "\(b)/movie/\(u)/\(p)/\(id).\(ext)") else { continue }
            out.append(Channel(id: "vod-\(id)", name: name,
                               group: "Movies · " + (vc[string(r, "category_id") ?? ""] ?? "All"),
                               logo: URL(string: string(r, "stream_icon") ?? ""), url: url))
        }
        return out
    }

    /// Now/next for one live channel. get_short_epg is a single small request per channel;
    /// the alternative (xmltv.php) is a multi-megabyte dump of the entire portal.
    static func epg(_ s: Server, streamID: String, limit: Int = 8) async throws -> [Programme] {
        let listings = try await rows(s, "get_short_epg", "&stream_id=\(streamID)&limit=\(limit)")
        return listings.compactMap { r in
            guard let startSecs = string(r, "start_timestamp").flatMap(Double.init),
                  let stopSecs = string(r, "stop_timestamp").flatMap(Double.init) else { return nil }
            return Programme(
                id: string(r, "id") ?? "\(startSecs)",
                title: decodeEPGText(string(r, "title") ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                summary: decodeEPGText(string(r, "description") ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                start: Date(timeIntervalSince1970: startSecs),
                stop: Date(timeIntervalSince1970: stopSecs))
        }
        .sorted { $0.start < $1.start }
    }
}

/// Starred channels, keyed by source + channel name so they survive a playlist reordering
/// (M3U entry ids are positional). ponytail: UserDefaults, not a file — it is a string set.
enum Favorites {
    private static let key = "favorites"

    static func key(_ source: Source.ID, _ channel: Channel) -> String {
        "\(source.uuidString)|\(channel.name)"
    }

    static func load() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func save(_ favorites: Set<String>) {
        UserDefaults.standard.set(Array(favorites), forKey: key)
    }
}

// MARK: - M3U

private let attrRE = try! NSRegularExpression(pattern: "([A-Za-z0-9_-]+)=\"([^\"]*)\"")

/// Splits `#EXTINF:-1 group-title="News, Sports",BBC One` at the first comma outside quotes.
func splitEXTINF(_ s: String) -> (attrs: String, name: String) {
    var quoted = false
    for i in s.indices {
        if s[i] == "\"" { quoted.toggle() }
        else if s[i] == "," && !quoted {
            return (String(s[s.startIndex..<i]), String(s[s.index(after: i)...]))
        }
    }
    return (s, "")
}

func parseM3U(_ text: String, base: URL? = nil) -> [Channel] {
    var out: [Channel] = []
    var name = "", group = "", logo = ""
    for raw in text.split(whereSeparator: \.isNewline) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("#EXTINF") {
            let (attrs, n) = splitEXTINF(line)
            name = n.trimmingCharacters(in: .whitespaces)
            var found: [String: String] = [:]
            for m in attrRE.matches(in: attrs, range: NSRange(attrs.startIndex..., in: attrs)) {
                guard let k = Range(m.range(at: 1), in: attrs), let v = Range(m.range(at: 2), in: attrs) else { continue }
                found[String(attrs[k]).lowercased()] = String(attrs[v])
            }
            group = found["group-title"] ?? ""
            logo = found["tvg-logo"] ?? ""
        } else if !line.isEmpty, !line.hasPrefix("#") {
            guard let url = URL(string: line, relativeTo: base) else { continue }
            out.append(Channel(id: "m3u-\(out.count)", name: name.isEmpty ? line : name,
                               group: group.isEmpty ? "Playlist" : group,
                               logo: URL(string: logo), url: url.absoluteURL))
            name = ""; group = ""; logo = ""
        }
    }
    return out
}

// MARK: - MPEG-TS remux
// AVPlayer has no MPEG-TS demuxer, and most Xtream panels serve .ts. ffmpeg repackages the
// same elementary streams into a local HLS playlist (-c copy, no transcode) that AVPlayer
// can open. ponytail: one stream at a time, and a copy-only remux — a channel using codecs
// HLS can't carry (MPEG-2, AC-3) still fails; add an -c:v h264 transcode branch if that shows up.

enum Remux {
    static let ffmpeg: String? = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    private static var proc: Process?
    private static let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("xstream-remux", isDirectory: true)

    static func stop() {
        proc?.terminate()
        proc = nil
    }

    /// Starts ffmpeg on `source` and returns a local playlist URL once it has segments.
    static func start(_ source: URL, userAgent: String) async throws -> URL {
        guard let ffmpeg else {
            throw Err("This channel is MPEG-TS, which the native player can't decode. Install ffmpeg (brew install ffmpeg) to remux it, or use Open Externally.")
        }
        stop()
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let playlist = dir.appendingPathComponent("stream.m3u8")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = [
            "-hide_banner", "-loglevel", "error",
            "-user_agent", userAgent,
            "-i", source.absoluteString,
            "-c", "copy",
            "-f", "hls", "-hls_time", "2", "-hls_list_size", "6",
            "-hls_flags", "delete_segments+omit_endlist",
            playlist.path,
        ]
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        proc = p

        // Wait for the first segments to land, else AVPlayer opens an empty playlist.
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(250))
            if let s = try? String(contentsOf: playlist, encoding: .utf8), s.contains(".ts") { return playlist }
            if !p.isRunning {
                let msg = String(data: errPipe.fileHandleForReading.availableData, encoding: .utf8) ?? ""
                throw Err("ffmpeg could not read the stream. \(msg.split(separator: "\n").last.map(String.init) ?? "")")
            }
        }
        stop()
        throw Err("ffmpeg produced no segments within 15s — the server is stalling or the stream is dead.")
    }
}

/// Xtream serves the same channel at .m3u8 (HLS) and .ts (raw MPEG-TS). Swap to .ts.
func tsVariant(_ url: URL) -> URL? {
    guard url.pathExtension.lowercased() == "m3u8" else { return nil }
    return url.deletingPathExtension().appendingPathExtension("ts")
}

// MARK: - Redirect resolution

/// AVFoundation refuses to follow an https→http redirect and reports it as "A TLS error
/// caused the secure connection to fail". Xtream panels behind Cloudflare routinely 302 a
/// stream to a plain-http edge node, so resolve the chain ourselves and hand AVPlayer the
/// final URL. Headers only — the body is cancelled, so this never pulls the stream itself.
private final class StopAtRedirect: NSObject, URLSessionTaskDelegate {
    static let shared = StopAtRedirect()
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

func resolveStream(_ url: URL, userAgent: String) async -> URL {
    var current = url
    for _ in 0..<5 {
        var req = URLRequest(url: current)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (bytes, response) = try? await URLSession.shared.bytes(for: req, delegate: StopAtRedirect.shared),
              let http = response as? HTTPURLResponse else { return current }
        bytes.task.cancel()
        guard (300...399).contains(http.statusCode),
              let location = http.value(forHTTPHeaderField: "Location"),
              let next = URL(string: location, relativeTo: current) else { return current }
        current = next.absoluteURL
    }
    return current
}

// MARK: - External players

import AppKit

/// Handing the stream to VLC/Infuse/IINA sidesteps every AVFoundation limitation at once:
/// they demux MPEG-TS, follow https→http redirects, and handle mkv/AC-3.
struct External: Identifiable, Hashable {
    let name: String
    let bundleID: String
    let app: URL
    var id: String { bundleID }

    static let installed: [External] = [
        ("VLC", "org.videolan.vlc"),
        ("IINA", "com.colliderli.iina"),
        ("Infuse", "com.firecore.infuse"),
        ("mpv", "io.mpv"),
        ("QuickTime Player", "com.apple.QuickTimePlayerX"),
    ].compactMap { name, id in
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            .map { External(name: name, bundleID: id, app: $0) }
    }

    /// VLC is the default when installed: it demuxes TS and follows redirects, so it works
    /// on panels the native player can't touch. Falls back to the built-in player if absent.
    static let defaultChoice = installed.first { $0.bundleID == "org.videolan.vlc" }?.id ?? ""

    func play(_ stream: URL) {
        // Infuse takes streams through its x-callback scheme rather than as an opened URL.
        if bundleID == "com.firecore.infuse",
           let enc = stream.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
           let deepLink = URL(string: "infuse://x-callback-url/play?url=\(enc)") {
            NSWorkspace.shared.open(deepLink)
            return
        }
        NSWorkspace.shared.open([stream], withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration())
    }
}
