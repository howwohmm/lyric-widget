import SwiftUI

/// Matches the stock desktop widgets: 24pt corner radius, thin material, generous padding.
struct PanelView: View {
    @ObservedObject var engine: SyncEngine

    private let corner: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }

    private var background: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(.ultraThinMaterial)
            if let tint = engine.tint {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Color(nsColor: tint).opacity(0.55))
            }
        }
    }

    @ViewBuilder private var header: some View {
        if let t = engine.state.track {
            HStack(spacing: 6) {
                Image(systemName: engine.state.isPlaying ? "waveform" : "pause.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(t.name).fontWeight(.semibold).lineLimit(1)
                Text("·").opacity(0.5)
                Text(t.artist).lineLimit(1).opacity(0.75)
            }
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.85))
        }
    }

    @ViewBuilder private var content: some View {
        switch engine.state.status {
        case .nothingPlaying: placeholder("Nothing playing", "music.note")
        case .searching:      placeholder("Finding lyrics…", "magnifyingglass")
        case .noLyrics:       placeholder("No synced lyrics", "text.badge.xmark")
        case .instrumental:   placeholder("Instrumental", "music.quarternote.3")
        case .error(let m):
            Text(m).font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        case .ok:
            lyrics
        }
    }

    private var lyrics: some View {
        VStack(alignment: .leading, spacing: 8) {
            line(engine.state.previous, size: 13, opacity: 0.35)
            if let cur = engine.state.current {
                if cur.isEmpty {
                    Image(systemName: "music.note").font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.6))
                } else {
                    KaraokeText(text: cur, progress: engine.progress,
                                base: .white.opacity(0.45), fill: .white)
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Spacer().frame(height: 22)
            }
            line(engine.state.next, size: 13, opacity: 0.35)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: engine.state.current)
    }

    @ViewBuilder private func line(_ s: String?, size: CGFloat, opacity: Double) -> some View {
        Text(s ?? " ")
            .font(.system(size: size, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(opacity))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func placeholder(_ text: String, _ symbol: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 12))
            Text(text).font(.system(size: 13, weight: .medium, design: .rounded))
        }
        .foregroundStyle(.white.opacity(0.55))
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
    }
}
