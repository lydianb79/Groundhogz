import AppKit
import CoreText

/// Glyph metrics are in em units; the renderer multiplies by the em size in logical pixels.
struct Glyph { var u0, v0, u1, v1: Float; var bx, top, w, h, adv: Float }

/// Rasterizes the system's heavy rounded font into a mipmapped texture at startup.
final class FontAtlas {
    let size = 1024
    let height = 512
    let px: CGFloat = 64
    var pixels: [UInt8] = []
    var gray: [UInt8] = []
    var glyphs: [Character: Glyph] = [:]
    var capHeight: Float = 0.7

    init() {
        let base = NSFont.systemFont(ofSize: px, weight: .heavy)
        var font = base
        if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: px) { font = f }
        let ct = font as CTFont
        capHeight = Float(CTFontGetCapHeight(ct) / px)
        guard let ctx = CGContext(data: nil, width: size, height: height, bitsPerComponent: 8, bytesPerRow: size,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: height))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.setShouldAntialias(true)

        var chars: [Character] = []
        for c in 32...126 { chars.append(Character(UnicodeScalar(c)!)) }
        chars += ["…", "★", "•", "×", "é", "’", "−", "–", "—", "»", "«", "·"]
        let pad = 4
        var x = pad, y = pad, rowH = 0
        for ch in chars {
            var units = Array(String(ch).utf16)
            var glyph = CGGlyph(0)
            guard units.count == 1, CTFontGetGlyphsForCharacters(ct, &units, &glyph, 1) else { continue }
            var adv = CGSize.zero
            CTFontGetAdvancesForGlyphs(ct, .horizontal, &glyph, &adv, 1)
            var bb = CGRect.zero
            CTFontGetBoundingRectsForGlyphs(ct, .horizontal, &glyph, &bb, 1)
            if bb.width < 0.5 || bb.height < 0.5 {
                glyphs[ch] = Glyph(u0: 0, v0: 0, u1: 0, v1: 0, bx: 0, top: 0, w: 0, h: 0, adv: Float(adv.width / px))
                continue
            }
            let gw = Int(ceil(bb.width)) + pad * 2, gh = Int(ceil(bb.height)) + pad * 2
            if x + gw > size { x = pad; y += rowH + 2; rowH = 0 }
            rowH = max(rowH, gh)
            var pos = CGPoint(x: CGFloat(x + pad) - bb.origin.x,
                              y: CGFloat(height - (y + gh)) + CGFloat(pad) - bb.origin.y)
            CTFontDrawGlyphs(ct, &glyph, &pos, 1, ctx)
            glyphs[ch] = Glyph(u0: Float(x) / Float(size), v0: Float(y) / Float(height),
                               u1: Float(x + gw) / Float(size), v1: Float(y + gh) / Float(height),
                               bx: Float(bb.origin.x - CGFloat(pad)) / Float(px),
                               top: Float(bb.origin.y + bb.height + CGFloat(pad)) / Float(px),
                               w: Float(gw) / Float(px), h: Float(gh) / Float(px), adv: Float(adv.width / px))
            x += gw + 2
        }
        guard let data = ctx.data else { return }
        let src = data.bindMemory(to: UInt8.self, capacity: size * height)
        gray = Array(UnsafeBufferPointer(start: src, count: size * height))
        pixels = [UInt8](repeating: 255, count: size * height * 4)
        for i in 0..<(size * height) { pixels[i * 4 + 3] = gray[i] }
    }

    /// Coverage lookup in em space for baking text into sprites (box-filtered).
    func coverage(_ ch: Character, _ ex: Float, _ ey: Float, _ step: Float) -> Float {
        guard let g = glyphs[ch], g.w > 0 else { return 0 }
        let gx0 = g.u0 * Float(size), gy0 = g.v0 * Float(height)
        let sx = gx0 + (ex - g.bx) * Float(px)
        let sy = gy0 + (g.top - ey) * Float(px)
        let n = max(1, Int(step * Float(px)))
        var sum: Float = 0
        var cnt: Float = 0
        for j in 0..<n {
            for i in 0..<n {
                let X = Int(sx) + i, Y = Int(sy) + j
                if X >= Int(gx0) && X < Int(g.u1 * Float(size)) && Y >= Int(gy0) && Y < Int(g.v1 * Float(height)) {
                    sum += Float(gray[Y * size + X]) / 255
                }
                cnt += 1
            }
        }
        return sum / cnt
    }
}
