import Foundation
import simd

func wrapText(_ s: String, _ maxChars: Int) -> [String] {
    var lines: [String] = []
    var cur = ""
    for word in s.split(separator: " ") {
        if cur.isEmpty { cur = String(word) } else if cur.count + 1 + word.count <= maxChars { cur += " " + word } else {
            lines.append(cur); cur = String(word)
        }
    }
    if !cur.isEmpty { lines.append(cur) }
    return lines
}

func starsFor(_ pct: Int, _ need: Int) -> Int {
    if pct < 0 || pct < need { return 0 }
    if pct >= 100 { return 3 }
    return pct >= (need + 100) / 2 ? 2 : 1
}

let INK = C(70, 44, 24)

func smoothstepF(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
    let k = max(0, min(1, (x - e0) / (e1 - e0)))
    return k * k * (3 - 2 * k)
}
func backOut(_ k: Float) -> Float { let c: Float = 1.9; let q = k - 1; return 1 + (c + 1) * q * q * q + c * q * q }
func bounceOut(_ x: Float) -> Float {
    let n: Float = 7.5625, d: Float = 2.75
    if x < 1 / d { return n * x * x }
    if x < 2 / d { let y = x - 1.5 / d; return n * y * y + 0.75 }
    if x < 2.5 / d { let y = x - 2.25 / d; return n * y * y + 0.9375 }
    let y = x - 2.625 / d; return n * y * y + 0.984375
}

extension Game {
    var top: Float { -Renderer.originY }

    func draw(_ r: Renderer) {
        switch screen {
        case .splash: drawSplash(r)
        case .title: drawTitle(r)
        case .levelSelect: drawSelect(r)
        case .briefing: drawBriefing(r)
        case .playing: drawWorld(r); drawPanel(r); drawPlayOverlays(r)
        case .results: drawWorld(r); drawPanel(r); drawResults(r)
        }
        drawIris(r)
    }

    /// Circular iris-wipe that opens on every new screen.
    func drawIris(_ r: Renderer) {
        let d: Double = 0.55
        guard screenTime < d && screen != .results && screen != .splash && fromSplashDelay == 0 else { return }
        r.layer = r.ui
        let k = Float(screenTime / d)
        let e = k * k * (3 - 2 * k)
        let cx: Float = 320, cy: Float = (top + 360) / 2
        let rad = max(1, e * 420)
        let x0 = cx - rad, x1 = cx + rad, y0 = cy - rad, y1 = cy + rad
        let ink = C(8, 5, 4)
        r.spriteRect(r.atlas.hole, x0, y0, rad * 2, rad * 2)
        r.rect(-10, top - 10, x0 + 10, 380 - top, ink)
        r.rect(x1, top - 10, 660 - x1, 380 - top, ink)
        r.rect(x0, top - 10, x1 - x0, y0 - top + 10, ink)
        r.rect(x0, y1, x1 - x0, 380 - y1, ink)
    }

    func setTheme(_ r: Renderer, _ th: Theme, cam: Float) {
        var g = r.globals
        g.skyTop = th.skyTop; g.skyBottom = th.skyBottom
        g.hillA = th.hillA; g.hillB = th.hillB
        g.params = SIMD4(Float(th.id), th.night ? 1 : 0, th.snow ? 1 : 0, 0)
        g.time = Float(time.truncatingRemainder(dividingBy: 3600))
        g.camX = cam
        g.worldSize = SIMD2(Float(terrain.w), Float(terrain.h))
        g.waterColor = th.water
        func c3(_ c: (Int, Int, Int)) -> SIMD4<Float> { SIMD4(Float(c.0) / 255, Float(c.1) / 255, Float(c.2) / 255, 1) }
        g.dirtA = c3(th.dirtA); g.dirtB = c3(th.dirtB); g.grass = c3(th.grass)
        switch th.id {
        case 1: g.ambient = SIMD4(0.98, 1.0, 1.05, 0.45); g.counts.z = 1; g.counts.w = 0.38
        case 2: g.ambient = SIMD4(1.03, 0.97, 0.92, 0.5); g.counts.z = 2; g.counts.w = 0.1
        case 3: g.ambient = SIMD4(0.44, 0.5, 0.74, 0.6); g.counts.z = 4; g.counts.w = 0.22
        default: g.ambient = SIMD4(1, 1, 1, 0.42); g.counts.z = 3; g.counts.w = 0.05
        }
        r.globals = g
    }

    var lightScale: Float { level.theme.night ? 1 : 0.35 }

    // MARK: world

