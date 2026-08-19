import Foundation
import SwiftUI
import Combine

/// Owns the poll loop and turns Spotify state + lyrics into what the panel renders.
@MainActor
final class SyncEngine: ObservableObject {

    @Published private(set) var state = LyricViewState(track: nil, previous: nil, current: nil,
                                                       next: nil, isPlaying: false,
                                                       status: .nothingPlaying)
    @Published private(set) var progress: Double = 0
    @Published private(set) var tint: NSColor?

    /// Persisted user nudge. Positive = show lyrics later.
    @AppStorage("quest.ohm.lyricbar.offset") var offset: Double = 0 {
        didSet { poller.userOffset = offset }
    }

    private let poller = SpotifyPoller()
    private let provider = LRCLibProvider()

    private var index = LyricIndex([])
    private var currentTrackID: String?
    private var fetchTask: Task<Void, Never>?
    private var pollTimer: Timer?
    private var displayTimer: Timer?
    private var slowCounter = 0

    // Measured cadence: 1s while playing, 5s while paused.
    private let playingInterval: TimeInterval = 1.0
    private let pausedInterval: TimeInterval = 5.0
    private let displayHz: TimeInterval = 1.0 / 30.0

    func start() {
        poller.userOffset = offset
        schedulePoll(interval: playingInterval)
        tick()
    }

    func stop() {
        pollTimer?.invalidate(); pollTimer = nil
        displayTimer?.invalidate(); displayTimer = nil
        fetchTask?.cancel()
    }

    func nudge(_ delta: TimeInterval) {
        offset = (offset + delta).rounded(toPlaces: 3)
    }

    private func schedulePoll(interval: TimeInterval) {
        pollTimer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = interval * 0.1
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    // MARK: - Poll

    private func tick() {
        let reported = poller.samplePosition()
        let discontinuity = reported.map { poller.isDiscontinuity(reported: $0) } ?? true

        // Metadata is ~60ms, so only on discontinuity or every 5th poll.
        slowCounter += 1
        if discontinuity || slowCounter >= 5 || currentTrackID == nil {
            slowCounter = 0
            let snap = poller.sampleMetadata()
            apply(snap)
        }
        refreshDisplay()
    }

    private func apply(_ snap: SpotifyPoller.Snapshot) {
        guard !snap.permissionDenied else {
            teardownDisplay()
            state = LyricViewState(track: nil, previous: nil, current: nil, next: nil,
                                   isPlaying: false,
                                   status: .error("Allow LyricBar to control Spotify in\nSystem Settings › Privacy & Security › Automation"))
            return
        }
        guard snap.spotifyRunning, let track = snap.track else {
            teardownDisplay()
            currentTrackID = nil
            index = LyricIndex([])
            state = LyricViewState(track: nil, previous: nil, current: nil, next: nil,
                                   isPlaying: false, status: .nothingPlaying)
            return
        }

        if track.id != currentTrackID {
            currentTrackID = track.id
            index = LyricIndex([])
            progress = 0
            tint = nil
            state = LyricViewState(track: track, previous: nil, current: nil, next: nil,
                                   isPlaying: snap.isPlaying, status: .searching)
            fetchLyrics(for: track)
            fetchArtwork(snap.artworkURL, for: track.id)
        }

        // Timers only run while playing — keeps idle CPU at zero.
        schedulePoll(interval: snap.isPlaying ? playingInterval : pausedInterval)
        if snap.isPlaying { ensureDisplayTimer() } else { teardownDisplay() }
    }

    private func fetchLyrics(for track: Track) {
        fetchTask?.cancel()
        let wanted = track.id
        fetchTask = Task { [provider] in
            let result = await provider.lyrics(for: track)
            await MainActor.run {
                // Guard against a superseded track finishing last.
                guard self.currentTrackID == wanted else { return }
                switch result {
                case .synced(let lines): self.index = LyricIndex(lines)
                case .plain:             self.index = LyricIndex([])
                case .instrumental:      self.index = LyricIndex([])
                case .notFound:          self.index = LyricIndex([])
                }
                self.pendingResult = result
                self.refreshDisplay()
            }
        }
    }

    private var pendingResult: LyricsResult = .notFound

    private func fetchArtwork(_ urlString: String?, for trackID: String) {
        guard let urlString, let url = URL(string: urlString), url.scheme == "https" else { return }
        Task.detached(priority: .utility) {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let t = ArtworkColor.tint(from: data) else { return }
            await MainActor.run {
                guard self.currentTrackID == trackID else { return }
                self.tint = t.nsColor
            }
        }
    }

    // MARK: - Display

    private func ensureDisplayTimer() {
        guard displayTimer == nil else { return }
        let t = Timer(timeInterval: displayHz, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDisplay() }
        }
        t.tolerance = displayHz * 0.2
        RunLoop.main.add(t, forMode: .common)
        displayTimer = t
    }
    private func teardownDisplay() {
        displayTimer?.invalidate(); displayTimer = nil
    }

    private func refreshDisplay() {
        guard let track = state.track ?? currentTrack else { return }
        let playing = state.isPlaying
        guard let pos = poller.currentPosition() else { return }

        var status: LyricViewState.Status = .ok
        var prev: String?, cur: String?, nxt: String?

        if index.isEmpty {
            switch pendingResult {
            case .instrumental: status = .instrumental
            case .plain:        status = .noLyrics
            case .notFound:     status = fetchTask?.isCancelled == false ? .searching : .noLyrics
            case .synced:       status = .searching
            }
        } else {
            let w = index.lookup(at: pos)
            prev = w.previous; cur = w.current; nxt = w.next
            progress = w.progress
        }

        state = LyricViewState(track: track, previous: prev, current: cur, next: nxt,
                               isPlaying: playing, status: status)
    }

    private var currentTrack: Track? { state.track }
}

private extension Double {
    func rounded(toPlaces p: Int) -> Double {
        let m = pow(10.0, Double(p)); return (self * m).rounded() / m
    }
}
