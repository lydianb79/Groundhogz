import Foundation
import simd

// Every sprite is drawn procedurally at 2x detail (32x32 per 16x16 logical hog) with
// spherical shading, sel-out outlines, highlights and fur noise.

struct Region { var x: Int; var y: Int; var w: Int; var h: Int; var s: Float = 2 }

@inline(__always) func c8(_ v: Int) -> UInt32 { UInt32(max(0, min(255, v))) }
@inline(__always) func rgba(_ r: Int, _ g: Int, _ b: Int, _ a: Int = 255) -> UInt32 {
    c8(r) | (c8(g) << 8) | (c8(b) << 16) | (c8(a) << 24)
}
@inline(__always) func channels(_ c: UInt32) -> (Int, Int, Int, Int) {
    (Int(c & 255), Int((c >> 8) & 255), Int((c >> 16) & 255), Int((c >> 24) & 255))
}
func scaleC(_ c: UInt32, _ k: Float) -> UInt32 {
    let (r, g, b, a) = channels(c)
    return rgba(Int(Float(r) * k), Int(Float(g) * k), Int(Float(b) * k), a)
}
func mixC(_ a: UInt32, _ b: UInt32, _ t: Float) -> UInt32 {
    let (r1, g1, b1, a1) = channels(a), (r2, g2, b2, a2) = channels(b)
    func m(_ x: Int, _ y: Int) -> Int { Int(Float(x) + (Float(y) - Float(x)) * t) }
    return rgba(m(r1, r2), m(g1, g2), m(b1, b2), m(a1, a2))
}

typealias RGB3 = (Int, Int, Int)

func ell(_ cx: Float, _ cy: Float, _ rx: Float, _ ry: Float) -> (Float, Float) -> Bool {
    return { x, y in
        let dx = (x - cx) / rx, dy = (y - cy) / ry
        return dx * dx + dy * dy <= 1
    }
}

func seg(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ r: Float) -> (Float, Float) -> Bool {
    return { x, y in
        let p = SIMD2<Float>(x, y), ab = b - a
        let t = max(0, min(1, simd_dot(p - a, ab) / max(simd_dot(ab, ab), 0.0001)))
        let d = p - (a + ab * t)
        return simd_dot(d, d) <= r * r
    }
}

struct Canvas {
    let w: Int, h: Int
    var buf: [UInt32]
    init(_ w: Int, _ h: Int) { self.w = w; self.h = h; buf = [UInt32](repeating: 0, count: w * h) }

    mutating func shape(_ c: UInt32, _ f: (Float, Float) -> Bool) {
        for y in 0..<h { for x in 0..<w where f(Float(x) + 0.5, Float(y) + 0.5) { buf[y * w + x] = c } }
    }
    /// Shaded ellipsoid: lit from the top-left.
    mutating func ball(_ base: RGB3, _ cx: Float, _ cy: Float, _ rx: Float, _ ry: Float, amb: Float = 0.62,
                       noise: Float = 0, spec: Float = 0, clip: ((Float, Float) -> Bool)? = nil) {
        for y in 0..<h {
            for x in 0..<w {
                let px = Float(x) + 0.5, py = Float(y) + 0.5
                let dx = (px - cx) / rx, dy = (py - cy) / ry
                let d2 = dx * dx + dy * dy
                if d2 > 1 { continue }
                if let c = clip, !c(px, py) { continue }
                let nz = sqrt(max(0, 1 - d2))
                let lam = max(0, -0.45 * dx - 0.6 * dy + 0.66 * nz)
                var k = amb + 0.55 * lam
                if noise > 0 { k += (rnd01((x >> 1) &* 7 &+ Int(cx * 13), (y >> 1) &* 3 &+ Int(cy * 11)) - 0.5) * noise }
                let sp = spec * pow(lam, 12) * 255
                buf[y * w + x] = rgba(Int(Float(base.0) * k + sp), Int(Float(base.1) * k + sp), Int(Float(base.2) * k + sp))
            }
        }
    }
    mutating func dot(_ x: Float, _ y: Float, _ c: UInt32) { set(Int(floor(x)), Int(floor(y)), c) }
    mutating func set(_ x: Int, _ y: Int, _ c: UInt32) {
        if x >= 0 && x < w && y >= 0 && y < h { buf[y * w + x] = c }
    }
    mutating func blend(_ x: Int, _ y: Int, _ c: UInt32, _ t: Float) {
        if x >= 0 && x < w && y >= 0 && y < h && buf[y * w + x] != 0 { buf[y * w + x] = mixC(buf[y * w + x], c, t) }
    }
    func get(_ x: Int, _ y: Int) -> UInt32 { (x >= 0 && x < w && y >= 0 && y < h) ? buf[y * w + x] : 0 }

    /// Sel-out: outline pixels take a darkened version of the neighbouring colour.
    mutating func selout(_ k: Float = 0.38, alpha: Int = 255) {
        var out = buf
        for y in 0..<h {
            for x in 0..<w where buf[y * w + x] == 0 {
                for (dx, dy) in [(0, 1), (0, -1), (1, 0), (-1, 0)] {
                    let n = get(x + dx, y + dy)
                    if n != 0 && (n >> 24) > 200 {
                        let (r, g, b, _) = channels(n)
                        out[y * w + x] = rgba(Int(Float(r) * k) + 8, Int(Float(g) * k) + 4, Int(Float(b) * k) + 4, alpha)
                        break
                    }
                }
            }
        }
        buf = out
    }
}

enum Eye { case open, closed, wide, shades, dead }
enum Hat { case none, hardhat, helmet, headband }

struct Pose {
    var bx: Float = 7.5, by: Float = 10.3, brx: Float = 4.0, bry: Float = 4.1
    var hx: Float = 9.0, hy: Float = 5.0, hr: Float = 3.2
    var fh = SIMD2<Float>(10.6, 11.0)
    var bh = SIMD2<Float>(5.0, 11.0)
    var ff = SIMD2<Float>(9.4, 14.0)
    var bf = SIMD2<Float>(6.0, 14.0)
    var eye: Eye = .open
    var hat: Hat = .none
    var mouth = false
    var glove = false
    var carrot = false
    var pickTip: SIMD2<Float>? = nil