    func drawWorld(_ r: Renderer) {
        r.layer = r.world
        setTheme(r, level.theme, cam: camX)
        r.syncTerrain(terrain)
        let sh: Float = shake > 0 ? Float.random(in: -shake...shake) : 0
        let cx = camX + sh
        let a = r.atlas
        let ls = lightScale

        // hog crate hanging from the sky, with a lantern
        let ex = Float(level.entrance.x) - cx, ey = Float(level.entrance.y)
        r.rect(ex - 12, top, 1, ey - 23 - top, C(110, 78, 44))
        r.rect(ex + 11, top, 1, ey - 23 - top, C(110, 78, 44))
        r.sprite(tick > 25 || screen != .playing ? a.crateOpen : a.crateClosed, ex - 16, ey - 24)
        let swing = sin(Float(time) * 1.6) * 1.5
        r.sprite(a.lantern, ex + 16 + swing, ey - 22, scale: 1)
        r.addLight(ex + 19 + swing, ey - 17, 70, C(255, 200, 120), 0.9 * ls)

        r.terrainQuad(terrain, -cx, 0, Float(terrain.w), Float(terrain.h))

        // the burrow
        let bx = Float(exitX) - cx, by = Float(exitY)
        r.sprite(a.burrow, bx - 24, by - 36)
        r.sprite(a.flags[Int(time * 5) % 2], bx - 24 + 11, by - 36 + 3)
        r.addLight(bx - 12, by - 12, 50, C(255, 200, 110), 0.9 * ls)
        r.addLight(bx + 1, by - 4, 34, C(255, 170, 90), 0.8 * ls)
        r.glow(bx - 12, by - 12, 8, C(255, 210, 120, 0.5))

        // hogs (shadows first)
        for h in hogs where h.alive && (h.state == .walking || h.state == .blocking || h.state == .building || h.state == .bashing || h.state == .shrugging) {
            r.spriteRect(a.puff, Float(h.x) - cx - 7, Float(h.y) - 1, 14, 3.5, color: RGBA(0, 0, 0, 0.32))
        }
        for h in hogs where h.alive { drawHog(r, h, cx) }

        // water regions are rendered in the composite pass
        for w in level.water { r.waters.append(SIMD4(Float(w.x0), Float(w.x1), Float(w.top), 0)) }

        drawParticles(r, cx)

        // lamp lights
        for h in hogs where h.alive {
            if h.state == .mining && level.theme.night {
                r.addLight(Float(h.x) - cx + Float(h.dir) * 6, Float(h.y) - 10, 46, C(255, 240, 180), 0.7)
            }
            if h.fuse > 0 && h.state != .ohno {
                r.glow(Float(h.x) - cx, Float(h.y) - 20, 6, RGBA(1, 0.6, 0.2, 0.5 + 0.3 * sin(Float(time) * 12)))
            }
        }

        // speech bubbles (skip ones that would overlap an earlier bubble)
        var placed: [(Float, Float, Float)] = []
        for h in hogs where h.alive {
            guard let q = h.quip else { continue }
            let tw = r.textWidth(q, scale: 0.75)
            let w = tw + 10
            let bxx = max(2, min(638 - w, Float(h.x) - cx - w / 2))
            let byy = max(top + 2, Float(h.y) - 34)
            if placed.contains(where: { abs($0.1 - byy) < 15 && bxx < $0.0 + $0.2 + 2 && $0.0 < bxx + w + 2 }) { continue }
            placed.append((bxx, byy, w))
            let alpha = min(1, Float(h.quipT) / 10)
            r.nine(a.bubble, bxx, byy, w, 13, b: 8, color: RGBA(1, 1, 1, alpha))
            let tx = max(bxx + 4, min(bxx + w - 6, Float(h.x) - cx))
            r.rect(tx - 1, byy + 12.5, 3, 1.2, C(255, 252, 242, alpha))
            r.rect(tx - 0.5, byy + 13.5, 1.5, 1.5, C(60, 44, 30, alpha))
            r.text(q, bxx + 5, byy + 3.2, scale: 0.75, color: C(60, 40, 24, alpha), shadow: nil)
        }

        // hover marker
        if screen == .playing, let h = hovered {
            let hx = Float(h.x) - cx, hy = Float(h.y) - 7
            let ok = canAssign(Skill(rawValue: selected)!, h) && skills[selected] > 0
            let c = ok ? C(255, 245, 190) : C(255, 120, 100)
            let s: Float = 10 + sin(Float(time) * 8) * 0.8
            for (sx, sy) in [(-1, -1), (1, -1), (-1, 1), (1, 1)] as [(Float, Float)] {
                r.rect(hx + sx * s - (sx > 0 ? 3 : 0), hy + sy * s - (sy > 0 ? 1 : 0), 3, 1, c)
                r.rect(hx + sx * s - (sx > 0 ? 1 : 0), hy + sy * s - (sy > 0 ? 3 : 0), 1, 3, c)
            }
            r.glow(hx, hy, 14, c * RGBA(1, 1, 1, 0.18))
        }
    }

    func drawParticles(_ r: Renderer, _ cx: Float) {
        let a = r.atlas
        for p in particles {
            let px = p.x - cx, py = p.y
            let k = max(0, p.life / p.maxLife)
            switch p.kind {
            case .dot:
                var c = p.color; c.w *= min(1, k * 2)
                r.rect(px, py, p.size, p.size, c)
            case .smoke:
                var c = p.color; c.w *= k
                r.spriteRect(a.puff, px - p.size, py - p.size, p.size * 2, p.size * 2, color: c)
            case .ghost:
                r.sprite(a.ghost, px - 8 + sin(p.life * 0.15) * 2, py - 8, color: RGBA(1, 1, 1, min(1, k * 1.5)), smooth: true)
                r.glow(px, py - 6, 10, RGBA(0.6, 0.7, 1, 0.25 * k))
            case .text:
                var c = p.color; c.w = min(1, k * 2)
                r.text(p.text, px, py, scale: 0.9, color: c, align: .center, shadow: nil, outline: RGBA(0.2, 0.1, 0.05, c.w))
            case .star, .spark:
                var c = p.color; c.w = k
                r.glow(px, py, p.size, c * RGBA(1.6, 1.6, 1.6, 1))
            case .rock:
                var c = p.color; c.w = min(1, k * 3)
                r.spriteRot(a.rock, px, py, scale: p.size, angle: p.rot, color: c)
            case .ring:
                let rad = p.size * (1.15 - k)
                r.spriteRect(a.ring, px - rad, py - rad, rad * 2, rad * 2, color: RGBA(1.4, 1.2, 1.0, k * 0.9), blend: .add)
            case .fire:
                r.glow(px, py, p.size, RGBA(1.6, 0.9 * k + 0.3, 0.25 * k, k * 0.9))
            case .confetti:
                var c = p.color; c.w = min(1, k * 3)
                r.rectRot(px, py, 2.2, 1.3 * abs(cos(p.rot * 2)) + 0.3, p.rot, c)
            case .flash:
                r.glow(px, py, p.size * (1.2 - k * 0.4), RGBA(1.5, 1.2, 0.8, k))
                r.addLight(px, py, p.size * 2.2, p.color, 2.2 * k)
            }
        }

    }

