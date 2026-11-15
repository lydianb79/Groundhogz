import Foundation
import simd

var audio: Audio? = nil
func sfx(_ name: String, _ vol: Float = 0.5, pan: Float = 0, cooldown: Double = 0.03) {
    audio?.play(name, vol, pan: pan, cooldown: cooldown)
}

enum Skill: Int, CaseIterable {
    case climber, floater, bomber, blocker, builder, basher, miner, digger

    var title: String { ["SCRAMBLER", "BROLLY", "KABOOM", "BOUNCER", "STACKER", "PUNCHER", "PICKAXE", "DIGGER"][rawValue] }
    var blurb: String {
        ["Climbs walls", "Floats down safely", "Explodes. Sorry.", "Turns others around",
         "Stacks carrot stairs", "Punches sideways", "Digs diagonally", "Digs straight down"][rawValue]
    }
    var quips: [String] {
        switch self {
        case .climber: return ["Up I go!", "Parkour!", "Climb time!"]
        case .floater: return ["Brolly ready!", "Safety first!"]
        case .bomber: return ["Wait, what?", "Why me?!", "Uh oh."]
        case .blocker: return ["None shall pass.", "Talk to the paw.", "Nope."]
        case .builder: return ["Carrot time!", "Measure twice!"]
        case .basher: return ["Hi-yah!", "Pow!", "Fists of fury!"]
        case .miner: return ["To the depths!", "Diagonally!"]
        case .digger: return ["Dig dig dig!", "Downwards!", "Born for this."]
        }
    }
    static func named(_ s: String) -> Skill? {
        let u = s.uppercased()
        let alt = ["CLIMBER", "FLOATER", "BOMBER", "BLOCKER", "BUILDER", "BASHER", "MINER", "DIGGER"]
        return Skill.allCases.first { $0.title == u || alt[$0.rawValue] == u }
    }
}

enum HogState { case walking, falling, climbing, digging, bashing, mining, building, shrugging, blocking, ohno, splatting, drowning, exiting, dead, saved }

let hogNames = ["Gary", "Phil", "Chuck", "Wendy", "Kevin", "Doug", "Mabel", "Pudge", "Clover", "Biscuit", "Nibbles",
                "Woody", "Marge", "Sir Digsalot", "Burrowsby", "Tater", "Lumpy", "Dot", "Peanut", "Barry", "Gerald",
                "Sunny", "Muffin", "Dusty", "Hazel", "Otto", "Pickle", "Waldo", "Beans", "Fern", "Gus", "Truffle",
                "Rolo", "Nugget", "Penny", "Maude", "Brenda", "Steve", "Clementine", "Bartholomew", "Pip", "Tofu",
                "Duchess", "Meatball", "Professor", "Waffles", "Ziggy", "Noodle", "Bramble", "Crumpet"]

final class Hog {
    let id: Int
    let name: String
    var x: Int, y: Int        // y = the (empty) pixel row the feet occupy
    var dir = 1
    var state: HogState = .falling
    var t = 0
    var fall = 0
    var climber = false, floater = false, umbrella = false
    var fuse = -1
    var bricks = 0
    var quip: String? = nil
    var quipT = 0

    init(id: Int, x: Int, y: Int) {
        self.id = id; self.x = x; self.y = y
        let base = hogNames[id % hogNames.count]
        name = id < hogNames.count ? base : base + " " + ["II", "III", "IV", "V"][min(3, id / hogNames.count - 1)]
    }
    var alive: Bool { state != .dead && state != .saved }
    var active: Bool { alive && state != .exiting && state != .splatting && state != .drowning }
}

enum PKind { case dot, smoke, ghost, text, star, spark, flash, rock, ring, fire, confetti }

struct Particle {
    var kind: PKind
    var x: Float, y: Float, vx: Float, vy: Float
    var life: Float, maxLife: Float
    var color: RGBA
    var size: Float = 1
    var grav: Float = 0
    var text: String = ""
    var rot: Float = 0
    var vr: Float = 0
}

enum Screen { case splash, title, levelSelect, briefing, playing, results }

struct TitleHog { var x: Float; var dir: Float; var speed: Float; var phase: Float }

final class Game {
    var screen: Screen = .title
    var levelIndex = 0
    var level: LevelDef
    var terrain: Terrain
    var hogs: [Hog] = []
    var particles: [Particle] = []
    var skills = [Int](repeating: 0, count: 8)
    var selected = 0
    var rate = 50, minRate = 50
    var spawned = 0, saved = 0
    var spawnTimer = 0, tick = 0, timeLeft = 0
    var exitX = 0, exitY = 0
    var paused = false, fast = false
    var nuking = false, nukeIdx = 0
    var nukeArm: Double = -10
    var camX: Float = 0
    var camTarget: Float = 0
    var shake: Float = 0
    var mouse = SIMD2<Float>(320, 180)
    var mouseIsDown = false
    var heldButton = -1
    var holdTime: Double = 0
    var draggingMinimap = false
    var keys = Set<UInt16>()
    var time: Double = 0
    var acc: Double = 0
    var endTimer = -1
    var hovered: Hog? = nil
    var playTime: Double = 0
    var screenTime: Double = 0
    var unlocked = 1
    var best: [Int] = []
    var lostNames: [String] = []
    var success = false
    var newBest = false
    var musicOn = true
    var titleHogs: [TitleHog] = []
    var skyHogY: Float = -40
    var skyHogX: Float = 200
    var page = 0
    var lastHover = ""
    var headless = false
    var splashEvents = 0
    var fromSplashDelay: Float = 0
    var splashLetterX: [Float] = []
    var splashLogoY: Float = 40
    var splashAcc: Double = 0

