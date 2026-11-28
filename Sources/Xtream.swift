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

enum SourceKind: Codable, Hashable {
    case xtream(Server)
    case m3u(path: String)
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