    func drawHog(_ r: Renderer, _ h: Hog, _ cx: Float) {
        let a = r.atlas
        var f: Region
        var oy: Float = 0, ox: Float = 0
        var alpha: Float = 1
        let t = h.t
        switch h.state {
        case .walking:
            let blink = (tick / 5 + h.id * 13) % 37 == 0
            f = a.frame(blink ? "walkb" : "walk", tick / 2 + h.id)
        case .falling: f = h.umbrella ? a.frame("float", t / 8) : a.frame("fall", t / 3)
        case .climbing: f = a.frame("climb", t / 4); ox = -Float(h.dir) * 2
        case .digging: f = a.frame("dig", t / 3)
        case .bashing: f = a.frame("bash", t / 2)
        case .mining: f = a.frame("mine", t + 2)
        case .building: f = a.frame("build", t / 6)
        case .shrugging: f = a.frame("shrug", t / 8)
        case .blocking: f = a.frame("block", t / 20)
        case .ohno: f = a.frame("ohno", t / 2)
        case .splatting:
            f = a.frame("splat", 0)
            alpha = t > 16 ? Float(26 - t) / 10 : 1
        case .drowning: f = a.frame("drown", t / 4); oy = Float(t) / 3
        case .exiting:
            f = a.frame("exit", t / 3)
            alpha = t > 10 ? max(0, Float(18 - t) / 8) : 1
        case .dead, .saved: return
        }
        let sx = Float(h.x) - 8 - cx + ox, sy = Float(h.y) - 14 + oy
        if sx < -20 || sx > 660 { return }
        r.sprite(f, sx, sy, flip: h.dir < 0, color: RGBA(1, 1, 1, alpha), smooth: true)
        if h.state == .falling && h.umbrella {
            let hand: Float = h.dir > 0 ? 12.8 : 3.2
            r.sprite(a.umbrella, sx + hand - 8, sy - 6)
        }
        if h.fuse > 0 && h.state != .ohno {
            r.text("\(h.fuse / 30 + 1)", Float(h.x) - cx, sy - 10, scale: 0.9, color: C(255, 236, 110), align: .center,
                   shadow: nil, outline: C(80, 30, 10))
        }
    }

    // MARK: HUD

    func skillIcon(_ r: Renderer, _ s: Skill, _ x: Float, _ y: Float, _ scale: Float, _ c: RGBA) {
        let a = r.atlas
        switch s {
        case .climber: r.sprite(a.frame("climb", 0), x, y, scale: scale, color: c, smooth: true)
        case .floater: r.sprite(a.umbrella, x, y + 3 * scale, scale: scale, color: c, smooth: true)
        case .bomber: r.sprite(a.bomb, x, y, scale: scale, color: c, smooth: true)
        case .blocker: r.sprite(a.frame("block", 0), x, y, scale: scale, color: c, smooth: true)
        case .builder: r.sprite(a.frame("build", 0), x, y, scale: scale, color: c, smooth: true)
        case .basher: r.sprite(a.frame("bash", 2), x, y, scale: scale, color: c, smooth: true)
        case .miner: r.sprite(a.frame("mine", 2), x, y, scale: scale, color: c, smooth: true)
        case .digger: r.sprite(a.frame("dig", 0), x, y, scale: scale, color: c, smooth: true)
        }
    }

    func button(_ r: Renderer, _ x: Float, _ y: Float, _ w: Float, _ h: Float, lit: Bool, hot: Bool) {
        let a = r.atlas
        r.nine(lit ? a.buttonSel : (hot ? a.buttonHot : a.button), x, y, w, h, b: 10)
    }

    func stateName(_ h: Hog) -> String {
        switch h.state {
        case .walking: return "Waddler"
        case .falling: return h.umbrella ? "Brolly" : "Faller"
        case .climbing: return "Scrambler"
        case .digging: return "Digger"
        case .bashing: return "Puncher"
        case .mining: return "Pickaxe"
        case .building, .shrugging: return "Stacker"
        case .blocking: return "Bouncer"
        case .ohno: return "Kaboom"
        case .splatting, .drowning, .dead: return "Gone"
        case .exiting, .saved: return "Home"
        }
    }