    mutating func shift(_ dx: Float, _ dy: Float) {
        bx += dx; by += dy; hx += dx; hy += dy
        fh += SIMD2(dx, dy); bh += SIMD2(dx, dy)
    }
}

let FUR: RGB3 = (182, 120, 66)
let FUR_D: RGB3 = (128, 80, 44)
let BELLY: RGB3 = (240, 204, 150)
let PAW: RGB3 = (96, 62, 38)
let EYE = rgba(18, 12, 12)
let TOOTH = rgba(255, 255, 246)
let NOSE = rgba(70, 34, 34)

/// Supersampled painter: shapes are given in 16-unit hog space, painted at K px/unit,
/// outlined, then box-downsampled 2x for smooth edges.
struct Painter {
    var c: Canvas
    let K: Float
    init(_ size: Int, _ k: Float) { c = Canvas(size, size); K = k }
    func e(_ cx: Float, _ cy: Float, _ rx: Float, _ ry: Float) -> (Float, Float) -> Bool { ell(cx * K, cy * K, rx * K, ry * K) }
    mutating func ball(_ base: RGB3, _ cx: Float, _ cy: Float, _ rx: Float, _ ry: Float, amb: Float = 0.62, noise: Float = 0,
                       spec: Float = 0, clip: ((Float, Float) -> Bool)? = nil) {
        c.ball(base, cx * K, cy * K, rx * K, ry * K, amb: amb, noise: noise, spec: spec, clip: clip)
    }
    mutating func fill(_ col: UInt32, _ f: (Float, Float) -> Bool) { c.shape(col, f) }
    mutating func oval(_ col: UInt32, _ cx: Float, _ cy: Float, _ rx: Float, _ ry: Float) { c.shape(col, e(cx, cy, rx, ry)) }
    mutating func line(_ col: UInt32, _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ r: Float) { c.shape(col, seg(a * K, b * K, r * K)) }
    /// Tints opaque pixels; transparent ones get a translucent pixel (for whiskers).
    mutating func over(_ col: UInt32, _ t: Float, _ f: (Float, Float) -> Bool, onEmpty: Bool = false) {
        let (r, g, b, _) = channels(col)
        for y in 0..<c.h {
            for x in 0..<c.w where f(Float(x) + 0.5, Float(y) + 0.5) {
                let i = y * c.w + x
                if c.buf[i] != 0 { c.buf[i] = mixC(c.buf[i], col | 0xFF00_0000, t) } else if onEmpty { c.buf[i] = rgba(r, g, b, Int(255 * t)) }
            }
        }
    }
    mutating func finish(outline: Bool = true, passes: Int = 2) -> [UInt32] {
        if outline {
            c.selout(0.36)
            for i in 1..<max(2, passes) { c.selout(i == 1 ? 0.5 : 0.9) }
        }
        let n = c.w / 2
        var out = [UInt32](repeating: 0, count: n * n)
        for y in 0..<n {
            for x in 0..<n {
                var sr: Float = 0, sg: Float = 0, sb: Float = 0, sa: Float = 0
                for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                    let (r, g, b, a) = channels(c.buf[(y * 2 + dy) * c.w + x * 2 + dx])
                    let af = Float(a) / 255
                    sr += Float(r) * af; sg += Float(g) * af; sb += Float(b) * af; sa += af
                }
                if sa > 0.01 { out[y * n + x] = rgba(Int(sr / sa), Int(sg / sa), Int(sb / sa), Int(sa / 4 * 255)) }
            }
        }
        return out
    }
}

