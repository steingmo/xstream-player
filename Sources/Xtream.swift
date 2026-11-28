import Foundation

// MARK: - Model

enum ChannelQuality: String, Hashable, Sendable, Comparable {
    case uhd4K = "4K"
    case raw = "RAW"
    case fhd = "FHD"
    case hd = "HD"
    case sd = "SD"

    var rank: Int {
        switch self {
        case .uhd4K: return 4
        case .raw: return 3
        case .fhd: return 2
        case .hd: return 1
        case .sd: return 0
        }
    }

    static func < (lhs: ChannelQuality, rhs: ChannelQuality) -> Bool { lhs.rank < rhs.rank }

    var isHighDefinition: Bool { rank >= 1 }
}

struct Channel: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let name: String
    let group: String
    let logo: URL?
    let url: URL
    /// Xtream live stream id — nil for VOD and for M3U entries, which have no EPG.
    var streamID: String? = nil
    /// Optional schedule or description text (e.g. XML portal `<epgdata>`).
    var notes: String? = nil

    var quality: ChannelQuality? { Self.parseQuality(name) }

    /// Detects quality tags like 4K/UHD/2160p, RAW, FHD/1080p, HD/720p, SD (including
    /// Unicode superscript tags such as ᴴᴰ or ᴿᴬᵂ common on IPTV portals) on whole-word
    /// boundaries so words like "Shadow" or "Draw" never false-match.
    static func parseQuality(_ name: String) -> ChannelQuality? {
        var normalized = String()
        normalized.reserveCapacity(name.count)
        for ch in name {
            switch ch {
            case "ᴬ": normalized.append("A")
            case "ᴰ": normalized.append("D")
            case "ᶠ": normalized.append("F")
            case "ᴴ": normalized.append("H")
            case "ᴷ": normalized.append("K")
            case "ᴾ": normalized.append("P")
            case "ᴿ": normalized.append("R")
            case "ˢ": normalized.append("S")
            case "ᵁ": normalized.append("U")
            case "ᵂ": normalized.append("W")
            case "⁰": normalized.append("0")
            case "¹": normalized.append("1")
            case "²": normalized.append("2")
            case "⁴": normalized.append("4")
            case "⁶": normalized.append("6")
            case "⁷": normalized.append("7")
            case "⁸": normalized.append("8")
            default:
                if ch.isLetter || ch.isNumber {
                    normalized.append(ch.uppercased())
                } else {
                    normalized.append(" ")
                }
            }
        }

        var best: ChannelQuality?
        for token in normalized.split(separator: " ") {
            let candidate: ChannelQuality?
            switch token {
            case "4K", "UHD", "2160P": candidate = .uhd4K
            case "RAW": candidate = .raw
            case "FHD", "1080P": candidate = .fhd
            case "HD", "720P": candidate = .hd
            case "SD", "576P", "480P": candidate = .sd
            default: candidate = nil
            }
            if let candidate, best == nil || candidate > best! {
                best = candidate
            }
        }
        return best
    }
}

struct Programme: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let summary: String
    let start: Date
    let stop: Date

    var isNow: Bool { let t = Date(); return t >= start && t < stop }
}

/// Subscription and connection status returned by Xtream's `player_api.php` (no action).
struct AccountInfo: Equatable, Sendable {
    let status: String
    let expiresAt: Date?
    let activeConnections: Int?
    let maxConnections: Int?
    let isTrial: Bool
    let allowedFormats: [String]
    let timezone: String?

    var isActive: Bool { status.caseInsensitiveCompare("Active") == .orderedSame }

    func daysRemaining(from now: Date = Date()) -> Int? {
        guard let expiresAt else { return nil }
        return Int(floor(expiresAt.timeIntervalSince(now) / 86_400))
    }

    var connectionsSummary: String? {
        switch (activeConnections, maxConnections) {
        case let (a?, m?): return "\(a) / \(m)"
        case let (nil, m?): return "max \(m)"
        default: return nil
        }
    }
}

struct Server: Codable, Hashable {
    var host = ""          // http://host:port
    var username = ""
    var password = ""
}

struct XMLPortalServer: Codable, Hashable, Sendable {
    var baseURL = ""
    var loginPath = "/amember/login"
    var directoryPath = ""
    var username = ""
    var password = ""
}

enum SourceKind: Codable, Hashable {
    case xtream(Server)
    case m3u(path: String)
    case xmlPortal(XMLPortalServer)
}

struct Source: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var kind: SourceKind
    /// Optional so sources.json files written before filters existed still decode.
    var filter: SourceFilter?
}

/// Per-source choice of what the channel list shows: whole sections on or off, which
/// categories are hidden, and the order categories appear in.
struct SourceFilter: Codable, Hashable, Sendable {
    var live = true
    var movies = true
    /// Groups (Channel.group) the user unticked.
    var hidden: Set<String> = []
    /// Every group the server had when the filter was last saved. With `showNew` off, a
    /// group outside this set is treated as hidden, so "only these three" stays three.
    var known: Set<String> = []
    var showNew = true
    /// The user's category order. Groups not in it follow, A–Z. Empty means plain A–Z.
    var order: [String] = []

    static let moviePrefix = "Movies · "

    init() {}

    // Hand-written so a field added later doesn't make older saved filters undecodable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        live = try c.decodeIfPresent(Bool.self, forKey: .live) ?? true
        movies = try c.decodeIfPresent(Bool.self, forKey: .movies) ?? true
        hidden = try c.decodeIfPresent(Set<String>.self, forKey: .hidden) ?? []
        known = try c.decodeIfPresent(Set<String>.self, forKey: .known) ?? []
        showNew = try c.decodeIfPresent(Bool.self, forKey: .showNew) ?? true
        order = try c.decodeIfPresent([String].self, forKey: .order) ?? []
    }

    func isVisible(group: String) -> Bool {
        if hidden.contains(group) { return false }
        return showNew || known.isEmpty || known.contains(group)
    }

    func includes(_ c: Channel) -> Bool {
        if !live && c.id.hasPrefix("live-") { return false }
        if !movies && c.id.hasPrefix("vod-") { return false }
        return isVisible(group: c.group)
    }

    func apply(_ channels: [Channel]) -> [Channel] { channels.filter(includes) }

    /// `groups` in the user's order, then everything else A–Z. Duplicates collapse.
    func sorted(_ groups: [String]) -> [String] {
        let all = Set(groups)
        var seen = Set<String>()
        let pinned = order.filter { all.contains($0) && seen.insert($0).inserted }
        let rest = all.subtracting(seen)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return pinned + rest
    }
}

