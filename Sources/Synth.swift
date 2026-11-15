import Foundation

// A small offline synthesizer: oscillators, filters, envelopes, instruments, drums,
// a formant "hog voice", an algorithmic composer and ambience generators.

let SR = 44100.0

struct Rng {
    var s: UInt64
    init(_ seed: UInt64) { s = seed &* 0x9E3779B97F4A7C15 &+ 0x632BE59BD9B4E019 }
    mutating func next() -> UInt64 {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func f() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * f() }
    mutating func int(_ a: Int, _ b: Int) -> Int { b <= a ? a : a + Int(next() % UInt64(b - a + 1)) }
    mutating func chance(_ p: Double) -> Bool { f() < p }
    mutating func pick<T>(_ a: [T]) -> T { a[int(0, a.count - 1)] }
}

struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0, z1 = 0.0, z2 = 0.0
    enum Kind { case lp, hp, bp }
    init() {}
    init(_ k: Kind, _ f: Double, _ q: Double = 0.707) { set(k, f, q) }
    mutating func set(_ k: Kind, _ f: Double, _ q: Double = 0.707) {
        let w0 = 2 * Double.pi * min(f, SR * 0.45) / SR
        let cw = cos(w0), alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        switch k {
        case .lp: b0 = (1 - cw) / 2; b1 = 1 - cw; b2 = (1 - cw) / 2
        case .hp: b0 = (1 + cw) / 2; b1 = -(1 + cw); b2 = (1 + cw) / 2
        case .bp: b0 = alpha; b1 = 0; b2 = -alpha
        }
        a1 = -2 * cw; a2 = 1 - alpha
        b0 /= a0; b1 /= a0; b2 /= a0; a1 /= a0; a2 /= a0
    }
    @inline(__always) mutating func run(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

@inline(__always) func polyblep(_ t: Double, _ dt: Double) -> Double {
    if t < dt { let x = t / dt; return x + x - x * x - 1 }
    if t > 1 - dt { let x = (t - 1) / dt; return x * x + x + x + 1 }
    return 0
}

struct Osc {
    var ph = 0.0
    @inline(__always) mutating func saw(_ f: Double) -> Double {
        let dt = f / SR
        let v = 2 * ph - 1 - polyblep(ph, dt)
        ph += dt; if ph >= 1 { ph -= 1 }
        return v
    }
    @inline(__always) mutating func pulse(_ f: Double, _ duty: Double) -> Double {
        let dt = f / SR
        var v = ph < duty ? 1.0 : -1.0
        v += polyblep(ph, dt)
        var t2 = ph + 1 - duty; if t2 >= 1 { t2 -= 1 }
        v -= polyblep(t2, dt)
        ph += dt; if ph >= 1 { ph -= 1 }
        return v
    }
    @inline(__always) mutating func sine(_ f: Double) -> Double {
        let v = sin(2 * Double.pi * ph)
        ph += f / SR; if ph >= 1 { ph -= 1 }
        return v
    }
    @inline(__always) mutating func tri(_ f: Double) -> Double {
        let v = 4 * abs(ph - 0.5) - 1
        ph += f / SR; if ph >= 1 { ph -= 1 }
        return v
    }
}

@inline(__always) func adsr(_ t: Double, _ a: Double, _ d: Double, _ s: Double, _ r: Double, _ len: Double) -> Double {
    var v: Double
    if t < a { v = t / a } else if t < a + d { v = 1 - (1 - s) * (t - a) / d } else { v = s }
    if t > len { v *= max(0, 1 - (t - len) / r) }
    return v
}

func mtof(_ m: Double) -> Double { 440 * pow(2, (m - 69) / 12) }

/// Stereo accumulation buffer. Optionally wraps (for seamless loops).
final class Mix {
    var l: [Float], r: [Float]
    let n: Int
    var wrap = false
    init(_ seconds: Double) { n = max(1, Int(seconds * SR)); l = [Float](repeating: 0, count: n); r = l }
    @inline(__always) func add(_ i: Int, _ v: Double, _ pan: Double = 0) {
        var j = i
        if j >= n { if wrap { j %= n } else { return } }
        if j < 0 { return }
        let a = (pan + 1) * Double.pi / 4
        l[j] += Float(v * cos(a) * 1.414)
        r[j] += Float(v * sin(a) * 1.414)
    }
    func addMono(_ s: [Float], at: Int, gain: Double, pan: Double = 0) {
        let a = (pan + 1) * Double.pi / 4
        let gl = Float(gain * cos(a) * 1.414), gr = Float(gain * sin(a) * 1.414)
        for (k, v) in s.enumerated() {
            var j = at + k
            if j >= n { if wrap { j %= n } else { break } }
            l[j] += v * gl; r[j] += v * gr
        }
    }
    func normalize(_ peak: Float = 0.9, soft: Bool = true) {
        if soft { for i in 0..<n { l[i] = tanhf(l[i] * 1.1); r[i] = tanhf(r[i] * 1.1) } }
        var m: Float = 0.0001
        for i in 0..<n { m = max(m, abs(l[i]), abs(r[i])) }
        let k = peak / m
        for i in 0..<n { l[i] *= k; r[i] *= k }
    }
    /// Ping-pong delay.
    func delay(_ time: Double, fb: Float, mixAmt: Float) {
        let d = Int(time * SR)
        guard d > 0 && d < n else { return }
        var dl = [Float](repeating: 0, count: n), dr = dl
        for i in 0..<n {
            let j = i - d
            let il = j >= 0 ? dr[j] : (wrap ? dr[(j + n) % n] : 0)
            let ir = j >= 0 ? dl[j] : (wrap ? dl[(j + n) % n] : 0)
            dl[i] = l[i] * 0.5 + il * fb
            dr[i] = r[i] * 0.5 + ir * fb
        }
        for i in 0..<n { l[i] += dl[i] * mixAmt; r[i] += dr[i] * mixAmt }
    }
}

// MARK: - instruments (mono note renderers)

enum Inst { case lead, bell, pluck, epiano, bass, pad, brass, marimba }

func renderNote(_ inst: Inst, _ freq: Double, _ len: Double, _ vel: Double, _ rng: inout Rng) -> [Float] {
    let tail: Double
    switch inst {
    case .bell: tail = 1.6
    case .pluck: tail = 1.2
    case .epiano: tail = 0.8
    case .pad: tail = 0.7
    case .marimba: tail = 0.6
    default: tail = 0.15
    }
    let n = Int((len + tail) * SR)
    var out = [Float](repeating: 0, count: n)
    switch inst {
    case .lead:
        var o = Osc(), o2 = Osc()
        var lp = Biquad(.lp, 3800, 0.8)
        for i in 0..<n {
            let t = Double(i) / SR
            let vib = 1 + 0.005 * sin(2 * .pi * 5.6 * t) * min(1, max(0, (t - 0.12) * 5))
            let duty = 0.32 + 0.12 * sin(2 * .pi * 0.7 * t)
            let v = o.pulse(freq * vib, duty) * 0.7 + o2.saw(freq * vib * 1.004) * 0.25
            out[i] = Float(lp.run(v) * adsr(t, 0.006, 0.12, 0.7, 0.12, len) * vel)
        }
    case .brass:
        var o = Osc(), o2 = Osc()
        var lp = Biquad()
        for i in 0..<n {
            let t = Double(i) / SR
            if i % 64 == 0 { lp.set(.lp, 600 + 3000 * min(1, t * 8) * adsr(t, 0.05, 0.3, 0.6, 0.2, len), 1.2) }
            let v = o.saw(freq) * 0.6 + o2.saw(freq * 1.006) * 0.5
            out[i] = Float(lp.run(v) * adsr(t, 0.03, 0.15, 0.8, 0.15, len) * vel)
        }
    case .bell:
        var c = Osc(), m = Osc(), c2 = Osc()
        for i in 0..<n {
            let t = Double(i) / SR
            let idx = 2.4 * exp(-t * 5)
            let mod = m.sine(freq * 3.5) * idx
            let v = sin(2 * .pi * c.ph + mod) * 0.7 + c2.sine(freq * 2.01) * 0.2 * exp(-t * 3)
            c.ph += freq / SR; if c.ph >= 1 { c.ph -= 1 }
            out[i] = Float(v * exp(-t * 2.4) * min(1, t * 400) * vel)
        }
    case .marimba:
        var c = Osc(), m = Osc()
        for i in 0..<n {
            let t = Double(i) / SR
            let mod = m.sine(freq * 4) * 1.5 * exp(-t * 30)
            let v = sin(2 * .pi * c.ph + mod)
            c.ph += freq / SR; if c.ph >= 1 { c.ph -= 1 }
            out[i] = Float(v * exp(-t * 7) * min(1, t * 600) * vel)
        }
    case .epiano:
        var c = Osc(), m = Osc()
        for i in 0..<n {
            let t = Double(i) / SR
            let mod = m.sine(freq) * 1.3 * exp(-t * 3.5)
            let v = sin(2 * .pi * c.ph + mod) * (1 + 0.15 * sin(2 * .pi * 4.5 * t))
            c.ph += freq / SR; if c.ph >= 1 { c.ph -= 1 }
            out[i] = Float(v * adsr(t, 0.003, 1.4, 0.25, 0.4, len) * vel)
        }
    case .pluck:
        let N = max(2, Int(SR / freq))
        var ring = [Double](repeating: 0, count: N)
        var lpf = 0.0
        for k in 0..<N { lpf += (rng.range(-1, 1) - lpf) * 0.6; ring[k] = lpf }
        var idx = 0
        let damp = 0.996
        for i in 0..<n {
            let t = Double(i) / SR
            let a = ring[idx], b = ring[(idx + 1) % N]
            let v = (a + b) * 0.5 * damp
            ring[idx] = v
            idx = (idx + 1) % N
            out[i] = Float(a * vel * (t > len + 0.3 ? max(0, 1 - (t - len - 0.3) / 0.9) : 1))
        }
    case .bass:
        var o = Osc(), s = Osc()
        var lp = Biquad(.lp, 700, 1.0)
        for i in 0..<n {
            let t = Double(i) / SR
            let v = lp.run(o.saw(freq) * 0.5) + s.sine(freq) * 0.8
            out[i] = Float(v * adsr(t, 0.004, 0.2, 0.65, 0.08, len) * vel)
        }
    case .pad:
        var os = [Osc(), Osc(), Osc()]
        var lp = Biquad(.lp, 1500, 0.7)
        let det = [1.0, 1.007, 0.993]
        for i in 0..<n {
            let t = Double(i) / SR
            var v = 0.0
            for k in 0..<3 { v += os[k].saw(freq * det[k]) }
            out[i] = Float(lp.run(v / 3) * adsr(t, 0.35, 0.4, 0.8, 0.6, len) * vel)
        }
    }
    return out
}

// MARK: - drums

func kick() -> [Float] {
    let n = Int(0.35 * SR)
    var out = [Float](repeating: 0, count: n)
    var ph = 0.0
    for i in 0..<n {
        let t = Double(i) / SR
        let f = 45 + 110 * exp(-t * 30)
        ph += f / SR
        out[i] = Float(sin(2 * .pi * ph) * exp(-t * 8) + (t < 0.004 ? 0.4 : 0))
    }
    return out
}

func snare(_ rng: inout Rng) -> [Float] {
    let n = Int(0.25 * SR)
    var out = [Float](repeating: 0, count: n)
    var bp = Biquad(.bp, 1900, 0.8)
    var o = Osc()
    for i in 0..<n {
        let t = Double(i) / SR
        out[i] = Float(bp.run(rng.range(-1, 1)) * 1.6 * exp(-t * 16) + o.sine(185) * 0.5 * exp(-t * 25))
    }
    return out
}

func hat(_ rng: inout Rng, open: Bool) -> [Float] {
    let n = Int((open ? 0.3 : 0.06) * SR)
    var out = [Float](repeating: 0, count: n)
    var hp = Biquad(.hp, 7500, 0.8)
    for i in 0..<n {
        let t = Double(i) / SR
        out[i] = Float(hp.run(rng.range(-1, 1)) * exp(-t * (open ? 10 : 55)))
    }
    return out
}

func shaker(_ rng: inout Rng) -> [Float] {
    let n = Int(0.09 * SR)
    var out = [Float](repeating: 0, count: n)
    var hp = Biquad(.hp, 5000, 0.7)
    for i in 0..<n {
        let t = Double(i) / SR
        out[i] = Float(hp.run(rng.range(-1, 1)) * min(1, t * 80) * exp(-t * 40))
    }
    return out
}

// MARK: - composer

struct SongSpec {
    var bpm: Double
    var root: Int
    var minor: Bool
    var progA: [Int]
    var progB: [Int]
    var lead: Inst
    var comp: Inst
    var compStyle: Int     // 0 offbeat stabs, 1 arpeggio, 2 block chords
    var drums: Int         // 0 bouncy, 1 soft, 2 folk, 3 lofi, 4 none
    var swing: Double
    var seed: UInt64
    var pad: Bool
}

func composeSong(_ sp: SongSpec) -> Mix {
    var rng = Rng(sp.seed)
    let scale = sp.minor ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 4, 5, 7, 9, 11]
    func deg(_ d: Int) -> Int {
        let o = Int(floor(Double(d) / 7)), k = ((d % 7) + 7) % 7
        return sp.root + 12 * o + scale[k]
    }
    let beat = 60 / sp.bpm
    let bar = beat * 4
    let sections = [0, 0, 1, 0]
    let bars = sections.count * 8
    let mix = Mix(Double(bars) * bar)
    mix.wrap = true
    let lead = Mix(Double(bars) * bar)
    lead.wrap = true
    func tpos(_ barI: Int, _ eighth: Double) -> Int {
        var e = eighth
        if Int(e) % 2 == 1 && e == floor(e) { e += sp.swing }
        return Int((Double(barI) * bar + e * beat / 2) * SR)
    }

    // motifs: list of (start eighth within 2 bars, length in eighths, degree offset from chord root)
    func makeMotif(_ rng: inout Rng, high: Bool) -> [(Double, Double, Int)] {
        let rhythms: [[(Double, Double)]] = [
            [(0, 2), (2, 1), (3, 1), (4, 2), (6, 2), (8, 3), (11, 1), (12, 4)],
            [(0, 1), (1, 1), (2, 2), (4, 1), (5, 1), (6, 2), (8, 2), (10, 2), (12, 3)],
            [(0, 3), (3, 1), (4, 2), (6, 1), (7, 1), (8, 4), (12, 2), (14, 2)],
            [(1, 1), (2, 1), (3, 1), (4, 2), (6, 2), (9, 1), (10, 2), (12, 4)],
            [(0, 2), (2, 2), (4, 1), (5, 1), (6, 1), (7, 1), (8, 6), (14, 2)],
        ]
        let r = rng.pick(rhythms)
        var cur = high ? rng.int(4, 7) : rng.int(2, 4)
        var out: [(Double, Double, Int)] = []
        for (k, (s, l)) in r.enumerated() {
            if Int(s) % 4 == 0 {
                let tones = [0, 2, 4, 7, 9]
                cur = tones.min(by: { abs($0 - cur) < abs($1 - cur) })!
                if rng.chance(0.3) { cur = rng.pick(tones) }
            } else {
                cur += rng.pick([-2, -1, -1, 1, 1, 2])
            }
            if k == r.count - 1 { cur = rng.pick([0, 2, 4]) }
            cur = max(-2, min(9, cur))
            out.append((s, l, cur))
        }
        return out
    }
    let motifA = makeMotif(&rng, high: false)
    let motifA2 = makeMotif(&rng, high: false)
    let motifB = makeMotif(&rng, high: true)

    let k = kick()
    var drng = Rng(sp.seed &+ 99)
    let sn = snare(&drng)
    let hats = (0..<4).map { _ in hat(&drng, open: false) }
    let ohat = hat(&drng, open: true)
    let shk = (0..<3).map { _ in shaker(&drng) }

    for b in 0..<bars {
        let sec = sections[b / 8]
        let inSec = b % 8
        let prog = sec == 0 ? sp.progA : sp.progB
        let chord = prog[inSec % prog.count]
        let chordNotes = [deg(chord), deg(chord + 2), deg(chord + 4)]

        // bass
        let bassPat: [(Double, Int, Double)]
        switch sp.drums {
        case 0: bassPat = [(0, 0, 1.5), (2, 12, 0.8), (3, 0, 0.8), (4, 7, 1.5), (6, 12, 1.5)]
        case 2: bassPat = [(0, 0, 2.5), (3, 7, 1), (4, 0, 2), (6, 7, 1.5)]
        case 3: bassPat = [(0, 0, 3), (3, 0, 1), (5, 7, 2.5)]
        default: bassPat = [(0, 0, 3.5), (4, 7, 3.5)]
        }
        for (e, off, l) in bassPat {
            let note = deg(chord) - 24 + off
            mix.addMono(renderNote(.bass, mtof(Double(note)), l * beat / 2 * 0.9, 0.55, &rng), at: tpos(b, e), gain: 0.42)
        }

        // comping
        switch sp.compStyle {
        case 0:
            for e in stride(from: 1.0, to: 8.0, by: 2.0) {
                for (j, nn) in chordNotes.enumerated() {
                    mix.addMono(renderNote(sp.comp, mtof(Double(nn)), beat * 0.35, 0.3, &rng), at: tpos(b, e), gain: 0.16, pan: Double(j - 1) * 0.5)
                }
            }
        case 1:
            let arp = [chordNotes[0], chordNotes[1], chordNotes[2], chordNotes[0] + 12, chordNotes[2], chordNotes[1], chordNotes[0] + 12, chordNotes[2] + 12]
            for (i, nn) in arp.enumerated() {
                mix.addMono(renderNote(sp.comp, mtof(Double(nn)), beat * 0.4, 0.35, &rng), at: tpos(b, Double(i)), gain: 0.13, pan: i % 2 == 0 ? -0.45 : 0.45)
            }
        default:
            for e in [0.0, 4.0] {
                for (j, nn) in chordNotes.enumerated() {
                    mix.addMono(renderNote(sp.comp, mtof(Double(nn)), beat * 1.8, 0.32, &rng), at: tpos(b, e), gain: 0.15, pan: Double(j - 1) * 0.4)
                }
            }
        }
        if sp.pad && (sec == 1 || b >= 16) && inSec % 2 == 0 {
            for (j, nn) in chordNotes.enumerated() {
                mix.addMono(renderNote(.pad, mtof(Double(nn - 12)), bar * 1.9, 0.3, &rng), at: tpos(b, 0), gain: 0.1, pan: Double(j - 1) * 0.7)
            }
        }

        // melody
        if !(sec == 0 && b < 2 && sp.drums == 4) {
            let motif: [(Double, Double, Int)] = sec == 1 ? motifB : (inSec >= 4 && inSec < 6 ? motifA2 : motifA)
            let half = inSec % 2
            for (s, l, d) in motif where (s >= 8) == (half == 1) {
                var dd = chord + d
                var ln = l
                if inSec == 7 && half == 1 && s >= 12 { dd = 7; ln = 4 }
                let note = deg(dd) + 12
                let e = s - Double(half) * 8
                lead.addMono(renderNote(sp.lead, mtof(Double(note)), ln * beat / 2 * 0.92, 0.5, &rng), at: tpos(b, e), gain: 0.3, pan: 0)
            }
        }

        // drums
        func hit(_ s: [Float], _ e: Double, _ g: Double, _ pan: Double = 0) { mix.addMono(s, at: tpos(b, e), gain: g, pan: pan) }
        let fill = inSec == 7
        switch sp.drums {
        case 0:
            hit(k, 0, 0.55); hit(k, 4, 0.55); if b % 2 == 1 { hit(k, 5, 0.35) }
            hit(sn, 2, 0.32); hit(sn, fill ? 5 : 6, 0.32)
            if fill { hit(sn, 6.5, 0.22); hit(sn, 7, 0.26); hit(sn, 7.5, 0.3) }
            for e in 0..<8 { hit(hats[e % 4], Double(e), e % 2 == 1 ? 0.13 : 0.08, 0.3) }
        case 1:
            hit(k, 0, 0.4); hit(k, 5, 0.25)
            for e in 0..<8 { hit(shk[e % 3], Double(e), e % 2 == 1 ? 0.1 : 0.06, -0.3) }
            if inSec % 2 == 1 { hit(ohat, 4, 0.05, 0.4) }
        case 2:
            hit(k, 0, 0.5); hit(k, 3, 0.35); hit(k, 4, 0.45)
            hit(sn, 2, 0.26); hit(sn, 6, 0.26)
            for e in 0..<8 { hit(shk[e % 3], Double(e), 0.08, 0.35) }
        case 3:
            hit(k, 0, 0.5); hit(k, 3.5, 0.3); hit(k, 5, 0.35)
            hit(sn, 2, 0.24); hit(sn, 6, 0.24)
            for e in 0..<8 { hit(hats[e % 4], Double(e), e % 2 == 1 ? 0.07 : 0.05, 0.25) }
        default: break
        }
    }
    lead.delay(beat * 0.75, fb: 0.32, mixAmt: 0.35)
    for i in 0..<mix.n { mix.l[i] += lead.l[i]; mix.r[i] += lead.r[i] }
    mix.normalize(0.85)
    return mix
}