/// Renders a hog pose at 4x (64x64), supersampled from 128x128. Pose coordinates are in 16-space.
func renderHog(_ p: Pose, size: Int = 64) -> [UInt32] {
    var P = Painter(size * 2, Float(size * 2) / 16)
    let K = P.K
    // back arm, back foot, tail
    P.line(rgba(FUR_D.0, FUR_D.1, FUR_D.2), SIMD2(p.bx - 1.0, p.by - 2.4), p.bh, 0.95)
    P.ball(PAW, p.bh.x, p.bh.y, 1.05, 1.05, amb: 0.5)
    P.ball(PAW, p.bf.x, p.bf.y - 0.4, 1.75, 1.0, amb: 0.5)
    P.ball(FUR_D, p.bx - 3.9, p.by + 2.4, 1.6, 1.25, amb: 0.55, noise: 0.12)
    // body, back stripe, belly
    let bodyE = P.e(p.bx, p.by, p.brx, p.bry)
    P.ball(FUR, p.bx, p.by, p.brx, p.bry, noise: 0.14, spec: 0.08)
    P.ball(FUR_D, p.bx, p.by, p.brx, p.bry, amb: 0.7, noise: 0.12) { x, y in bodyE(x, y) && (x - p.bx * K) < -p.brx * K * 0.45 }
    P.ball(BELLY, p.bx + 1.8, p.by + 0.6, 2.6, 3.4, amb: 0.74, noise: 0.06, clip: bodyE)
    // front foot with toes
    P.ball(PAW, p.ff.x, p.ff.y - 0.4, 1.85, 1.0, amb: 0.55)
    P.oval(rgba(150, 120, 100), p.ff.x + 1.1, p.ff.y - 0.35, 0.22, 0.2)
    P.oval(rgba(150, 120, 100), p.ff.x + 1.6, p.ff.y - 0.15, 0.2, 0.2)
    // head, ear, muzzle, cheek blush
    P.ball(FUR, p.hx, p.hy, p.hr, p.hr * 0.95, noise: 0.14, spec: 0.1)
    P.ball(FUR_D, p.hx - 1.4, p.hy - 2.7, 1.15, 1.05, amb: 0.6)
    P.oval(rgba(235, 150, 150), p.hx - 1.35, p.hy - 2.55, 0.55, 0.45)
    P.ball(BELLY, p.hx + 2.1, p.hy + 0.9, 1.95, 1.55, amb: 0.8, spec: 0.12)
    P.over(rgba(255, 130, 140), 0.38, P.e(p.hx + 0.7, p.hy + 1.5, 0.75, 0.5))
    // headgear
    switch p.hat {
    case .hardhat, .helmet:
        let col: RGB3 = p.hat == .hardhat ? (252, 206, 40) : (240, 124, 36)
        let cut = (p.hy - 1.0) * K
        P.ball(col, p.hx - 0.2, p.hy - 1.1, p.hr + 0.45, 2.8, amb: 0.7, spec: 0.7) { _, y in y < cut }
        P.ball((Int(Float(col.0) * 0.85), Int(Float(col.1) * 0.85), Int(Float(col.2) * 0.85)), p.hx + 0.3, p.hy - 1.0, p.hr + 1.0, 0.38, amb: 0.8)
        P.line(rgba(Int(Float(col.0) * 0.8), Int(Float(col.1) * 0.8), Int(Float(col.2) * 0.8)),
               SIMD2(p.hx - 0.3, p.hy - 3.8), SIMD2(p.hx - 0.1, p.hy - 1.3), 0.18)
        if p.hat == .helmet {
            P.ball((255, 250, 190), p.hx + 2.5, p.hy - 2.2, 1.1, 1.0, amb: 1.0, spec: 0.5)
            P.oval(rgba(255, 255, 255), p.hx + 2.3, p.hy - 2.45, 0.35, 0.3)
        }
    case .headband:
        let headE = P.e(p.hx, p.hy, p.hr, p.hr * 0.95)
        let y0 = (p.hy - 1.95) * K, y1 = (p.hy - 1.15) * K
        P.fill(rgba(222, 52, 52)) { x, y in headE(x, y) && y >= y0 && y < y1 }
        P.fill(rgba(250, 110, 110)) { x, y in headE(x, y) && y >= y0 && y < y0 + K * 0.22 }
        P.line(rgba(210, 44, 44), SIMD2(p.hx - 3.0, p.hy - 1.5), SIMD2(p.hx - 4.7, p.hy - 0.5), 0.35)
        P.line(rgba(190, 36, 40), SIMD2(p.hx - 3.0, p.hy - 1.5), SIMD2(p.hx - 4.3, p.hy + 0.4), 0.3)
    case .none: break
    }
    // held items
    if p.carrot {
        P.line(rgba(248, 140, 30), p.fh, p.fh + SIMD2(3.6, 0.6), 0.85)
        P.line(rgba(255, 190, 90), p.fh + SIMD2(0.3, -0.4), p.fh + SIMD2(3.0, 0.1), 0.18)
        for i in 1..<4 { let q = p.fh + SIMD2(Float(i) * 0.9, Float(i) * 0.15); P.line(rgba(200, 100, 20), q + SIMD2(0, -0.6), q + SIMD2(0.15, 0.5), 0.08) }
        P.line(rgba(80, 180, 60), p.fh + SIMD2(-0.4, -0.3), p.fh + SIMD2(-1.6, -1.7), 0.32)
        P.line(rgba(60, 150, 50), p.fh + SIMD2(-0.4, -0.2), p.fh + SIMD2(-1.9, -0.8), 0.28)
    }
    if let tip = p.pickTip {
        P.line(rgba(140, 92, 48), p.fh, tip, 0.45)
        let d = simd_normalize(tip - p.fh)
        let n = SIMD2<Float>(-d.y, d.x)
        P.line(rgba(150, 156, 170), tip - n * 2.6, tip + n * 2.6, 0.55)
        P.line(rgba(235, 238, 245), tip - n * 2.3 - d * 0.2, tip + n * 0.6 - d * 0.2, 0.18)
    }
    // front arm + hand
    P.line(rgba(FUR.0, FUR.1, FUR.2), SIMD2(p.bx + 1.2, p.by - 2.2), p.fh, 0.95)
    if p.glove {
        P.ball((226, 48, 48), p.fh.x, p.fh.y, 1.7, 1.55, amb: 0.6, spec: 0.6)
        P.line(rgba(250, 245, 235), p.fh + SIMD2(-1.3, -1.0), p.fh + SIMD2(-1.5, 1.0), 0.3)
    } else {
        P.ball(PAW, p.fh.x, p.fh.y, 1.05, 1.05, amb: 0.6)
    }
    // face
    let ex = p.hx + 0.95, ey = p.hy - 0.5
    let white = rgba(255, 255, 255)
    switch p.eye {
    case .open:
        P.oval(EYE, ex, ey, 0.5, 0.62)
        P.oval(white, ex - 0.15, ey - 0.25, 0.19, 0.19)
    case .closed:
        P.line(EYE, SIMD2(ex - 0.6, ey + 0.1), SIMD2(ex, ey - 0.28), 0.14)
        P.line(EYE, SIMD2(ex, ey - 0.28), SIMD2(ex + 0.55, ey + 0.1), 0.14)
    case .wide:
        P.oval(white, ex, ey - 0.1, 0.78, 0.9)
        P.oval(EYE, ex + 0.25, ey, 0.42, 0.5)
        P.oval(white, ex + 0.12, ey - 0.18, 0.15, 0.15)
    case .shades:
        P.line(EYE, SIMD2(p.hx - 1.3, ey - 0.4), SIMD2(p.hx + 2.7, ey - 0.4), 0.2)
        P.oval(rgba(28, 28, 40), ex + 0.15, ey + 0.05, 0.85, 0.62)
        P.oval(rgba(28, 28, 40), p.hx - 0.65, ey + 0.05, 0.55, 0.55)
        P.line(rgba(170, 195, 255), SIMD2(ex - 0.35, ey - 0.15), SIMD2(ex + 0.15, ey - 0.3), 0.09)
    case .dead:
        P.line(EYE, SIMD2(ex - 0.5, ey - 0.5), SIMD2(ex + 0.5, ey + 0.5), 0.15)
        P.line(EYE, SIMD2(ex - 0.5, ey + 0.5), SIMD2(ex + 0.5, ey - 0.5), 0.15)
    }
    P.oval(NOSE, p.hx + 3.85, p.hy + 0.45, 0.55, 0.45)
    P.oval(rgba(170, 110, 110), p.hx + 3.7, p.hy + 0.3, 0.18, 0.12)
    let tx0 = (p.hx + 2.1) * K, tx1 = (p.hx + 2.95) * K, ty0 = (p.hy + 2.2) * K, ty1 = (p.hy + 3.55) * K
    P.fill(TOOTH) { x, y in x >= tx0 && x < tx1 && y >= ty0 && y < ty1 }
    P.line(rgba(205, 200, 185), SIMD2(p.hx + 2.52, p.hy + 2.3), SIMD2(p.hx + 2.52, p.hy + 3.5), 0.05)
    if p.mouth { P.oval(rgba(100, 30, 34), p.hx + 3.15, p.hy + 1.95, 0.5, 0.35) }
    var out = P
    let pixels = out.finish(passes: max(2, size / 56))
    // whiskers on top, at final resolution
    var W = Painter(size, Float(size) / 16)
    let wk = Float(size) / 16
    W.c.buf = pixels
    for (dx, dy) in [(1.6, -0.5), (1.7, 0.2), (1.5, 0.8)] as [(Float, Float)] {
        let a = SIMD2<Float>(p.hx + 3.3, p.hy + 1.0)
        W.over(rgba(255, 250, 235), 0.55, seg(a * wk, (a + SIMD2(dx, dy)) * wk, 0.07 * wk), onEmpty: true)
    }
    return W.c.buf
}

