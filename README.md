# Sonos Bar

A small macOS menu bar remote for Sonos speakers, built for an older S1 system (it works with S2 too).

- See what every room is playing, play/pause and skip
- Group and ungroup rooms, set group and per-room volume
- Start any of your Sonos favorites
- **Play Mac audio here**: sends everything the Mac is playing to any room, even speakers without AirPlay. The sound runs a few seconds behind, so it suits music better than video.

It talks to the speakers directly over the local network (UPnP on port 1400). No Sonos account or cloud needed.

## Build

Needs macOS 14.2 or later, Xcode command line tools, and `ffmpeg` from Homebrew (`brew install ffmpeg`) for the Mac audio feature.

```sh
./build.sh
cp -R "build/Sonos Bar.app" /Applications/
```

The first time you use Play Mac audio here, macOS asks for permission to record system audio, and the firewall may ask to allow incoming connections. Both are needed: the app captures the Mac's sound, encodes it to MP3 and serves it to the speakers as a radio stream.