    init() {
        level = levels[0]
        terrain = Terrain(w: 640, h: 300, theme: .spring)
        let d = UserDefaults.standard
        unlocked = max(1, min(levels.count, d.integer(forKey: "unlocked")))
        best = (d.array(forKey: "best") as? [Int]) ?? []
        if best.count < levels.count { best += [Int](repeating: -1, count: levels.count - best.count) }
        for i in 0..<10 {
            titleHogs.append(TitleHog(x: Float.random(in: 0...640), dir: i % 2 == 0 ? 1 : -1,
                                      speed: Float.random(in: 14...26), phase: Float.random(in: 0...10)))
        }
        page = (unlocked - 1) / 60
    }

    func setScreen(_ s: Screen) {
        fromSplashDelay = 0
        if screen == .splash && s == .title { fromSplashDelay = -0.6 }   // splash flows straight into the title: no wipe
        screen = s
        screenTime = 0
        switch s {
        case .splash, .title, .levelSelect:
            audio?.setMusic("title"); audio?.setAmbience(s == .splash ? "spring" : nil)
            if s == .splash { particles = []; splashEvents = 0 }
        case .briefing, .playing:
            audio?.setMusic(level.theme.name); audio?.setAmbience(level.theme.name)
        case .results: break
        }
    }

    // MARK: level lifecycle

    func loadLevel(_ i: Int) {
        levelIndex = i
        level = levels[i]
        terrain = Terrain(w: level.width, h: 300, theme: level.theme)
        level.build(terrain)
        terrain.finalize()
        hogs = []
        particles = []
        skills = level.skills
        rate = level.rate; minRate = level.rate
        spawned = 0; saved = 0; spawnTimer = 0; tick = 0
        timeLeft = level.minutes * 60 * 30
        exitX = level.exit.x
        var gy = max(0, level.exit.y)
        while gy < terrain.h - 1 && !terrain.solid(exitX, gy) { gy += 1 }
        exitY = gy
        paused = false; fast = false; nuking = false; nukeIdx = 0; endTimer = -1; acc = 0
        lostNames = []
        selected = skills.firstIndex(where: { $0 > 0 }) ?? 0
        camX = Float(level.entrance.x) - 320
        clampCam()
        camTarget = camX
        hovered = nil; shake = 0
    }

    func startPlaying() {
        setScreen(.playing)
        playTime = 0
        sfx("start", 0.55)
    }

    func finishLevel() {
        guard screen == .playing else { return }
        let pct = saved * 100 / max(1, level.count)
        success = pct >= level.need
        newBest = pct > best[levelIndex]
        if headless { screen = .results; return }
        setScreen(.results)
        if newBest { best[levelIndex] = pct; UserDefaults.standard.set(best, forKey: "best") }
        if success && levelIndex + 2 > unlocked {
            unlocked = min(levels.count, levelIndex + 2)
            UserDefaults.standard.set(unlocked, forKey: "unlocked")
        }
        sfx(success ? "win" : "lose", 0.7)
        audio?.setMusic(nil)
    }

    var savedPercent: Int { saved * 100 / max(1, level.count) }
    var aliveCount: Int { hogs.reduce(0) { $0 + ($1.alive ? 1 : 0) } }

    func clampCam() {
        camX = max(0, min(Float(max(0, terrain.w - 640)), camX))
    }

    func spawnInterval() -> Int { max(4, 4 + (99 - rate) * 56 / 98) }

    func changeRate(_ d: Int) {
        let n = max(minRate, min(99, rate + d))
        if n != rate { rate = n; sfx("click", 0.15) }
    }

    func panFor(_ wx: Int) -> Float { max(-0.9, min(0.9, (Float(wx) - camX - 320) / 340)) }
    func onScreen(_ wx: Int) -> Bool { Float(wx) > camX - 60 && Float(wx) < camX + 700 }
    func sfxAt(_ name: String, _ wx: Int, _ vol: Float, cooldown: Double = 0.03) {
        if headless || !onScreen(wx) { return }
        sfx(name, vol, pan: panFor(wx), cooldown: cooldown)
    }

    // MARK: simulation tick (30 per second)

    func step() {
        tick += 1
        if timeLeft > 0 {
            timeLeft -= 1
            if timeLeft == 0 { finishLevel(); return }
        }
        if tick == 22 { sfxAt("door", level.entrance.x, 0.5) }
        if tick > 30 && !nuking && spawned < level.count {
            spawnTimer -= 1
            if spawnTimer <= 0 {
                let h = Hog(id: spawned, x: level.entrance.x, y: level.entrance.y + 2)
                hogs.append(h)
                spawned += 1
                spawnTimer = spawnInterval()
                sfxAt("pop", h.x, 0.3)
                if Int.random(in: 0..<4) == 0 {
                    say(h, ["Wheee!", "Hello world!", "Is it spring?", "YOLO!", "Morning!", "Here we go!"].randomElement()!, voice: "wheee")
                }
            }
        }
        if nuking && tick % 3 == 0 {
            while nukeIdx < hogs.count {
                let h = hogs[nukeIdx]
                nukeIdx += 1
                if h.active && h.fuse < 0 && h.state != .ohno { h.fuse = 90; break }
            }
        }
        for h in hogs where h.alive { update(h) }
        updateParticles()
        if tick % 20 == 0 {
            emit(Particle(kind: .smoke, x: Float(exitX + 11), y: Float(exitY - 33), vx: 0.12, vy: -0.35,
                          life: 100, maxLife: 100, color: RGBA(1, 1, 1, 0.45), size: 5))
        }
        if shake > 0 { shake = max(0, shake - 0.4) }
        if (spawned >= level.count || nuking) && aliveCount == 0 && endTimer < 0 { endTimer = 50 }
        if endTimer > 0 {
            endTimer -= 1
            if endTimer == 0 { finishLevel() }
        }
    }