// MARK: - jingles

func jingle(_ kind: String) -> Mix {
    var rng = Rng(77)
    switch kind {
    case "win":
        let m = Mix(3.2)
        let notes = [72, 76, 79, 84, 79, 84, 88]
        for (i, n) in notes.enumerated() {
            let len = i == notes.count - 1 ? 1.4 : 0.12
            m.addMono(renderNote(.lead, mtof(Double(n)), len, 0.5, &rng), at: Int(Double(i) * 0.13 * SR), gain: 0.4)
            m.addMono(renderNote(.bell, mtof(Double(n + 12)), 0.1, 0.4, &rng), at: Int(Double(i) * 0.13 * SR), gain: 0.15, pan: 0.4)
        }
        for n in [60, 64, 67, 72] {
            m.addMono(renderNote(.brass, mtof(Double(n)), 1.3, 0.5, &rng), at: Int(0.78 * SR), gain: 0.2, pan: Double(n - 66) / 12)
        }
        m.addMono(kick(), at: Int(0.78 * SR), gain: 0.6)
        m.addMono(hat(&rng, open: true), at: Int(0.78 * SR), gain: 0.25)
        m.normalize(0.8)
        return m
    case "lose":
        let m = Mix(2.6)
        let notes: [Double] = [55, 54, 53, 52]
        for (i, n) in notes.enumerated() {
            let len = i == 3 ? 1.1 : 0.32
            let s = renderNote(.brass, mtof(n), len, 0.6, &rng)
            var w = s
            if i == 3 { for j in 0..<w.count { w[j] *= Float(1 + 0.25 * sin(Double(j) / SR * 2 * .pi * 6)) } }
            m.addMono(w, at: Int(Double(i) * 0.38 * SR), gain: 0.5)
        }
        m.normalize(0.75)
        return m
    default: // start
        let m = Mix(1.4)
        for i in 0..<6 { m.addMono(snare(&rng), at: Int(Double(i) * 0.06 * SR), gain: 0.15 + Double(i) * 0.04) }
        for n in [60, 67, 72, 76] {
            m.addMono(renderNote(.brass, mtof(Double(n)), 0.45, 0.5, &rng), at: Int(0.38 * SR), gain: 0.22, pan: Double(n - 68) / 14)
        }
        m.addMono(kick(), at: Int(0.38 * SR), gain: 0.7)
        m.addMono(hat(&rng, open: true), at: Int(0.38 * SR), gain: 0.2)
        m.normalize(0.8)
        return m
    }
}