    func drawPanel(_ r: Renderer) {
        r.layer = r.ui
        let a = r.atlas
        r.nine(a.panel, -4, 299, 648, 70, b: 14)
        r.rect(0, 299, 640, 1, C(30, 18, 10))

        var label = ""
        if let h = hovered {
            var extra: [String] = []
            if h.climber { extra.append("scrambler") }
            if h.floater { extra.append("brolly") }
            label = "\(h.name) · \(stateName(h))" + (extra.isEmpty ? "" : " (" + extra.joined(separator: ", ") + ")")
        } else if let b = buttonAt(mouse) {
            switch b {
            case 0: label = "Release rate down"
            case 1: label = "Release rate up"
            case 2...9: let s = Skill(rawValue: b - 2)!; label = "\(s.title): \(s.blurb)  [\(b - 1)]"
            case 10: label = "Pause  [P]"
            case 11: label = "Nuke: early spring  [N twice]"
            case 12: label = "Fast forward  [F]"
            default: break
            }
        }
        r.text(label, 6, 302.5, scale: 0.85, color: C(255, 230, 170))
        r.text("Out \(aliveCount)", 262, 302.5, scale: 0.85, color: C(170, 240, 130))
        r.text("Home \(savedPercent)%", 318, 302.5, scale: 0.85, color: savedPercent >= level.need ? C(170, 240, 130) : WHITE)
        r.text("Need \(level.need)%", 388, 302.5, scale: 0.85, color: C(240, 220, 190))
        let secs = timeLeft / 30
        r.text(String(format: "%d:%02d", secs / 60, secs % 60), 458, 302.5, scale: 0.85, color: secs < 30 ? C(255, 120, 100) : C(240, 220, 190))
        r.text("Level \(levelIndex + 1)", 634, 302.5, scale: 0.85, color: C(220, 190, 150), align: .right)

        let hotB = buttonAt(mouse)
        for i in 0..<13 {
            let b = buttonRect(i)
            let lit: Bool
            switch i {
            case 2...9: lit = selected == i - 2
            case 10: lit = paused
            case 11: lit = nuking || (time - nukeArm < 1.2 && Int(time * 8) % 2 == 0)
            case 12: lit = fast
            default: lit = heldButton == i
            }
            let bounce: Float = (lit && i >= 2 && i <= 9) ? -1 : 0
            button(r, b.x, b.y + bounce, b.w, b.h, lit: lit, hot: hotB == i)
            let mx = b.x + b.w / 2
            let ink = lit ? C(70, 36, 10) : C(255, 240, 210)
            switch i {
            case 0:
                r.text("\(minRate)", mx, b.y + 4, scale: 0.8, color: ink, align: .center, shadow: nil)
                r.text("−", mx, b.y + 17, scale: 2, color: ink, align: .center, shadow: nil)
            case 1:
                r.text("\(rate)", mx, b.y + 4, scale: 0.8, color: ink, align: .center, shadow: nil)
                r.text("+", mx, b.y + 17, scale: 2, color: ink, align: .center, shadow: nil)
            case 2...9:
                let s = Skill(rawValue: i - 2)!
                let n = skills[s.rawValue]
                r.text(n > 0 ? "\(n)" : "–", mx, b.y + 3.5 + bounce, scale: 0.85, color: n > 0 ? ink : C(160, 130, 100), align: .center, shadow: nil)
                skillIcon(r, s, b.x + 3, b.y + 14 + bounce, 1.6, n > 0 ? WHITE : RGBA(1, 1, 1, 0.35))
            case 10:
                r.rect(mx - 6, b.y + 13, 4, 17, ink)
                r.rect(mx + 2, b.y + 13, 4, 17, ink)
            case 11:
                r.sprite(a.bomb, b.x + 3, b.y + 8, scale: 1.6, smooth: true)
            case 12:
                r.text("»", mx, b.y + 12, scale: 2.2, color: ink, align: .center, shadow: nil)
            default: break
            }
        }

        // minimap
        let m = minimapRect()
        r.rect(450, 311, 188, 46, C(24, 16, 10))
        r.rect(m.x, m.y, m.w, m.h, level.theme.skyBottom * RGBA(0.55, 0.6, 0.7, 1))
        r.terrainQuad(terrain, m.x, m.y, m.w, m.h, flat: true)
        for w in level.water {
            r.rect(m.x + Float(w.x0) * m.s, m.y + Float(w.top) * m.s, Float(w.x1 - w.x0) * m.s, Float(300 - w.top) * m.s, level.theme.water)
        }
        r.rect(m.x + Float(exitX) * m.s - 1.5, m.y + Float(exitY) * m.s - 3, 3, 3, C(255, 80, 80))
        for h in hogs where h.active {
            r.rect(m.x + Float(h.x) * m.s - 0.5, m.y + Float(h.y) * m.s - 1, 1.2, 1.2, C(255, 236, 90))
        }
        r.box(m.x + camX * m.s, m.y, 640 * m.s, m.h, C(255, 255, 255, 0.85), 0.7)
    }

    func drawPlayOverlays(_ r: Renderer) {
        r.layer = r.ui
        if playTime < 2.4 {
            let k = Float(min(1, (2.4 - playTime) / 0.6))
            let pop = Float(min(1, playTime * 4))
            let s = 4.5 * (0.6 + 0.4 * pop) + sin(Float(playTime) * 10) * 0.08
            r.text("Let's dig!", 320, 104, scale: s, color: C(255, 214, 90, k), align: .center, shadow: RGBA(0, 0, 0, 0.4 * k), outline: C(90, 40, 10, k))
            r.text(level.name, 320, 152, scale: 1.6, color: RGBA(1, 1, 1, k), align: .center, outline: C(40, 30, 20, k * 0.8))
        }
        if paused {
            r.rect(0, top, 640, 300 - top, RGBA(0, 0, 0.1, 0.35))
            r.text("Paused", 320, 110, scale: 4, color: C(255, 236, 190), align: .center, outline: C(60, 30, 10))
            r.text("The hogs are hibernating. Press P to wake them.", 320, 156, scale: 1.1, color: C(240, 230, 210), align: .center)
        }
        if !nuking && time - nukeArm < 1.2 {
            r.text("Press nuke again for an early spring. (Everyone explodes.)", 320, 280, scale: 1, color: C(255, 150, 120), align: .center, outline: C(60, 10, 0))
        }
    }