    func setState(_ h: Hog, _ s: HogState) { h.state = s; h.t = 0 }

    func say(_ h: Hog, _ s: String, force: Bool = false, voice: String = "babble") {
        let active = hogs.reduce(0) { $0 + ($1.quip != nil ? 1 : 0) }
        if force || active < 4 {
            h.quip = s; h.quipT = 80
            sfxAt(voice, h.x, 0.45, cooldown: 0.15)
        }
    }

    func atExit(_ h: Hog) -> Bool {
        abs(h.x - exitX) <= 3 && h.y >= exitY - 9 && h.y <= exitY + 1
    }

    func inWater(_ x: Int, _ y: Int) -> Bool {
        for w in level.water where x >= w.x0 && x < w.x1 && y >= w.top { return true }
        return false
    }

    func kill(_ h: Hog, ghost: Bool = true) {
        setState(h, .dead)
        lostNames.append(h.name)
        if ghost {
            emit(Particle(kind: .ghost, x: Float(h.x), y: Float(h.y) - 8, vx: 0, vy: -0.45, life: 80, maxLife: 80, color: WHITE))
        }
    }

    func update(_ h: Hog) {
        h.t += 1
        if h.quipT > 0 { h.quipT -= 1; if h.quipT == 0 { h.quip = nil } }
        if h.fuse > 0 && h.active && h.state != .ohno {
            h.fuse -= 1
            if h.fuse % 30 == 0 && h.fuse > 0 { sfxAt((h.fuse / 30) % 2 == 0 ? "tick" : "tock", h.x, 0.35, cooldown: 0) }
            if h.fuse == 0 {
                setState(h, .ohno)
                say(h, ["Oh crumbs!", "Oh nuts!", "Not again!"].randomElement()!, force: true, voice: "uhoh")
            }
        }
        switch h.state {
        case .walking: walk(h)
        case .falling: fallStep(h)
        case .climbing: climbStep(h)
        case .digging: digStep(h)
        case .bashing: bashStep(h)
        case .mining: mineStep(h)
        case .building: buildStep(h)
        case .shrugging: if h.t >= 16 { setState(h, .walking) }
        case .blocking:
            if !terrain.solid(h.x, h.y + 1) { setState(h, .falling); h.fall = 0 }
        case .ohno:
            if !terrain.solid(h.x, h.y + 1) { h.y += 1 }
            if h.t >= 24 { explode(h) }
        case .splatting: if h.t >= 26 { kill(h) }
        case .drowning: if h.t >= 34 { kill(h) }
        case .exiting:
            if h.t >= 18 {
                setState(h, .saved)
                saved += 1
                for _ in 0..<8 {
                    emit(Particle(kind: .spark, x: Float(exitX), y: Float(exitY - 14), vx: .random(in: -1.4...1.4),
                                  vy: .random(in: -2.2 ... -0.6), life: 30, maxLife: 30, color: C(255, 230, 120), size: 3, grav: 0.06))
                }
                let palette = [C(255, 90, 90), C(255, 210, 60), C(90, 200, 255), C(120, 230, 110), C(220, 120, 255), C(255, 150, 60)]
                for _ in 0..<7 {
                    emit(Particle(kind: .confetti, x: Float(exitX), y: Float(exitY - 16), vx: .random(in: -1.6...1.6),
                                  vy: .random(in: -2.8 ... -1.4), life: 70, maxLife: 70, color: palette.randomElement()!,
                                  size: 1, grav: 0.07, rot: .random(in: 0...6), vr: .random(in: -0.4...0.4)))
                }
            }
        case .dead, .saved: break
        }
        if h.active {
            if inWater(h.x, h.y) {
                setState(h, .drowning)
                h.umbrella = false
                say(h, "Blub!", force: true, voice: "drown")
                for _ in 0..<8 {
                    emit(Particle(kind: .dot, x: Float(h.x) + .random(in: -4...4), y: Float(h.y), vx: .random(in: -1...1),
                                  vy: .random(in: -2.5 ... -1), life: 20, maxLife: 20, color: C(220, 240, 255, 0.9), size: 1.5, grav: 0.15))
                }
            } else if h.y >= terrain.h + 8 {
                kill(h, ghost: false)
            }
        }
    }

    // MARK: behaviours

    func walk(_ h: Hog) {
        for b in hogs where b.state == .blocking && b !== h {
            let dx = b.x - h.x
            if abs(b.y - h.y) <= 10 && dx * h.dir > 0 && abs(dx) <= 6 { h.dir = -h.dir; break }
        }
        let nx = h.x + h.dir
        if terrain.solid(nx, h.y) {
            var up = 0
            while up <= 6 && terrain.solid(nx, h.y - up) { up += 1 }
            if up > 6 {
                if h.climber && nx >= 0 && nx < terrain.w {
                    setState(h, .climbing)
                } else {
                    h.dir = -h.dir
                }
                return
            }
            h.x = nx
            h.y -= up
        } else {
            h.x = nx
            var down = 0
            while down < 4 && !terrain.solid(h.x, h.y + 1 + down) { down += 1 }
            if down >= 4 {
                h.y += 3
                setState(h, .falling)
                h.fall = 3
                return
            }
            h.y += down
        }
        if atExit(h) {
            setState(h, .exiting)
            sfxAt("exit", h.x, 0.4)
            if Int.random(in: 0..<3) == 0 { say(h, ["Home!", "Burrow sweet burrow!", "Nap time!", "Snacks!"].randomElement()!, voice: "yay") }
        } else if Int.random(in: 0..<2600) == 0 {
            say(h, ["La la la", "Nice dirt.", "Shadow? Where?", "I'm hungry.", "Carrots...", "Dig it.",
                    "*sniff sniff*", "Are we there yet?", "Hmm.", "I love mud."].randomElement()!)
        }
    }