func renderSplat() -> [UInt32] {
    var P = Painter(128, 8)
    P.ball(FUR_D, 1.5, 13.3, 1.3, 1.0, amb: 0.55)
    P.ball(FUR, 8, 13.6, 6.4, 1.8, noise: 0.12)
    P.ball(BELLY, 8.8, 14.1, 3.7, 0.9, amb: 0.75)
    P.ball(PAW, 3, 14.8, 1.3, 0.6)
    P.ball(PAW, 12.5, 14.8, 1.3, 0.6)
    P.line(EYE, SIMD2(10.0, 12.0), SIMD2(11.0, 13.0), 0.14)
    P.line(EYE, SIMD2(10.0, 13.0), SIMD2(11.0, 12.0), 0.14)
    P.fill(TOOTH) { x, y in x >= 13.4 * 8 && x < 14.2 * 8 && y >= 13.8 * 8 && y < 14.6 * 8 }
    return P.finish()
}

private func hogPoses() -> [(String, [Pose])] {
    var list: [(String, [Pose])] = []
    var walk: [Pose] = []
    for i in 0..<8 {
        let a = Float(i) / 8 * 2 * Float.pi
        let s = sin(a)
        var p = Pose()
        p.ff = SIMD2(8.0 + 2.4 * s, 14 - max(0, -cos(a)) * 0.9)
        p.bf = SIMD2(7.2 - 2.4 * s, 14 - max(0, cos(a)) * 0.9)
        p.fh = SIMD2(10.6 - 1.5 * s, 11.2)
        p.bh = SIMD2(5.0 + 1.5 * s, 11.2)
        p.shift(0, -abs(cos(a)) * 0.5)
        walk.append(p)
    }
    list.append(("walk", walk))
    list.append(("walkb", walk.map { var q = $0; q.eye = .closed; return q }))
    list.append(("fall", (0..<2).map { i in
        var p = Pose(); let f = Float(i)
        p.fh = SIMD2(13.2, 3.5 + f); p.bh = SIMD2(3.2, 4.5 - f)
        p.ff = SIMD2(9.6, 14 - f * 0.8); p.bf = SIMD2(5.8, 13.2 + f * 0.8)
        p.eye = .wide; p.mouth = true
        return p
    }))
    list.append(("float", (0..<2).map { i in
        var p = Pose(); let f = Float(i)
        p.fh = SIMD2(12.8, 3.0); p.bh = SIMD2(4.0, 9.0 + f * 0.6)
        p.ff = SIMD2(9.2 + f * 0.6, 14); p.bf = SIMD2(6.2 - f * 0.6, 13.6)
        p.eye = .closed
        return p
    }))
    list.append(("climb", (0..<2).map { i in
        var p = Pose(); let f = Float(i)
        p.bx = 8.2; p.hx = 9.6
        p.fh = SIMD2(13.3, 3.2 + f * 2); p.bh = SIMD2(12.6, 7.0 - f * 2)
        p.ff = SIMD2(11.6, 13.4 - f); p.bf = SIMD2(10.6, 13.4 - (1 - f))
        p.hat = .headband
        return p
    }))
    list.append(("dig", (0..<2).map { i in
        var p = Pose(); let f = Float(i)
        p.shift(0.3, 0.8); p.hy += 0.4; p.hx += 0.4
        p.hat = .hardhat
        p.fh = SIMD2(10.6 - f * 2.5, 14.2); p.bh = SIMD2(6.4 + f * 2.5, 14.2)
        p.ff = SIMD2(11.4, 14); p.bf = SIMD2(4.4, 14)
        return p
    }))
    let punch: [Float] = [10.8, 13.2, 14.0, 12.0]
    list.append(("bash", (0..<4).map { i in
        var p = Pose()
        p.hx += 0.5; p.glove = true
        p.fh = SIMD2(punch[i], 9.0); p.bh = SIMD2(5.4, 9.6)
        p.mouth = i == 2
        p.ff = SIMD2(10.4, 14); p.bf = SIMD2(5.0, 14)
        return p
    }))
    let hands: [SIMD2<Float>] = [SIMD2(9.4, 3.6), SIMD2(12.0, 4.6), SIMD2(12.6, 10.0), SIMD2(12.2, 10.6)]
    let tips: [SIMD2<Float>] = [SIMD2(5.0, 1.4), SIMD2(14.6, 1.2), SIMD2(15.0, 13.4), SIMD2(14.6, 14.2)]
    list.append(("mine", (0..<4).map { i in
        var p = Pose()
        p.hat = .helmet
        p.fh = hands[i]; p.bh = hands[i] + SIMD2(-1.2, 0.8)
        p.pickTip = tips[i]
        p.ff = SIMD2(10.6, 14); p.bf = SIMD2(5.0, 14)
        return p
    }))
    list.append(("build", (0..<2).map { i in
        var p = Pose(); let f = Float(i)
        p.shift(0, 0.8)
        p.hat = .hardhat; p.carrot = true
        p.fh = SIMD2(11.6 + f, 12.4 + f * 0.6); p.bh = SIMD2(6.0, 12.0)
        p.ff = SIMD2(10.0, 14); p.bf = SIMD2(5.4, 14)
        return p
    }))
    list.append(("block", (0..<2).map { i in
        var p = Pose(); let f = Float(i)
        p.eye = .shades
        p.fh = SIMD2(14.0, 7.6); p.bh = SIMD2(1.6, 7.6)
        p.ff = SIMD2(10.6, 14 - f * 0.9); p.bf = SIMD2(4.6, 14)
        return p
    }))
    list.append(("shrug", (0..<2).map { i in
        var p = Pose(); let f = Float(i)
        p.eye = .closed
        p.fh = SIMD2(13.2, 6.0 - f); p.bh = SIMD2(2.4, 6.0 - f)
        return p
    }))
    list.append(("ohno", (0..<2).map { i in
        var p = Pose()
        p.eye = .wide; p.mouth = true
        p.shift(i == 0 ? -0.4 : 0.4, 0)
        p.fh = SIMD2(12.4, 7.4); p.bh = SIMD2(6.2, 6.6)
        return p
    }))
    let jumps: [Float] = [0, -1, -2, -1]
    list.append(("exit", (0..<4).map { i in
        var p = Pose()
        let j = jumps[i]
        p.shift(0, j)
        p.ff.y += j; p.bf.y += j
        p.fh = SIMD2(13.0, 2.0 + j); p.bh = SIMD2(3.6, 2.4 + j)
        p.eye = .closed; p.mouth = true
        return p
    }))
    list.append(("drown", (0..<2).map { i in
        var p = Pose(); let f = Float(i)
        p.eye = .wide; p.mouth = true
        p.fh = SIMD2(13.0, 2.6 + f); p.bh = SIMD2(3.0, 3.6 - f)
        return p
    }))
    list.append(("wave", (0..<2).map { i in
        var p = Pose()
        p.fh = SIMD2(13.2, 3.0 + Float(i) * 2.0)
        p.mouth = true
        return p
    }))
    list.append(("idle", [Pose()]))
    return list
}

