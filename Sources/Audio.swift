import AVFoundation

/// Audio engine: pooled stereo SFX players (panned) through a room reverb,
/// cross-fading music decks through a hall reverb, and a looping ambience bed.
/// Everything is synthesized on a background queue at startup.
final class Audio {
    let engine = AVAudioEngine()
    let fmt = AVAudioFormat(standardFormatWithSampleRate: SR, channels: 2)!
    var sfx: [AVAudioPlayerNode] = []
    var nextSfx = 0
    let sfxMix = AVAudioMixerNode()
    let sfxVerb = AVAudioUnitReverb()
    let musicMix = AVAudioMixerNode()
    let musicVerb = AVAudioUnitReverb()
    var decks: [AVAudioPlayerNode] = []
    var deckVol: [Float] = [0, 0]
    var deckTarget: [Float] = [0, 0]
    var deckTrack: [String?] = [nil, nil]
    var ambDecks: [AVAudioPlayerNode] = []
    var ambVol: [Float] = [0, 0]
    var ambTarget: [Float] = [0, 0]
    var ambTrack: [String?] = [nil, nil]

    var bank: [String: [AVAudioPCMBuffer]] = [:]
    var tracks: [String: AVAudioPCMBuffer] = [:]
    var lastPlay: [String: Double] = [:]
    var ok = false
    var musicOn = true
    var wantMusic: String? = nil
    var wantAmb: String? = nil
    var musicLevel: Float = 0.6

    init() {
        engine.attach(sfxMix); engine.attach(sfxVerb); engine.attach(musicMix); engine.attach(musicVerb)
        sfxVerb.loadFactoryPreset(.mediumRoom)
        sfxVerb.wetDryMix = 14
        musicVerb.loadFactoryPreset(.mediumHall)
        musicVerb.wetDryMix = 16
        engine.connect(sfxMix, to: sfxVerb, format: fmt)
        engine.connect(sfxVerb, to: engine.mainMixerNode, format: fmt)
        engine.connect(musicMix, to: musicVerb, format: fmt)
        engine.connect(musicVerb, to: engine.mainMixerNode, format: fmt)
        for _ in 0..<24 {
            let p = AVAudioPlayerNode()
            engine.attach(p)
            engine.connect(p, to: sfxMix, format: fmt)
            sfx.append(p)
        }
        for _ in 0..<2 {
            let d = AVAudioPlayerNode()
            engine.attach(d); engine.connect(d, to: musicMix, format: fmt)
            decks.append(d)
            let a = AVAudioPlayerNode()
            engine.attach(a); engine.connect(a, to: engine.mainMixerNode, format: fmt)
            a.volume = 0
            ambDecks.append(a)
        }
        engine.mainMixerNode.outputVolume = 0.9
        do { try engine.start(); ok = true } catch { ok = false; return }

        let q = DispatchQueue(label: "synth", qos: .userInitiated)
        q.async { [weak self] in
            let b = sfxBank()
            DispatchQueue.main.async { self?.install(bank: b) }
            for (name, spec) in Audio.songs {
                let m = composeSong(spec)
                DispatchQueue.main.async { self?.install(track: name, m) }
            }
            for name in ["spring", "winter", "autumn", "night"] {
                let m = ambience(name)
                DispatchQueue.main.async { self?.install(track: "amb_" + name, m) }
            }
        }
    }

    static let songs: [(String, SongSpec)] = [
        ("title", SongSpec(bpm: 126, root: 65, minor: false, progA: [0, 4, 5, 3, 0, 4, 3, 4], progB: [3, 4, 2, 5, 3, 4, 1, 4],
                           lead: .lead, comp: .marimba, compStyle: 1, drums: 0, swing: 0.15, seed: 11, pad: true)),
        ("spring", SongSpec(bpm: 132, root: 60, minor: false, progA: [0, 3, 4, 0, 5, 3, 1, 4], progB: [3, 4, 0, 5, 3, 4, 1, 4],
                            lead: .lead, comp: .pluck, compStyle: 0, drums: 0, swing: 0.1, seed: 3, pad: false)),
        ("winter", SongSpec(bpm: 96, root: 62, minor: false, progA: [0, 5, 3, 4, 0, 5, 1, 4], progB: [5, 3, 0, 4, 5, 3, 1, 4],
                            lead: .bell, comp: .bell, compStyle: 1, drums: 1, swing: 0, seed: 21, pad: true)),
        ("autumn", SongSpec(bpm: 112, root: 55, minor: false, progA: [0, 6, 3, 0, 0, 6, 3, 4], progB: [3, 0, 4, 5, 3, 0, 1, 4],
                            lead: .pluck, comp: .pluck, compStyle: 1, drums: 2, swing: 0.12, seed: 31, pad: true)),
        ("night", SongSpec(bpm: 84, root: 57, minor: true, progA: [0, 5, 2, 6, 0, 5, 3, 4], progB: [5, 2, 3, 0, 5, 2, 3, 4],
                           lead: .epiano, comp: .epiano, compStyle: 2, drums: 3, swing: 0.3, seed: 41, pad: true)),
    ]