    // MARK: screens

    func drawBackdrop(_ r: Renderer, _ th: Theme, groundY: Float = 292, hogFirst: Bool = false) {
        r.layer = r.world
        setTheme(r, th, cam: Float(time) * 14)
        r.globals.worldSize = SIMD2(640, 300)
        let gy = groundY
        r.rect(0, gy + 4, 640, 360 - gy, C(Float(th.dirtA.0), Float(th.dirtA.1), Float(th.dirtA.2)))
        for i in 0..<5 {
            let y = gy + 14 + Float(i) * 13
            r.rect(0, y, 640, 6, C(Float(th.dirtB.0), Float(th.dirtB.1), Float(th.dirtB.2), 0.6))
        }
        r.rect(0, gy, 640, 6, C(Float(th.grass.0), Float(th.grass.1), Float(th.grass.2)))
        for x in stride(from: 0, to: 640, by: 2) {
            let h = 1 + Float(Int(rnd01(x, 9) * 4)) + sin(Float(time) * 1.7 + Float(x) * 0.09) * 0.4
            r.rect(Float(x), gy - h + 1, 1, h, C(Float(th.grass.0) * 0.8, Float(th.grass.1) * 0.8, Float(th.grass.2) * 0.8))
        }
        for i in 0..<50 {
            r.rect(Float(Int(rnd01(i, 4) * 640)), gy + 10 + Float(Int(rnd01(i, 5) * 60)), 2, 1.5, C(80, 54, 34, 0.6))
        }
    }

    // MARK: shared home scene (splash + title)

    static let logoScale: Float = 7.2
    var logoY: Float { top * 0.5 + 28 }
    var subtitleY: Float { logoY + 74 }
    static let footerY: Float = 334
    static let heroLines = ["Is it spring yet?!", "Let's dig!", "Pick a burrow!", "Six more weeks? Nope!", "Carrots, anyone?"]

    /// Sky, hills, ground, the burrow, wandering hogs, a brolly hog and the hero hog at its hole.
    /// `day` 0...1 drives the sunrise, `pop` 0...1 how far the hero is out of the hole.
    func drawHomeScene(_ r: Renderer, day: Float, pop: Float, waving: Bool, extras: Float) {
        let a = r.atlas
        let dawn = 1 - abs(day * 2 - 1)
        var th = Theme.spring
        let nightTop = C(10, 12, 40), nightBot = C(40, 30, 70), dawnBot = C(255, 170, 120)
        th.skyTop = nightTop + (Theme.spring.skyTop - nightTop) * day
        th.skyBottom = (nightBot + (Theme.spring.skyBottom - nightBot) * day) * (1 - dawn) + dawnBot * dawn

        // hero first so the ground strip hides it while it is still underground
        let gy: Float = 292
        let hogH: Float = 64
        let hogTop = gy - hogH * 14.5 / 16 + (1 - pop) * (hogH + 6)
        r.layer = r.world
        r.sprite(a.splashHog[waving ? Int(time * 4) % 2 : 0], 320 - hogH / 2, hogTop, scale: 4, smooth: true)
        drawBackdrop(r, th, hogFirst: true)
        r.globals.params.w = (1 - backOut(smoothstepF(0.0, 1.0, day))) * 190
        let amb = 0.4 + 0.6 * day
        r.globals.ambient = SIMD4(amb + dawn * 0.15, amb, amb + (1 - day) * 0.25, 0.6)

        // hole with a dirt rim
        r.spriteRect(a.puff, 320 - 36, gy - 1, 72, 11, color: C(120, 78, 44))
        r.spriteRect(a.puff, 320 - 26, gy + 1, 52, 7, color: RGBA(0.04, 0.025, 0.02, 0.95))

        // the burrow on the right, hogs wandering, a brolly hog drifting down
        if extras > 0 {
            let ea = RGBA(1, 1, 1, extras)
            r.sprite(a.burrow, 548, gy - 36, color: ea)
            r.sprite(a.flags[Int(time * 5) % 2], 548 + 11, gy - 36 + 3, color: ea)
            r.addLight(560, gy - 12, 50, C(255, 200, 110), 0.5 * extras)
            for h in titleHogs where abs(h.x - 320) > 44 {
                let f = a.frame("walk", Int(time * 15 + Double(h.phase) * 7))
                r.spriteRect(a.puff, floor(h.x) - 7, gy - 1, 14, 3.5, color: RGBA(0, 0, 0, 0.3 * extras))
                r.sprite(f, floor(h.x) - 8, gy - 14, flip: h.dir < 0, color: ea, smooth: true)
            }
            r.sprite(a.frame("float", Int(time * 4)), skyHogX - 8, skyHogY - 14, color: ea, smooth: true)
            r.sprite(a.umbrella, skyHogX - 8 + 12.8 - 8, skyHogY - 20, color: ea, smooth: true)
        }
        if pop > 0 {
            r.spriteRect(a.puff, 320 - 18, gy - 1.5, 36, 5, color: RGBA(0, 0, 0, 0.35 * pop))
        }
        drawParticles(r, 0)
        r.addLight(320, gy - 30, 120, C(255, 220, 160), 0.6 * (1 - day))
    }

