# Xstream

A native macOS player for Xtream Codes IPTV portals and M3U playlists — your
channel list in a real Mac app, playing in AVKit, VLC, or Infuse.

- **Xtream portals** — add a server with host, username, and password; live
  channels and the VOD catalogue load with their categories
- **M3U playlists** — open any `.m3u`/`.m3u8` file, with `group-title` and
  `tvg-logo` honoured
- **Favorites** — star any channel (right-click) and filter the list to just those
- **EPG** — the current programme under every channel in the list, plus now/next
  with progress for the one playing. Rows fetch their own guide as they scroll
  into view and cache it, so a 5000-channel portal costs a few requests, not 5000
- **Search and category filter** across the whole channel list
- **Plays in VLC** — pick a channel and it opens there, with the guide and stream
  details staying in Xstream
- **Export to M3U** — hand your channels to anything that reads a playlist. The
  list's own search and category filters are the picker: export what's visible,
  just your favorites, or the whole source. Exported URLs contain your portal
  username and password, so treat the file like a password
- **Updates itself** — Sparkle checks the appcast and installs new versions in
  place; also available on demand from *Xstream ▸ Check for Updates…*
- Real error messages when a stream fails, not a black rectangle

## Install

With [Homebrew](https://brew.sh):

```sh
brew install --cask steingmo/tap/xstream-player
```

### Or install manually

Download the notarized universal build and drop it in `/Applications`:

```sh
curl -L https://github.com/steingmo/xstream-player/releases/latest/download/Xstream.zip \
  -o ~/Downloads/Xstream.zip
ditto -x -k ~/Downloads/Xstream.zip /Applications
```

Or grab `Xstream.zip` from the [releases page](https://github.com/steingmo/xstream-player/releases/latest),
double-click it, and drag `Xstream.app` to Applications. The build is signed and
notarized, so it opens without a Gatekeeper prompt.

### Or build it yourself

```sh
git clone https://github.com/steingmo/xstream-player.git
cd xstream-player
./build.sh install
```

That needs Xcode's command-line tools and nothing else. Your own build is
ad-hoc signed rather than notarized — fine locally, since macOS only quarantines
what it downloaded. Pick one install method: `./build.sh install` overwrites
`/Applications/Xstream.app`, including a copy Homebrew is managing.

## Why VLC

Most Xtream panels serve raw MPEG-TS and sit behind a CDN that redirects
`https://` stream URLs to a plain-`http` edge node. AVFoundation refuses both —
it has no TS demuxer, and it reports the redirect downgrade as *"A TLS error
caused the secure connection to fail"*. VLC handles both without complaint, so
Xstream hands it the URL and stays out of the way. Xstream is the channel list,
the search, the favorites and the guide; VLC is the player.

Install it with `brew install --cask vlc` if you don't have it — Xstream will say
so if it's missing.

## Build from source

Needs Xcode's command-line tools. One dependency (Sparkle, for updates), no
`.xcodeproj`:

```sh
./build.sh          # build build/Xstream.app
./build.sh run      # build and launch it
./build.sh install  # build and copy to /Applications
./build.sh test     # run the M3U parser self-check
./release.sh        # signed, notarized, universal build for distribution
```

The icon is generated, not checked in as artwork alone — edit
`Resources/make-icon.swift` and run `Resources/make-icon.sh`.

## Note

Xstream is a channel browser, not a player. It ships with no channels, no playlists, and no provider —
you bring your own subscription, exactly as you would with VLC.

## License

MIT