    private func toBuffer(_ m: Mix) -> AVAudioPCMBuffer? {
        guard let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(m.n)) else { return nil }
        b.frameLength = AVAudioFrameCount(m.n)
        let l = b.floatChannelData![0], r = b.floatChannelData![1]
        m.l.withUnsafeBufferPointer { src in l.update(from: src.baseAddress!, count: m.n) }
        m.r.withUnsafeBufferPointer { src in r.update(from: src.baseAddress!, count: m.n) }
        return b
    }

    private func install(bank b: [String: [Mix]]) {
        for (k, v) in b { bank[k] = v.compactMap { toBuffer($0) } }
    }

    private func install(track name: String, _ m: Mix) {
        tracks[name] = toBuffer(m)
        if name == wantMusic { setMusic(name, force: true) }
        if name == "amb_" + (wantAmb ?? "") { setAmbience(wantAmb, force: true) }
    }

    // MARK: playback

    func play(_ name: String, _ vol: Float = 0.5, pan: Float = 0, cooldown: Double = 0.03) {
        guard ok, let list = bank[name], !list.isEmpty else { return }
        let now = CACurrentMediaTime()
        if let last = lastPlay[name], now - last < cooldown { return }
        lastPlay[name] = now
        let p = sfx[nextSfx]
        nextSfx = (nextSfx + 1) % sfx.count
        p.stop()
        p.volume = vol
        p.pan = max(-1, min(1, pan))
        p.scheduleBuffer(list.randomElement()!, at: nil, options: [], completionHandler: nil)
        p.play()
    }

    func setMusic(_ name: String?, force: Bool = false) {
        wantMusic = name
        guard ok else { return }
        let active = deckTarget[0] > 0 ? 0 : (deckTarget[1] > 0 ? 1 : -1)
        if !force, active >= 0, deckTrack[active] == name { return }
        guard let n = name, let buf = tracks[n] else {
            if name == nil { deckTarget = [0, 0] }
            return
        }
        if active >= 0 && deckTrack[active] == n { return }
        let slot = active == 0 ? 1 : 0
        deckTarget = [0, 0]
        deckTarget[slot] = 1
        decks[slot].stop()
        decks[slot].volume = 0
        deckVol[slot] = 0
        decks[slot].scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)
        decks[slot].play()
        deckTrack[slot] = n
    }

    func setAmbience(_ name: String?, force: Bool = false) {
        wantAmb = name
        guard ok else { return }
        let key = name.map { "amb_" + $0 }
        let active = ambTarget[0] > 0 ? 0 : (ambTarget[1] > 0 ? 1 : -1)
        if !force, active >= 0, ambTrack[active] == key { return }
        guard let k = key, let buf = tracks[k] else {
            if name == nil { ambTarget = [0, 0] }
            return
        }
        if active >= 0 && ambTrack[active] == k { return }
        let slot = active == 0 ? 1 : 0
        ambTarget = [0, 0]
        ambTarget[slot] = 1
        ambDecks[slot].stop()
        ambDecks[slot].scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)
        ambDecks[slot].play()
        ambTrack[slot] = k
    }

    /// Called every frame for cross-fades.
    func update(_ dt: Double) {
        guard ok else { return }
        let k = Float(min(1, dt * 1.2))
        for i in 0..<2 {
            deckVol[i] += (deckTarget[i] - deckVol[i]) * k
            decks[i].volume = deckVol[i] * (musicOn ? musicLevel : 0)
            if deckTarget[i] == 0 && deckVol[i] < 0.01 && decks[i].isPlaying { decks[i].stop(); deckTrack[i] = nil }
            ambVol[i] += (ambTarget[i] - ambVol[i]) * k
            ambDecks[i].volume = ambVol[i] * 0.7
            if ambTarget[i] == 0 && ambVol[i] < 0.01 && ambDecks[i].isPlaying { ambDecks[i].stop(); ambTrack[i] = nil }
        }
    }
}