final class Atlas {
    static let size = 1024
    var px: [UInt32]
    var anims: [String: [Region]] = [:]

    let white = Region(x: 1000, y: 1000, w: 16, h: 16, s: 1)
    let umbrella = Region(x: 0, y: 320, w: 32, h: 20)
    let crateClosed = Region(x: 40, y: 320, w: 64, h: 48)
    let crateOpen = Region(x: 110, y: 320, w: 64, h: 48)
    let burrow = Region(x: 180, y: 320, w: 96, h: 72)
    let flags = [Region(x: 280, y: 320, w: 16, h: 12), Region(x: 300, y: 320, w: 16, h: 12)]
    let puff = Region(x: 320, y: 320, w: 32, h: 32)
    let bomb = Region(x: 360, y: 320, w: 32, h: 32)
    let lantern = Region(x: 440, y: 320, w: 12, h: 18)
    let star = Region(x: 460, y: 320, w: 20, h: 20)
    let lock = Region(x: 484, y: 320, w: 16, h: 20)
    let check = Region(x: 504, y: 320, w: 20, h: 20)
    let glow = Region(x: 528, y: 320, w: 64, h: 64)
    let panel = Region(x: 600, y: 320, w: 48, h: 48)
    let button = Region(x: 656, y: 320, w: 32, h: 32)
    let buttonHot = Region(x: 696, y: 320, w: 32, h: 32)
    let buttonSel = Region(x: 736, y: 320, w: 32, h: 32)
    let bubble = Region(x: 776, y: 320, w: 24, h: 24)
    let paper = Region(x: 808, y: 320, w: 48, h: 48)
    let ghost = Region(x: 0, y: 400, w: 64, h: 64, s: 4)
    let rock = Region(x: 70, y: 400, w: 16, h: 16)
    let ring = Region(x: 90, y: 400, w: 64, h: 64)
    let hole = Region(x: 160, y: 400, w: 128, h: 128, s: 1)
    let splashHog = [Region(x: 300, y: 400, w: 256, h: 256, s: 16), Region(x: 560, y: 400, w: 256, h: 256, s: 16)]

    init(font: FontAtlas) {
        px = [UInt32](repeating: 0, count: Atlas.size * Atlas.size)
        buildHogs()
        buildProps(font)
        buildUI()
        for y in 0..<white.h { for x in 0..<white.w { put(white.x + x, white.y + y, rgba(255, 255, 255)) } }
    }

    func frame(_ name: String, _ i: Int) -> Region {
        guard let f = anims[name], !f.isEmpty else { return white }
        return f[((i % f.count) + f.count) % f.count]
    }

    func put(_ x: Int, _ y: Int, _ c: UInt32) {
        if x >= 0 && x < Atlas.size && y >= 0 && y < Atlas.size { px[y * Atlas.size + x] = c }
    }

    func blit(_ c: Canvas, _ x: Int, _ y: Int) {
        for j in 0..<c.h { for i in 0..<c.w where c.buf[j * c.w + i] != 0 { put(x + i, y + j, c.buf[j * c.w + i]) } }
    }

