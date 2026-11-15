import Foundation

// Procedural level generator for levels 9-101.
//
// Every generated level is a left-to-right chain of terrain obstacles. Each obstacle is
// solved by a terrain-changing skill, so the whole crowd can follow the path one "lead"
// hog cuts. The generator also writes that solution (a lead hog clears the route while a
// Bouncer on a steel pad holds the crowd, then a Kaboom releases them), and the
// `--verify` tool runs every level headlessly to prove it is beatable.

private let genNames = [
    "Hog Wild", "Burrow Ugh", "Dig Deep", "Tunnel Vision", "Shadow Boxing", "Carrot Top", "Soil Searching",
    "Clod Almighty", "Burrowed Time", "Gopher Broke", "Lawn and Order", "Hole in One", "Mud Pie in the Sky",
    "Pothole Pandemonium", "The Dirt Show", "Rodent Rhapsody", "Earthworm Jam", "Trench Coat", "Sod Off",
    "The Grass Menagerie", "Weasel Words", "Out on a Ledge", "Pit Stop", "Steel My Heart", "Floor Show",
    "The Moss Effect", "Six Feet Over", "Drop Zone", "Hedge Fund", "Lost and Ground", "Rock Bottom",
    "Down to Earth", "Hogwash", "The Hole Truth", "Mole Patrol", "Ground Control", "Spring Cleaning",
    "Shovel Ready", "Bog Standard", "Rooted", "Crater Expectations", "Gravel Gravy", "Furry Road",
    "Hog Heaven", "Peak Performance", "Ups and Downs", "Clay Day", "Dirt Cheap", "Terra Firma",
    "Topsoil Turmoil", "Pebble Dash", "The Big Dig", "Cliffhanger", "Stairway to Hogs", "Muddy Waters",
    "Root of All Evil", "Plot Twist", "Buried Treasure", "Underground Overground", "Fault Line", "Cold Feet",
    "Frost Bitten", "Snow Way Out", "Ice Ice Hogby", "Leaf It Out", "Fallen Leaves", "Harvest Hustle",
    "Night Shift", "Moonlit Mayhem", "Star Struck", "Owl Be Back", "Firefly Fiasco", "Nocturnal Nonsense",
    "The Long Burrow", "Hogs and Kisses", "Snout of Bounds", "Paws for Thought", "Whisker Away",
    "Teeth First", "Chubby Checkpoints", "The Great Waddle", "Marmot Mayhem", "Woodchuck Chuckles",
    "How Much Wood", "Weather or Not", "Forecast: Chaos", "Shadow of a Doubt", "Early Spring",
    "The Last Burrow", "Hog Day Afternoon", "Burrow Wars", "The Groundhog Gauntlet", "Spring Has Sprung",
]

private let jokes = [
    "Somewhere, a meteorologist is very nervous.",
    "These hogs have one brain cell and they take turns with it.",
    "Every hog lost is a hog that can no longer forecast the weather.",
    "The burrow has snacks. The hogs do not know this yet.",
    "Union rules require at least one dramatic explosion per shift.",
    "Fun fact: real groundhogs can climb trees. Yours are special.",
    "Spring is coming. Probably. If you hurry.",
    "No hogs were harmed in the making of this level. Several will be in the playing of it.",
    "A groundhog's favourite direction is forward, regardless of what is there.",
    "Today's forecast: eighty percent chance of hogs.",
    "The carrots were donated by a very confused farmer.",
    "Dig like nobody's watching. Everyone is watching.",
    "They are not lost. They are exploring aggressively.",
    "Every great journey begins with a single, mindless waddle.",
    "Warning: contains walls, holes and poor decision-making.",
    "Six more weeks of winter is a choice. Make better choices.",
    "The hogs have unionised. Their only demand is snacks.",
    "Gary has volunteered to go first. Nobody asked Gary.",
    "Mind the steel. It does not mind you.",
    "If you listen closely you can hear them thinking. It is mostly humming.",
    "This level was designed by a hog. It shows.",
    "Remember: the brolly is a tool, not a fashion statement. It is also a fashion statement.",
    "The burrow's welcome mat says 'Wipe your paws'. Nobody ever does.",
    "Hogs dig. You think. It's a partnership.",
]

private func hint(_ k: String) -> String {
    switch k {
    case "wall": return "A wall! Punchers love walls."
    case "gap": return "Water ahead. Stack carrots across it."
    case "pit": return "A bottomless-ish pit. Stack carrots across."
    case "ledge": return "That ledge is too tall to hop. Stairs, anyone?"
    case "fence": return "Steel fences can't be punched, but stairs go over anything."
    case "dig": return "Steel blocks the way, but the floor looks diggable..."
    case "cliff": return "That cliff is deadly. A Pickaxe tunnel takes the edge off."
    case "brolly": return "Long way down. Brollies for everyone."
    case "climb": return "A sheer cliff. Every hog needs to Scramble."
    default: return ""
    }
}

func generateLevels() -> [LevelDef] { (0..<93).map { genLevel($0) } }

