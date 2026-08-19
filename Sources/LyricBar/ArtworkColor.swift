import AppKit
import Foundation

/// Dominant-colour extraction from album artwork, tuned to produce a background
/// tint that is guaranteed readable under white text.
/// AppKit + Foundation only. No third-party packages.
public enum ArtworkColor {

    // MARK: - Public result

    public struct Tint: Equatable, Sendable {
        /// Final sRGB components in 0...1, already darkened to pass contrast.
        public let r: Double, g: Double, b: Double
        /// Dominant colour before contrast correction (useful for accents/glow).
        public let rawR: Double, rawG: Double, rawB: Double
        /// Multiplier applied to raw to reach the contrast target (1.0 = untouched).
        public let darkenFactor: Double
        /// WCAG contrast ratio of `r,g,b` against pure white.
        public let contrastWithWhite: Double

        public var nsColor: NSColor {
            NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        }
        public var hex: String {
            String(format: "#%02X%02X%02X",
                   Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
        }
    }

    // MARK: - Entry points

    /// Extract a tint from encoded image data (JPEG/PNG bytes from `artwork url`).
    public static func tint(from data: Data,
                            minimumContrast: Double = 4.5,
                            sampleSide: Int = 32) -> Tint? {
        guard let rep = NSBitmapImageRep(data: data), let cg = rep.cgImage else { return nil }
        return tint(from: cg, minimumContrast: minimumContrast, sampleSide: sampleSide)
    }

    public static func tint(from cgImage: CGImage,
                            minimumContrast: Double = 4.5,
                            sampleSide: Int = 32) -> Tint? {
        guard let pixels = downsample(cgImage, side: sampleSide) else { return nil }
        let raw = dominant(in: pixels)
        return correct(raw: raw, minimumContrast: minimumContrast)
    }

    // MARK: - Step 1: downsample into a known sRGB byte buffer

    /// Returns `side*side` RGB triples in 0...255. Drawing into an explicit sRGB
    /// context normalises whatever colour space / bit depth the JPEG carried.
    static func downsample(_ image: CGImage, side: Int) -> [(UInt8, UInt8, UInt8)]? {
        let bytesPerRow = side * 4
        var buf = [UInt8](repeating: 0, count: bytesPerRow * side)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let ok: Bool = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress,
                                      width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: space, bitmapInfo: info) else { return false }
            ctx.interpolationQuality = .medium
            // Opaque black underlay so transparent art does not skew the average.
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard ok else { return nil }
        var out: [(UInt8, UInt8, UInt8)] = []
        out.reserveCapacity(side * side)
        for i in stride(from: 0, to: buf.count, by: 4) {
            out.append((buf[i], buf[i + 1], buf[i + 2]))
        }
        return out
    }

    // MARK: - Step 2: dominant colour by saturation-weighted histogram

