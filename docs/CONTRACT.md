# Module contract — read before writing any code

Types live in `Sources/LyricBar/Contracts.swift`. **Do not edit that file**; if you need a
change, write the request into `docs/CONTRACT-CHANGES.md` and code around it for now.

## File ownership (one owner each — never edit a file you do not own)
| File | Owns |
|---|---|
| `Contracts.swift` | integrator only |
| `SpotifyPoller.swift` | Apple Events sampling + monotonic interpolation |
| `LRCLib.swift` | network lookup + on-disk cache |
| `LRCParser.swift` | `[mm:ss.xx]` parsing + current-line lookup |
| `SyncEngine.swift` | combines poller + lyrics -> `LyricViewState` |
| `PanelWindow.swift` | NSWindow at desktop level, non-activating |
| `PanelView.swift` | SwiftUI rendering of `LyricViewState` |
| `MenuBarController.swift` | LSUIElement status item, settings, quit |
| `main.swift` | app entry, wiring |

## Hard rules
1. **Never print lyric text into logs, test output, commit messages, or reports.**
   Report line counts, timestamps, and indexes only.
2. No third-party packages. Foundation / AppKit / SwiftUI only.
3. Build must stay clean: `swift build -c release` with zero warnings.
4. `swift test` must pass. Network tests must be skippable offline.
