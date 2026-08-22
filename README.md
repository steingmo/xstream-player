# Xstream

A native macOS player for Xtream Codes IPTV portals and M3U playlists — your
channel list in a real Mac app, playing in AVKit, VLC, or Infuse.

- **Xtream portals** — add a server with host, username, and password; live
  channels and the VOD catalogue load with their categories
- **M3U playlists** — open any `.m3u`/`.m3u8` file, with `group-title` and
  `tvg-logo` honoured
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
./build.sh run      # build build/Xstream.app and launch it
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
