import Foundation

// ponytail: one self-check for the only tricky logic here — the M3U parser.
// Run with ./build.sh test

let sample = """
#EXTM3U
#EXTINF:-1 tvg-id="bbc1" tvg-logo="http://x/logo.png" group-title="News, Sports",BBC One HD
http://example.com/live/1.m3u8
#EXTINF:-1,No Attributes
relative/stream.m3u8
bare-url-without-extinf.m3u8
"""

let base = URL(fileURLWithPath: "/tmp/playlist.m3u")
let cs = parseM3U(sample, base: base)

assert(cs.count == 3, "expected 3 entries, got \(cs.count)")
assert(cs[0].name == "BBC One HD", cs[0].name)
assert(cs[0].group == "News, Sports", cs[0].group)   // comma inside quotes must not split
assert(cs[0].logo?.absoluteString == "http://x/logo.png")
assert(cs[0].url.absoluteString == "http://example.com/live/1.m3u8")
assert(cs[1].name == "No Attributes" && cs[1].group == "Playlist", cs[1].group)
assert(cs[1].url.path == "/tmp/relative/stream.m3u8", cs[1].url.path)  // relative to playlist
assert(cs[2].name == "bare-url-without-extinf.m3u8", cs[2].name)

var s = Server(host: "http://tv.example.com:8080/", username: "u", password: "p")
assert(Xtream.base(s) == "http://tv.example.com:8080", Xtream.base(s))
s.host = "tv.example.com"
assert(Xtream.base(s) == "http://tv.example.com", Xtream.base(s))
assert(Xtream.string(["stream_id": 42], "stream_id") == "42")

// EPG text: panels base64 it, inconsistently.
assert(decodeEPGText("UHJlbWllciBMZWFndWU=") == "Premier League", decodeEPGText("UHJlbWllciBMZWFndWU="))
assert(decodeEPGText("Premier League") == "Premier League")   // not base64 -> passed through
assert(decodeEPGText("News") == "News", decodeEPGText("News")) // 4 chars: valid base64, invalid UTF-8
assert(decodeEPGText("") == "")

// Export has to survive our own parser, or the file is no use to anyone else either.
let roundTripped = parseM3U(exportM3U(cs), base: base)
assert(roundTripped.count == cs.count, "\(roundTripped.count) != \(cs.count)")
for (a, b) in zip(cs, roundTripped) {
    assert(a.name == b.name, "\(a.name) != \(b.name)")
    assert(a.group == b.group, "\(a.group) != \(b.group)")
    assert(a.url == b.url, "\(a.url) != \(b.url)")
    assert(a.logo == b.logo, "\(String(describing: a.logo)) != \(String(describing: b.logo))")
}
assert(exportM3U([]).hasPrefix("#EXTM3U"))

// The header is informational; it must not confuse a parser reading the file back.
let headed = exportM3U(cs, note: "my portal (favorites)")
assert(headed.hasPrefix("#EXTM3U\n# Exported from Xstream"), String(headed.prefix(60)))
assert(headed.contains("# my portal (favorites)"))
assert(headed.contains("# 3 channels, "))
assert(exportM3U([Channel(id: "1", name: "One", group: "G", logo: nil,
                          url: URL(string: "http://x/1.ts")!)]).contains("# 1 channel, "))
assert(parseM3U(headed, base: base) == parseM3U(exportM3U(cs), base: base), "header changed parsing")

// Real portals carry quotes in group names and stray whitespace in channel names —
// both showed up in a 29k-channel export. Pin the documented normalisation.
let tricky = [Channel(id: "x", name: "Ch \" One ", group: "US | \"Big Four\" Locals",
                      logo: nil, url: URL(string: "http://example.com/live/1.ts")!)]
let trickyBack = parseM3U(exportM3U(tricky), base: nil)
assert(trickyBack[0].url == tricky[0].url, "url must survive exactly")
assert(trickyBack[0].group == "US | 'Big Four' Locals", trickyBack[0].group)
assert(trickyBack[0].name == "Ch \" One", trickyBack[0].name)   // parser trims the trailing space
// And stable from there — a second trip changes nothing.
assert(parseM3U(exportM3U(trickyBack), base: nil) == trickyBack)

