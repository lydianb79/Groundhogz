import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Metal

// Developer tools: PNG export, icon generation, headless simulation, level verification, snapshots.

func writePNG(bytes: [UInt8], w: Int, h: Int, path: String, bgra: Bool) {
    let cs = CGColorSpaceCreateDeviceRGB()
    let info: UInt32 = bgra
        ? CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        : CGImageAlphaInfo.last.rawValue
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
          let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: cs,
                            bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil,
                            shouldInterpolate: false, intent: .defaultIntent),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { print("could not write \(path)"); return }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

func pixelsToBytes(_ px: [UInt32]) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: px.count * 4)
    for (i, c) in px.enumerated() {
        out[i * 4] = UInt8(c & 255); out[i * 4 + 1] = UInt8((c >> 8) & 255)
        out[i * 4 + 2] = UInt8((c >> 16) & 255); out[i * 4 + 3] = UInt8((c >> 24) & 255)
    }
    return out
}

func dumpAtlas(_ path: String) {
    let a = Atlas(font: FontAtlas())
    let s = 3, n = Atlas.size, rows = 210, cols = 870
    var big = [UInt32](repeating: rgba(60, 120, 90), count: rows * cols * s * s)
    for y in 0..<(rows * s) { for x in 0..<(cols * s) {
        let c = a.px[(y / s) * n + x / s]
        let al = Float(c >> 24) / 255
        if al > 0 { big[y * cols * s + x] = mixC(rgba(60, 120, 90), c | 0xFF00_0000, al) }
    } }
    writePNG(bytes: pixelsToBytes(big), w: cols * s, h: rows * s, path: path, bgra: false)
}

