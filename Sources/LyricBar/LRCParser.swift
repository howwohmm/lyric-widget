import Foundation

/// LRC parsing per docs/SPIKES.md — validated against 73,315 real timed lines.
/// Text examples in comments use placeholders (LINE_A) deliberately.
enum LRCParser {

    /// Parse an LRC document into time-sorted lines. Empty result means "not synced".
    static func parse(_ src: String) -> [LyricLine] {
        var offset: TimeInterval = 0
        var out: [(time: TimeInterval, text: String, seq: Int)] = []
        var seq = 0

        var body = src
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }

        // Must split on CRLF / CR / LF — 3 records in the corpus are CRLF.
        for raw in body.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(raw)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            // Collect leading timestamps NON-greedily: a second bracket may be lyric text.
            var stamps: [TimeInterval] = []
            var idx = line.startIndex
            while true {
                var j = idx
                while j < line.endIndex, line[j] == " " || line[j] == "\t" { j = line.index(after: j) }
                guard let m = matchTimestamp(line, from: j) else { break }
                stamps.append(m.seconds)
                idx = m.end
            }

            if stamps.isEmpty {
                if let tag = matchTag(line.trimmingCharacters(in: .whitespaces)),
                   tag.ident.lowercased() == "offset",
                   let ms = Double(tag.value.replacingOccurrences(of: "+", with: "")
                                            .trimmingCharacters(in: .whitespaces)) {
                    offset = ms / 1000.0
                }
                continue   // untimed lines are never emitted
            }

            var text = String(line[idx...])
            text = stripWordTags(text)
            text = text.trimmingCharacters(in: .whitespaces)   // 97.4% need this

            for t in stamps { out.append((t, text, seq)); seq += 1 }
        }

        // Positive offset makes lyrics appear earlier.
        let shifted = out.map { (time: max(0, $0.time - offset), text: $0.text, seq: $0.seq) }
        // Stable sort: Swift's sort is not stable, so break ties on seq.
        let sorted = shifted.sorted { $0.time == $1.time ? $0.seq < $1.seq : $0.time < $1.time }
        return sorted.map { LyricLine(time: $0.time, text: $0.text) }
    }

    /// `[mm:ss.xx]` / `[mm:ss.xxx]` / `[mm:ss]` / `[mm:ss:xx]`. Seconds >= 60 is not a timestamp.
    private static func matchTimestamp(_ s: String, from start: String.Index)
        -> (seconds: TimeInterval, end: String.Index)? {
        var i = start
        guard i < s.endIndex, s[i] == "[" else { return nil }
        i = s.index(after: i)

        var minDigits = ""
        while i < s.endIndex, s[i].isNumber, minDigits.count < 4 { minDigits.append(s[i]); i = s.index(after: i) }
        guard !minDigits.isEmpty, i < s.endIndex, s[i] == ":" else { return nil }
        i = s.index(after: i)

        var secDigits = ""
        while i < s.endIndex, s[i].isNumber, secDigits.count < 2 { secDigits.append(s[i]); i = s.index(after: i) }
        guard !secDigits.isEmpty, let sec = Int(secDigits), sec < 60 else { return nil }

        var frac = 0.0
        if i < s.endIndex, s[i] == "." || s[i] == ":" {
            let sep = s.index(after: i)
            var fracDigits = ""
            var k = sep
            while k < s.endIndex, s[k].isNumber, fracDigits.count < 3 { fracDigits.append(s[k]); k = s.index(after: k) }
            if !fracDigits.isEmpty, let f = Double(fracDigits) {
                frac = f / pow(10, Double(fracDigits.count))
                i = k
            }
        }
        guard i < s.endIndex, s[i] == "]" else { return nil }
        let seconds = Double(minDigits)! * 60 + Double(sec) + frac
        return (seconds, s.index(after: i))
    }

    private static func matchTag(_ s: String) -> (ident: String, value: String)? {
        guard s.hasPrefix("["), s.hasSuffix("]") else { return nil }
        let inner = String(s.dropFirst().dropLast())
        guard let c = inner.firstIndex(of: ":") else { return nil }
        let ident = String(inner[inner.startIndex..<c])
        guard let f = ident.first, f.isLetter || f == "#" else { return nil }
        return (ident, String(inner[inner.index(after: c)...]))
    }

    /// Flatten enhanced LRC `<mm:ss.xx>` word tags.
    private static func stripWordTags(_ s: String) -> String {
        guard s.contains("<") else { return s }
        var out = ""; var depth = 0
        for ch in s {
            if ch == "<" { depth += 1 } else if ch == ">" { if depth > 0 { depth -= 1 } } else if depth == 0 { out.append(ch) }
        }
        return out
    }
}

/// Binary-search index over parsed lines.
struct LyricIndex {
    let lines: [LyricLine]
    init(_ lines: [LyricLine]) { self.lines = lines }
    var isEmpty: Bool { lines.isEmpty }

    /// -1 means "before the first line" — a normal state, not an error.
    func indexOfCurrent(at t: TimeInterval) -> Int {
        var lo = 0, hi = lines.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if lines[mid].time <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo - 1
    }

    /// previous / current / next plus 0...1 progress through the current line.
    func lookup(at t: TimeInterval)
        -> (previous: String?, current: String?, next: String?, progress: Double) {
        guard !lines.isEmpty else { return (nil, nil, nil, 0) }
        let i = indexOfCurrent(at: t)
        if i < 0 { return (nil, nil, lines[0].text, 0) }
        let prev = i > 0 ? lines[i - 1].text : nil
        let next = i + 1 < lines.count ? lines[i + 1].text : nil
        var progress = 1.0
        if i + 1 < lines.count {
            let span = lines[i + 1].time - lines[i].time
            if span > 0.01 { progress = min(max((t - lines[i].time) / span, 0), 1) }
        } else {
            progress = min(max((t - lines[i].time) / 4.0, 0), 1)
        }
        return (prev, lines[i].text, next, progress)
    }
}
