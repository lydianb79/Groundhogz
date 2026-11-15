import Foundation

struct Water { var x0: Int; var x1: Int; var top: Int }

struct Theme {
    var skyTop: RGBA, skyBottom: RGBA, hillA: RGBA, hillB: RGBA
    var grass: (Int, Int, Int), dirtA: (Int, Int, Int), dirtB: (Int, Int, Int)
    var water: RGBA
    var night = false
    var snow = false
    var id = 0
    var name = "spring"

    static let spring = Theme(skyTop: C(70, 150, 245), skyBottom: C(214, 238, 255), hillA: C(130, 196, 140), hillB: C(78, 156, 88),
                              grass: (98, 190, 62), dirtA: (156, 104, 60), dirtB: (126, 82, 46), water: C(50, 130, 220))
    static let winter = Theme(skyTop: C(118, 156, 214), skyBottom: C(232, 240, 250), hillA: C(210, 224, 242), hillB: C(170, 194, 226),
                              grass: (244, 248, 255), dirtA: (128, 104, 92), dirtB: (104, 84, 76), water: C(80, 140, 205),
                              snow: true, id: 1, name: "winter")
    static let autumn = Theme(skyTop: C(236, 132, 84), skyBottom: C(255, 224, 168), hillA: C(210, 130, 80), hillB: C(146, 78, 48),
                              grass: (214, 140, 46), dirtA: (138, 90, 54), dirtB: (110, 68, 40), water: C(60, 110, 170),
                              id: 2, name: "autumn")
    static let night = Theme(skyTop: C(8, 10, 34), skyBottom: C(46, 44, 96), hillA: C(34, 38, 80), hillB: C(22, 26, 56),
                             grass: (70, 140, 96), dirtA: (120, 86, 64), dirtB: (98, 70, 52), water: C(40, 76, 170),
                             night: true, id: 3, name: "night")
}

/// A scripted assignment used by the headless simulator to prove a level is solvable.
struct SimRule {
    var skill: Skill
    var x: Int? = nil
    var t: Int? = nil
    var dir: Int? = nil
    var times = 1
    var hog: Int? = nil
    var saved: Int? = nil
}

struct LevelDef {
    var name: String
    var tagline: String
    var width: Int
    var count: Int
    var need: Int          // percent
    var rate: Int          // release rate 1...99
    var minutes: Int
    var skills: [Int]      // climber, floater, bomber, blocker, builder, basher, miner, digger
    var entrance: (x: Int, y: Int)   // bottom-centre of the crate
    var exit: (x: Int, y: Int)       // scan down from here for the ground
    var theme: Theme
    var water: [Water] = []
    var build: (Terrain) -> Void
    var solution: [SimRule] = []
}

func bumpy(_ base: Int, _ amp: Float, _ seed: Int, _ freq: Float = 0.03) -> (Int) -> Int {
    return { x in base + Int(noise1(Float(x) * freq, seed) * amp) }
}

let levels: [LevelDef] = handLevels + generateLevels()