    private func buildHogs() {
        var cell = 0
        func add(_ name: String, _ buf: [UInt32]) {
            let x = (cell % 16) * 64, y = (cell / 16) * 64
            for j in 0..<64 { for i in 0..<64 { put(x + i, y + j, buf[j * 64 + i]) } }
            anims[name, default: []].append(Region(x: x, y: y, w: 64, h: 64, s: 4))
            cell += 1
        }
        var idle: [UInt32] = []
        for (name, poses) in hogPoses() {
            for p in poses {
                let b = renderHog(p)
                if name == "idle" { idle = b }
                add(name, b)
            }
        }
        add("splat", renderSplat())
        var g = Canvas(64, 64)
        for i in 0..<(64 * 64) where idle[i] != 0 {
            let (r, gg, b, a) = channels(idle[i])
            let l = (r + gg + b) / 3
            g.buf[i] = rgba(200 + l / 5, 214 + l / 6, 255, Int(Float(a) * (l < 90 ? 0.68 : 0.8)))
        }
        let halo = ell(38, 5, 12.8, 4.4), inner = ell(38, 5, 9, 2.2)
        g.shape(rgba(255, 228, 90)) { x, y in halo(x, y) && !inner(x, y) }
        blit(g, ghost.x, ghost.y)

        // big hi-res waving hog for the splash screen
        for (i, reg) in splashHog.enumerated() {
            var p = Pose()
            p.bh = SIMD2(2.4 - Float(i) * 0.6, 3.4 + Float(i) * 1.4)
            p.fh = SIMD2(11.4, 10.6)
            p.mouth = true
            p.eye = i == 0 ? .open : .closed
            let b = renderHog(p, size: 256)
            for j in 0..<256 { for k in 0..<256 { put(reg.x + k, reg.y + j, b[j * 256 + k]) } }
        }

        // rock chunk (for debris)
        var rk = Canvas(16, 16)
        rk.ball((150, 130, 115), 8, 8.5, 6, 5, amb: 0.5, noise: 0.2)
        rk.selout(0.45)
        blit(rk, rock.x, rock.y)
        // shockwave ring
        var rg = Canvas(64, 64)
        for y in 0..<64 { for x in 0..<64 {
            let d = hypot(Float(x) - 31.5, Float(y) - 31.5) / 31.5
            let a = max(0, 1 - abs(d - 0.82) / 0.16)
            if a > 0 { rg.set(x, y, rgba(255, 255, 255, Int(a * a * 255))) }
        } }
        blit(rg, ring.x, ring.y)
        // iris-wipe hole: opaque outside a soft circle
        var ho = Canvas(128, 128)
        for y in 0..<128 { for x in 0..<128 {
            let d = hypot(Float(x) - 63.5, Float(y) - 63.5)
            let a = min(1, max(0, (d - 61) / 2.5))
            ho.set(x, y, a > 0 ? rgba(8, 5, 4, Int(a * 255)) : 0)
        } }
        blit(ho, hole.x, hole.y)
    }

    private func drawString(_ c: inout Canvas, _ font: FontAtlas, _ s: String, _ x: Float, _ baseY: Float, _ em: Float, _ col: UInt32) {
        var cx = x
        let step = 1 / em
        for ch in s {
            guard let gl = font.glyphs[ch] else { continue }
            if gl.w > 0 {
                let x0 = Int(cx + gl.bx * em), x1 = Int(ceil(cx + (gl.bx + gl.w) * em))
                let y0 = Int(baseY - gl.top * em), y1 = Int(ceil(baseY - (gl.top - gl.h) * em))
                for py in y0...y1 {
                    for pxx in x0...x1 {
                        let ex = (Float(pxx) - cx) / em, ey = (baseY - Float(py)) / em
                        let a = font.coverage(ch, ex, ey, step)
                        if a > 0.05 {
                            let old = c.get(pxx, py)
                            c.set(pxx, py, old == 0 ? col : mixC(old, col, min(1, a * 1.3)))
                        }
                    }
                }
            }
            cx += gl.adv * em
        }
    }