    /// The GroundhogZ logo: drop shadow, thick outline, two-tone bevelled letters, idle bob and a periodic shine.
    func drawLogo(_ r: Renderer, appear: (Int) -> Float) {
        r.layer = r.ui
        let letters = Game.splashLetters
        let scale = Game.logoScale
        let em = 10 * scale
        let widths = letters.map { r.textWidth(String($0), scale: scale) }
        var x = 320 - widths.reduce(0, +) / 2
        splashLogoY = logoY
        splashLetterX = []
        for (i, ch) in letters.enumerated() {
            let k = appear(i)
            splashLetterX.append(x + widths[i] / 2)
            if k > 0 {
                let bob: Float = k >= 1 ? sin(Float(time) * 2.6 + Float(i) * 0.65) * 2.4 : 0
                let y = logoY - (1 - bounceOut(min(1, k))) * 170 + bob
                let base = i % 2 == 0 ? C(255, 204, 72) : C(255, 146, 46)
                let hi = i % 2 == 0 ? C(255, 246, 196) : C(255, 212, 140)
                let s = String(ch)
                r.text(s, x + em * 0.05, y + em * 0.1, scale: scale, color: RGBA(0.12, 0.05, 0, 0.45), shadow: nil)
                r.text(s, x, y, scale: scale, color: C(86, 38, 12), shadow: nil, outline: C(86, 38, 12))
                r.text(s, x, y - em * 0.04, scale: scale, color: hi, shadow: nil)
                r.text(s, x, y + em * 0.025, scale: scale, color: base, shadow: nil)
            }
            x += widths[i]
        }
        let phase = Float(time.truncatingRemainder(dividingBy: 4.5))
        let x0 = 320 - widths.reduce(0, +) / 2 + 20, x1 = 320 + widths.reduce(0, +) / 2 - 20
        if appear(letters.count - 1) >= 1 && phase < 1.4 {
            let sx = x0 + phase / 1.4 * (x1 - x0)
            let fade = min(1, phase * 5, (1.4 - phase) * 5)
            r.spriteRect(r.atlas.glow, sx - 22, logoY - 6, 44, 66, color: RGBA(1, 0.95, 0.75, 0.32 * fade), blend: .add)
        }
    }

    func drawSubtitle(_ r: Renderer, _ alpha: Float) {
        guard alpha > 0 else { return }
        r.layer = r.ui
        r.text("A fairly irresponsible rodent rescue simulator", 320, subtitleY, scale: 1.35, color: RGBA(1, 1, 1, alpha),
               align: .center, shadow: RGBA(0, 0, 0, 0.3 * alpha), outline: C(40, 50, 90, 0.85 * alpha))
    }

    func drawFooter(_ r: Renderer, _ text: String, _ alpha: Float) {
        guard alpha > 0 else { return }
        r.layer = r.ui
        r.text(text, 320, Game.footerY, scale: 1.1, color: C(255, 242, 210, alpha), align: .center,
               shadow: RGBA(0, 0, 0, 0.3 * alpha), outline: C(70, 40, 20, 0.8 * alpha))
    }

    func drawBubble(_ r: Renderer, _ text: String, _ x: Float, _ y: Float, _ alpha: Float) {
        guard alpha > 0 else { return }
        r.layer = r.ui
        let w = r.textWidth(text, scale: 1) + 14
        r.nine(r.atlas.bubble, x, y, w, 17, b: 8, color: RGBA(1, 1, 1, alpha))
        r.rect(x + 6, y + 16, 4, 1.5, C(255, 252, 242, alpha))
        r.rect(x + 6.5, y + 17.5, 2, 1.5, C(60, 44, 30, alpha))
        r.text(text, x + 7, y + 4.5, scale: 1, color: C(60, 40, 24, alpha), shadow: nil)
    }

    func heroBubble(_ r: Renderer, _ text: String, _ alpha: Float) {
        drawBubble(r, text, 350, 292 - 84, alpha)
    }

    func drawSplash(_ r: Renderer) {
        let t = Float(screenTime)
        let day = smoothstepF(0.1, 2.8, t)
        let pop = t < 1.2 ? 0 : backOut(min(1, (t - 1.2) / 0.55))
        drawHomeScene(r, day: day, pop: pop, waving: t > 2.0, extras: smoothstepF(3.8, 4.8, t))
        if t > 2.2 && t < 4.6 { heroBubble(r, Game.heroLines[0], min(1, (t - 2.2) * 6, (4.6 - t) * 4)) }
        drawLogo(r) { i in max(0, min(1, (t - Float(Game.splashLetterTime(i))) / 0.42)) }
        drawSubtitle(r, smoothstepF(3.6, 4.4, t))
        if t > 4.8 {
            let pulse = 0.6 + 0.4 * sin((t - 4.8) * 4)
            drawFooter(r, "Click or press any key", pulse * smoothstepF(4.8, 5.3, t))
        }
        if t < 0.8 { r.layer = r.ui; r.rect(-10, top - 10, 660, 400 - top, RGBA(0, 0, 0, 1 - t / 0.8)) }
    }