/// The app icon: a big shaded hog in a hard hat waving in front of a sunrise scene,
/// inside a macOS-style rounded square with a soft drop shadow.
func makeIcon(_ path: String) {
    let N = 1024
    let box: Float = 824, cx: Float = 512, cy: Float = 500
    func sq(_ x: Float, _ y: Float) -> Float {          // superellipse distance (<1 inside)
        let u = abs(x - cx) / (box / 2), v = abs(y - cy) / (box / 2)
        return pow(pow(u, 5) + pow(v, 5), 0.2)
    }
    func mixf(_ a: (Float, Float, Float), _ b: (Float, Float, Float), _ t: Float) -> (Float, Float, Float) {
        (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
    }
    func sstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float { let t = max(0, min(1, (x - e0) / (e1 - e0))); return t * t * (3 - 2 * t) }
    let sun = (x: Float(770), y: Float(240), r: Float(92))
    // scene colour in icon space (before mask)
    func scene(_ x: Float, _ y: Float) -> (Float, Float, Float) {
        let k = (y - 88) / 824
        var c = mixf((52, 128, 240), (255, 214, 160), max(0, min(1, k * 1.25)))
        // rays + glow
        let dx = x - sun.x, dy = y - sun.y
        let d = hypot(dx, dy)
        let ang = atan2(dy, dx)
        let rays = pow(0.5 + 0.5 * sin(ang * 12), 6) * exp(-d / 360) * 0.35
        c = mixf(c, (255, 248, 210), min(1, rays + exp(-d / 170) * 0.6))
        // cloud
        let blobs: [(Float, Float, Float)] = [(250, 330, 70), (330, 300, 90), (420, 330, 64), (180, 350, 50)]
        var cl: Float = 0
        for (bx, by, br) in blobs { cl = max(cl, sstep(br + 2, br - 2, hypot(x - bx, y - by))) }
        if y > 352 { cl *= sstep(370, 352, y) }
        c = mixf(c, mixf((255, 255, 255), (214, 222, 240), max(0, (y - 290) / 80)), cl * 0.95)
        // sun disc with sunglasses and a grin
        if d < sun.r + 2 {
            let a = sstep(sun.r + 1.5, sun.r - 1.5, d)
            var sc: (Float, Float, Float) = (255, 226, 92)
            sc = mixf(sc, (255, 246, 170), max(0, -dy / sun.r) * 0.6)
            let lensL = hypot((dx + 34) / 1.0, (dy + 12) / 0.75), lensR = hypot((dx - 34) / 1.0, (dy + 12) / 0.75)
            if lensL < 28 || lensR < 28 || (abs(dy + 18) < 5 && abs(dx) < 14) { sc = (30, 26, 40) }
            if hypot(dx + 44, dy + 22) < 7 || hypot(dx - 24, dy + 22) < 7 { sc = (230, 236, 255) }
            if abs(hypot(dx, dy + 6) - 52) < 6 && dy > 22 { sc = (200, 110, 40) }
            c = mixf(c, sc, a)
        }
        // hills
        let h1 = 640 + 34 * sin(x * 0.009 + 1.2) + 18 * sin(x * 0.023)
        if y > h1 { c = mixf((132, 200, 130), (110, 180, 112), sstep(h1, h1 + 120, y)) }
        let h2 = 712 + 26 * sin(x * 0.012 + 3.0)
        if y > h2 { c = mixf((88, 168, 84), (66, 140, 66), sstep(h2, h2 + 80, y)) }
        // grass + dirt
        let blade = 6 + 10 * rnd01(Int(x / 5), 3)
        if y > 790 - blade * (rnd01(Int(x / 5), 4) > 0.3 ? 1 : 0) { c = (96, 192, 64) }
        if y > 800 { c = mixf((104, 200, 70), (70, 150, 48), sstep(800, 830, y)) }
        if y > 830 {
            let strata = sin(y * 0.08 + sin(x * 0.01) * 2) * 0.5 + 0.5
            c = mixf((156, 104, 60), (124, 80, 44), strata)
            let pc = (Int(x / 26), Int(y / 22))
            let jx = (rnd01(pc.0, pc.1 + 9) - 0.5) * 14, jy = (rnd01(pc.0 + 5, pc.1) - 0.5) * 10
            let pr = 4 + 4 * rnd01(pc.0 + 2, pc.1 + 3)
            let pd = hypot(x - (Float(pc.0) + 0.5) * 26 - jx, y - (Float(pc.1) + 0.5) * 22 - jy)
            if rnd01(pc.0, pc.1) > 0.68 && pd < pr { c = mixf((190, 180, 168), (120, 110, 100), max(0, (y - (Float(pc.1) + 0.5) * 22 - jy) / pr * 0.5 + 0.4)) }
        }
        return c
    }

    // paint background, 2x2 supersampled, with the squircle mask and drop shadow
    var px = [UInt32](repeating: 0, count: N * N)
    for y in 0..<N {
        for x in 0..<N {
            var r: Float = 0, g: Float = 0, b: Float = 0, a: Float = 0
            for (ox, oy) in [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)] as [(Float, Float)] {
                let fx = Float(x) + ox, fy = Float(y) + oy
                if sq(fx, fy) <= 1 {
                    let c = scene(fx, fy)
                    r += c.0; g += c.1; b += c.2; a += 1
                }
            }
            if a > 0 {
                px[y * N + x] = rgba(Int(r / a), Int(g / a), Int(b / a), Int(a / 4 * 255))
                if a < 4 {   // blend edge over shadow
                    let s = (1 - a / 4) * 0.3
                    px[y * N + x] = rgba(Int(r / a * a / 4), Int(g / a * a / 4), Int(b / a * a / 4), Int((a / 4 + s) * 255))
                }
            } else {
                let d = sq(Float(x), Float(y) - 12)
                let sh = max(0, 1 - (d - 1) * 14) * 0.35
                if sh > 0 { px[y * N + x] = rgba(0, 0, 0, Int(sh * 255)) }
            }
        }
    }

    // the hero hog
    var p = Pose()
    p.bh = SIMD2(2.2, 3.2)
    p.fh = SIMD2(11.4, 10.6)
    p.mouth = true
    p.hat = .hardhat
    let HS = 600
    let hog = renderHog(p, size: HS)
    let ox = 450 - HS / 2, oy = 806 - Int(Float(HS) * 14.5 / 16)
    // contact shadow
    for y in 780..<830 { for x in 300..<640 {
        let d = hypot(Float(x - 470) / 150, Float(y - 806) / 16)
        if d < 1 && px[y * N + x] != 0 { px[y * N + x] = mixC(px[y * N + x], rgba(20, 40, 10), (1 - d) * 0.45) }
    } }
    for j in 0..<HS {
        for i in 0..<HS {
            let c = hog[j * HS + i]
            let al = Float(c >> 24) / 255
            if al <= 0 { continue }
            let X = ox + i, Y = oy + j
            guard X >= 0, X < N, Y >= 0, Y < N, sq(Float(X), Float(Y)) < 0.985 else { continue }
            px[Y * N + X] = mixC(px[Y * N + X], c | 0xFF00_0000, al)
        }
    }
    writePNG(bytes: pixelsToBytes(px), w: N, h: N, path: path, bgra: false)
}

func parseRules(_ args: [String]) -> [SimRule] {
    var rules: [SimRule] = []
    var i = 0
    while i < args.count {
        if args[i] == "--do", i + 1 < args.count {
            let parts = args[i + 1].split(separator: "@").map(String.init)
            if let s = Skill.named(parts[0]) {
                var r = SimRule(skill: s)
                for p in parts.dropFirst() {
                    let v = Int(p.dropFirst())
                    switch p.first {
                    case "x": r.x = v
                    case "t": r.t = v
                    case "d": r.dir = v
                    case "n": r.times = v ?? 1
                    case "h": r.hog = v
                    case "s": r.saved = v
                    default: break
                    }
                }
                rules.append(r)
            }
            i += 1
        }
        i += 1
    }
    return rules
}

func applyRules(_ g: Game, _ rules: inout [SimRule]) {
    for i in rules.indices where rules[i].times > 0 {
        let r = rules[i]
        if let t = r.t, g.tick < t { continue }
        if let s = r.saved, g.saved < s { continue }
        for h in g.hogs where g.canAssign(r.skill, h) {
            if let x = r.x, h.x != x { continue }
            if let d = r.dir, h.dir != d { continue }
            if let id = r.hog, h.id != id { continue }
            if g.assign(r.skill, h) { rules[i].times -= 1; break }
        }
    }
}