    func fallStep(_ h: Hog) {
        let speed = h.umbrella ? 1 : 3
        for _ in 0..<speed {
            if terrain.solid(h.x, h.y + 1) {
                if h.fall > 60 && !h.umbrella {
                    setState(h, .splatting)
                    sfxAt("splat", h.x, 0.6)
                    sfxAt("ow", h.x, 0.35)
                    emit(Particle(kind: .text, x: Float(h.x), y: Float(h.y) - 12, vx: 0, vy: -0.4, life: 40, maxLife: 40,
                                  color: C(255, 110, 90), text: ["SPLAT!", "SPLORT!", "OOF!", "THWUMP!"].randomElement()!))
                    return
                }
                if h.fall > 8 || h.umbrella {
                    let c = level.theme.dirtA
                    for i in 0..<4 {
                        emit(Particle(kind: .smoke, x: Float(h.x) + Float(i - 2) * 2.5, y: Float(h.y) - 1, vx: Float(i - 2) * 0.25,
                                      vy: -0.15, life: 26, maxLife: 26,
                                      color: C(Float(c.0) + 60, Float(c.1) + 50, Float(c.2) + 40, 0.5), size: 2.2))
                    }
                }
                h.umbrella = false
                h.fall = 0
                setState(h, .walking)
                return
            }
            h.y += 1
            h.fall += 1
            if h.y >= terrain.h + 8 { return }
        }
        if h.floater && !h.umbrella && h.fall > 16 {
            h.umbrella = true
            sfxAt("brolly", h.x, 0.35)
        }
    }

    func climbStep(_ h: Hog) {
        if h.t % 2 == 1 { return }
        if h.t % 12 == 0 { sfxAt("climb", h.x, 0.18, cooldown: 0.2) }
        if terrain.solid(h.x, h.y - 14) {
            h.dir = -h.dir
            h.x += h.dir
            setState(h, .falling)
            h.fall = 0
            return
        }
        h.y -= 1
        if !terrain.solid(h.x + h.dir, h.y) {
            h.x += h.dir
            setState(h, .walking)
        }
    }

    func digStep(_ h: Hog) {
        if h.t % 3 != 0 { return }
        for dx in -4...4 where terrain.steel(h.x + dx, h.y + 1) {
            setState(h, .walking)
            say(h, "CLANG!", force: true, voice: "ow")
            sfxAt("clang", h.x, 0.45)
            return
        }
        var removed = 0
        for dx in -4...4 where terrain.carve(h.x + dx, h.y + 1) { removed += 1 }
        if removed == 0 {
            setState(h, .falling)
            h.fall = 0
            return
        }
        h.y += 1
        dirt(h.x, h.y, 2)
        if h.t % 6 == 0 { chunk(h.x + Int.random(in: -4...4), h.y - 2) }
        if h.t % 9 == 0 { sfxAt("dig", h.x, 0.3, cooldown: 0.12) }
    }

    func bashStep(_ h: Hog) {
        if h.t % 2 != 0 { return }
        var any = false
        outer: for c in 1...12 {
            for r in 0...11 where terrain.diggable(h.x + h.dir * c, h.y - r) { any = true; break outer }
        }
        if !any { setState(h, .walking); return }
        for c in 1...5 {
            let px = h.x + h.dir * c
            for r in 0...12 {
                let py = h.y - r
                if terrain.steel(px, py) {
                    h.dir = -h.dir
                    setState(h, .walking)
                    say(h, "Ow! Steel!", force: true, voice: "ow")
                    sfxAt("clang", h.x, 0.45)
                    return
                }
                terrain.carve(px, py)
            }
        }
        h.x += h.dir
        if !terrain.solid(h.x, h.y + 1) {
            var down = 0
            while down < 4 && !terrain.solid(h.x, h.y + 1 + down) { down += 1 }
            if down >= 4 { setState(h, .falling); h.fall = 0; return }
            h.y += down
        }
        if h.t % 8 == 0 {
            dirt(h.x + h.dir * 6, h.y - 4, 3)
            sfxAt("punch", h.x, 0.35, cooldown: 0.1)
        }
    }

    func mineStep(_ h: Hog) {
        if h.t % 4 != 0 { return }
        let cx = h.x + h.dir * 4, cy = h.y - 5
        if terrain.ellipseHasSteel(cx, cy, 6, 8) {
            h.dir = -h.dir
            setState(h, .walking)
            say(h, "CLANG!", force: true, voice: "ow")
            sfxAt("clang", h.x, 0.45)
            return
        }
        let removed = terrain.carveEllipse(cx, cy, 6, 8)
        if removed == 0 && h.t > 4 { setState(h, .walking); return }
        h.x += h.dir
        h.y += 1
        dirt(h.x + h.dir * 5, h.y, 3)
        if h.t % 8 == 0 {
            sfxAt("pick", h.x, 0.3, cooldown: 0.1)
            emit(Particle(kind: .spark, x: Float(h.x + h.dir * 7), y: Float(h.y - 2), vx: Float(h.dir) * .random(in: 0.5...1.5),
                          vy: .random(in: -1.5 ... -0.3), life: 10, maxLife: 10, color: C(255, 220, 140), size: 2, grav: 0.1))
        }
        if !terrain.solid(h.x, h.y + 1) { setState(h, .falling); h.fall = 0 }
    }

