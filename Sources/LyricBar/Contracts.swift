import Foundation

// MARK: - Shared contracts. DO NOT EDIT without updating docs/CONTRACT.md.
// Every module codes against these types. Owned by the integrator.

/// A single track as reported by Spotify.
public struct Track: Equatable, Sendable, Codable {
    public let id: String          // Spotify URI, e.g. spotify:track:xxxx — the identity key
    public let name: String
    public let artist: String
    public let album: String
    public let duration: TimeInterval   // seconds
    public init(id: String, name: String, artist: String, album: String, duration: TimeInterval) {
        self.id = id; self.name = name; self.artist = artist
        self.album = album; self.duration = duration
    }
}

/// A raw sample taken from Spotify via Apple Events.
public struct PlayerSample: Sendable {
    public let track: Track?
    public let position: TimeInterval    // seconds into the track, as reported
    public let isPlaying: Bool
    public let sampledAt: DispatchTime   // monotonic clock at moment of sample
    public init(track: Track?, position: TimeInterval, isPlaying: Bool, sampledAt: DispatchTime) {
        self.track = track; self.position = position
        self.isPlaying = isPlaying; self.sampledAt = sampledAt
    }
}

/// One timed lyric line.
public struct LyricLine: Equatable, Sendable, Codable {
    public let time: TimeInterval   // seconds from track start
    public let text: String         // may be "" for instrumental breaks
    public init(time: TimeInterval, text: String) { self.time = time; self.text = text }
}

/// Result of a lyrics lookup.
public enum LyricsResult: Equatable, Sendable, Codable {
    case synced([LyricLine])
    case plain(String)
    case instrumental
    case notFound
}

/// What the UI renders at any instant.
public struct LyricViewState: Equatable, Sendable {
    public let track: Track?
    public let previous: String?
    public let current: String?
    public let next: String?
    public let isPlaying: Bool
    public let status: Status
    public enum Status: Equatable, Sendable {
        case ok, searching, noLyrics, instrumental, nothingPlaying, error(String)
    }
    public init(track: Track?, previous: String?, current: String?, next: String?,
                isPlaying: Bool, status: Status) {
        self.track = track; self.previous = previous; self.current = current
        self.next = next; self.isPlaying = isPlaying; self.status = status
    }
}

// MARK: - Module boundaries

public protocol PlayerSource: Sendable {
    /// One sample of Spotify state. Must not block longer than 1s.
    func sample() async -> PlayerSample
}

public protocol LyricsProvider: Sendable {
    /// Fetch lyrics for a track. Implementations must cache on disk by track.id.
    func lyrics(for track: Track) async -> LyricsResult
}