/// Pre-indexed view of a source's visible channels so switching categories, looking up a
/// selection, and searching don't rescan 30k channels on every SwiftUI body render.
struct ChannelIndex: Equatable, Sendable {
    static let allGroup = "All"
    static let favoritesGroup = "\u{2605} Favorites"
    static let recentsGroup = "Recent"

    let channels: [Channel]
    let groups: [String]
    let categoryGroups: [String]
    let byGroup: [String: [Channel]]
    let byID: [Channel.ID: Channel]

    static let empty = ChannelIndex(channels: [], filter: SourceFilter())

    init(channels: [Channel], filter: SourceFilter) {
        self.channels = channels
        var grouped: [String: [Channel]] = [:]
        var indexed: [Channel.ID: Channel] = Dictionary(minimumCapacity: channels.count)
        for c in channels {
            grouped[c.group, default: []].append(c)
            if indexed[c.id] == nil { indexed[c.id] = c }
        }
        self.byGroup = grouped
        self.byID = indexed
        let sortedCategories = filter.sorted(Array(grouped.keys))
        self.categoryGroups = sortedCategories
        self.groups = [Self.allGroup, Self.favoritesGroup] + sortedCategories
    }

    /// The channels in `group` before any search query is applied — O(1) for every group.
    func base(group: String, favorites: [Channel], recents: [Channel] = []) -> [Channel] {
        switch group {
        case Self.allGroup: return channels
        case Self.favoritesGroup: return favorites
        case Self.recentsGroup: return recents
        default: return byGroup[group] ?? []
        }
    }

    func filter(group: String, query: String, favorites: [Channel], recents: [Channel] = []) -> [Channel] {
        Self.filter(base(group: group, favorites: favorites, recents: recents), query: query)
    }

    /// Filters a pre-selected pool by `query`. Checks task cancellation periodically so a
    /// superseded search over tens of thousands of channels exits early.
    static func filter(_ pool: [Channel], query: String) -> [Channel] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return pool }
        var out: [Channel] = []
        for (i, c) in pool.enumerated() {
            if i & 1023 == 0 && Task.isCancelled { return [] }
            if c.name.localizedCaseInsensitiveContains(q) { out.append(c) }
        }
        return out
    }
}

/// Xtream panels base64-encode EPG text, but not all of them do it consistently —
/// only decode strict base64 whose UTF-8 output contains printable text, otherwise pass
/// through raw so plain-text titles never get garbled.
func decodeEPGText(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count % 4 == 0 else { return raw }
    // Strict base64 check: only valid base64 chars, '=' padding only at the end (max 2).
    var seenPad = 0
    for u in trimmed.unicodeScalars {
        let v = u.value
        let isAlphaNum = (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || (v >= 48 && v <= 57)
        if isAlphaNum || v == 43 || v == 47 {
            if seenPad > 0 { return raw }
        } else if v == 61 {
            seenPad += 1
            if seenPad > 2 { return raw }
        } else {
            return raw
        }
    }
    guard let d = Data(base64Encoded: trimmed),
          let s = String(data: d, encoding: .utf8), !s.isEmpty else { return raw }
    // Reject ASCII control characters (except tab/LF/CR) that indicate coincidental decode.
    for u in s.unicodeScalars {
        let v = u.value
        if (v < 0x20 && v != 0x09 && v != 0x0A && v != 0x0D) || v == 0x7F { return raw }
    }
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
        // Created 0600 rather than chmod-ed after, so the password is never world-readable.
        FileManager.default.createFile(atPath: file.path, contents: d, attributes: [.posixPermissions: 0o600])
    }
}

/// Per-source disk cache of fetched channels so Xstream opens instantaneously on large
/// portals while refreshing in the background. Stored 0600 because stream URLs embed
/// portal credentials.
enum ChannelCache {
    private struct Snapshot: Codable {
        let live: Bool
        let movies: Bool
        let channels: [Channel]
    }

    static let directory: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Xstream/cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func url(for sourceID: Source.ID) -> URL {
        directory.appendingPathComponent("\(sourceID.uuidString).json")
    }

    static func load(sourceID: Source.ID, live: Bool, movies: Bool) async -> [Channel]? {
        let file = url(for: sourceID)
        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: file),
                  let snap = try? JSONDecoder().decode(Snapshot.self, from: data),
                  snap.live == live && snap.movies == movies else { return nil }
            return snap.channels
        }.value
    }

    static func save(_ channels: [Channel], sourceID: Source.ID, live: Bool, movies: Bool) {
        let file = url(for: sourceID)
        let snap = Snapshot(live: live, movies: movies, channels: channels)
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snap) else { return }
            FileManager.default.createFile(atPath: file.path, contents: data,
                                           attributes: [.posixPermissions: 0o600])
        }
    }

    static func remove(sourceID: Source.ID) {
        try? FileManager.default.removeItem(at: url(for: sourceID))
    }
}

// MARK: - Xtream Codes API

/// Xtream panels inconsistently encode IDs, timestamps, and flags as either strings or
/// numbers. Decoding loosely into a String avoids failing on either representation.
struct LossyString: Decodable {
    let value: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { value = nil; return }
        if let s = try? c.decode(String.self) { value = s.isEmpty ? nil : s; return }
        if let i = try? c.decode(Int64.self) { value = String(i); return }
        if let d = try? c.decode(Double.self) { value = String(d); return }
        if let b = try? c.decode(Bool.self) { value = b ? "1" : "0"; return }
        value = nil
    }
}