    func buildStep(_ h: Hog) {
        if h.t % 12 != 0 { return }
        for i in 0..<6 {
            terrain.placeBrick(h.x + h.dir * i, h.y, i, lower: false)
            terrain.placeBrick(h.x + h.dir * i, h.y + 1, i, lower: true)
        }
        sfxAt("brick", h.x, 0.3, cooldown: 0.05)
        h.bricks -= 1
        if h.bricks == 2 { sfxAt("warn", h.x, 0.35) }
        h.y -= 1
        for _ in 0..<2 {
            if terrain.solid(h.x + h.dir, h.y) || terrain.solid(h.x + h.dir, h.y - 9) {
                setState(h, .walking)
                return
            }
            h.x += h.dir
        }
        if terrain.solid(h.x, h.y - 13) {
            h.dir = -h.dir
            setState(h, .walking)
            return
        }
        if h.bricks <= 0 {
            setState(h, .shrugging)
            say(h, "Out of carrots!", force: true, voice: "hmm")
        }
    }

    func explode(_ h: Hog) {
        let cx = h.x, cy = h.y - 6
        terrain.carveEllipse(cx, cy, 16, 16)
        if !headless { sfx("boom", 0.8, pan: panFor(cx)) }
        shake = 7
        let dirtC = C(Float(level.theme.dirtA.0), Float(level.theme.dirtA.1), Float(level.theme.dirtA.2))
        for _ in 0..<50 {
            let a = Float.random(in: 0...(2 * .pi)), s = Float.random(in: 0.8...3.8)
            emit(Particle(kind: .dot, x: Float(cx), y: Float(cy), vx: cos(a) * s, vy: sin(a) * s - 1.5,
                          life: 50, maxLife: 50, color: dirtC, size: Float(Int.random(in: 1...2)), grav: 0.15))
        }
        for _ in 0..<24 {
            let a = Float.random(in: 0...(2 * .pi)), s = Float.random(in: 1.5...4.5)
            emit(Particle(kind: .spark, x: Float(cx), y: Float(cy), vx: cos(a) * s, vy: sin(a) * s - 1,
                          life: 22, maxLife: 22, color: C(255, 190, 80), size: 3, grav: 0.08))
        }
        for _ in 0..<10 {
            emit(Particle(kind: .smoke, x: Float(cx) + .random(in: -8...8), y: Float(cy) + .random(in: -8...8),
                          vx: .random(in: -0.4...0.4), vy: .random(in: -0.6 ... -0.1), life: 60, maxLife: 60,
                          color: C(120, 110, 100, 0.7), size: 10))
        }
        emit(Particle(kind: .flash, x: Float(cx), y: Float(cy), vx: 0, vy: 0, life: 14, maxLife: 14, color: C(255, 200, 120), size: 90))
        emit(Particle(kind: .ring, x: Float(cx), y: Float(cy), vx: 0, vy: 0, life: 16, maxLife: 16, color: C(255, 240, 200), size: 30))
        for _ in 0..<7 {
            emit(Particle(kind: .fire, x: Float(cx) + .random(in: -6...6), y: Float(cy) + .random(in: -6...6),
                          vx: .random(in: -0.6...0.6), vy: .random(in: -1.0 ... -0.2), life: 24, maxLife: 24,
                          color: C(255, 160, 60), size: .random(in: 8...14)))
        }
        for _ in 0..<14 {
            let a = Float.random(in: Float.pi...(2 * .pi)), sp = Float.random(in: 1.5...4)
            emit(Particle(kind: .rock, x: Float(cx), y: Float(cy), vx: cos(a) * sp, vy: sin(a) * sp - 1, life: 70, maxLife: 70,
                          color: dirtC, size: .random(in: 0.5...1.0), grav: 0.16, rot: .random(in: 0...6), vr: .random(in: -0.4...0.4)))
        }
        emit(Particle(kind: .text, x: Float(cx), y: Float(cy) - 14, vx: 0, vy: -0.5, life: 40, maxLife: 40,
                      color: C(255, 230, 90), text: ["KABOOM!", "POP!", "BOOM!", "KAPOW!"].randomElement()!))
        kill(h)
    }

    // MARK: skills

    func canAssign(_ s: Skill, _ h: Hog) -> Bool {
        guard h.active, h.state != .ohno else { return false }
        let ground: Set<HogState> = [.walking, .digging, .bashing, .mining, .building, .shrugging]
        switch s {
        case .climber: return !h.climber
        case .floater: return !h.floater
        case .bomber: return h.fuse < 0
        case .blocker: return ground.contains(h.state)
        case .builder: return ground.contains(h.state) && h.state != .building
        case .basher: return ground.contains(h.state) && h.state != .bashing
        case .miner: return ground.contains(h.state) && h.state != .mining
        case .digger: return ground.contains(h.state) && h.state != .digging
        }
    }

    @discardableResult func assign(_ s: Skill, _ h: Hog) -> Bool {
        guard skills[s.rawValue] > 0, canAssign(s, h) else { return false }
        skills[s.rawValue] -= 1
        switch s {
        case .climber: h.climber = true
        case .floater: h.floater = true
        case .bomber: h.fuse = 150
        case .blocker: setState(h, .blocking)
        case .builder: setState(h, .building); h.bricks = 12
        case .basher: setState(h, .bashing)
        case .miner: setState(h, .mining)
        case .digger: setState(h, .digging)
        }
        if !headless {
            if let a = audio, a.ok { a.play("assign", 0.4, pan: panFor(h.x), cooldown: 0) }
            emit(Particle(kind: .spark, x: Float(h.x), y: Float(h.y - 8), vx: 0, vy: -0.3, life: 14, maxLife: 14, color: C(255, 240, 160), size: 10))
            if Int.random(in: 0..<2) == 0 { say(h, s.quips.randomElement()!) }
        }
        return true
    }

