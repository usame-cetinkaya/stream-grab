# StreamGrab

An IDM-style video grabber for macOS. Play a video in Chrome and a **Download this video** button
appears over it; open its menu, pick a quality (1080p, 720p, 480p…), and the StreamGrab app downloads
the whole stream.

- **HLS streams** (`.m3u8`, the format most streaming sites use): lists every quality from the
  master playlist with an estimated size, downloads segments in parallel, decrypts AES-128
  segments, and merges video and separate audio tracks into one `.mp4` with ffmpeg.
- **Plain video files** (`.mp4`, `.webm`, …): split into pieces and fetched over 8 connections, like IDM.
- Replays the page's own request headers (Referer, Origin, Cookie, User-Agent), so CDNs that
  check them still serve the stream.
- Pause, resume (even after quitting the app), retry, and a list of finished downloads.
- Paste a link into the app to download it without the browser.

DRM-protected services (Netflix, Disney+, Prime Video, Spotify…) and live streams are not supported.
YouTube's player doesn't load a single stream file, so YouTube videos aren't picked up either.

## Install

Download the latest `.dmg` and `StreamGrab-Chrome-Extension-*.zip` from
[Releases](https://github.com/usame-cetinkaya/stream-grab/releases), or build locally:

1. App: open the DMG (or run `scripts/build.sh` → `dist/StreamGrab.app`), move the app to /Applications and open it once.
   It's ad-hoc signed, so the first launch needs right-click → **Open**.
   Opening it registers it with Chrome, Brave, Edge, Vivaldi, Arc and Chromium (a native-messaging host manifest).
2. In Chrome, open `chrome://extensions`, turn on **Developer mode**, click **Load unpacked**, and choose
   the unzipped `StreamGrab Chrome Extension` folder, or the copy the app keeps at
   `~/Library/Application Support/StreamGrab/Chrome Extension` (its **Show Extension Folder** button reveals it).
3. Reload open tabs and play a video.

Optional but recommended: `brew install ffmpeg`. Without it, HLS downloads are saved as `.ts`
(plays in IINA/VLC) and separate audio tracks stay in a separate file.

## How it works

```
 Chrome tab ──► content.js ─ draws the button + quality menu over the <video>
     │                ▲
     ▼                │ items for this frame
 background.js ───────┘ watches network requests (webRequest) for .m3u8 / video files
     │  chrome.runtime.sendNativeMessage("com.streamgrab.host")
     ▼
 StreamGrab (launched by Chrome as the native host: same executable, no UI)
     │  "probe": fetch the playlist with the page's headers → qualities, duration, DRM/live flags
     │  "download": forward over a Unix socket to the app (launches it if needed)
     ▼
 StreamGrab.app ─ download manager: Engine (pieces → decrypt → concat → ffmpeg remux)
```

| Path | What |
| --- | --- |
| `Sources/StreamGrab/App.swift` | Entry point (app vs. native host), window, menus, socket requests |
| `Sources/StreamGrab/NativeHost.swift` | Chrome native-messaging protocol, playlist probing |
| `Sources/StreamGrab/HLS.swift` | m3u8 parsing, AES-128 decryption |
| `Sources/StreamGrab/Engine.swift` | Piece downloads, resume, merge, ffmpeg remux |
| `Sources/StreamGrab/Fetcher.swift` | URLSession wrapper that replays browser headers |
| `Sources/StreamGrab/DownloadManager.swift` | Queue, pause/resume, persistence, settings |
| `Sources/StreamGrab/Views.swift` | SwiftUI download list, setup guide, settings |
| `Sources/StreamGrab/Setup.swift` | Installs host manifests and the extension folder on launch |
| `Extension/` | Chrome MV3 extension (fixed ID `ljopggppagmplkghfflbeopnlacihime` via `key`) |

Downloads in progress live in `~/Library/Caches/StreamGrab/<id>/`; the list is kept in
`~/Library/Application Support/StreamGrab/downloads.json`.

## Releases

Push a version tag (`git tag 1.2.0 && git push origin 1.2.0`, or `v1.2.0`). GitHub Actions builds the
app with that version, the DMG, and the extension zip (same version in its manifest), and publishes
them as a GitHub release. Pushes to `main` and pull requests run the same build and keep the
files as workflow artifacts.

Building needs only the Command Line Tools (no Xcode). `scripts/make-icons.swift` regenerates the icons.
