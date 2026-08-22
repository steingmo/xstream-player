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
- **Choose your player** — VLC or Infuse by default when installed, or the
  built-in AVKit player with fullscreen, Picture-in-Picture, and AirPlay
- **MPEG-TS fallback** — AVFoundation can't demux `.ts`, so the built-in player
  remuxes it to local HLS with ffmpeg when ffmpeg is installed
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

## Why the external players

Most Xtream panels serve raw MPEG-TS and sit behind a CDN that redirects
`https://` stream URLs to a plain-`http` edge node. AVFoundation refuses both —
it has no TS demuxer, and it reports the redirect downgrade as *"A TLS error
caused the secure connection to fail"*. VLC and Infuse handle both without
complaint, so Xstream hands them the URL and stays out of the way. The built-in
player resolves the redirect chain itself and falls back to an ffmpeg remux, but
VLC remains the default because it just works.

## Build from source

Needs Xcode's command-line tools. No dependencies, no `.xcodeproj`:

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

Xstream is a player. It ships with no channels, no playlists, and no provider —
you bring your own subscription, exactly as you would with VLC.

## License

MIT
