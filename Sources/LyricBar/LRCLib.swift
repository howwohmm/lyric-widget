import Foundation

/// LRCLIB client. Matching chain measured at 28/29 hits, 0 false positives.
/// Tier 1: /api/get with normalised title + primary artist + RAW album + rounded duration
/// Tier 2: same, album omitted   (dropping album is the single biggest win)
/// Tier 3: /api/search + strict validator (never trust top-1)
struct LRCLibProvider: LyricsProvider {

    static let userAgent = "LyricBar/1.0 (https://github.com/howwohmm/lyric-widget)"
    private static let base = "https://lrclib.net"
    /// Server tolerance is ±2s; client re-validation uses 2.5s to absorb float→int rounding.
    private static let durationTolerance: Double = 2.5

    private let session: URLSession
    private let cacheDir: URL

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 20
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
        self.cacheDir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("quest.ohm.lyricbar", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: - Entry point

    func lyrics(for track: Track) async -> LyricsResult {
        if let hit = readCache(track) { return hit }

        let title = Self.normaliseTitle(track.name)
        let artist = Self.primaryArtist(track.artist)
        let dur = Int(track.duration.rounded())

        var result: LyricsResult = .notFound
        if let r = await get(title: title, artist: artist, album: track.album, duration: dur) {
            result = r
        } else if let r = await get(title: title, artist: artist, album: nil, duration: dur) {
            result = r
        } else if let r = await search(title: title, artist: artist, duration: track.duration) {
            result = r
        }
        writeCache(track, result)
        return result
    }

    // MARK: - Tiers

    private func get(title: String, artist: String, album: String?, duration: Int) async -> LyricsResult? {
        var items = [URLQueryItem(name: "track_name", value: title),
                     URLQueryItem(name: "artist_name", value: artist)]
        if let album, !album.isEmpty { items.append(URLQueryItem(name: "album_name", value: album)) }
        if duration >= 1 && duration <= 3600 {
            items.append(URLQueryItem(name: "duration", value: String(duration)))
        }
        guard let rec: Record = await fetch("/api/get", items) else { return nil }
        return Self.materialise(rec)
    }

    private func search(title: String, artist: String, duration: TimeInterval) async -> LyricsResult? {
        let items = [URLQueryItem(name: "track_name", value: title),
                     URLQueryItem(name: "artist_name", value: artist)]
        guard let recs: [Record] = await fetch("/api/search", items) else { return nil }
        // Validator: search top-1 is wrong or mistimed 50% of the time without this.
        let valid = recs.filter { r in
            guard let d = r.duration, abs(d - duration) <= Self.durationTolerance else { return false }
            return Self.titleOverlap(r.trackName ?? "", title) >= 0.6
                && Self.artistOverlaps(r.artistName ?? "", artist)
        }
        let best = valid.first(where: { ($0.syncedLyrics?.isEmpty == false) }) ?? valid.first
        return best.flatMap(Self.materialise)
    }

    private func fetch<T: Decodable>(_ path: String, _ items: [URLQueryItem]) async -> T? {
        var comp = URLComponents(string: Self.base + path)!
        comp.queryItems = items
        guard let url = comp.url, url.scheme == "https" else { return nil }
        var req = URLRequest(url: url)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func materialise(_ r: Record) -> LyricsResult? {
        if r.instrumental == true { return .instrumental }
        if let s = r.syncedLyrics, !s.isEmpty {
            let lines = LRCParser.parse(s)
            if !lines.isEmpty { return .synced(lines) }   // never emit .synced([])
        }
        if let p = r.plainLyrics, !p.isEmpty { return .plain(p) }
        return nil
    }

    /// Allowlist decode — the response also carries a large `lyricsfile` blob we ignore.
    private struct Record: Decodable {
        let id: Int?
        let trackName: String?
        let artistName: String?
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    // MARK: - Normalisation (ablation-tested; see docs/SPIKES.md)

    private static let suffixVocab = [
        "remaster", "remastered", "re-master", "mix", "version", "edit", "live", "acoustic",
        "demo", "mono", "stereo", "bonus track", "single", "radio", "remix", "instrumental",
        "anniversary", "deluxe", "expanded",
    ]

    /// Strips release-variant tails, but only anchored to Spotify's literal " - " separator,
    /// which is what keeps titles like "Live Forever" intact.
    static func normaliseTitle(_ raw: String) -> String {
        var s = raw.precomposedStringWithCompatibilityMapping   // NFKC

        while let r = s.range(of: " - ", options: .backwards) {
            let tail = String(s[r.upperBound...]).lowercased()
            if isVariantTail(tail) { s = String(s[s.startIndex..<r.lowerBound]) } else { break }
        }
        s = dropParentheticals(s)
        if let r = s.range(of: " feat. ", options: [.caseInsensitive]) { s = String(s[s.startIndex..<r.lowerBound]) }
        if let r = s.range(of: " ft. ", options: [.caseInsensitive]) { s = String(s[s.startIndex..<r.lowerBound]) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func isVariantTail(_ tail: String) -> Bool {
        var t = tail
        // optional leading 4-digit year: "2011 remaster"
        if t.count > 5, let y = Int(t.prefix(4)), y > 1900, y < 2100 { t = String(t.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
        if t.hasPrefix("live at") || t.hasPrefix("live from") || t.hasPrefix("live in") || t.hasPrefix("live on") { return true }
        if t.hasPrefix("from \"") { return true }
        return suffixVocab.contains { t == $0 || t.hasPrefix($0 + " ") || t.hasSuffix(" " + $0) }
    }

    private static func dropParentheticals(_ s: String) -> String {
        var out = s
        for (open, close) in [("(", ")"), ("[", "]")] {
            while let o = out.range(of: open), let c = out.range(of: close, range: o.upperBound..<out.endIndex) {
                let inner = String(out[o.upperBound..<c.lowerBound]).lowercased()
                let isFeat = inner.hasPrefix("feat.") || inner.hasPrefix("ft.")
                    || inner.hasPrefix("featuring") || inner.hasPrefix("with ")
                let isFrom = inner.hasPrefix("from \"") || inner.hasPrefix("from ")
                if isFeat || isFrom || isVariantTail(inner) {
                    out.replaceSubrange(o.lowerBound..<c.upperBound, with: "")
                } else { break }
            }
        }
        return out.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
    }

    static func primaryArtist(_ raw: String) -> String {
        var s = raw.precomposedStringWithCompatibilityMapping
        for sep in [", ", " & ", " feat. ", " ft. ", " featuring ", " with ", " x ", " vs "] {
            if let r = s.range(of: sep, options: [.caseInsensitive]) { s = String(s[s.startIndex..<r.lowerBound]) }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func tokens(_ s: String) -> Set<String> {
        Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }
    private static func titleOverlap(_ a: String, _ b: String) -> Double {
        let ta = tokens(a), tb = tokens(b)
        guard !tb.isEmpty else { return 0 }
        return Double(ta.intersection(tb).count) / Double(tb.count)
    }
    private static func artistOverlaps(_ a: String, _ b: String) -> Bool {
        !tokens(a).intersection(tokens(b)).isEmpty
    }

    // MARK: - Disk cache (positive forever, negative for 24h)

    private func cacheURL(_ track: Track) -> URL {
        var h: UInt64 = 5381
        for b in Array(track.id.utf8) { h = h &* 33 &+ UInt64(b) }
        return cacheDir.appendingPathComponent(String(h, radix: 36) + ".json")
    }
    private struct Envelope: Codable { let stored: Date; let result: LyricsResult }

    private func readCache(_ track: Track) -> LyricsResult? {
        guard let d = try? Data(contentsOf: cacheURL(track)),
              let e = try? JSONDecoder().decode(Envelope.self, from: d) else { return nil }
        if e.result == .notFound, Date().timeIntervalSince(e.stored) > 86_400 { return nil }
        return e.result
    }
    private func writeCache(_ track: Track, _ r: LyricsResult) {
        guard let d = try? JSONEncoder().encode(Envelope(stored: Date(), result: r)) else { return }
        try? d.write(to: cacheURL(track), options: .atomic)
    }
}