    /// 4 bits per channel = 4096 buckets. Each pixel votes with a weight that
    /// favours colourful mid-tones, so a photo on a white sleeve still yields
    /// the ink colour rather than "white". Falls back to the plain mean when the
    /// image really is achromatic.
    static func dominant(in pixels: [(UInt8, UInt8, UInt8)]) -> (Double, Double, Double) {
        guard !pixels.isEmpty else { return (0.5, 0.5, 0.5) }

        var weight = [Double](repeating: 0, count: 4096)
        var sumR = [Double](repeating: 0, count: 4096)
        var sumG = [Double](repeating: 0, count: 4096)
        var sumB = [Double](repeating: 0, count: 4096)
        var totalWeight = 0.0
        var meanR = 0.0, meanG = 0.0, meanB = 0.0

        for (r8, g8, b8) in pixels {
            let r = Double(r8) / 255, g = Double(g8) / 255, b = Double(b8) / 255
            meanR += r; meanG += g; meanB += b

            let mx = max(r, max(g, b)), mn = min(r, min(g, b))
            let sat = mx <= 0 ? 0 : (mx - mn) / mx
            // Mid-tone bell: kills pure black and blown-out white, keeps body colour.
            let midness = 1.0 - abs(mx - 0.55) / 0.55
            let w = (0.10 + sat) * max(0.05, midness)

            let idx = (Int(r8) >> 4) << 8 | (Int(g8) >> 4) << 4 | (Int(b8) >> 4)
            weight[idx] += w
            sumR[idx] += r * w; sumG[idx] += g * w; sumB[idx] += b * w
            totalWeight += w
        }

        let n = Double(pixels.count)
        meanR /= n; meanG /= n; meanB /= n

        var best = -1, bestW = 0.0
        for i in 0..<4096 where weight[i] > bestW { bestW = weight[i]; best = i }
        guard best >= 0, totalWeight > 0, bestW / totalWeight >= 0.02 else {
            return (meanR, meanG, meanB)
        }
        // Blend the winning bucket toward the global mean so a single loud
        // bucket in a busy cover does not fully dictate the tint.
        let br = sumR[best] / bestW, bg = sumG[best] / bestW, bb = sumB[best] / bestW
        let mix = 0.75
        return (br * mix + meanR * (1 - mix),
                bg * mix + meanG * (1 - mix),
                bb * mix + meanB * (1 - mix))
    }

    // MARK: - Step 3: WCAG contrast correction against white text

    static func linearise(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// WCAG 2.x relative luminance of an sRGB colour.
    public static func relativeLuminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        0.2126 * linearise(r) + 0.7152 * linearise(g) + 0.0722 * linearise(b)
    }

    /// WCAG contrast ratio against pure white (#FFFFFF, luminance 1.0).
    public static func contrastWithWhite(_ r: Double, _ g: Double, _ b: Double) -> Double {
        1.05 / (relativeLuminance(r, g, b) + 0.05)
    }

    /// Scales the colour toward black until white text clears `minimumContrast`.
    /// Uniform scaling of sRGB components preserves hue and HSB saturation and
    /// is strictly monotonic in luminance, so a 24-step bisection is exact to ~1e-7.
    static func correct(raw: (Double, Double, Double), minimumContrast: Double) -> Tint {
        let (rr, rg, rb) = raw
        let rawContrast = contrastWithWhite(rr, rg, rb)
        if rawContrast >= minimumContrast {
            return Tint(r: rr, g: rg, b: rb, rawR: rr, rawG: rg, rawB: rb,
                        darkenFactor: 1.0, contrastWithWhite: rawContrast)
        }
        var lo = 0.0, hi = 1.0           // contrast at k=0 is 21:1, at k=1 it fails
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if quantisedContrast(rr * mid, rg * mid, rb * mid) >= minimumContrast {
                lo = mid
            } else {
                hi = mid
            }
        }
        // The bisection works on floats but the colour is finally rendered as
        // 8-bit sRGB; rounding up can push it back under the threshold (e.g. a
        // float 4.500 tint rounds to #777777 = 4.478). Step down until the
        // colour that actually ships on screen passes.
        var k = lo
        var guard8 = 0
        while quantisedContrast(rr * k, rg * k, rb * k) < minimumContrast && k > 0 && guard8 < 600 {
            k -= 1.0 / 512.0
            guard8 += 1
        }
        k = max(0, k)
        let r = quantise(rr * k), g = quantise(rg * k), b = quantise(rb * k)
        return Tint(r: r, g: g, b: b, rawR: rr, rawG: rg, rawB: rb,
                    darkenFactor: k, contrastWithWhite: contrastWithWhite(r, g, b))
    }

    /// Snap a 0...1 component to the 8-bit value that will actually be rendered.
    static func quantise(_ c: Double) -> Double {
        (min(1, max(0, c)) * 255).rounded() / 255
    }

    /// Contrast of the colour *after* 8-bit rounding — the value the user sees.
    static func quantisedContrast(_ r: Double, _ g: Double, _ b: Double) -> Double {
        contrastWithWhite(quantise(r), quantise(g), quantise(b))
    }
}