    func drawTitle(_ r: Renderer) {
        let a = r.atlas
        drawHomeScene(r, day: 1, pop: 1, waving: Int(time) % 6 < 3, extras: 1)
        let cycle = Int(time / 7)
        let ct = Float(time.truncatingRemainder(dividingBy: 7))
        if ct > 1 && ct < 4 { heroBubble(r, Game.heroLines[cycle % Game.heroLines.count], min(1, (ct - 1) * 6, (4 - ct) * 4)) }
        drawLogo(r) { _ in 1 }
        drawSubtitle(r, 1)

        // menu buttons fade/slide in (they are the only thing that differs from the splash)
        r.layer = r.ui
        let k = smoothstepF(0, 0.45, Float(screenTime))
        for (i, b) in titleButtons().enumerated() {
            let kk = smoothstepF(Float(i) * 0.12, Float(i) * 0.12 + 0.6, k * 1.4)
            if kk <= 0 { continue }
            let hot = inRect(mouse, (b.x, b.y, b.w, b.h))
            let dy = (1 - kk) * 14 - (hot ? 1 : 0)
            let isPlay = b.id == "play"
            r.nine(isPlay ? a.buttonSel : (hot ? a.buttonHot : a.button), b.x, b.y + dy, b.w, b.h, b: 10, color: RGBA(1, 1, 1, kk))
            let ink = isPlay ? C(70, 36, 10, kk) : C(255, 242, 210, kk)
            let sc: Float = isPlay ? 1.4 : 1.15
            r.text(b.label, b.x + b.w / 2, b.y + dy + b.h / 2 - 3.6 * sc, scale: sc, color: ink, align: .center, shadow: nil)
        }
        drawFooter(r, "\(levels.count) levels  ·  1-8 skills  ·  P pause  ·  F fast  ·  N nuke  ·  M music  ·  Esc quit", 1)
    }

    func drawSelect(_ r: Renderer) {
        let a = r.atlas
        let th = [Theme.spring, .autumn][page % 2]
        drawBackdrop(r, th)
        for h in titleHogs.prefix(5) {
            r.sprite(a.frame("walk", Int(time * 15 + Double(h.phase) * 7)), floor(h.x) - 8, 278, flip: h.dir < 0)
        }
        r.layer = r.ui
        r.nine(a.paper, 20, 18, 600, 262, b: 16)
        r.text("Choose a burrow", 320, 28, scale: 2, color: INK, align: .center, shadow: nil)
        r.text("Page \(page + 1) of \(pageCount)", 600, 34, scale: 0.9, color: INK * RGBA(1, 1, 1, 0.7), align: .right, shadow: nil)
        var hoverText = ""
        for i in (page * Game.perPage)..<min(levels.count, (page + 1) * Game.perPage) {
            let t = tileRect(i)
            let open = i < unlocked
            let hot = inRect(mouse, t)
            let st = starsFor(best[i], levels[i].need)
            button(r, t.x, t.y - (hot && open ? 1 : 0), t.w, t.h, lit: open && i == unlocked - 1, hot: hot && open)
            let yy = t.y - (hot && open ? 1 : 0)
            if open {
                let ink = i == unlocked - 1 ? C(70, 36, 10) : C(255, 240, 210)
                r.text("\(i + 1)", t.x + t.w / 2, yy + 5, scale: 1.25, color: ink, align: .center, shadow: nil)
                for s in 0..<3 {
                    r.sprite(a.star, t.x + t.w / 2 - 15 + Float(s) * 10, yy + 18.5, scale: 0.5,
                             color: s < st ? WHITE : RGBA(0, 0, 0, 0.25), smooth: true)
                }
            } else {
                r.sprite(a.lock, t.x + t.w / 2 - 6, yy + 7.5, scale: 1.5, color: RGBA(1, 1, 1, 0.75), smooth: true)
            }
            if hot {
                hoverText = open ? "\(i + 1). \(levels[i].name)" + (best[i] >= 0 ? "  —  best \(best[i])%" : "") : "Level \(i + 1) is still asleep."
            }
        }
        r.text(hoverText, 320, 264, scale: 1.05, color: INK, align: .center, shadow: nil)
        for b in selectButtons() {
            let hot = inRect(mouse, (b.x, b.y, b.w, b.h))
            button(r, b.x, b.y - (hot ? 1 : 0), b.w, b.h, lit: false, hot: hot)
            r.text(b.label, b.x + b.w / 2, b.y + 7.5 - (hot ? 1 : 0), scale: 1, color: C(255, 240, 210), align: .center, shadow: nil)
        }
    }