let handLevels: [LevelDef] = [
    LevelDef(
        name: "Just Dig It",
        tagline: "Groundhogs dig. It is literally in the job description. Click a hog, make it dig, feel like a manager.",
        width: 640, count: 10, need: 50, rate: 50, minutes: 5,
        skills: [0, 0, 0, 0, 0, 0, 0, 10],
        entrance: (150, 76), exit: (470, 150), theme: .spring,
        build: { t in
            t.ground(0, 640, bumpy(170, 4, 1))
            t.fillEllipse(110, 182, 70, 14)
            t.fillEllipse(560, 186, 60, 16)
            t.slab(40, 120, 560, 20, rough: 4, seed: 3)
            t.fill(40, 72, 14, 50)
            t.fill(586, 72, 14, 50)
            t.fillEllipse(320, 122, 34, 6)
        }, solution: [SimRule(skill: .digger, x: 200)]),
    LevelDef(
        name: "Wall Street",
        tagline: "Some walls just need a firm talking-to. With fists. Punch them when the hog is close to the wall.",
        width: 800, count: 15, need: 60, rate: 50, minutes: 5,
        skills: [0, 0, 0, 0, 0, 5, 0, 0],
        entrance: (90, 174), exit: (700, 200), theme: .spring,
        build: { t in
            t.ground(0, 800, bumpy(220, 4, 2, 0.04))
            t.fill(256, 132, 28, 92)
            t.fillEllipse(270, 134, 14, 6)
            t.fill(470, 110, 44, 112)
            t.fillEllipse(492, 112, 22, 8)
            t.fillEllipse(380, 226, 40, 10)
        }, solution: [SimRule(skill: .basher, x: 250, dir: 1), SimRule(skill: .basher, x: 462, dir: 1)]),
    LevelDef(
        name: "Mind The Gap",
        tagline: "Carrots: high in vitamin A, surprisingly load-bearing. Stack them over the water. Hogs cannot swim. At all.",
        width: 800, count: 12, need: 60, rate: 40, minutes: 5,
        skills: [0, 0, 2, 2, 6, 0, 0, 0],
        entrance: (70, 154), exit: (660, 170), theme: .spring,
        water: [Water(x0: 330, x1: 380, top: 262)],
        build: { t in
            t.ground(0, 330, bumpy(200, 2, 4))
            t.ground(380, 800, bumpy(188, 2, 5))
            t.fill(330, 282, 50, 18)
            t.fillEllipse(600, 196, 50, 12)
        }, solution: [SimRule(skill: .builder, x: 326, dir: 1, hog: 0), SimRule(skill: .blocker, x: 120, dir: 1, hog: 1), SimRule(skill: .builder, x: 353, dir: 1, hog: 0), SimRule(skill: .bomber, x: 120, saved: 1)]),
    LevelDef(
        name: "Six More Weeks Of Falling",
        tagline: "The groundhog saw its shadow. Then it saw the ground. Very quickly. Brollies, please. Then scramble.",
        width: 640, count: 10, need: 80, rate: 30, minutes: 5,
        skills: [10, 10, 0, 0, 0, 0, 0, 0],
        entrance: (60, 36), exit: (560, 250), theme: .winter,
        build: { t in
            t.ground(0, 640, bumpy(268, 3, 6))
            t.slab(0, 80, 222, 20, rough: 5, seed: 8)
            t.fill(430, 200, 22, 72)
            t.fillEllipse(441, 200, 11, 5)
            t.fillEllipse(250, 276, 50, 12)
        }, solution: [SimRule(skill: .floater, times: 10), SimRule(skill: .climber, times: 10)]),
    LevelDef(
        name: "Hold Your Hogs",
        tagline: "Sometimes the bravest thing a hog can do is stand there in sunglasses looking cool.",
        width: 640, count: 20, need: 80, rate: 50, minutes: 5,
        skills: [0, 0, 1, 2, 0, 2, 0, 0],
        entrance: (330, 154), exit: (60, 190), theme: .spring,
        water: [Water(x0: 470, x1: 560, top: 268)],
        build: { t in
            t.ground(0, 640, bumpy(200, 3, 7))
            t.clear(470, 180, 90, 120)
            t.fill(470, 290, 90, 10)
            t.fill(160, 174, 14, 28)
            t.fillEllipse(167, 175, 7, 3)
        }, solution: [SimRule(skill: .blocker, x: 345, dir: 1), SimRule(skill: .basher, x: 178, dir: -1)]),
    LevelDef(
        name: "Steel Yourself",
        tagline: "Steel: the only thing tougher than a groundhog's will to nap. You cannot dig it. You can go around it.",
        width: 800, count: 20, need: 75, rate: 50, minutes: 6,
        skills: [0, 0, 0, 1, 0, 4, 3, 3],
        entrance: (150, 104), exit: (120, 190), theme: .autumn,
        build: { t in
            t.ground(0, 800, bumpy(203, 2, 9))
            t.fill(0, 150, 800, 25)
            t.slab(0, 171, 800, 4, rough: 4, seed: 10)
            t.fill(0, 165, 520, 10, Mat.steel)
            t.fill(400, 60, 40, 90)
            t.fill(400, 60, 40, 64, Mat.steel)
            t.fill(300, 184, 16, 22)
            t.fillEllipse(308, 184, 8, 3)
        }, solution: [SimRule(skill: .basher, x: 390, dir: 1), SimRule(skill: .digger, x: 600, dir: 1), SimRule(skill: .basher, x: 324, t: 1400, dir: -1)]),
    LevelDef(
        name: "Kaboom Burrow",
        tagline: "When life gives you walls, make craters. Tip: a Bouncer right against the wall makes a fine Kaboom.",
        width: 640, count: 20, need: 85, rate: 60, minutes: 5,
        skills: [0, 0, 3, 3, 0, 0, 0, 0],
        entrance: (210, 152), exit: (560, 190), theme: .night,
        build: { t in
            t.fill(0, 214, 640, 86)
            t.fill(420, 200, 220, 14)
            t.fill(80, 200, 340, 14, Mat.steel)
            t.fill(80, 110, 12, 90)
            t.fill(330, 110, 10, 90)
            t.fillEllipse(86, 110, 6, 4)
            t.fillEllipse(335, 110, 5, 4)
        }, solution: [SimRule(skill: .blocker, x: 329, dir: 1), SimRule(skill: .bomber, x: 329, t: 500)]),
    LevelDef(
        name: "The Grand Hogfather",
        tagline: "Every skill. Every hog. Zero chill. Dig down, stack across, punch through, stack again. Good luck.",
        width: 1200, count: 30, need: 60, rate: 40, minutes: 8,
        skills: [2, 2, 2, 4, 10, 4, 3, 4],
        entrance: (70, 64), exit: (1120, 190), theme: .spring,
        water: [Water(x0: 430, x1: 480, top: 250), Water(x0: 960, x1: 1010, top: 250)],
        build: { t in
            t.slab(0, 110, 270, 20, rough: 3, seed: 11)
            t.fill(256, 80, 14, 30)
            t.ground(0, 430, bumpy(160, 2, 12))
            t.fill(430, 282, 50, 18)
            t.ground(480, 900, bumpy(150, 2, 13))
            t.fill(640, 60, 34, 94)
            t.fill(640, 60, 34, 60, Mat.steel)
            t.ground(900, 1200, bumpy(198, 2, 14))
            t.clear(960, 190, 50, 80)
        }, solution: [SimRule(skill: .blocker, x: 200, dir: 1, hog: 1), SimRule(skill: .digger, x: 150, hog: 0), SimRule(skill: .blocker, x: 100, dir: 1, hog: 2), SimRule(skill: .builder, x: 426, dir: 1, hog: 0), SimRule(skill: .builder, x: 453, dir: 1, hog: 0), SimRule(skill: .basher, x: 630, dir: 1, hog: 0), SimRule(skill: .builder, x: 956, dir: 1, hog: 0), SimRule(skill: .builder, x: 983, dir: 1, hog: 0), SimRule(skill: .bomber, x: 200, saved: 1), SimRule(skill: .bomber, x: 100, saved: 1)]),
]