func simulate(_ g: Game, level: Int, ticks: Int?, rules: [SimRule], headless: Bool = true) {
    var rules = rules
    g.headless = headless
    g.loadLevel(level)
    g.screen = .playing
    g.playTime = 10
    let limit = ticks ?? (g.level.minutes * 60 * 30 + 10)
    for _ in 0..<limit {
        applyRules(g, &rules)
        g.step()
        if g.screen != .playing { break }
    }
}

func runSim(_ args: [String], value: (String) -> String?) {
    let lv = Int(value("--level") ?? "1") ?? 1
    let g = Game()
    var rules = parseRules(args)
    if rules.isEmpty { rules = levels[lv - 1].solution }
    simulate(g, level: lv - 1, ticks: value("--ticks").flatMap { Int($0) }, rules: rules)
    var hist: [String: Int] = [:]
    for h in g.hogs { hist["\(h.state)", default: 0] += 1 }
    print("level \(lv) '\(g.level.name)': tick \(g.tick) spawned \(g.spawned) saved \(g.saved) (\(g.savedPercent)% need \(g.level.need)%) width \(g.level.width)")
    print("  states: \(hist.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
    print("  skills left: \(g.skills)")
}

func runVerify(_ value: (String) -> String?) {
    let from = Int(value("--from") ?? "1") ?? 1
    let to = Int(value("--to") ?? "\(levels.count)") ?? levels.count
    var fails = 0
    for i in (from - 1)..<min(to, levels.count) {
        let l = levels[i]
        if l.solution.isEmpty { continue }
        let g = Game()
        simulate(g, level: i, ticks: nil, rules: l.solution)
        let ok = g.savedPercent >= l.need
        if !ok { fails += 1 }
        var hist: [String: Int] = [:]
        for h in g.hogs { hist["\(h.state)", default: 0] += 1 }
        let left = g.timeLeft / 30
        print(String(format: "%@ %3d %-28@ saved %3d%% need %2d%%  hogs %2d  w %4d  timeLeft %3ds  %@",
                     ok ? "ok  " : "FAIL", i + 1, l.name as NSString, g.savedPercent, l.need, l.count, l.width, left,
                     hist.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ") as NSString))
    }
    print("\(fails) failing level(s)")
}

func runSnapshot(_ path: String, _ args: [String], value: (String) -> String?) {
    guard let dev = MTLCreateSystemDefaultDevice(), let r = Renderer(device: dev, pixelFormat: .bgra8Unorm) else {
        print("no metal"); return
    }
    let g = Game()
    let lv = Int(value("--level") ?? "1") ?? 1
    let ticks = Int(value("--ticks") ?? "300") ?? 300
    g.time = Double(ticks) / 30 + 3
    switch value("--screen") ?? "play" {
    case "title": g.screen = .title; g.update(dt: 0.5)
    case "splash":
        g.screen = .splash
        let target = Double(value("--t") ?? "5") ?? 5
        while g.screenTime < target { g.time += 1.0 / 30; g.screenTime += 1.0 / 30; g.updateSplash(1.0 / 30) }
        let r2 = Renderer(device: dev, pixelFormat: .bgra8Unorm)!
        _ = r2.snapshot(game: g, width: 640, height: 400)   // lay out letters once so sparks know positions
    case "select": g.unlocked = Int(value("--unlocked") ?? "30") ?? 30; g.screen = .levelSelect; g.update(dt: 0.5)
    case "briefing": g.loadLevel(lv - 1); g.screen = .briefing
    default:
        var rules = parseRules(args)
        if rules.isEmpty && args.contains("--solution") { rules = levels[lv - 1].solution }
        simulate(g, level: lv - 1, ticks: ticks, rules: rules, headless: false)
        if value("--screen") == "results" { g.screen = .playing; g.finishLevelForSnapshot() ; g.screenTime = 3 } else { g.screen = .playing }
        g.playTime = 10
        // regenerate a few particles for flavour
        if let cx = value("--cam"), let c = Float(cx) { g.camX = c; g.clampCam() } else {
            if let lead = g.hogs.first(where: { $0.alive }) { g.camX = Float(lead.x) - 320; g.clampCam() }
        }
        if let mx = value("--mouse") {
            let p = mx.split(separator: ",").compactMap { Float($0) }
            if p.count == 2 { g.mouse = SIMD2(p[0], p[1]); g.hovered = g.hogAt(p[0] + floor(g.camX), p[1]) }
        }
    }
    if g.screen != .results && g.screen != .splash { g.screenTime = 5 }
    let size = (value("--size") ?? "1280x720").split(separator: "x").compactMap { Int($0) }
    let w = size.count == 2 ? size[0] : 1280, h = size.count == 2 ? size[1] : 720
    if let bytes = r.snapshot(game: g, width: w, height: h) {
        writePNG(bytes: bytes, w: w, h: h, path: path, bgra: true)
        print("wrote \(path)")
    }
}

extension Game {
    func finishLevelForSnapshot() {
        let pct = saved * 100 / max(1, level.count)
        success = pct >= level.need
        newBest = true
        screen = .results
    }
}