func genLevel(_ n: Int) -> LevelDef {
    var rng = Rng(UInt64(n) &* 7919 &+ 1234)
    let d = Double(n) / 92
    let themes: [Theme] = [.spring, .autumn, .winter, .night]
    let theme = themes[(n / 3) % 4]
    let brollyLevel = n % 9 == 4
    let climbLevel = n % 9 == 7
    var count = 10 + Int(d * 36) + rng.int(0, 6)
    if brollyLevel || climbLevel { count = min(count, 12 + Int(d * 12)) }

    var ops: [(Terrain) -> Void] = []
    var rules: [SimRule] = []
    var skills = [Int](repeating: 0, count: 8)
    var water: [Water] = []
    var kinds: [String] = []
    var seed = n * 31

    func flat(_ x0: Int, _ x1: Int, _ g: Int, _ amp: Float = 2) {
        seed += 1
        let s = seed
        ops.append { t in t.ground(x0, x1, bumpy(g, amp, s, 0.04)) }
    }

    // start area: entrance, crowd pen and the bouncer's steel pad
    var G = brollyLevel ? rng.int(72, 95) : (climbLevel ? rng.int(190, 230) : rng.int(150, 200))
    let startW = rng.int(132, 160)
    let entX = rng.int(36, 56)
    let blockX = startW - 34
    let G0 = G
    ops.append { t in t.fill(0, G0, startW, 300 - G0) }
    ops.append { t in t.fill(blockX - 18, G0, 36, 8, Mat.steel) }
    rules.append(SimRule(skill: .blocker, x: blockX, dir: 1, hog: 1))
    rules.append(SimRule(skill: .bomber, x: blockX, saved: 1))
    skills[Skill.blocker.rawValue] += 1
    skills[Skill.bomber.rawValue] += 1
    var x = startW

    if brollyLevel {
        let G2 = rng.int(205, 245)
        flat(x, x + 70, G2)
        x += 70; G = G2
        rules.append(SimRule(skill: .floater, times: count))
        skills[Skill.floater.rawValue] += count
        kinds.append("brolly")
    } else if climbLevel {
        let h = rng.int(55, min(95, G - 70))
        let cx = x + 40
        flat(x, cx, G)
        flat(cx, cx + 60, G - h)
        x = cx + 60; G -= h
        rules.append(SimRule(skill: .climber, times: count))
        skills[Skill.climber.rawValue] += count
        kinds.append("climb")
    }

    let nObs = min(7, 1 + Int(d * 5.5) + (rng.chance(0.35) ? 1 : 0))
    var last = ""
    for _ in 0..<nObs {
        // filler: a little run of ground, sometimes with a safe step down
        let run = rng.int(24, 60)
        flat(x, x + run, G)
        x += run
        if rng.chance(0.25) && G + 40 < 250 {
            let drop = rng.int(14, 36)
            G += drop
            flat(x, x + 30, G)
            x += 30
        }

        var cands: [String] = []
        if G >= 64 { cands.append("wall") }
        if G <= 236 { cands.append("dig") }
        if n >= 2 && G <= 236 { cands.append("gap") }
        if n >= 6 && G - 9 >= 72 { cands.append("ledge") }
        if n >= 10 { cands.append("fence") }
        if n >= 14 && G + 72 <= 270 { cands.append("cliff") }
        if cands.count > 1 { cands.removeAll { $0 == last } }
        let k = rng.pick(cands)
        last = k
        kinds.append(k)

        switch k {
        case "wall":
            let approach = rng.int(30, 50)
            let T = rng.int(8, 26 + Int(d * 12))
            let H = rng.int(18, min(72, G - 42))
            let wx = x + approach
            flat(x, wx + T + 34, G)
            let g = G
            let cap = H > 36 && rng.chance(0.45)
            ops.append { t in
                t.fill(wx, g - H, T, H + 4)
                t.fillEllipse(wx + T / 2, g - H, max(2, T / 2), 4)
                if cap { t.fill(wx, g - H - 4, T, H - 18 + 4, Mat.steel) }
            }
            rules.append(SimRule(skill: .basher, x: wx - 6, dir: 1, hog: 0))
            skills[Skill.basher.rawValue] += 1
            x = wx + T + 34
        case "gap":
            let nb = (d > 0.35 && rng.chance(0.5)) ? 2 : 1
            let Wg = nb == 1 ? rng.int(14, 22) : rng.int(30, 46)
            let approach = rng.int(30, 50)
            let gx = x + approach
            flat(x, gx, G, 1)
            let G2 = G + rng.int(0, 6)
            let dry = G <= 215 && rng.chance(0.4)
            if dry {
                ops.append { t in t.fill(gx, 296, Wg, 4) }
                kinds[kinds.count - 1] = "pit"
            } else {
                let top = min(286, G + rng.int(45, 70))
                ops.append { t in t.fill(gx, 292, Wg, 8) }
                water.append(Water(x0: gx, x1: gx + Wg, top: top))
            }
            flat(gx + Wg, gx + Wg + 40, G2)
            rules.append(SimRule(skill: .builder, x: gx - 3, dir: 1, hog: 0))
            if nb == 2 { rules.append(SimRule(skill: .builder, x: gx + 24, dir: 1, hog: 0)) }
            skills[Skill.builder.rawValue] += nb
            x = gx + Wg + 40
            G = G2
        case "ledge":
            let nb = (d > 0.45 && rng.chance(0.4) && G - 28 >= 72) ? 2 : 1
            let h = nb == 1 ? rng.int(9, 16) : rng.int(20, 26)
            let lx = x + (nb == 1 ? 34 : 60) + rng.int(0, 10)
            flat(x, lx, G, 1)
            flat(lx, lx + 40, G - h)
            let s = lx - (nb == 1 ? 27 : 55)
            rules.append(SimRule(skill: .builder, x: s, dir: 1, hog: 0))
            if nb == 2 { rules.append(SimRule(skill: .builder, x: s + 27, dir: 1, hog: 0)) }
            skills[Skill.builder.rawValue] += nb
            x = lx + 40
            G -= h
        case "fence":
            let hf = rng.int(12, 16), T = rng.int(6, 10)
            let fx = x + 40 + rng.int(0, 10)
            flat(x, fx + T + 50, G, 1)
            let g = G
            ops.append { t in t.fill(fx, g - hf, T, hf + 8, Mat.steel) }
            rules.append(SimRule(skill: .builder, x: fx - 27, dir: 1, hog: 0))
            skills[Skill.builder.rawValue] += 1
            x = fx + T + 50
        case "dig":
            let Tf = rng.int(10, 20)
            let Hc = rng.int(18, min(54 - Tf, 266 - G - Tf))
            let G2 = G + Tf + Hc
            let sx = x + rng.int(50, 70)
            let g = G, x0 = x
            seed += 1
            let s = seed
            ops.append { t in
                t.ground(x0, sx + 60, bumpy(G2, 2, s, 0.04))
                t.slab(x0, g, sx - x0, Tf, rough: 3, seed: s)
                t.fill(sx, g - 50, 10, 50 + Tf, Mat.steel)
            }
            rules.append(SimRule(skill: .digger, x: sx - 14, dir: 1, hog: 0))
            skills[Skill.digger.rawValue] += 1
            x = sx + 60
            G = G2
        default: // cliff
            let dd = rng.int(72, min(100, 270 - G))
            let cx = x + (dd - 35) + rng.int(20, 40)
            let s = cx - (dd - 35)
            flat(x, cx, G, 1)
            flat(cx, cx + 50, G + dd)
            rules.append(SimRule(skill: .miner, x: s, dir: 1, hog: 0))
            skills[Skill.miner.rawValue] += 1
            x = cx + 50
            G += dd
        }
    }

    // home stretch
    let width = max(x + 100, 640)
    flat(x, width, G)
    let exitX = width - 50

    // slack skills + a distraction
    let slack = d < 0.3 ? 2 : (d < 0.65 ? 1 : 0)
    for i in 0..<8 where skills[i] > 0 { skills[i] += slack }
    if rng.chance(0.55) { skills[rng.int(0, 7)] += rng.int(1, 3) }

    let rate = (brollyLevel || climbLevel) ? rng.int(25, 40) : min(85, 35 + Int(d * 40) + rng.int(0, 10))
    let interval = max(4, 4 + (99 - rate) * 56 / 98)
    let secs = Double(width) * 2.6 / 30 + 40 + Double(count * interval) / 30 + Double(nObs) * 14
    let minutes = max(2, Int(ceil(secs / 60)))
    var need = 45 + Int(d * 45)
    need = (need / 5) * 5
    if brollyLevel || climbLevel { need = min(need, 80) }

    var parts = [rng.pick(jokes)]
    for k in Array(Set(kinds)).sorted().prefix(2) { parts.append(hint(k)) }
    if n < 8 { parts.append("Tip: a Bouncer near the crate holds the crowd while one brave hog clears the way.") }

    // optional mirror
    let mirror = n >= 3 && rng.chance(0.5)
    var entrance = (x: entX, y: G0 - 46)
    var exitPos = (x: exitX, y: G - 12)
    if mirror {
        entrance.x = width - 1 - entX
        exitPos.x = width - 1 - exitX
        water = water.map { Water(x0: width - $0.x1, x1: width - $0.x0, top: $0.top) }
        rules = rules.map { r in
            var q = r
            if let xx = r.x { q.x = width - 1 - xx }
            if let dd = r.dir { q.dir = -dd }
            return q
        }
    }
    let allOps = ops
    return LevelDef(
        name: n < genNames.count ? genNames[n] : "Burrow \(n + 9)",
        tagline: parts.joined(separator: " "),
        width: width, count: count, need: need, rate: rate, minutes: minutes,
        skills: skills, entrance: entrance, exit: exitPos, theme: theme, water: water,
        build: { t in
            for op in allOps { op(t) }
            if mirror { t.mirror() }
        },
        solution: rules)
}
