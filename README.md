# LyricBar

A desktop widget that shows the lyrics of whatever is playing in Spotify, in sync.

Sits on the macOS desktop behind your windows, like the stock Clock and Calendar widgets.
Tints itself to the album artwork. Menu bar icon for controls.

## Install

```bash
./Scripts/make_app.sh
open build/LyricBar.app
```

**First launch needs one approval.** macOS will ask whether LyricBar may control Spotify.
Click OK. If you miss the prompt, enable it manually:
System Settings › Privacy & Security › Automation › LyricBar › Spotify.

Without it the panel says so instead of showing lyrics.

## Using it

- The panel sits top-left of the desktop. It is click-through, so it never intercepts clicks.
- Menu bar (`quote.bubble` icon): nudge sync ±100 ms, reset offset, hide/show panel, quit.
- If lyrics run early or late — common on Bluetooth, which adds 150–300 ms — nudge until they line up.
  The offset persists.

## How it works

- **Position**: in-process precompiled `NSAppleScript`, polled 1 s while playing / 5 s while paused,
  interpolated on a monotonic clock in between. Measured interpolation residual: ±5 ms.
  Samples slower than 30 ms are discarded; the anchor is taken *before* the Apple Event, not after.
- **Lyrics**: [LRCLIB](https://lrclib.net), an open community database. No account, no credentials,
  no cookies. Matching is a 4-tier chain (exact → no-album → validated search) measured at
  28/29 on an adversarial set with zero false positives.
- **Cache**: `~/Library/Caches/quest.ohm.lyricbar/`. Misses re-checked after 24 h.

## Limitations

- **Coverage is not universal.** LRCLIB is community-contributed. Older Indian film tracks in
  particular often have unsynced lyrics only, or a record whose duration belongs to a different
  release — in which case LyricBar shows "No synced lyrics" rather than lines that drift.
  That is deliberate: a wrong match is worse than none.
- Podcasts and Spotify adverts have no lyrics and will show the empty state.
- The panel is at desktop level, so **any maximised window hides it**. That is how desktop
  widgets work, not a bug.
- This is a floating panel, not a WidgetKit widget. A real widget is feasible on this machine
  (App Groups were proven to work on a free personal team) but is not built yet.

## Uninstall

```bash
pkill -f LyricBar.app
rm -rf build/LyricBar.app ~/Library/Caches/quest.ohm.lyricbar
defaults delete quest.ohm.lyricbar 2>/dev/null
```