enum Xtream {
    private struct CategoryRow: Decodable {
        let category_id: LossyString?
        let category_name: LossyString?
    }

    private struct LiveRow: Decodable {
        let stream_id: LossyString?
        let name: LossyString?
        let category_id: LossyString?
        let stream_icon: LossyString?
    }

    private struct VodRow: Decodable {
        let stream_id: LossyString?
        let name: LossyString?
        let category_id: LossyString?
        let stream_icon: LossyString?
        let container_extension: LossyString?
    }

    private struct EPGRow: Decodable {
        let id: LossyString?
        let title: LossyString?
        let description: LossyString?
        let start_timestamp: LossyString?
        let stop_timestamp: LossyString?
    }

    private struct EPGEnvelope: Decodable {
        let epg_listings: [EPGRow]?
    }

    private struct AccountEnvelope: Decodable {
        struct UserInfo: Decodable {
            let status: LossyString?
            let exp_date: LossyString?
            let active_cons: LossyString?
            let max_connections: LossyString?
            let is_trial: LossyString?
            let allowed_output_formats: [String]?
        }
        struct ServerInfo: Decodable {
            let timezone: LossyString?
        }
        let user_info: UserInfo?
        let server_info: ServerInfo?
    }

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

    private static func fetch(_ s: Server, _ action: String? = nil, _ extra: String = "") async throws -> Data {
        var str = "\(base(s))/player_api.php?username=\(esc(s.username))&password=\(esc(s.password))"
        if let action { str += "&action=\(action)\(extra)" }
        guard let u = URL(string: str) else { throw Err("Bad server address") }
        let (d, r) = try await URLSession.shared.data(from: u)
        if let h = r as? HTTPURLResponse, h.statusCode != 200 {
            throw Err("HTTP \(h.statusCode)\(action.map { " on \($0)" } ?? "")")
        }
        return d
    }

