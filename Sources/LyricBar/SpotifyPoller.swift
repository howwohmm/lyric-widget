import Foundation
import AppKit

/// Reads Spotify via in-process precompiled NSAppleScript.
/// Measured: 5ms per property in-process vs ~180ms shelling out to osascript.
/// Anchoring at t0 rather than t1 is worth ~10ms rms for free (measured alpha = 0.06).
final class SpotifyPoller: @unchecked Sendable {

    struct Snapshot {
        var track: Track?
        var isPlaying: Bool
        var position: TimeInterval
        var artworkURL: String?
        var spotifyRunning: Bool
        var permissionDenied: Bool
    }

    /// Discard any sample slower than this — removes the cold-AE outlier entirely.
    private static let rttGate: TimeInterval = 0.030
    /// Reported vs interpolated disagreement above this means seek or track change.
    static let seekThreshold: TimeInterval = 0.250

    private let queue = DispatchQueue(label: "quest.ohm.lyricbar.applescript")
    private var positionScript: NSAppleScript?
    private var metadataScript: NSAppleScript?

    // Interpolation anchor, guarded by `lock`.
    private let lock = NSLock()
    private var anchorPosition: TimeInterval = 0
    private var anchorUptime: TimeInterval = 0
    private var anchorValid = false
    private var playing = false

    /// Audio output latency: the reported position is a render clock and leads the speaker.
    var outputLatency: TimeInterval = 0.035
    /// User-tunable nudge, persisted by SyncEngine.
    var userOffset: TimeInterval = 0

    init() {
        queue.sync {
            positionScript = NSAppleScript(source:
                #"tell application "Spotify" to return player position"#)
            positionScript?.compileAndReturnError(nil)
            // NB: `st` is a reserved token in AppleScript (ordinal suffix, as in "1st"),
            // so variable names here must stay unambiguous.
            metadataScript = NSAppleScript(source: """
            tell application "Spotify"
              set theState to player state as text
              set theTrack to current track
              return (id of theTrack) & "\\n" & (name of theTrack) & "\\n" \
                & (artist of theTrack) & "\\n" & (album of theTrack) & "\\n" \
                & (duration of theTrack as text) & "\\n" & theState & "\\n" \
                & (artwork url of theTrack)
            end tell
            """)
            metadataScript?.compileAndReturnError(nil)
        }
    }

    private static func spotifyRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty
    }

    // MARK: - Position (cheap: one property, ~5ms)

    /// Samples position and re-anchors the interpolator. Returns nil if unusable.
    @discardableResult
    func samplePosition() -> TimeInterval? {
        guard Self.spotifyRunning() else { invalidate(); return nil }
        var value: TimeInterval?
        queue.sync {
            let t0 = Self.uptime()
            var err: NSDictionary?
            let desc = positionScript?.executeAndReturnError(&err)
            let t1 = Self.uptime()
            guard err == nil, let desc else { return }
            guard t1 - t0 <= Self.rttGate else { return }   // gate: 44.5ms -> 3.6ms worst case
            let pos = desc.doubleValue
            guard pos.isFinite, pos >= 0 else { return }
            value = pos
            self.setAnchor(position: pos, at: t0)           // anchor at t0, not t1
        }
        return value
    }

    /// Position now, interpolated at rate 1.000 (measured clock error <= 21 ppm).
    func currentPosition() -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        guard anchorValid else { return nil }
        let elapsed = playing ? (Self.uptime() - anchorUptime) : 0
        return max(0, anchorPosition + elapsed - outputLatency + userOffset)
    }

    /// True when the freshly reported position disagrees with the interpolation.
    func isDiscontinuity(reported: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard anchorValid, playing else { return false }
        let expected = anchorPosition + (Self.uptime() - anchorUptime)
        return abs(reported - expected) > Self.seekThreshold
    }

    private func setAnchor(position: TimeInterval, at uptime: TimeInterval) {
        lock.lock(); anchorPosition = position; anchorUptime = uptime; anchorValid = true; lock.unlock()
    }
    func invalidate() {
        lock.lock(); anchorValid = false; lock.unlock()
    }
    func setPlaying(_ p: Bool) {
        lock.lock()
        if p != playing {
            // Freeze the clock at the moment of the transition.
            if !p, anchorValid { anchorPosition += Self.uptime() - anchorUptime }
            anchorUptime = Self.uptime()
            playing = p
        }
        lock.unlock()
    }

    // MARK: - Metadata (expensive: ~60ms, only on discontinuity or slow timer)

    func sampleMetadata() -> Snapshot {
        guard Self.spotifyRunning() else {
            invalidate()
            return Snapshot(track: nil, isPlaying: false, position: 0, artworkURL: nil,
                            spotifyRunning: false, permissionDenied: false)
        }
        var snap = Snapshot(track: nil, isPlaying: false, position: 0, artworkURL: nil,
                            spotifyRunning: true, permissionDenied: false)
        queue.sync {
            var err: NSDictionary?
            let desc = metadataScript?.executeAndReturnError(&err)
            if let err {
                // -1743 = user has not granted Apple Events permission.
                let code = (err[NSAppleScript.errorNumber] as? Int) ?? 0
                snap.permissionDenied = (code == -1743)
                return
            }
            guard let raw = desc?.stringValue else { return }
            let f = raw.components(separatedBy: "\n")
            guard f.count >= 6 else { return }
            let durMs = Double(f[4]) ?? 0
            snap.track = Track(id: f[0].isEmpty ? "\(f[1])|\(f[2])|\(durMs)" : f[0],
                               name: f[1], artist: f[2], album: f[3],
                               duration: durMs / 1000.0)          // Spotify reports ms
            snap.isPlaying = (f[5] == "playing")
            snap.artworkURL = f.count >= 7 ? f[6] : nil
        }
        setPlaying(snap.isPlaying)
        return snap
    }

    private static func uptime() -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}