// Per-source filter: sections, hidden categories, order.
func ch(_ id: String, _ group: String) -> Channel {
    Channel(id: id, name: id, group: group, logo: nil, url: URL(string: "http://x/\(id)")!)
}
let mixed = [ch("live-1", "News"), ch("live-2", "Sport"), ch("vod-3", "Movies · Action"), ch("m3u-0", "News")]
var f = SourceFilter()
assert(f.apply(mixed) == mixed, "default filter must show everything")
f.movies = false
assert(f.apply(mixed).map(\.id) == ["live-1", "live-2", "m3u-0"])
f.movies = true; f.live = false
assert(f.apply(mixed).map(\.id) == ["vod-3", "m3u-0"], "M3U entries are not a section")
f.live = true; f.hidden = ["Sport"]
assert(f.apply(mixed).map(\.id) == ["live-1", "vod-3", "m3u-0"])
// showNew off: a category added after the last save stays hidden.
f.known = ["News", "Sport", "Movies · Action"]; f.showNew = false
assert(f.isVisible(group: "News") && !f.isVisible(group: "Kids"))
f.showNew = true
assert(f.isVisible(group: "Kids"))

assert(SourceFilter().sorted(["b", "A", "c", "b"]) == ["A", "b", "c"], "A–Z, deduplicated")
f.order = ["Sport", "Gone", "News", "Sport"]
assert(f.sorted(["Arts", "News", "Sport", "Zoo"]) == ["Sport", "News", "Arts", "Zoo"],
       f.sorted(["Arts", "News", "Sport", "Zoo"]).joined(separator: ","))

// Older sources.json files have no filter, and older filters may lack newer keys.
let oldJSON = #"[{"id":"7D3F7A43-1A7C-4C1E-9C55-2B0E2F1E7A11","name":"p","kind":{"m3u":{"path":"/x"}}}]"#
let old = try! JSONDecoder().decode([Source].self, from: Data(oldJSON.utf8))
assert(old[0].filter == nil)
let partial = try! JSONDecoder().decode(SourceFilter.self, from: Data(#"{"movies":false}"#.utf8))
assert(!partial.movies && partial.live && partial.showNew && partial.hidden.isEmpty)
var withFilter = old[0]; withFilter.filter = f
let back = try! JSONDecoder().decode(Source.self, from: JSONEncoder().encode(withFilter))
assert(back == withFilter, "filter must round-trip")

// ChannelIndex: pre-indexed groups, O(1) lookup, category filtering, and search.
let idxFilter = {
    var sf = SourceFilter()
    sf.order = ["Sport", "News"]
    return sf
}()
let dup = Channel(id: "live-1", name: "Duplicate", group: "News", logo: nil, url: URL(string: "http://x/dup")!)
let idxChannels = [
    Channel(id: "live-1", name: "BBC News", group: "News", logo: nil, url: URL(string: "http://x/1")!),
    dup,
    Channel(id: "live-2", name: "Sky Sports HD", group: "Sport", logo: nil, url: URL(string: "http://x/2")!),
    Channel(id: "vod-3", name: "Movies · Action Hero", group: "Movies · Action", logo: nil, url: URL(string: "http://x/3")!),
]
let idx = ChannelIndex(channels: idxChannels, filter: idxFilter)
assert(idx.groups == [ChannelIndex.allGroup, ChannelIndex.favoritesGroup, "Sport", "News", "Movies · Action"],
       idx.groups.joined(separator: ","))
assert(idx.byID["live-1"]?.name == "BBC News", "first entry wins on duplicate id")
assert(idx.byID["missing"] == nil)
assert(idx.base(group: ChannelIndex.allGroup, favorites: []).count == 4)
assert(idx.base(group: "Sport", favorites: []).map(\.id) == ["live-2"])
assert(idx.base(group: "Unknown", favorites: []).isEmpty)
let favs = [idxChannels[0], idxChannels[2]]
assert(idx.base(group: ChannelIndex.favoritesGroup, favorites: favs).map(\.id) == ["live-1", "live-2"])
assert(idx.filter(group: ChannelIndex.allGroup, query: "  sports  ", favorites: favs).map(\.id) == ["live-2"])
assert(idx.filter(group: ChannelIndex.favoritesGroup, query: "bbc", favorites: favs).map(\.id) == ["live-1"])
assert(idx.filter(group: "News", query: "   ", favorites: favs).count == 2)

// Large-portal index & filter sanity check (30k channels).
let big: [Channel] = (0..<30_000).map { i in
    Channel(id: "live-\(i)", name: i == 19_999 ? "Kringvarp Føroya HD" : "Channel \(i)",
            group: "Group \(i % 50)", logo: nil, url: URL(string: "http://x/\(i)")!)
}
let bigIdx = ChannelIndex(channels: big, filter: SourceFilter())
assert(bigIdx.groups.count == 52)
assert(bigIdx.byID["live-19999"]?.name == "Kringvarp Føroya HD")
assert(bigIdx.byGroup["Group 49"]?.count == 600)
assert(bigIdx.filter(group: ChannelIndex.allGroup, query: "kringvarp", favorites: []).map(\.id) == ["live-19999"])
assert(bigIdx.filter(group: "Group 49", query: "føroya", favorites: []).map(\.id) == ["live-19999"])

print("ok — \(cs.count) channels parsed, all checks passed")