    func hogAt(_ wx: Float, _ wy: Float) -> Hog? {
        var best: Hog? = nil
        var bestScore = Float.greatestFiniteMagnitude
        let sk = Skill(rawValue: selected)!
        for h in hogs where h.active {
            let cx = Float(h.x), cy = Float(h.y) - 6
            if abs(wx - cx) <= 8 && abs(wy - cy) <= 10 {
                var score = (wx - cx) * (wx - cx) + (wy - cy) * (wy - cy)
                if !canAssign(sk, h) { score += 1000 }
                if score < bestScore { bestScore = score; best = h }
            }
        }
        return best
    }

    // MARK: particles

    func emit(_ p: Particle) { if !headless && particles.count < 1200 { particles.append(p) } }

    func dirt(_ x: Int, _ y: Int, _ n: Int) {
        let c = level.theme.dirtA
        for _ in 0..<n {
            let k = Float.random(in: 0.7...1.2)
            emit(Particle(kind: .dot, x: Float(x) + .random(in: -3...3), y: Float(y) - 1, vx: .random(in: -1.2...1.2),
                          vy: .random(in: -2.2 ... -0.6), life: 28, maxLife: 28,
                          color: C(Float(c.0) * k, Float(c.1) * k, Float(c.2) * k), size: Float(Int.random(in: 1...2)), grav: 0.18))
        }
    }

    func chunk(_ x: Int, _ y: Int) {
        let c = level.theme.dirtA
        emit(Particle(kind: .rock, x: Float(x), y: Float(y), vx: .random(in: -1.2...1.2), vy: .random(in: -2.4 ... -1.0),
                      life: 40, maxLife: 40, color: C(Float(c.0), Float(c.1), Float(c.2)), size: .random(in: 0.35...0.6),
                      grav: 0.18, rot: .random(in: 0...6), vr: .random(in: -0.5...0.5)))
    }

    func updateParticles() {
        var i = 0
        while i < particles.count {
            var p = particles[i]
            p.x += p.vx
            p.y += p.vy
            p.vy += p.grav
            p.life -= 1
            p.rot += p.vr
            if (p.kind == .dot || p.kind == .rock) && p.vy > 0 && terrain.solid(Int(p.x), Int(p.y)) {
                if p.kind == .rock && p.vy > 1.2 { p.vy *= -0.35; p.vx *= 0.6; p.vr *= 0.5 } else { p.vx = 0; p.vy = 0; p.grav = 0; p.vr = 0 }
            }
            if p.kind == .smoke { p.size += 0.08 }
            if p.kind == .fire { p.size += 0.35 }
            if p.kind == .confetti { p.vx *= 0.97; p.vx += sin(p.life * 0.25 + p.rot) * 0.04; p.vy = min(p.vy, 0.55) }
            if p.life <= 0 {
                particles.swapAt(i, particles.count - 1)
                particles.removeLast()
            } else {
                particles[i] = p
                i += 1
            }
        }
    }

    // MARK: per-frame update

    func update(dt: Double) {
        time += dt
        screenTime += dt
        audio?.update(dt)
        switch screen {
        case .playing:
            playTime += dt
            var scroll: Float = 0
            if keys.contains(123) || keys.contains(0) { scroll -= 1 }
            if keys.contains(124) || keys.contains(2) { scroll += 1 }
            if mouse.y >= -Renderer.originY && mouse.y < 300 {
                if mouse.x < 8 && mouse.x > -60 { scroll -= 1 } else if mouse.x > 632 && mouse.x < 700 { scroll += 1 }
            }
            camTarget += scroll * 420 * Float(dt)
            camTarget = max(0, min(Float(max(0, terrain.w - 640)), camTarget))
            camX += (camTarget - camX) * Float(min(1, dt * 12))
            clampCam()
            if mouseIsDown && (heldButton == 0 || heldButton == 1) {
                holdTime += dt
                while holdTime > 0.35 { holdTime -= 0.05; changeRate(heldButton == 0 ? -1 : 1) }
            }
            if !paused {
                let mul = fast ? 3.0 : 1.0
                acc = min(acc + dt * mul, 0.25 * mul)
                while acc >= 1.0 / 30 && screen == .playing {
                    acc -= 1.0 / 30
                    step()
                }
            }
            hovered = (mouse.y >= -Renderer.originY && mouse.y < 300) ? hogAt(mouse.x + floor(camX), mouse.y) : nil
        case .splash:
            updateSplash(dt)
        case .title, .levelSelect:
            for i in titleHogs.indices {
                titleHogs[i].x += titleHogs[i].dir * titleHogs[i].speed * Float(dt)
                if titleHogs[i].x > 680 { titleHogs[i].x = -40 }
                if titleHogs[i].x < -40 { titleHogs[i].x = 680 }
            }
            skyHogY += Float(dt) * 22
            if skyHogY > 320 { skyHogY = -60 - Renderer.originY; skyHogX = Float.random(in: 40...600) }
        default: break
        }
    }

    // MARK: geometry

    func buttonRect(_ i: Int) -> (x: Float, y: Float, w: Float, h: Float) { (4 + Float(i) * 34, 313, 32, 43) }

    func buttonAt(_ p: SIMD2<Float>) -> Int? {
        for i in 0..<13 {
            let r = buttonRect(i)
            if p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h { return i }
        }
        return nil
    }

    func minimapRect() -> (x: Float, y: Float, w: Float, h: Float, s: Float) {
        let s = min(180 / Float(terrain.w), 40 / Float(terrain.h))
        let w = Float(terrain.w) * s, h = Float(terrain.h) * s
        return (454 + (180 - w) / 2, 314 + (40 - h) / 2, w, h, s)
    }

