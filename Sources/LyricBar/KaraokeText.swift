import SwiftUI

// MARK: - KaraokeText
//
// Progressive left-to-right fill of a single lyric line.
//
// Technique (a): two stacked, identical `Text` views. The top copy is masked by a
// `Rectangle` whose width is driven by `scaleEffect(x:anchor:.leading)` — a pure affine
// transform. The `Text` values never change while a line is on screen, so SwiftUI reuses
// the cached glyph layout: no text measurement, no line breaking, no glyph rasterisation
// per frame. Only the mask's transform is invalidated.
//
// `Animatable` conformance lets SwiftUI interpolate `progress` in the render phase, so the
// caller can either drive it from its own clock every frame, or hand off a single
// `withAnimation(.linear(duration:))` and let the render server tick it.
//
// macOS 14+. Foundation / SwiftUI only.

public struct KaraokeText: View, Animatable {

    public var text: String
    /// Fill fraction, 0...1. Values outside the range are clamped.
    public var progress: Double
    /// Colour of the not-yet-sung part.
    public var base: Color
    /// Colour of the sung part.
    public var fill: Color
    /// Width in points of the feathered leading edge. `0` (default) is the cheapest path
    /// and skips the geometry read entirely.
    public var softEdge: CGFloat

    // `View` is @MainActor but `Animatable.animatableData` is a nonisolated requirement.
    // Under Swift 6 strict concurrency the conformance fails to compile without this.
    public nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    @State private var lineWidth: CGFloat = 0

    public init(text: String,
                progress: Double,
                base: Color = .secondary,
                fill: Color = .primary,
                softEdge: CGFloat = 0) {
        self.text = text
        self.progress = progress
        self.base = base
        self.fill = fill
        self.softEdge = softEdge
    }

    // Never let the scale hit exactly 0: a zero-determinant matrix trips a CoreAnimation
    // warning and, on some paths, drops the layer entirely.
    private var p: Double { min(max(progress, 0.0001), 1) }

    public var body: some View {
        // The hard-edge path deliberately carries NO extra modifier: attaching the
        // geometry probe unconditionally measured ~1% extra CPU at 105 fps even when
        // it resolved to EmptyView.
        if softEdge <= 0 {
            stack
        } else {
            stack.background(alignment: .leading) { widthProbe }
        }
    }

    private var stack: some View {
        ZStack(alignment: .leading) {
            Text(text)
                .foregroundStyle(base)
            Text(text)
                .foregroundStyle(fill)
                .mask(alignment: .leading) { fillMask }
                .accessibilityHidden(true)   // the base copy already speaks the line
        }
    }

    @ViewBuilder
    private var fillMask: some View {
        if softEdge <= 0 {
            // Transform-only. Cheapest measured path.
            Rectangle()
                .scaleEffect(x: p, anchor: .leading)
        } else {
            // A *static* gradient strip that is only translated. The stops depend on
            // lineWidth/softEdge, which are constant for the life of the line, so no
            // gradient is rebuilt per frame — unlike animating `stops` directly.
            let total = max(lineWidth + softEdge, 1)
            LinearGradient(
                stops: [
                    .init(color: .white, location: 0),
                    .init(color: .white, location: max(lineWidth / total, 0)),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing)
                .frame(width: total)
                .offset(x: -(1 - p) * total)
        }
    }

    @ViewBuilder
    private var widthProbe: some View {
        if softEdge > 0 {
            GeometryReader { g in
                Color.clear
                    .onChange(of: g.size.width, initial: true) { _, w in
                        if abs(w - lineWidth) > 0.5 { lineWidth = w }
                    }
            }
        }
    }
}

// MARK: - Driving `progress`

public enum KaraokeProgress {

    /// Graceful degrade path: no word timings, so fill linearly across the line's duration.
    /// `start`/`end` are track-relative seconds; `now` is the interpolated playhead.
    public static func linear(now: TimeInterval,
                              start: TimeInterval,
                              end: TimeInterval) -> Double {
        guard end > start else { return now >= end ? 1 : 0 }
        return min(max((now - start) / (end - start), 0), 1)
    }

    /// Word-level path. `wordStarts` are track-relative onset seconds for each word, in
    /// order; `weights` is the visual width share of each word (character counts work
    /// well). Returns the fraction of the line that should be filled, interpolating
    /// linearly *within* the word currently being sung so the edge never stalls.
    public static func words(now: TimeInterval,
                             wordStarts: [TimeInterval],
                             weights: [Double],
                             lineEnd: TimeInterval) -> Double {
        guard !wordStarts.isEmpty, wordStarts.count == weights.count else { return 0 }
        let total = weights.reduce(0, +)
        guard total > 0 else { return 0 }
        if now <= wordStarts[0] { return 0 }
        if now >= lineEnd { return 1 }

        var consumed = 0.0
        for i in wordStarts.indices {
            let wEnd = (i + 1 < wordStarts.count) ? wordStarts[i + 1] : lineEnd
            if now < wEnd {
                let span = wEnd - wordStarts[i]
                let within = span > 0 ? min(max((now - wordStarts[i]) / span, 0), 1) : 1
                return min((consumed + weights[i] * within) / total, 1)
            }
            consumed += weights[i]
        }
        return 1
    }

    /// Convenience: character-count weights for a line, ignoring whitespace runs.
    public static func characterWeights(words: [String]) -> [Double] {
        words.map { Double(max($0.count, 1)) }
    }
}