    func drawBriefing(_ r: Renderer) {
        let a = r.atlas
        r.layer = r.world
        setTheme(r, level.theme, cam: Float(time) * 10)
        r.syncTerrain(terrain)
        r.layer = r.ui
        r.nine(a.paper, 40, 16 + top * 0.3, 560, 330, b: 16)
        let y0 = 16 + top * 0.3
        r.text("Level \(levelIndex + 1)", 320, y0 + 12, scale: 1.4, color: C(170, 90, 30), align: .center, shadow: nil)
        let nm = level.name
        let sc: Float = r.textWidth(nm, scale: 3) > 520 ? 2.2 : 3
        r.text(nm, 320, y0 + 30, scale: sc, color: INK, align: .center, shadow: nil)
        for (i, l) in wrapText(level.tagline, 92).prefix(3).enumerated() {
            r.text(l, 320, y0 + 66 + Float(i) * 11, scale: 0.95, color: INK * RGBA(1, 1, 1, 0.85), align: .center, shadow: nil)
        }
        let s = min(470 / Float(terrain.w), 110 / Float(terrain.h))
        let pw = Float(terrain.w) * s, ph = Float(terrain.h) * s
        let px = 320 - pw / 2, py = y0 + 104
        r.rect(px - 2, py - 2, pw + 4, ph + 4, C(90, 60, 30))
        r.rect(px, py, pw, ph, level.theme.skyBottom)
        r.rect(px, py, pw, ph * 0.5, level.theme.skyTop * RGBA(1, 1, 1, 0.5))
        r.terrainQuad(terrain, px, py, pw, ph, flat: true)
        for w in level.water {
            r.rect(px + Float(w.x0) * s, py + Float(w.top) * s, Float(w.x1 - w.x0) * s, Float(300 - w.top) * s, level.theme.water)
        }
        r.rect(px + Float(level.entrance.x) * s - 3, py + Float(level.entrance.y) * s - 4, 6, 4, C(190, 130, 66))
        r.rect(px + Float(exitX) * s - 3, py + Float(exitY) * s - 5, 6, 5, C(230, 60, 60))

        let stats = "\(level.count) hogs   ·   rescue \(level.need)%   ·   rate \(level.rate)   ·   \(level.minutes) min"
        r.text(stats, 320, py + ph + 10, scale: 1.1, color: INK, align: .center, shadow: nil)

        let avail = Skill.allCases.filter { level.skills[$0.rawValue] > 0 }
        let slot: Float = 62
        var sx = 320 - Float(avail.count) * slot / 2
        let iy = py + ph + 26
        for sk in avail {
            skillIcon(r, sk, sx + slot / 2 - 13, iy, 1.6, WHITE)
            r.text(sk.title, sx + slot / 2, iy + 28, scale: 0.75, color: INK, align: .center, shadow: nil)
            r.text("×\(level.skills[sk.rawValue])", sx + slot / 2, iy + 37, scale: 0.85, color: C(170, 90, 30), align: .center, shadow: nil)
            sx += slot
        }
        let pulse = 0.75 + 0.25 * sin(Float(time) * 4)
        r.text("Click to dig in", 320, y0 + 300, scale: 1.7, color: C(200, 110, 30, pulse), align: .center, shadow: nil)
        if best[levelIndex] >= 0 {
            r.text("Best: \(best[levelIndex])%", 580, y0 + 14, scale: 0.9, color: INK, align: .right, shadow: nil)
        }
    }

    func drawResults(_ r: Renderer) {
        let a = r.atlas
        r.layer = r.ui
        r.rect(0, top, 640, 360 - top, RGBA(0, 0, 0, 0.35))
        let k = Float(min(1, screenTime * 3))
        let yOff = (1 - k) * 30
        r.nine(a.paper, 70, 26 + yOff, 500, 284, b: 16, color: RGBA(1, 1, 1, k))
        let pct = savedPercent
        let head = success ? "Spring is saved!" : "Six more weeks of winter..."
        let hs: Float = r.textWidth(head, scale: 3) > 460 ? 2.4 : 3
        r.text(head, 320, 38 + yOff, scale: hs, color: success ? C(60, 140, 40) : C(180, 60, 40), align: .center, shadow: nil)
        let st = starsFor(pct, level.need)
        for s in 0..<3 {
            let pop = min(1, max(0, Float(screenTime) * 3 - Float(s) * 0.6 - 0.5))
            let sc: Float = s < st ? 1.2 + (1 - pop) * 0.8 : 1.0
            r.sprite(a.star, 320 - 40 + Float(s) * 28 - 6 * sc + 6, 72 + yOff - 6 * sc + 6, scale: sc,
                     color: s < st ? RGBA(1, 1, 1, pop) : RGBA(0, 0, 0, 0.2), smooth: true)
        }
        r.text("You rescued \(pct)%   ·   you needed \(level.need)%", 320, 104 + yOff, scale: 1.4, color: INK, align: .center, shadow: nil)
        if newBest && pct > 0 {
            r.text("New best!", 430, 76 + yOff, scale: 1, color: C(200, 110, 30), align: .left, shadow: nil)
        }
        let msg: String
        if pct == 100 { msg = "Flawless. Every single hog made it home. They are already writing songs about you. The songs are mostly squeaking." }
        else if success { msg = "The hogs are home, fed, and already napping. Nobody asked about the ones who didn't make it. Good work." }
        else if pct == 0 { msg = "Nobody made it. Not one. Winter is now permanent and the weather people would like a word." }
        else if pct >= level.need - 15 { msg = "So close. The survivors will tell their grandchildren about you. Not kindly, but still." }
        else { msg = "The hogs have filed a formal complaint with the Burrow Council. It is mostly drawings of you." }
        for (i, l) in wrapText(msg, 74).enumerated() {
            r.text(l, 320, 128 + yOff + Float(i) * 12, scale: 1, color: INK * RGBA(1, 1, 1, 0.9), align: .center, shadow: nil)
        }
        if !lostNames.isEmpty {
            var memo = "In loving memory of " + lostNames.prefix(3).joined(separator: ", ")
            if lostNames.count > 3 { memo += " and \(lostNames.count - 3) others" }
            for (i, l) in wrapText(memo + ".", 74).enumerated() {
                r.text(l, 320, 182 + yOff + Float(i) * 12, scale: 1, color: C(90, 90, 150), align: .center, shadow: nil)
            }
            r.sprite(a.ghost, 312, 212 + yOff + sin(Float(time) * 3) * 2, smooth: true)
        }
        for b in resultButtons() {
            let hot = inRect(mouse, (b.x, b.y, b.w, b.h))
            button(r, b.x, b.y + yOff - (hot ? 1 : 0), b.w, b.h, lit: b.id == "next", hot: hot)
            r.text(b.label, b.x + b.w / 2, b.y + yOff + 9 - (hot ? 1 : 0), scale: 1.1,
                   color: b.id == "next" ? C(70, 36, 10) : C(255, 240, 210), align: .center, shadow: nil)
        }
    }
}