    func inMinimap(_ p: SIMD2<Float>) -> Bool {
        let m = minimapRect()
        return p.x >= m.x && p.x < m.x + m.w && p.y >= m.y && p.y < m.y + m.h
    }

    func moveCamToMinimap(_ p: SIMD2<Float>) {
        let m = minimapRect()
        camTarget = max(0, min(Float(max(0, terrain.w - 640)), (p.x - m.x) / m.s - 320))
    }

    func inRect(_ p: SIMD2<Float>, _ r: (x: Float, y: Float, w: Float, h: Float)) -> Bool {
        p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h
    }

    func titleButtons() -> [(id: String, label: String, x: Float, y: Float, w: Float, h: Float)] {
        [("play", unlocked > 1 ? "Continue  ·  Level \(unlocked)" : "Play", 215, logoY + 102, 210, 32),
         ("levels", "Levels", 245, logoY + 140, 150, 26),
         ("quit", "Quit", 275, logoY + 172, 90, 22)]
            .map { (id: $0.0, label: $0.1, x: $0.2, y: $0.3, w: $0.4, h: $0.5) }
    }

    static let perPage = 60
    func tileRect(_ i: Int) -> (x: Float, y: Float, w: Float, h: Float) {
        let k = i - page * Game.perPage
        return (36 + Float(k % 10) * 57, 66 + Float(k / 10) * 36, 52, 31)
    }
    var pageCount: Int { (levels.count + Game.perPage - 1) / Game.perPage }

    func selectButtons() -> [(id: String, label: String, x: Float, y: Float, w: Float, h: Float)] {
        var b: [(String, String, Float, Float, Float, Float)] = [("back", "BACK", 36, 290, 90, 24)]
        if page > 0 { b.append(("prev", "< PREV", 390, 290, 100, 24)) }
        if page < pageCount - 1 { b.append(("next", "NEXT >", 500, 290, 100, 24)) }
        return b.map { (id: $0.0, label: $0.1, x: $0.2, y: $0.3, w: $0.4, h: $0.5) }
    }

    func resultButtons() -> [(id: String, label: String, x: Float, y: Float, w: Float, h: Float)] {
        var b: [(String, String, Float, Float, Float, Float)] = [("retry", "RETRY", 130, 272, 110, 28)]
        if success && levelIndex + 1 < levels.count { b.append(("next", "NEXT LEVEL", 265, 272, 110, 28)) }
        b.append(("menu", "MENU", 400, 272, 110, 28))
        return b.map { (id: $0.0, label: $0.1, x: $0.2, y: $0.3, w: $0.4, h: $0.5) }
    }

    // MARK: input

    func mouseMoved(_ p: SIMD2<Float>) {
        mouse = p
        if draggingMinimap { moveCamToMinimap(p) }
        var hov = ""
        switch screen {
        case .title: hov = titleButtons().first { inRect(p, ($0.x, $0.y, $0.w, $0.h)) }?.id ?? ""
        case .levelSelect:
            hov = selectButtons().first { inRect(p, ($0.x, $0.y, $0.w, $0.h)) }?.id ?? ""
            if hov.isEmpty {
                for i in (page * Game.perPage)..<min(levels.count, (page + 1) * Game.perPage) where inRect(p, tileRect(i)) { hov = "t\(i)" }
            }
        case .results: hov = resultButtons().first { inRect(p, ($0.x, $0.y, $0.w, $0.h)) }?.id ?? ""
        case .playing: hov = buttonAt(p).map { "b\($0)" } ?? ""
        default: break
        }
        if hov != lastHover && !hov.isEmpty { sfx("hover", 0.25, cooldown: 0.02) }
        lastHover = hov
    }

    func mouseDown(_ p: SIMD2<Float>, right: Bool) {
        mouse = p
        mouseIsDown = true
        switch screen {
        case .splash:
            sfx("click", 0.4)
            setScreen(.title)
        case .title:
            for b in titleButtons() where inRect(p, (b.x, b.y, b.w, b.h)) {
                sfx("click", 0.4)
                switch b.id {
                case "play": loadLevel(unlocked - 1); setScreen(.briefing)
                case "levels": setScreen(.levelSelect)
                default: NSAppTerminate()
                }
            }
        case .levelSelect:
            for b in selectButtons() where inRect(p, (b.x, b.y, b.w, b.h)) {
                sfx("click", 0.4)
                switch b.id {
                case "prev": page -= 1
                case "next": page += 1
                default: setScreen(.title)
                }
                return
            }
            for i in (page * Game.perPage)..<min(levels.count, (page + 1) * Game.perPage) where inRect(p, tileRect(i)) {
                if i < unlocked {
                    sfx("click", 0.4)
                    loadLevel(i)
                    setScreen(.briefing)
                } else {
                    sfx("hmm", 0.3)
                }
            }
        case .briefing:
            startPlaying()
        case .playing:
            if p.y < 300 {
                if let h = hogAt(p.x + floor(camX), p.y) {
                    if !assign(Skill(rawValue: selected)!, h) { sfx("hmm", 0.25, cooldown: 0.3) }
                }
            } else if let b = buttonAt(p) {
                pressButton(b)
            } else if inMinimap(p) {
                draggingMinimap = true
                moveCamToMinimap(p)
            }
        case .results:
            for b in resultButtons() where inRect(p, (b.x, b.y, b.w, b.h)) { resultAction(b.id) }
        }
    }

    func mouseUp() {
        mouseIsDown = false
        heldButton = -1
        draggingMinimap = false
    }