    private func buildProps(_ font: FontAtlas) {
        // umbrella
        var u = Canvas(32, 20)
        let canopy = ell(16, 14.4, 15.2, 14.0)
        for y in 0..<14 {
            for x in 0..<32 where canopy(Float(x) + 0.5, Float(y) + 0.5) {
                let stripe = Int(floor((Float(x) - 16) / 5.4 + 10)) % 2 == 1
                let base: RGB3 = stripe ? (250, 244, 236) : (226, 52, 52)
                let k: Float = 0.75 + 0.35 * (1 - Float(y) / 14) - abs(Float(x) - 16) / 60
                u.set(x, y, rgba(Int(Float(base.0) * k), Int(Float(base.1) * k), Int(Float(base.2) * k)))
            }
        }
        for x in 0..<32 where (x / 3) % 2 == 0 { u.set(x, 13, 0); u.set(x, 12, x % 3 == 1 ? 0 : u.get(x, 12)) }
        u.selout(0.45)
        for y in 12...19 { u.set(16, y, rgba(70, 46, 30)); u.set(17, y, rgba(100, 70, 46)) }
        u.set(15, 19, rgba(70, 46, 30)); u.set(14, 18, rgba(70, 46, 30))
        u.set(16, 0, rgba(240, 210, 80))
        blit(u, umbrella.x, umbrella.y)

        // supply crate
        for open in [false, true] {
            var c = Canvas(64, 48)
            for y in 0..<40 {
                for x in 0..<64 {
                    let plank = y / 10
                    let grain = sin(Float(x) * 0.35 + Float(plank) * 2.1 + sin(Float(x) * 0.07) * 3) * 0.5 + 0.5
                    var k: Float = 0.8 + 0.25 * grain + (rnd01(x, y) - 0.5) * 0.08
                    if y % 10 == 0 { k = 0.55 } else if y % 10 == 1 { k *= 1.12 }
                    var col = rgba(Int(186 * k), Int(126 * k), Int(68 * k))
                    if x < 2 || x > 61 || y < 2 || y > 37 { col = rgba(80, 48, 24) }
                    if (x < 7 || x > 56) && (y < 7 || y > 32) {
                        let lit: Float = (x < 7 ? 1.1 : 0.85) * (y < 7 ? 1.1 : 0.9)
                        col = rgba(Int(150 * lit), Int(158 * lit), Int(170 * lit))
                        if (x == 4 || x == 59) && (y == 4 || y == 35) { col = rgba(230, 236, 245) }
                    }
                    c.set(x, y, col)
                }
            }
            drawString(&c, font, "HOGS", 11, 27, 17, rgba(70, 40, 20))
            drawString(&c, font, "HOGS", 10, 26, 17, rgba(255, 232, 176))
            if open {
                for y in 31..<40 { for x in 7..<57 { c.set(x, y, rgba(14, 8, 6)) } }
                for y in 38..<48 {
                    for x in 2..<7 { c.set(x, y, rgba(150, 100, 52)) }
                    for x in 57..<62 { c.set(x, y, rgba(150, 100, 52)) }
                }
            } else {
                for y in 40..<46 { for x in 2..<62 { c.set(x, y, y == 45 ? rgba(70, 40, 20) : rgba(150, 100, 52)) } }
            }
            c.selout(0.4)
            blit(c, open ? crateOpen.x : crateClosed.x, crateClosed.y)
        }

        // the burrow
        var b = Canvas(96, 72)
        let mound = ell(48, 72, 47, 48)
        for y in 0..<72 {
            for x in 0..<96 where mound(Float(x) + 0.5, Float(y) + 0.5) {
                let dx = (Float(x) + 0.5 - 48) / 47, dy = (Float(y) + 0.5 - 72) / 48
                let nz = sqrt(max(0, 1 - dx * dx - dy * dy))
                let lam = max(0, -0.45 * dx - 0.6 * dy + 0.66 * nz)
                let strata = sin(Float(y) * 0.5 + sin(Float(x) * 0.1) * 2) * 0.06
                let k = 0.55 + 0.55 * lam + strata + (rnd01(x, y) - 0.5) * 0.1
                b.set(x, y, rgba(Int(150 * k), Int(98 * k), Int(56 * k)))
            }
        }
        for x in 0..<96 {
            for y in 0..<72 where b.get(x, y) != 0 {
                let depth = 4 + Int(rnd01(x, 3) * 3)
                for k in 0..<depth { b.set(x, y + k, rgba(Int(98 - k * 6), Int(190 - k * 10), Int(66 - k * 4))) }
                let hgt = Int(rnd01(x, 9) * 4)
                for k in 1...max(1, hgt) where x % 2 == 0 { b.set(x, y - k, rgba(80, 170, 56)) }
                break
            }
        }
        // round window
        b.ball((120, 78, 40), 24, 48, 7.5, 7.5, amb: 0.8)
        b.shape(rgba(255, 214, 110), ell(24, 48, 5, 5))
        b.shape(rgba(255, 240, 180), ell(22.5, 46.5, 2.2, 2.2))
        for i in -5...5 { b.set(24 + i, 48, rgba(120, 78, 40)); b.set(24, 48 + i, rgba(120, 78, 40)) }
        // door frame + hole + warm interior
        let hole = ell(50, 73, 15, 24), frame = ell(50, 73, 19, 28)
        for y in 0..<72 {
            for x in 0..<96 {
                let fx = Float(x) + 0.5, fy = Float(y) + 0.5
                if frame(fx, fy) && !hole(fx, fy) {
                    let ang = atan2(fy - 73, fx - 50)
                    let plank = Int((ang + 3.2) * 4) % 2 == 0
                    b.set(x, y, plank ? rgba(140, 90, 44) : rgba(118, 74, 36))
                } else if hole(fx, fy) {
                    let k = max(0, min(1, (fy - 50) / 22))
                    b.set(x, y, rgba(Int(30 + 120 * k * k), Int(16 + 70 * k * k), Int(10 + 20 * k * k)))
                }
            }
        }
        // chimney
        for y in 10..<32 {
            for x in 64..<74 {
                let mortar = y % 4 == 0 || (x + (y / 4) * 3) % 6 == 0
                b.set(x, y, mortar ? rgba(150, 120, 110) : rgba(186 - (x - 64) * 4, 76, 56))
            }
        }
        for x in 62..<76 { b.set(x, 8, rgba(80, 70, 70)); b.set(x, 9, rgba(110, 96, 96)) }
        // flag pole, mailbox
        for y in 6..<36 { b.set(20, y, rgba(90, 66, 44)); b.set(21, y, rgba(120, 90, 60)) }
        b.ball((250, 210, 50), 20.5, 5, 1.6, 1.6, amb: 0.8)
        for y in 50..<70 { b.set(84, y, rgba(100, 70, 40)) }
        b.ball((60, 110, 200), 85, 48, 4.5, 3.2, amb: 0.7)
        b.set(88, 44, rgba(230, 50, 50)); b.set(88, 45, rgba(230, 50, 50))
        b.selout(0.4)
        blit(b, burrow.x, burrow.y)

        // flags
        for i in 0..<2 {
            var f = Canvas(16, 12)
            for y in 0..<10 {
                let wave = sin(Float(y) * 0.6 + Float(i) * 2) * 1.5
                let w = 14 - abs(y - 5) * 2 + Int(wave)
                for x in 0..<max(2, w) {
                    let k: Float = 0.8 + 0.3 * sin(Float(x) * 0.6 + Float(i) * 2.5)
                    f.set(x, y, (y >= 4 && y <= 5 && x > 2 && x < 9) ? rgba(255, 244, 210) : rgba(Int(230 * k), Int(48 * k), Int(48 * k)))
                }
            }
            blit(f, flags[i].x, flags[i].y)
        }

        // soft puff + glow
        var p = Canvas(32, 32)
        for y in 0..<32 { for x in 0..<32 {
            let d = hypot(Float(x) - 15.5, Float(y) - 15.5) / 15.5
            if d < 1 { p.set(x, y, rgba(255, 255, 255, Int(pow(1 - d, 0.7) * 255))) }
        } }
        blit(p, puff.x, puff.y)
        var gl = Canvas(64, 64)
        for y in 0..<64 { for x in 0..<64 {
            let d = hypot(Float(x) - 31.5, Float(y) - 31.5) / 31.5
            if d < 1 { gl.set(x, y, rgba(255, 255, 255, Int(pow(1 - d, 2.2) * 255))) }
        } }
        blit(gl, glow.x, glow.y)

        // bomb
        var bm = Canvas(32, 32)
        bm.ball((60, 60, 74), 14, 20, 9.6, 9.6, amb: 0.45)
        bm.shape(rgba(200, 205, 220)) { x, y in hypot(x - 10, y - 15.5) < 2.2 }
        for x in 11...17 { for y in 8...10 { bm.set(x, y, rgba(130, 130, 140)) } }
        bm.shape(rgba(140, 92, 48), seg(SIMD2(14.5, 8.5), SIMD2(22, 3.5), 0.9))
        bm.selout()
        bm.shape(rgba(255, 220, 80), ell(24, 2.6, 2.2, 2.2))
        bm.shape(rgba(255, 255, 220), ell(24, 2.6, 1.0, 1.0))
        blit(bm, bomb.x, bomb.y)

        // lantern
        var ln = Canvas(12, 18)
        for y in 3..<16 { for x in 1..<11 { ln.set(x, y, (x == 1 || x == 10 || y == 3 || y == 15) ? rgba(60, 50, 40) : rgba(255, 220, 120)) } }
        for x in 3..<9 { ln.set(x, 2, rgba(60, 50, 40)) }
        ln.set(5, 0, rgba(60, 50, 40)); ln.set(6, 0, rgba(60, 50, 40)); ln.set(5, 1, rgba(60, 50, 40)); ln.set(6, 1, rgba(60, 50, 40))
        for y in 6..<13 { ln.set(5, y, rgba(255, 250, 220)); ln.set(6, y, rgba(255, 250, 220)) }
        blit(ln, lantern.x, lantern.y)

        // star icon
        var st = Canvas(20, 20)
        for y in 0..<20 { for x in 0..<20 {
            let dx = Float(x) + 0.5 - 10, dy = Float(y) + 0.5 - 10.5
            let a = atan2(dy, dx) + Float.pi / 2
            let r = hypot(dx, dy)
            let lim = 9.5 * (0.55 + 0.45 * pow(abs(cos(a * 2.5)), 3))
            if r < lim { st.set(x, y, rgba(255, Int(210 - dy * 4), Int(60 - dy * 3))) }
        } }
        st.selout(0.45)
        blit(st, star.x, star.y)

        // lock
        var lk = Canvas(16, 20)
        lk.shape(rgba(170, 176, 190)) { x, y in y < 11 && abs(hypot(x - 8, y - 8.5) - 4.5) < 1.4 }
        for y in 9..<19 { for x in 2..<14 { lk.set(x, y, rgba(220 - y * 4, 180 - y * 4, 60)) } }
        lk.set(7, 13, rgba(60, 40, 20)); lk.set(8, 13, rgba(60, 40, 20)); lk.set(7, 14, rgba(60, 40, 20)); lk.set(8, 14, rgba(60, 40, 20)); lk.set(8, 15, rgba(60, 40, 20))
        lk.selout()
        blit(lk, lock.x, lock.y)

        // check mark
        var ck = Canvas(20, 20)
        ck.shape(rgba(110, 220, 90), seg(SIMD2(3, 10), SIMD2(8, 15), 2.0))
        ck.shape(rgba(110, 220, 90), seg(SIMD2(8, 15), SIMD2(17, 4), 2.0))
        ck.selout(0.35)
        blit(ck, check.x, check.y)
    }