    private static func decodeArray<T: Decodable>(_ type: [T].Type, from data: Data, action: String) throws -> [T] {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw Err("Unexpected reply to \(action) — wrong credentials or not an Xtream server?")
        }
    }

    private static func names(_ rs: [CategoryRow]) -> [String: String] {
        Dictionary(rs.compactMap { r -> (String, String)? in
            guard let i = r.category_id?.value, let n = r.category_name?.value else { return nil }
            return (i, n)
        }, uniquingKeysWith: { a, _ in a })
    }

    /// Category names as the channel list groups them, in the provider's order. Two small
    /// requests, so the server sheet can offer them before any stream list is downloaded.
    static func categories(_ s: Server) async throws -> [String] {
        async let liveData = fetch(s, "get_live_categories")
        async let vodData = fetch(s, "get_vod_categories")
        let liveCats = try decodeArray([CategoryRow].self, from: try await liveData, action: "get_live_categories")
        let vodCats = try decodeArray([CategoryRow].self, from: try await vodData, action: "get_vod_categories")
        return liveCats.compactMap { $0.category_name?.value }
            + vodCats.compactMap { $0.category_name?.value.map { SourceFilter.moviePrefix + $0 } }
    }

    /// Live channels + VOD movies. Series are skipped: each one needs its own episode fetch.
    /// A section that is switched off is not downloaded at all; the VOD list is the big one.
    static func channels(_ s: Server, live wantLive: Bool = true,
                         movies wantMovies: Bool = true) async throws -> [Channel] {
        async let liveCatsData: Data? = wantLive ? try await fetch(s, "get_live_categories") : nil
        async let liveData: Data? = wantLive ? try await fetch(s, "get_live_streams") : nil
        async let vodCatsData: Data? = wantMovies ? try await fetch(s, "get_vod_categories") : nil
        async let vodData: Data? = wantMovies ? try await fetch(s, "get_vod_streams") : nil

        let lc = try await liveCatsData.map { try names(decodeArray([CategoryRow].self, from: $0, action: "get_live_categories")) } ?? [:]
        let liveRows = try await liveData.map { try decodeArray([LiveRow].self, from: $0, action: "get_live_streams") } ?? []
        let vc = try await vodCatsData.map { try names(decodeArray([CategoryRow].self, from: $0, action: "get_vod_categories")) } ?? [:]
        let vodRows = try await vodData.map { try decodeArray([VodRow].self, from: $0, action: "get_vod_streams") } ?? []

        let b = base(s), u = esc(s.username), p = esc(s.password)
        var out: [Channel] = []
        out.reserveCapacity(liveRows.count + vodRows.count)

        for r in liveRows {
            guard let id = r.stream_id?.value, let name = r.name?.value,
                  // .m3u8 rather than .ts: both work in VLC, and HLS survives a flaky
                  // connection better. Panels with HLS disabled would need .ts here.
                  let url = URL(string: "\(b)/live/\(u)/\(p)/\(id).m3u8") else { continue }
            out.append(Channel(id: "live-\(id)", name: name,
                               group: lc[r.category_id?.value ?? ""] ?? "Live",
                               logo: URL(string: r.stream_icon?.value ?? ""), url: url,
                               streamID: id))
        }

        for r in vodRows {
            guard let id = r.stream_id?.value, let name = r.name?.value else { continue }
            let ext = r.container_extension?.value ?? "mp4"
            guard let url = URL(string: "\(b)/movie/\(u)/\(p)/\(id).\(ext)") else { continue }
            out.append(Channel(id: "vod-\(id)", name: name,
                               group: SourceFilter.moviePrefix + (vc[r.category_id?.value ?? ""] ?? "All"),
                               logo: URL(string: r.stream_icon?.value ?? ""), url: url))
        }
        return out
    }

    /// Parses `user_info` + `server_info` from `player_api.php` (no action).
    static func parseAccountInfo(_ data: Data) -> AccountInfo? {
        guard let env = try? JSONDecoder().decode(AccountEnvelope.self, from: data),
              let user = env.user_info else { return nil }

        let status = user.status?.value ?? "Unknown"
        let expSecs = user.exp_date?.value.flatMap(Double.init)
        let expiresAt: Date? = (expSecs != nil && expSecs! > 0) ? Date(timeIntervalSince1970: expSecs!) : nil
        let activeCons = user.active_cons?.value.flatMap(Int.init)
        let maxCons = user.max_connections?.value.flatMap(Int.init)
        let trialStr = user.is_trial?.value?.lowercased() ?? "0"
        let isTrial = trialStr == "1" || trialStr == "true"

        return AccountInfo(
            status: status,
            expiresAt: expiresAt,
            activeConnections: activeCons,
            maxConnections: maxCons,
            isTrial: isTrial,
            allowedFormats: user.allowed_output_formats ?? [],
            timezone: env.server_info?.timezone?.value
        )
    }

    static func accountInfo(_ s: Server) async throws -> AccountInfo {
        let d = try await fetch(s)
        guard let info = parseAccountInfo(d) else {
            throw Err("Could not read account info — wrong credentials or not an Xtream server?")
        }
        return info
    }

    static func parseEPG(_ data: Data) -> [Programme] {
        let decoder = JSONDecoder()
        let rows: [EPGRow]
        if let env = try? decoder.decode(EPGEnvelope.self, from: data), let list = env.epg_listings {
            rows = list
        } else if let bare = try? decoder.decode([EPGRow].self, from: data) {
            rows = bare
        } else {
            return []
        }
        return rows.compactMap { r in
            guard let startSecs = r.start_timestamp?.value.flatMap(Double.init),
                  let stopSecs = r.stop_timestamp?.value.flatMap(Double.init) else { return nil }
            return Programme(
                id: r.id?.value ?? "\(startSecs)",
                title: decodeEPGText(r.title?.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                summary: decodeEPGText(r.description?.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                start: Date(timeIntervalSince1970: startSecs),
                stop: Date(timeIntervalSince1970: stopSecs))
        }
        .sorted { $0.start < $1.start }
    }

    /// Now/next for one live channel. get_short_epg is a single small request per channel;
    /// the alternative (xmltv.php) is a multi-megabyte dump of the entire portal.
    static func epg(_ s: Server, streamID: String, limit: Int = 12) async throws -> [Programme] {
        let data = try await fetch(s, "get_short_epg", "&stream_id=\(streamID)&limit=\(limit)")
        return parseEPG(data)
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

/// Recently played channels per source (ordered newest first, keyed by channel name).
enum Recents {
    private static let key = "recentsBySource"
    static let maxPerSource = 20

    static func load() -> [String: [String]] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: [String]]) ?? [:]
    }

    static func save(_ store: [String: [String]]) {
        UserDefaults.standard.set(store, forKey: key)
    }

    static func record(_ sourceID: Source.ID, channelName: String, in store: inout [String: [String]]) {
        let k = sourceID.uuidString
        var list = store[k] ?? []
        list.removeAll { $0 == channelName }
        list.insert(channelName, at: 0)
        if list.count > maxPerSource { list.removeLast(list.count - maxPerSource) }
        store[k] = list
    }

    static func resolve(_ sourceID: Source.ID, from store: [String: [String]], in channels: [Channel]) -> [Channel] {
        guard let names = store[sourceID.uuidString], !names.isEmpty else { return [] }
        var byName: [String: Channel] = [:]
        let wanted = Set(names)
        for c in channels where wanted.contains(c.name) && byName[c.name] == nil {
            byName[c.name] = c
        }
        return names.compactMap { byName[$0] }
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

/// Reads and parses a local M3U off the main actor so multi-megabyte playlists don't stall UI.
func loadM3U(path: String) async throws -> [Channel] {
    let url = URL(fileURLWithPath: path)
    let task = Task.detached(priority: .userInitiated) {
        parseM3U(try String(contentsOf: url, encoding: .utf8), base: url)
    }
    return try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}

// MARK: - M3U export

/// Writes a playlist any other player can open. Round-trips with parseM3U: URLs come back
/// byte-identical, names and groups come back the same except that a double quote inside a
/// group becomes an apostrophe and the parser trims surrounding whitespace. M3U attributes
/// have no escape for a quote — every parser, ours included, reads to the next one — so
/// substituting beats emitting a line that other apps would silently truncate.
/// Note the URLs carry the portal's username and password, as any IPTV playlist does.
func exportM3U(_ channels: [Channel], note: String? = nil, date: Date = Date()) -> String {
    func attr(_ v: String) -> String { v.replacingOccurrences(of: "\"", with: "'") }

    // Comment lines after #EXTM3U: players ignore what they don't recognise, so this says
    // where the file came from without making it unreadable anywhere.
    var out = "#EXTM3U\n"
    out += "# Exported from Xstream — https://github.com/steingmo/xstream-player\n"
    if let note { out += "# \(note)\n" }
    out += "# \(channels.count) channel\(channels.count == 1 ? "" : "s"), "
    out += "\(date.formatted(date: .abbreviated, time: .shortened))\n"
    out += "# The stream URLs below contain your portal username and password.\n"
    for c in channels {
        var attrs = ""
        if let logo = c.logo?.absoluteString, !logo.isEmpty { attrs += " tvg-logo=\"\(attr(logo))\"" }
        if !c.group.isEmpty { attrs += " group-title=\"\(attr(c.group))\"" }
        out += "#EXTINF:-1\(attrs),\(c.name)\n\(c.url.absoluteString)\n"
    }
    return out
}

// MARK: - VLC

import AppKit

/// Every stream goes to VLC. It demuxes MPEG-TS, follows the https→http redirects Xtream
/// panels hand out, and copes with mkv/AC-3 — none of which AVFoundation manages. That is
/// why the built-in player, its redirect resolver and the ffmpeg remux are all gone: they
/// existed only to work around AVFoundation, and VLC needs none of it.
enum VLC {
    /// Looked up on every play, so installing VLC while Xstream is open just works.
    static var app: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.videolan.vlc") }

    static func play(_ stream: URL) throws {
        guard let app else {
            throw Err("VLC is not installed. Install it with:  brew install --cask vlc")
        }
        NSWorkspace.shared.open([stream], withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - Guide cache

/// EPG is per-channel on Xtream (get_short_epg), so the list fills in as rows scroll into
/// view and every answer is cached. Shared by the channel rows and the player footer.
/// One ticker drives every row's idea of "now", so subtitles roll over at the top of the
/// hour instead of showing whatever was current when the row first appeared.
/// @MainActor is load-bearing, not decoration: without it `load` runs on the cooperative
/// pool, so the ~20 row tasks that fire on a fresh source mutate `listings`/`inflight`
/// concurrently and corrupt them (SIGSEGV inside Set.insert). Only the dictionary writes
/// happen here — the fetch and JSON parse stay off the main thread inside Xtream.epg.
@MainActor
@Observable
final class Guide {
    private struct Entry {
        let programmes: [Programme]
        let fetchedAt: Date
    }

    /// Empty EPG responses are cached briefly so channels with no guide don't re-request
    /// on every scroll, while still retrying later.
    private static let emptyTTL: TimeInterval = 15 * 60
    private static let maxConcurrent = 5

    private var entries: [String: Entry] = [:]
    /// Observed by every row, so bumping it re-evaluates which programme is current.
    private(set) var clock = Date()
    private var inflight: Set<String> = []
    private var activeRequests = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init() {
        // Lives as long as the app does, so there is nothing to cancel.
        Task { while true { try? await Task.sleep(for: .seconds(60)); clock = Date() } }
    }

    func programmes(_ channel: Channel) -> [Programme] { entries[channel.id]?.programmes ?? [] }

    func now(_ channel: Channel) -> Programme? {
        programmes(channel).first { clock >= $0.start && clock < $0.stop }
    }

    func needsRefresh(_ channel: Channel) -> Bool {
        guard channel.streamID != nil else { return false }
        guard let entry = entries[channel.id] else { return true }
        if let lastStop = entry.programmes.last?.stop {
            return lastStop <= clock
        }
        return clock.timeIntervalSince(entry.fetchedAt) >= Self.emptyTTL
    }

    func invalidate(_ channel: Channel) {
        entries.removeValue(forKey: channel.id)
    }

    func clear() {
        entries = [:]
        inflight = []
    }

    private func acquireSlot() async {
        if activeRequests < Self.maxConcurrent {
            activeRequests += 1
            return
        }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }

    private func releaseSlot() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        } else {
            activeRequests = max(0, activeRequests - 1)
        }
    }

    /// `debounce` lets rows that scroll straight past cancel before spending a request.
    /// `force` bypasses the cache for manual refreshes.
    func load(_ channel: Channel, from server: Server, debounce: Duration = .zero, force: Bool = false) async {
        guard let streamID = channel.streamID, !inflight.contains(channel.id) else { return }
        if !force && !needsRefresh(channel) { return }
        if debounce > .zero {
            try? await Task.sleep(for: debounce)
            if Task.isCancelled { return }
        }
        guard !inflight.contains(channel.id) else { return }
        if !force && !needsRefresh(channel) { return }

        inflight.insert(channel.id)
        defer { inflight.remove(channel.id) }

        await acquireSlot()
        defer { releaseSlot() }
        if Task.isCancelled { return }

        if let programmes = try? await Xtream.epg(server, streamID: streamID) {
            entries[channel.id] = Entry(programmes: programmes, fetchedAt: Date())
        }
    }
}

// MARK: - Stream Throughput & Latency Probe

struct StreamProbeResult: Equatable, Sendable {
    enum Quality: String, Sendable {
        case good = "Good"
        case fair = "Fair"
        case poor = "Poor"
    }

    let channelName: String
    let resolvedHost: String
    let ttfbMs: Int
    let pingMs: Int
    let jitterMs: Int
    let throughputMbps: Double
    let sampledBytes: Int
    let testedAt: Date

    var quality: Quality {
        if pingMs <= 120 && throughputMbps >= 10 { return .good }
        if pingMs <= 300 && throughputMbps >= 4 { return .fair }
        return .poor
    }
}

enum StreamProbe {
    private static let userAgent = "VLC/3.0.21 LibVLC/3.0.21"
    private static let maxSampleSeconds: TimeInterval = 2.0
    private static let maxSampleBytes = 6 * 1024 * 1024

    enum ProbeError: LocalizedError {
        case httpStatus(Int)
        case noData
        var errorDescription: String? {
            switch self {
            case .httpStatus(let code): return "Stream server returned HTTP \(code)."
            case .noData: return "Stream server returned no data."
            }
        }
    }

    /// Follows redirects on `channel.url` to the actual stream edge server, measures
    /// TTFB + ~2s download throughput (handles both live MPEG-TS and HLS .m3u8), and
    /// runs 2 lightweight follow-up pings to the resolved stream host for latency & jitter.
    static func measure(channel: Channel) async throws -> StreamProbeResult {
        var sample = try await sampleStream(url: channel.url)

        // If the channel URL returned an HLS playlist rather than raw TS video, resolve the
        // first media segment (following a master playlist one level if needed) and sample it.
        if let playlistText = sample.playlistText {
            if let firstURL = firstSegmentURL(in: playlistText, base: sample.finalURL) {
                let nextSample = try await sampleStream(url: firstURL)
                if let subText = nextSample.playlistText,
                   let segURL = firstSegmentURL(in: subText, base: nextSample.finalURL) {
                    sample = try await sampleStream(url: segURL)
                } else {
                    sample = nextSample
                }
            }
        }

        let resolvedHost = sample.finalURL.host ?? channel.url.host ?? "unknown"
        let ttfbMs = max(1, Int((sample.ttfb * 1000).rounded()))

        // 2 quick HEAD pings to the resolved stream edge origin for latency & jitter.
        var pings: [Int] = [ttfbMs]
        if let originURL = originURL(from: sample.finalURL) {
            for _ in 0..<2 {
                if let ms = await pingOrigin(originURL) {
                    pings.append(ms)
                }
            }
        }
        let sortedPings = pings.sorted()
        let medianPing = sortedPings[sortedPings.count / 2]
        let jitter = (sortedPings.last ?? medianPing) - (sortedPings.first ?? medianPing)

        let transferSecs = max(sample.transferDuration, 0.05)
        let mbps = (Double(sample.bytesRead) * 8.0) / (transferSecs * 1_000_000.0)

        return StreamProbeResult(
            channelName: channel.name,
            resolvedHost: resolvedHost,
            ttfbMs: ttfbMs,
            pingMs: medianPing,
            jitterMs: jitter,
            throughputMbps: mbps,
            sampledBytes: sample.bytesRead,
            testedAt: Date()
        )
    }

    static func firstSegmentURL(in playlist: String, base: URL) -> URL? {
        for raw in playlist.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let resolved = URL(string: line, relativeTo: base)?.absoluteURL {
                return resolved
            }
        }
        return nil
    }

    private static func originURL(from url: URL) -> URL? {
        var comps = URLComponents()
        comps.scheme = url.scheme ?? "http"
        comps.host = url.host
        comps.port = url.port
        comps.path = "/"
        return comps.url
    }

    private static func pingOrigin(_ url: URL) async -> Int? {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        req.httpMethod = "HEAD"
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let start = CFAbsoluteTimeGetCurrent()
        do {
            _ = try await URLSession.shared.data(for: req)
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            return max(1, Int((elapsed * 1000).rounded()))
        } catch {
            return nil
        }
    }

    private struct Sample {
        let finalURL: URL
        let ttfb: TimeInterval
        let transferDuration: TimeInterval
        let bytesRead: Int
        let playlistText: String?
    }

    private static func sampleStream(url: URL) async throws -> Sample {
        let delegate = StreamSampleDelegate(maxSeconds: maxSampleSeconds, maxBytes: maxSampleBytes)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 12
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                delegate.start(session: session, request: req, continuation: cont)
            }
        } onCancel: {
            delegate.cancel()
        }
    }

    private final class StreamSampleDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let maxSeconds: TimeInterval
        private let maxBytes: Int
        private let lock = NSLock()
        private var session: URLSession?
        private var task: URLSessionDataTask?
        private var continuation: CheckedContinuation<Sample, Error>?
        private var requestStart: CFAbsoluteTime = 0
        private var firstByteTime: CFAbsoluteTime = 0
        private var finalURL: URL?
        private var isPlaylist = false
        private var playlistBuffer = Data()
        private var bytesRead = 0
        private var finished = false

        init(maxSeconds: TimeInterval, maxBytes: Int) {
            self.maxSeconds = maxSeconds
            self.maxBytes = maxBytes
        }

        func start(session: URLSession, request: URLRequest, continuation: CheckedContinuation<Sample, Error>) {
            lock.lock()
            self.session = session
            self.continuation = continuation
            self.finalURL = request.url
            self.requestStart = CFAbsoluteTimeGetCurrent()
            let t = session.dataTask(with: request)
            self.task = t
            lock.unlock()
            t.resume()
        }

        func cancel() {
            lock.lock()
            let t = task
            let s = session
            let cont = finishLocked()
            lock.unlock()
            t?.cancel()
            s?.invalidateAndCancel()
            cont?.resume(throwing: CancellationError())
        }

        private func finishLocked() -> CheckedContinuation<Sample, Error>? {
            guard !finished else { return nil }
            finished = true
            let cont = continuation
            continuation = nil
            return cont
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            let now = CFAbsoluteTimeGetCurrent()
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                lock.lock()
                let cont = finishLocked()
                let s = self.session
                lock.unlock()
                completionHandler(.cancel)
                s?.invalidateAndCancel()
                cont?.resume(throwing: ProbeError.httpStatus(http.statusCode))
                return
            }
            let mime = (response.mimeType ?? "").lowercased()
            let url = response.url ?? dataTask.originalRequest?.url
            let looksPlaylist = mime.contains("mpegurl") || (url?.pathExtension.lowercased() == "m3u8")

            lock.lock()
            self.finalURL = url
            self.isPlaylist = looksPlaylist
            if self.firstByteTime == 0 { self.firstByteTime = now }
            lock.unlock()
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let now = CFAbsoluteTimeGetCurrent()
            lock.lock()
            if finished {
                lock.unlock()
                return
            }
            if firstByteTime == 0 { firstByteTime = now }
            bytesRead += data.count
            if isPlaylist && playlistBuffer.count < 64 * 1024 {
                playlistBuffer.append(data)
            }
            let elapsed = now - firstByteTime
            let shouldStop = !isPlaylist && (elapsed >= maxSeconds || bytesRead >= maxBytes)
            if shouldStop {
                let sample = Sample(
                    finalURL: finalURL ?? dataTask.originalRequest!.url!,
                    ttfb: max(0.001, firstByteTime - requestStart),
                    transferDuration: max(0.01, elapsed),
                    bytesRead: bytesRead,
                    playlistText: nil
                )
                let cont = finishLocked()
                let s = self.session
                lock.unlock()
                dataTask.cancel()
                s?.invalidateAndCancel()
                cont?.resume(returning: sample)
                return
            }
            lock.unlock()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let now = CFAbsoluteTimeGetCurrent()
            lock.lock()
            guard let cont = finishLocked() else {
                lock.unlock()
                return
            }
            let s = self.session
            let bytes = self.bytesRead
            let tStart = self.requestStart
            let tFirst = self.firstByteTime == 0 ? now : self.firstByteTime
            let url = self.finalURL ?? task.originalRequest?.url ?? URL(string: "http://localhost")!
            let plText: String? = self.isPlaylist && !self.playlistBuffer.isEmpty
                ? String(decoding: self.playlistBuffer, as: UTF8.self)
                : nil
            lock.unlock()

            s?.invalidateAndCancel()

            if bytes > 0 {
                let sample = Sample(
                    finalURL: url,
                    ttfb: max(0.001, tFirst - tStart),
                    transferDuration: max(0.01, now - tFirst),
                    bytesRead: bytes,
                    playlistText: plText
                )
                cont.resume(returning: sample)
            } else if let error {
                cont.resume(throwing: error)
            } else {
                cont.resume(throwing: ProbeError.noData)
            }
        }
    }
}

