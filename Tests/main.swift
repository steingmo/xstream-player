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

print("ok — \(cs.count) channels parsed, all checks passed")