    private func roundedBox(_ w: Int, _ h: Int, r: Float, _ f: (Int, Int, Float) -> UInt32) -> Canvas {
        var c = Canvas(w, h)
        for y in 0..<h {
            for x in 0..<w {
                let fx = Float(x) + 0.5, fy = Float(y) + 0.5
                let qx = max(r - fx, 0, fx - (Float(w) - r)), qy = max(r - fy, 0, fy - (Float(h) - r))
                let d = hypot(qx, qy) - r
                if d < 0 { c.set(x, y, f(x, y, -d)) }
            }
        }
        return c
    }

    private func buildUI() {
        // wooden panel
        let pn = roundedBox(48, 48, r: 10) { x, y, d in
            let grain = sin(Float(y) * 0.9 + sin(Float(x) * 0.15) * 2.5) * 0.5 + 0.5
            var k: Float = 0.78 + 0.16 * grain
            if d < 2 { k = 0.45 } else if d < 4 { k *= y < 24 ? 1.25 : 0.8 }
            return rgba(Int(120 * k), Int(80 * k), Int(48 * k))
        }
        blit(pn, panel.x, panel.y)
        // buttons
        for (reg, base, rim) in [(button, (122, 92, 62), (60, 40, 24)), (buttonHot, (150, 116, 78), (70, 46, 26)),
                                 (buttonSel, (238, 178, 64), (120, 70, 20))] as [(Region, RGB3, RGB3)] {
            let bt = roundedBox(32, 32, r: 7) { _, y, d in
                if d < 1.5 { return rgba(rim.0, rim.1, rim.2) }
                var k: Float = 1.15 - Float(y) / 32 * 0.4
                if d < 3 { k *= y < 14 ? 1.25 : 0.82 }
                return rgba(Int(Float(base.0) * k), Int(Float(base.1) * k), Int(Float(base.2) * k))
            }
            blit(bt, reg.x, reg.y)
        }
        // speech bubble
        let bb = roundedBox(24, 24, r: 8) { _, _, d in d < 1.5 ? rgba(60, 44, 30) : rgba(255, 252, 242) }
        blit(bb, bubble.x, bubble.y)
        // parchment
        let pp = roundedBox(48, 48, r: 12) { x, y, d in
            if d < 2 { return rgba(90, 60, 30, 240) }
            let n = rnd01(x / 2, y / 2) * 0.06
            let k: Float = 0.93 + n - (d < 6 ? (6 - d) * 0.02 : 0)
            return rgba(Int(250 * k), Int(236 * k), Int(204 * k), 245)
        }
        blit(pp, paper.x, paper.y)
    }
}
