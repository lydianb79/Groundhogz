import Foundation

@inline(__always) func hash2(_ x: Int, _ y: Int) -> UInt32 {
    var h = UInt32(truncatingIfNeeded: x &* 374761393 &+ y &* 668265263)
    h = (h ^ (h >> 13)) &* 1274126177
    return h ^ (h >> 16)
}
@inline(__always) func rnd01(_ x: Int, _ y: Int) -> Float { Float(hash2(x, y) & 0xFFFF) / 65535 }

func noise1(_ x: Float, _ seed: Int) -> Float {
    let i = Int(floor(x)), f = x - floor(x)
    let a = rnd01(i, seed), b = rnd01(i + 1, seed)
    let u = f * f * (3 - 2 * f)
    return a + (b - a) * u
}

enum Mat {
    static let empty: UInt8 = 0
    static let dirt: UInt8 = 1
    static let steel: UInt8 = 2
    static let carrot: UInt8 = 3
}

/// Destructible pixel terrain. `mat` drives physics; `px` is the GPU data texture:
/// R = solid, G = material code, B = depth below the original surface (or carrot brick code).
final class Terrain {
    let w: Int, h: Int
    var mat: [UInt8]
    var px: [UInt32]
    var dirtyMin = 0
    var dirtyMax = Int.max
    let theme: Theme

    init(w: Int, h: Int, theme: Theme) {
        self.w = w; self.h = h; self.theme = theme
        mat = [UInt8](repeating: 0, count: w * h)
        px = [UInt32](repeating: 0, count: w * h)
    }

    func markAllDirty() { dirtyMin = 0; dirtyMax = h - 1 }
    @inline(__always) func touch(_ y: Int) { if y < dirtyMin { dirtyMin = y }; if y > dirtyMax { dirtyMax = y } }

    @inline(__always) func inb(_ x: Int, _ y: Int) -> Bool { x >= 0 && x < w && y >= 0 && y < h }

    /// World edges act as walls; above/below the world is open air.
    @inline(__always) func solid(_ x: Int, _ y: Int) -> Bool {
        if y < 0 || y >= h { return false }
        if x < 0 || x >= w { return true }
        return mat[y * w + x] != 0
    }
    @inline(__always) func steel(_ x: Int, _ y: Int) -> Bool { inb(x, y) && mat[y * w + x] == Mat.steel }
    @inline(__always) func diggable(_ x: Int, _ y: Int) -> Bool {
        guard inb(x, y) else { return false }
        let m = mat[y * w + x]
        return m == Mat.dirt || m == Mat.carrot
    }

    @discardableResult func carve(_ x: Int, _ y: Int) -> Bool {
        guard inb(x, y) else { return false }
        let i = y * w + x
        let m = mat[i]
        if m == Mat.dirt || m == Mat.carrot { mat[i] = 0; px[i] = 0; touch(y); return true }
        return false
    }

    func ellipseHasSteel(_ cx: Int, _ cy: Int, _ rx: Int, _ ry: Int) -> Bool {
        for y in (cy - ry)...(cy + ry) {
            for x in (cx - rx)...(cx + rx) where inEllipse(x, y, cx, cy, rx, ry) && steel(x, y) { return true }
        }
        return false
    }

    @discardableResult func carveEllipse(_ cx: Int, _ cy: Int, _ rx: Int, _ ry: Int) -> Int {
        var n = 0
        for y in (cy - ry)...(cy + ry) {
            for x in (cx - rx)...(cx + rx) where inEllipse(x, y, cx, cy, rx, ry) { if carve(x, y) { n += 1 } }
        }
        return n
    }

    @inline(__always) private func inEllipse(_ x: Int, _ y: Int, _ cx: Int, _ cy: Int, _ rx: Int, _ ry: Int) -> Bool {
        let dx = Float(x - cx) / Float(rx), dy = Float(y - cy) / Float(ry)
        return dx * dx + dy * dy <= 1
    }

    /// Builders lay carrots. They are surprisingly structural.
    func placeBrick(_ x: Int, _ y: Int, _ i: Int, lower: Bool) {
        guard inb(x, y), mat[y * w + x] == Mat.empty else { return }
        mat[y * w + x] = Mat.carrot
        let code = UInt32(i * 36 + (lower ? 18 : 0))
        px[y * w + x] = 255 | (240 << 8) | (code << 16) | (255 << 24)
        touch(y)
    }

    // MARK: level construction helpers

    func fill(_ x: Int, _ y: Int, _ fw: Int, _ fh: Int, _ m: UInt8 = Mat.dirt) {
        guard fw > 0, fh > 0 else { return }
        for yy in max(0, y)..<min(h, y + fh) { for xx in max(0, x)..<min(w, x + fw) { mat[yy * w + xx] = m } }
    }

    func clear(_ x: Int, _ y: Int, _ fw: Int, _ fh: Int) { fill(x, y, fw, fh, Mat.empty) }

    func fillEllipse(_ cx: Int, _ cy: Int, _ rx: Int, _ ry: Int, _ m: UInt8 = Mat.dirt) {
        for y in (cy - ry)...(cy + ry) {
            for x in (cx - rx)...(cx + rx) where inb(x, y) && inEllipse(x, y, cx, cy, rx, ry) { mat[y * w + x] = m }
        }
    }

    func ground(_ x0: Int, _ x1: Int, _ top: (Int) -> Int) {
        guard x1 > x0 else { return }
        for x in max(0, x0)..<min(w, x1) { for y in max(0, top(x))..<h { mat[y * w + x] = Mat.dirt } }
    }

    /// A floating slab with a flat top and a craggy underside.
    func slab(_ x: Int, _ y: Int, _ sw: Int, _ sh: Int, rough: Int = 5, seed: Int = 7) {
        for xx in x..<(x + sw) {
            let edge = min(xx - x, x + sw - 1 - xx)
            let taper = edge < 8 ? (8 - edge) : 0
            let bottom = y + sh + Int(noise1(Float(xx) * 0.15, seed) * Float(rough)) - taper
            for yy in y..<max(y + 2, bottom) where inb(xx, yy) { mat[yy * w + xx] = Mat.dirt }
        }
    }

    func mirror() {
        for y in 0..<h {
            var a = y * w, b = y * w + w - 1
            while a < b { mat.swapAt(a, b); a += 1; b -= 1 }
        }
    }

    /// Build the GPU data texture from the material map (once, after level construction).
    func finalize() {
        for x in 0..<w {
            var run = 0
            for y in 0..<h {
                let i = y * w + x
                let m = mat[i]
                if m == Mat.empty { run = 0; px[i] = 0; continue }
                run += 1
                let code: UInt32 = m == Mat.dirt ? 80 : (m == Mat.steel ? 160 : 240)
                let info = UInt32(min(255, run))
                px[i] = 255 | (code << 8) | (info << 16) | (255 << 24)
            }
        }
        markAllDirty()
    }
}