// MARK: - hog voice (formant synthesis)

/// vowels: 0 a, 1 e, 2 i, 3 o, 4 u
func hogVoice(_ syl: [(Int, Double, Double, Double)], _ rng: inout Rng, breath: Double = 0.06) -> [Float] {
    let formants: [(Double, Double)] = [(800, 1200), (430, 2000), (320, 2400), (520, 900), (360, 760)]
    let scaleF = 1.45
    let total = syl.reduce(0.0) { $0 + $1.3 } + 0.08
    var out = [Float](repeating: 0, count: Int(total * SR))
    var o = Osc()
    var i0 = 0
    for (v, f0, f1, d) in syl {
        let n = Int(d * SR)
        var b1 = Biquad(.bp, formants[v].0 * scaleF, 4.5)
        var b2 = Biquad(.bp, formants[v].1 * scaleF, 6)
        var b3 = Biquad(.bp, 3200 * scaleF, 8)
        for i in 0..<n where i0 + i < out.count {
            let t = Double(i) / SR
            let k = t / d
            let f = (f0 + (f1 - f0) * k) * (1 + 0.025 * sin(2 * .pi * 7 * t))
            let src = o.saw(f) + rng.range(-1, 1) * breath
            let v = b1.run(src) * 1.0 + b2.run(src) * 0.55 + b3.run(src) * 0.2
            let env = min(1, t / 0.012) * min(1, (d - t) / 0.03)
            out[i0 + i] = Float(v * env * 2.2)
        }
        i0 += n
    }
    return out
}