    func pressButton(_ b: Int) {
        switch b {
        case 0, 1:
            heldButton = b
            holdTime = 0
            changeRate(b == 0 ? -1 : 1)
        case 2...9:
            selected = b - 2
            sfx("click", 0.3)
        case 10: paused.toggle(); sfx("click", 0.3)
        case 11: nukePressed()
        case 12: fast.toggle(); sfx("click", 0.3)
        default: break
        }
    }

    func nukePressed() {
        if nuking { return }
        if time - nukeArm < 1.2 {
            nuking = true
            nukeIdx = 0
            paused = false
            sfx("nuke", 0.5)
        } else {
            nukeArm = time
            sfx("warn", 0.3)
        }
    }

    func resultAction(_ id: String) {
        sfx("click", 0.4)
        switch id {
        case "retry": loadLevel(levelIndex); setScreen(.briefing)
        case "next": loadLevel(levelIndex + 1); setScreen(.briefing)
        default: page = levelIndex / Game.perPage; setScreen(.levelSelect)
        }
    }

    func scroll(_ dx: Float, _ dy: Float) {
        if screen == .playing {
            camTarget -= (abs(dx) > abs(dy) ? dx : dy) * 4
            camTarget = max(0, min(Float(max(0, terrain.w - 640)), camTarget))
        }
    }

    func keyDown(_ code: UInt16, _ chars: String, repeat isRepeat: Bool) {
        keys.insert(code)
        if isRepeat && code != 27 && code != 24 { return }
        let c = chars.lowercased()
        if c == "m" {
            musicOn.toggle()
            audio?.musicOn = musicOn
            return
        }
        switch screen {
        case .splash:
            setScreen(.title)
        case .title:
            if code == 36 || code == 49 { loadLevel(unlocked - 1); setScreen(.briefing) }
            if c == "l" { setScreen(.levelSelect) }
            if c == "u" { unlocked = levels.count; UserDefaults.standard.set(unlocked, forKey: "unlocked"); sfx("yay", 0.5) }
            if code == 53 { NSAppTerminate() }
        case .levelSelect:
            if code == 53 { setScreen(.title) }
            if code == 123 && page > 0 { page -= 1 }
            if code == 124 && page < pageCount - 1 { page += 1 }
        case .briefing:
            if code == 53 { setScreen(.levelSelect) } else if code == 36 || code == 49 { startPlaying() }
        case .playing:
            if let n = Int(c), n >= 1, n <= 8 { selected = n - 1; sfx("click", 0.25); return }
            switch c {
            case "p", " ": paused.toggle()
            case "f": fast.toggle()
            case "n": nukePressed()
            case "r": loadLevel(levelIndex); startPlaying()
            case "-": changeRate(-5)
            case "=", "+": changeRate(5)
            default: break
            }
            if code == 53 { page = levelIndex / Game.perPage; setScreen(.levelSelect) }
        case .results:
            if code == 36 || code == 49 { resultAction(success && levelIndex + 1 < levels.count ? "next" : "retry") }
            if c == "r" { resultAction("retry") }
            if code == 53 { resultAction("menu") }
        }
    }

    func keyUp(_ code: UInt16) { keys.remove(code) }

    // MARK: splash timeline

    static let splashLetters = Array("GroundhogZ")
    static func splashLetterTime(_ i: Int) -> Double { 2.55 + Double(i) * 0.085 }

    func updateSplash(_ dt: Double) {
        let t = screenTime
        func once(_ bit: Int, _ at: Double, _ f: () -> Void) {
            if t >= at && splashEvents & (1 << bit) == 0 { splashEvents |= 1 << bit; f() }
        }
        once(0, 1.25) {
            sfx("pop", 0.6); sfx("wheee", 0.55)
            for i in 0..<10 {
                let a = Float(i) / 10 * Float.pi
                emit(Particle(kind: .smoke, x: 320 + cos(a) * 18, y: 290, vx: cos(a) * 0.9, vy: -sin(a) * 0.6 - 0.2,
                              life: 40, maxLife: 40, color: C(214, 170, 120, 0.7), size: 4))
                chunk(320 + Int.random(in: -10...10), 289)
            }
        }
        for i in 0..<Game.splashLetters.count {
            once(1 + i, Game.splashLetterTime(i) + 0.32) {
                sfx("brick", 0.25, cooldown: 0)
                for _ in 0..<3 {
                    let lx = i < splashLetterX.count ? splashLetterX[i] : 320
                    emit(Particle(kind: .spark, x: lx + .random(in: -8...8), y: splashLogoY + 40, vx: .random(in: -1.2...1.2),
                                  vy: .random(in: -1.5 ... -0.3), life: 22, maxLife: 22, color: C(255, 220, 120), size: 4, grav: 0.05))
                }
            }
        }
        once(14, 3.6) {
            sfx("yay", 0.5)
            let palette = [C(255, 90, 90), C(255, 210, 60), C(90, 200, 255), C(120, 230, 110), C(220, 120, 255)]
            for _ in 0..<60 {
                emit(Particle(kind: .confetti, x: .random(in: 120...520), y: -Renderer.originY - 5, vx: .random(in: -0.8...0.8),
                              vy: .random(in: 0.2...1.2), life: 150, maxLife: 150, color: palette.randomElement()!,
                              size: 1, grav: 0.02, rot: .random(in: 0...6), vr: .random(in: -0.3...0.3)))
            }
        }
        once(15, 2.2) { sfx("babble", 0.5) }
        splashAcc += dt
        while splashAcc >= 1.0 / 30 { splashAcc -= 1.0 / 30; updateParticles() }
        if t > 9.5 { setScreen(.title) }
    }
}