// MARK: - Generic Authenticated XML Portal (aMember + XML Directory + wmsAuthSign)

actor XMLPortalSessionStore {
    static let shared = XMLPortalSessionStore()
    private var cookies: [String: String] = [:]

    private func key(for server: XMLPortalServer) -> String {
        "\(XMLPortal.normalizedBase(server))|\(server.username)"
    }

    func cookie(for server: XMLPortalServer) -> String? {
        cookies[key(for: server)]
    }

    func setCookie(_ cookie: String, for server: XMLPortalServer) {
        cookies[key(for: server)] = cookie
    }

    func clear(for server: XMLPortalServer) {
        cookies.removeValue(forKey: key(for: server))
    }
}

enum XMLPortal {
    private static let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    enum PortalError: LocalizedError {
        case invalidURL
        case loginFailed
        case tokenFailed
        case httpStatus(Int)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid XML portal URL or directory path."
            case .loginFailed: return "Login failed — check your username, password, and login path."
            case .tokenFailed: return "Could not obtain a stream signing token from the portal."
            case .httpStatus(let code): return "Portal returned HTTP \(code)."
            }
        }
    }

    /// Trust delegate for portals whose HTTPS endpoints use self-signed or incomplete chains.
    private final class PermissiveTLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        return URLSession(configuration: config, delegate: PermissiveTLSDelegate(), delegateQueue: nil)
    }()

    static func normalizedBase(_ server: XMLPortalServer) -> String {
        var b = server.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        if !b.isEmpty && !b.hasPrefix("http://") && !b.hasPrefix("https://") {
            b = "https://" + b
        }
        return b
    }

    static func loginURL(_ server: XMLPortalServer) -> URL? {
        let base = normalizedBase(server)
        guard !base.isEmpty else { return nil }
        var path = server.loginPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty { path = "/amember/login" }
        if !path.hasPrefix("/") { path = "/" + path }
        return URL(string: base + path)
    }

    static func directoryURL(_ server: XMLPortalServer) -> URL? {
        let base = normalizedBase(server)
        guard !base.isEmpty else { return nil }
        var path = server.directoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty { path = "/" }
        if !path.hasPrefix("/") { path = "/" + path }
        if !path.hasSuffix("/") { path += "/" }
        return URL(string: base + path)
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)?.replacingOccurrences(of: "%20", with: "+") ?? value
    }

    private static func request(_ url: URL,
                                method: String = "GET",
                                body: Data? = nil,
                                cookie: String? = nil,
                                referer: URL? = nil) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.httpMethod = method
        req.httpBody = body
        req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue("en-GB,en;q=0.5", forHTTPHeaderField: "Accept-Language")
        if let referer {
            req.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }
        if method == "POST" {
            req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        }
        if let cookie, !cookie.isEmpty {
            req.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw PortalError.invalidURL }
        guard (200...399).contains(http.statusCode) else { throw PortalError.httpStatus(http.statusCode) }
        return (data, http)
    }

    static func login(_ server: XMLPortalServer) async throws -> String {
        guard let url = loginURL(server) else { throw PortalError.invalidURL }
        let form = "amember_login=\(formEncode(server.username))&amember_pass=\(formEncode(server.password))"
        let (data, http) = try await request(url, method: "POST", body: Data(form.utf8), referer: url)

        let bodyText = String(decoding: data, as: UTF8.self)
        let headerFields = http.allHeaderFields.reduce(into: [String: String]()) { acc, kv in
            if let k = kv.key as? String, let v = kv.value as? String { acc[k] = v }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
        let cookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")

        let okInBody = bodyText.range(of: #""ok"\s*:\s*true"#, options: .regularExpression) != nil
        guard okInBody || !cookieHeader.isEmpty else { throw PortalError.loginFailed }
        guard !cookieHeader.isEmpty else { throw PortalError.loginFailed }

        await XMLPortalSessionStore.shared.setCookie(cookieHeader, for: server)
        return cookieHeader
    }

    static func fetchHash(_ server: XMLPortalServer, cookie: String) async throws -> String {
        guard let dirURL = directoryURL(server),
              var comps = URLComponents(url: dirURL, resolvingAgainstBaseURL: false) else {
            throw PortalError.invalidURL
        }
        comps.queryItems = [URLQueryItem(name: "hash", value: "on")]
        guard let hashURL = comps.url else { throw PortalError.invalidURL }

        let (data, _) = try await request(hashURL, cookie: cookie, referer: loginURL(server))
        let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !raw.localizedCaseInsensitiveContains("Please login") else {
            throw PortalError.tokenFailed
        }
        var padded = raw
        while padded.count % 4 != 0 { padded.append("=") }
        if let decoded = Data(base64Encoded: padded),
           let decodedStr = String(data: decoded, encoding: .utf8),
           decodedStr.hasPrefix("server_time=") {
            return raw
        }
        throw PortalError.tokenFailed
    }

    /// Ensures a valid session cookie and returns `(cookie, wmsAuthSignHash)`.
    static func authenticate(_ server: XMLPortalServer) async throws -> (cookie: String, hash: String) {
        if let cached = await XMLPortalSessionStore.shared.cookie(for: server),
           let hash = try? await fetchHash(server, cookie: cached) {
            return (cached, hash)
        }
        let freshCookie = try await login(server)
        let hash = try await fetchHash(server, cookie: freshCookie)
        return (freshCookie, hash)
    }

    static func signedURL(_ url: URL, hash: String) -> URL {
        let sep = url.query == nil ? "?" : "&"
        return URL(string: "\(url.absoluteString)\(sep)wmsAuthSign=\(hash)") ?? url
    }

    /// Resolves a fresh signed playback URL right before starting playback.
    static func resolvePlaybackURL(for channel: Channel, server: XMLPortalServer) async throws -> URL {
        let (_, hash) = try await authenticate(server)
        return signedURL(channel.url, hash: hash)
    }

    /// Crawls the portal's XML directory and returns all discovered channels grouped by XML file.
    static func channels(_ server: XMLPortalServer) async throws -> [Channel] {
        guard let rootURL = directoryURL(server) else { throw PortalError.invalidURL }
        let (cookie, _) = try await authenticate(server)
        var visited = Set<URL>()
        var xmlFiles: [(group: String, url: URL)] = []
        try await crawlDirectory(rootURL, prefix: "", cookie: cookie, referer: loginURL(server),
                                 depth: 0, visited: &visited, xmlFiles: &xmlFiles)

        var all: [Channel] = []
        for entry in xmlFiles {
            if Task.isCancelled { return [] }
            if let (data, _) = try? await request(entry.url, cookie: cookie, referer: loginURL(server)) {
                let text = String(decoding: data, as: UTF8.self)
                all.append(contentsOf: parseXMLItems(text, group: entry.group))
            }
        }
        return all
    }

    static func categories(_ server: XMLPortalServer) async throws -> [String] {
        try await channels(server).map(\.group)
    }

    private static func crawlDirectory(_ url: URL,
                                       prefix: String,
                                       cookie: String,
                                       referer: URL?,
                                       depth: Int,
                                       visited: inout Set<URL>,
                                       xmlFiles: inout [(group: String, url: URL)]) async throws {
        guard depth <= 3, visited.insert(url).inserted else { return }
        let (data, _) = try await request(url, cookie: cookie, referer: referer)
        let html = String(decoding: data, as: UTF8.self)
        let links = parseDirectoryLinks(html, baseURL: url)
        for link in links {
            if link.isDirectory {
                let subPrefix = prefix.isEmpty ? link.name : "\(prefix) · \(link.name)"
                try await crawlDirectory(link.url, prefix: subPrefix, cookie: cookie, referer: referer,
                                         depth: depth + 1, visited: &visited, xmlFiles: &xmlFiles)
            } else {
                let cleanName = link.name.replacingOccurrences(of: ".xml", with: "", options: .caseInsensitive)
                let group = prefix.isEmpty ? cleanName : "\(prefix) · \(cleanName)"
                xmlFiles.append((group: group, url: link.url))
            }
        }
    }

    struct DirectoryLink: Equatable {
        let name: String
        let url: URL
        let isDirectory: Bool
    }

    static func parseDirectoryLinks(_ html: String, baseURL: URL) -> [DirectoryLink] {
        let pattern = #"<a\s+[^>]*href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var results: [DirectoryLink] = []
        for m in matches {
            let href = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            let rawLabel = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            if href.isEmpty || href.hasPrefix("?") || href.hasPrefix("#") || href == "../" || href == "/" { continue }
            let lowerLabel = rawLabel.lowercased()
            if lowerLabel == "parent directory" || href.lowercased().contains("recycle_bin") { continue }
            guard let resolved = URL(string: href, relativeTo: baseURL)?.absoluteURL,
                  resolved.host == baseURL.host else { continue }
            let cleanLabel = rawLabel
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            let label = cleanLabel.isEmpty ? resolved.lastPathComponent : cleanLabel
            if href.hasSuffix("/") {
                results.append(DirectoryLink(name: label, url: resolved, isDirectory: true))
            } else if href.lowercased().hasSuffix(".xml") {
                results.append(DirectoryLink(name: label, url: resolved, isDirectory: false))
            }
        }
        return results
    }

    static func parseXMLItems(_ xml: String, group: String) -> [Channel] {
        let itemPattern = #"<item\b[^>]*>(.*?)</item>"#
        guard let itemRegex = try? NSRegularExpression(pattern: itemPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let ns = xml as NSString
        let matches = itemRegex.matches(in: xml, range: NSRange(location: 0, length: ns.length))
        var channels: [Channel] = []
        for (idx, m) in matches.enumerated() {
            let body = ns.substring(with: m.range(at: 1))
            let title = decodeXMLEntities(firstTag("title", in: body) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle = title.isEmpty ? "Stream \(idx + 1)" : title

            var links = allTags("link", in: body)
                .map { decodeXMLEntities($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if links.isEmpty {
                // Fallback for bare .m3u8 lines inside <item>
                for line in body.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.lowercased().hasSuffix(".m3u8"), trimmed.hasPrefix("http") {
                        links.append(trimmed)
                    }
                }
            }
            guard !links.isEmpty else { continue }

            let thumbStr = firstTag("thumbnail", in: body)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let logo = thumbStr.isEmpty ? nil : URL(string: thumbStr)
            let rawEpg = firstTag("epgdata", in: body).map(decodeXMLEntities)?
                .replacingOccurrences(of: "/NL/", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let notes = (rawEpg?.isEmpty ?? true) ? nil : rawEpg

            if links.count > 1 {
                for (altIdx, linkStr) in links.enumerated() {
                    guard let url = URL(string: linkStr) else { continue }
                    let name = "\(altIdx + 1)) \(displayTitle)"
                    channels.append(Channel(
                        id: "xml-\(group)-\(idx)-\(altIdx)-\(linkStr.hashValue)",
                        name: name,
                        group: group,
                        logo: logo,
                        url: url,
                        streamID: nil,
                        notes: notes
                    ))
                }
            } else if let url = URL(string: links[0]) {
                channels.append(Channel(
                    id: "xml-\(group)-\(idx)-\(links[0].hashValue)",
                    name: displayTitle,
                    group: group,
                    logo: logo,
                    url: url,
                    streamID: nil,
                    notes: notes
                ))
            }
        }
        return channels
    }

    private static func firstTag(_ tag: String, in text: String) -> String? {
        allTags(tag, in: text).first
    }

    private static func allTags(_ tag: String, in text: String) -> [String] {
        let pattern = "<\(tag)\\b[^>]*>(.*?)</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1))
        }
    }

    private static func decodeXMLEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
    }
}