// MARK: - ambience

func ambience(_ kind: String) -> Mix {
    var rng = Rng(UInt64(truncatingIfNeeded: kind.unicodeScalars.reduce(7) { $0 &* 31 &+ Int($1.value) }))
    let dur = 24.0
    let m = Mix(dur)
    m.wrap = true
    // wind bed
    var bp = Biquad(.bp, 400, 0.7)
    var bp2 = Biquad(.bp, 500, 0.7)
    let windAmt: Double = kind == "winter" ? 0.5 : (kind == "autumn" ? 0.3 : 0.12)
    for i in 0..<m.n {
        let t = Double(i) / SR
        if i % 256 == 0 {
            bp.set(.bp, 300 + 250 * sin(2 * .pi * t / 8) + 120 * sin(2 * .pi * t / 3.1), 0.9)
            bp2.set(.bp, 350 + 220 * sin(2 * .pi * t / 6 + 1), 0.9)
        }
        let gust = 0.55 + 0.45 * sin(2 * .pi * t / dur * 3) * sin(2 * .pi * t / dur * 2 + 1)
        // loop-safe: gusts use whole periods of the loop
        let nl = bp.run(rng.range(-1, 1)) * windAmt * gust
        let nr = bp2.run(rng.range(-1, 1)) * windAmt * gust
        m.l[i] += Float(nl); m.r[i] += Float(nr)
    }
    switch kind {
    case "spring", "title":
        var t = 0.3
        while t < dur {
            let pan = rng.range(-0.8, 0.8)
            let base = rng.range(2600, 4200)
            let notes = rng.int(2, 6)
            var tt = t
            for _ in 0..<notes {
                let len = rng.range(0.04, 0.12)
                let f0 = base * rng.range(0.85, 1.2), f1 = f0 * rng.range(0.8, 1.4)
                var o = Osc()
                let n = Int(len * SR)
                var s = [Float](repeating: 0, count: n)
                for i in 0..<n {
                    let k = Double(i) / Double(n)
                    s[i] = Float(o.sine(f0 + (f1 - f0) * k) * sin(.pi * k) * (1 + 0.3 * sin(Double(i) * 0.02)))
                }
                m.addMono(s, at: Int(tt * SR), gain: 0.07, pan: pan)
                tt += len + rng.range(0.02, 0.08)
            }
            t = tt + rng.range(0.8, 2.5)
        }
    case "autumn":
        var t = 0.5
        while t < dur {
            let n = Int(rng.range(0.2, 0.6) * SR)
            var hp = Biquad(.hp, 3000, 0.7)
            var s = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let k = Double(i) / Double(n)
                s[i] = Float(hp.run(rng.range(-1, 1)) * (rng.chance(0.08) ? 1 : 0.15) * sin(.pi * k))
            }
            m.addMono(s, at: Int(t * SR), gain: 0.12, pan: rng.range(-0.7, 0.7))
            t += rng.range(0.7, 2.2)
        }
    case "night":
        for c in 0..<2 {
            var t = Double(c) * 0.31
            let f = c == 0 ? 4600.0 : 4100.0
            let pan = c == 0 ? -0.6 : 0.5
            while t < dur {
                for p in 0..<3 {
                    let n = Int(0.018 * SR)
                    var s = [Float](repeating: 0, count: n)
                    var o = Osc()
                    for i in 0..<n { s[i] = Float(o.sine(f) * sin(.pi * Double(i) / Double(n))) }
                    m.addMono(s, at: Int((t + Double(p) * 0.03) * SR), gain: 0.05, pan: pan)
                }
                t += rng.range(0.45, 0.8)
            }
        }
        for t in [6.0, 17.0] {
            for (j, d) in [(0, 0.35), (1, 0.6)] {
                m.addMono(hogVoice([(4, 400, 380, d)], &rng, breath: 0.15), at: Int((t + Double(j) * 0.45) * SR), gain: 0.06, pan: 0.7)
            }
        }
    default: break
    }
    m.normalize(kind == "winter" ? 0.5 : 0.4, soft: false)
    return m
}

// MARK: - sound effects

func sfxBank() -> [String: [Mix]] {
    var rng = Rng(4242)
    var bank: [String: [Mix]] = [:]
    func mono(_ dur: Double, _ f: (Int, Double, Double) -> Double) -> Mix {
        let m = Mix(dur)
        for i in 0..<m.n {
            let t = Double(i) / SR
            let v = Float(f(i, t, t / dur))
            m.l[i] = v; m.r[i] = v
        }
        return m
    }
    func fromMono(_ s: [Float], _ g: Double = 1) -> Mix {
        let m = Mix(Double(s.count) / SR + 0.01)
        m.addMono(s, at: 0, gain: g)
        return m
    }

    // spawn pop
    bank["pop"] = (0..<3).map { k in
        var bp = Biquad(.bp, 1300 + Double(k) * 200, 2)
        var o = Osc()
        return mono(0.12) { _, t, _ in
            bp.run(Double.random(in: -1...1)) * exp(-t * 60) * 1.4 + o.sine(750 - t * 4000) * exp(-t * 35) * 0.5
        }
    }
    // ui
    var o1 = Osc()
    bank["click"] = [mono(0.05) { _, t, _ in o1.sine(1900) * exp(-t * 90) * 0.6 + Double.random(in: -1...1) * exp(-t * 400) * 0.2 }]
    var o2 = Osc()
    bank["hover"] = [mono(0.03) { _, t, _ in o2.sine(2600) * exp(-t * 160) * 0.25 }]
    // skill assign: rising two-tone per skill
    bank["assign"] = (0..<8).map { k in
        let base = mtof(Double(72 + [0, 4, 7, 2, 5, 9, 11, 12][k]))
        var o = Osc(), o3 = Osc()
        return mono(0.2) { _, t, _ in
            let f = t < 0.06 ? base : base * 1.5
            return (o.pulse(f, 0.3) * 0.25 + o3.sine(f * 2) * 0.2) * exp(-t * 14) * min(1, t * 500)
        }
    }
    // digging crunches
    bank["dig"] = (0..<4).map { k in
        var bp = Biquad(.bp, 500 + Double(k) * 160, 1.2)
        return mono(0.16) { _, t, _ in
            let grain = (Int(t * 90) % 3 == 0) ? 1.0 : 0.35
            return bp.run(Double.random(in: -1...1)) * grain * exp(-t * 22) * 1.6
        }
    }
    // punch
    bank["punch"] = (0..<3).map { k in
        var o = Osc()
        var lp = Biquad(.lp, 2500, 0.8)
        return mono(0.2) { _, t, _ in
            o.sine(130 - t * 300 + Double(k) * 15) * exp(-t * 22) * 0.9 + lp.run(Double.random(in: -1...1)) * exp(-t * 70) * 0.8
        }
    }
    // pickaxe
    bank["pick"] = (0..<2).map { k in
        var a = Osc(), b = Osc()
        var bp = Biquad(.bp, 700, 1)
        return mono(0.3) { _, t, _ in
            (a.sine(2300 + Double(k) * 140) * 0.4 + b.sine(3350) * 0.25) * exp(-t * 26) + bp.run(Double.random(in: -1...1)) * exp(-t * 30) * 0.8
        }
    }
    // carrot brick
    bank["brick"] = (0..<3).map { k in
        var o = Osc()
        var bp = Biquad(.bp, 900 + Double(k) * 120, 3)
        return mono(0.14) { _, t, _ in
            o.sine(520 + Double(k) * 60) * exp(-t * 40) * 0.7 + bp.run(Double.random(in: -1...1)) * exp(-t * 60) * 0.8
        }
    }
    var ow = Osc()
    bank["warn"] = [mono(0.32) { _, t, _ in
        (t.truncatingRemainder(dividingBy: 0.16) < 0.08 ? ow.pulse(t < 0.16 ? 1250 : 940, 0.5) * 0.25 : 0)
    }]
    bank["clang"] = [mono(0.8) { _, t, _ in
        let p = [523.0, 1307, 2141, 3183, 4300].enumerated().reduce(0.0) { acc, e in
            acc + sin(2 * .pi * e.element * t) * exp(-t * (6 + Double(e.offset) * 3)) / Double(e.offset + 1)
        }
        return p * 0.5 + (t < 0.005 ? Double.random(in: -1...1) * 0.5 : 0)
    }]
    bank["climb"] = (0..<2).map { _ in
        var hp = Biquad(.hp, 2500, 0.7)
        return mono(0.12) { _, t, _ in hp.run(Double.random(in: -1...1)) * (Int(t * 120) % 4 == 0 ? 0.8 : 0.05) * exp(-t * 10) }
    }
    var wb = Biquad()
    var wo = Osc()
    bank["brolly"] = [mono(0.4) { i, t, k in
        if i % 64 == 0 { wb.set(.bp, 500 + 2500 * k, 1.2) }
        return wb.run(Double.random(in: -1...1)) * sin(.pi * k) * 0.7 + wo.sine(110 - 60 * k) * exp(-t * 12) * 0.5
    }]
    // splat
    var sl = Biquad(.lp, 900, 1.5)
    bank["splat"] = [mono(0.45) { _, t, k in
        let wob = 0.6 + 0.4 * sin(t * 90)
        let blorp = sin(2 * .pi * (420 * t - 700 * t * t)) * exp(-t * 10) * 0.5 * (k < 0.5 ? 1 : 0)
        return sl.run(Double.random(in: -1...1)) * wob * exp(-t * 9) * 1.4 + blorp
    }]
    // explosion (stereo)
    bank["boom"] = (0..<2).map { _ in
        let m = Mix(1.8)
        var lpL = Biquad(), lpR = Biquad()
        var sub = Osc()
        for i in 0..<m.n {
            let t = Double(i) / SR
            if i % 64 == 0 { let f = 200 + 6000 * exp(-t * 6); lpL.set(.lp, f, 0.8); lpR.set(.lp, f * 0.9, 0.8) }
            let env = exp(-t * 2.8) * min(1, t * 300)
            let s = sub.sine(55 * exp(-t * 0.8) + 20) * exp(-t * 3.5) * 0.9
            let crack = Double.random(in: 0...1) < 0.004 * exp(-t * 2) ? Double.random(in: -1...1) * 1.5 : 0
            m.l[i] = Float(s + lpL.run(Double.random(in: -1...1)) * env * 1.6 + crack)
            m.r[i] = Float(s + lpR.run(Double.random(in: -1...1)) * env * 1.6 + crack)
        }
        m.normalize(0.95)
        return m
    }
    var tk = Osc()
    bank["tick"] = [mono(0.04) { _, t, _ in tk.sine(3200) * exp(-t * 200) * 0.5 }]
    var tk2 = Osc()
    bank["tock"] = [mono(0.04) { _, t, _ in tk2.sine(2100) * exp(-t * 200) * 0.5 }]
    // drown bubbles
    bank["drown"] = [{
        let m = Mix(0.9)
        for b in 0..<12 {
            let st = Double(b) * 0.06 + Double.random(in: 0...0.03)
            let f0 = Double.random(in: 300...700)
            var o = Osc()
            let n = Int(0.05 * SR)
            var s = [Float](repeating: 0, count: n)
            for i in 0..<n { let k = Double(i) / Double(n); s[i] = Float(o.sine(f0 * (1 + k * 1.8)) * sin(.pi * k)) }
            m.addMono(s, at: Int(st * SR), gain: 0.5, pan: Double.random(in: -0.4...0.4))
        }
        m.addMono(hogVoice([(4, 420, 300, 0.25)], &rng), at: 0, gain: 0.5)
        m.normalize(0.8)
        return m
    }()]
    // exit: thoop + chime
    bank["exit"] = (0..<2).map { k in
        let m = Mix(1.0)
        var o = Osc()
        let n = Int(0.09 * SR)
        var s = [Float](repeating: 0, count: n)
        for i in 0..<n { let kk = Double(i) / Double(n); s[i] = Float(o.sine(300 + 900 * kk) * sin(.pi * kk)) }
        m.addMono(s, at: 0, gain: 0.5)
        for (j, note) in [84, 88, 91].enumerated() {
            m.addMono(renderNote(.bell, mtof(Double(note + k * 2)), 0.05, 0.4, &rng), at: Int((0.05 + Double(j) * 0.05) * SR), gain: 0.22, pan: Double(j - 1) * 0.5)
        }
        m.normalize(0.7)
        return m
    }
    // door creak + clunk
    var cb = Biquad(.bp, 900, 3)
    var co = Osc()
    bank["door"] = [mono(0.6) { _, t, k in
        let f = 75 + 30 * sin(t * 13) + Double.random(in: -8...8)
        let creak = t < 0.45 ? cb.run(co.saw(f)) * sin(.pi * min(1, t / 0.45)) * 0.8 : 0
        let clunk = t > 0.45 ? sin(2 * .pi * 90 * (t - 0.45)) * exp(-(t - 0.45) * 30) : 0
        return creak + clunk * (k > 0 ? 0.9 : 0)
    }]
    var nu = Osc()
    bank["nuke"] = [mono(1.2) { _, t, k in nu.pulse(650 + 250 * sin(2 * .pi * 2.5 * t), 0.5) * 0.25 * sin(.pi * k) }]

    // voices
    func babble(_ r: inout Rng) -> [Float] {
        let n = r.int(2, 5)
        let base = r.range(520, 760)
        var syl: [(Int, Double, Double, Double)] = []
        for i in 0..<n {
            let v = r.int(0, 4)
            let rise = i == n - 1 ? r.range(-0.2, 0.35) : r.range(-0.12, 0.12)
            let f0 = base * r.range(0.9, 1.12)
            syl.append((v, f0, f0 * (1 + rise), r.range(0.06, 0.11)))
        }
        return hogVoice(syl, &r)
    }
    bank["babble"] = (0..<12).map { _ in fromMono(babble(&rng), 0.5) }
    bank["wheee"] = [fromMono(hogVoice([(1, 650, 700, 0.06), (2, 700, 1150, 0.42)], &rng), 0.5)]
    bank["uhoh"] = [fromMono(hogVoice([(0, 720, 760, 0.13), (3, 600, 470, 0.28)], &rng), 0.55)]
    bank["yay"] = [fromMono(hogVoice([(1, 640, 700, 0.06), (0, 720, 1000, 0.26)], &rng), 0.5),
                   fromMono(hogVoice([(2, 760, 820, 0.09), (2, 900, 1250, 0.22)], &rng), 0.5)]
    bank["ow"] = [fromMono(hogVoice([(0, 900, 520, 0.25)], &rng), 0.5)]
    bank["hmm"] = [fromMono(hogVoice([(4, 480, 520, 0.18), (4, 520, 450, 0.18)], &rng, breath: 0.02), 0.4)]

    // jingles
    bank["win"] = [jingle("win")]
    bank["lose"] = [jingle("lose")]
    bank["start"] = [jingle("start")]
    return bank
}
