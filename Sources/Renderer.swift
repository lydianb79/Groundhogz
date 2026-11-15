import Metal
import MetalKit
import simd

struct Vtx {
    var pos: SIMD2<Float>
    var uv: SIMD2<Float>
    var color: SIMD4<Float>
}

struct Globals {
    var screen = SIMD2<Float>(640, 360)
    var time: Float = 0
    var camX: Float = 0
    var skyTop = SIMD4<Float>(0.4, 0.6, 0.9, 1)
    var skyBottom = SIMD4<Float>(0.8, 0.9, 1, 1)
    var hillA = SIMD4<Float>(0.4, 0.7, 0.4, 1)
    var hillB = SIMD4<Float>(0.3, 0.55, 0.3, 1)
    var params = SIMD4<Float>(0, 0, 0, 0)
    var origin = SIMD2<Float>(0, 0)
    var worldSize = SIMD2<Float>(640, 300)
    var ambient = SIMD4<Float>(1, 1, 1, 0.5)
    var waterColor = SIMD4<Float>(0.2, 0.5, 0.85, 1)
    var counts = SIMD4<Float>(0, 0, 0, 0)
    var dirtA = SIMD4<Float>(0.6, 0.4, 0.23, 1)
    var dirtB = SIMD4<Float>(0.5, 0.33, 0.19, 1)
    var grass = SIMD4<Float>(0.38, 0.73, 0.25, 1)
}

struct LightU { var posRad: SIMD4<Float>; var color: SIMD4<Float> }

typealias RGBA = SIMD4<Float>
func C(_ r: Float, _ g: Float, _ b: Float, _ a: Float = 1) -> RGBA { RGBA(r / 255, g / 255, b / 255, a) }
let WHITE = RGBA(1, 1, 1, 1)

enum Align { case left, center, right }
enum Blend { case alpha, add }
enum Samp: Int { case nearest = 0, linear = 1, mip = 2 }
enum Pipe { case sprite, terrain }

struct DrawCmd { var tex: MTLTexture; var samp: Samp; var blend: Blend; var pipe: Pipe; var start: Int; var count: Int }

final class Layer {
    var verts: [Vtx] = []
    var cmds: [DrawCmd] = []
    func reset() { verts.removeAll(keepingCapacity: true); cmds.removeAll(keepingCapacity: true) }
}

final class Renderer {
    static var W: Float = 640
    static var H: Float = 360
    static var originY: Float = 0

    let device: MTLDevice
    let queue: MTLCommandQueue
    private var pso: [String: MTLRenderPipelineState] = [:]
    private var samplers: [MTLSamplerState] = []
    let atlas: Atlas
    let atlasTex: MTLTexture
    let font: FontAtlas
    let fontTex: MTLTexture
    var terrainTex: MTLTexture?
    private var sceneTex: MTLTexture?
    private var bloomA: MTLTexture?
    private var bloomB: MTLTexture?
    private var brightTex: MTLTexture?
    private var shaftTex: MTLTexture?

    let world = Layer()
    let ui = Layer()
    var layer: Layer
    var offset = SIMD2<Float>(0, 0)
    var globals = Globals()
    var drawBackground = true
    var lights: [LightU] = []
    var waters: [SIMD4<Float>] = []

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        self.device = device
        layer = world
        guard let q = device.makeCommandQueue() else { return nil }
        queue = q
        let lib: MTLLibrary
        do { lib = try device.makeLibrary(source: shaderSource, options: nil) } catch {
            print("Shader compile failed: \(error)")
            return nil
        }
        var psoL: [String: MTLRenderPipelineState] = [:]
        func make(_ name: String, _ vs: String, _ fs: String, _ fmt: MTLPixelFormat, _ blend: Blend?) {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: vs)
            d.fragmentFunction = lib.makeFunction(name: fs)
            let ca = d.colorAttachments[0]!
            ca.pixelFormat = fmt
            if let b = blend {
                ca.isBlendingEnabled = true
                ca.rgbBlendOperation = .add
                ca.alphaBlendOperation = .add
                ca.sourceRGBBlendFactor = .sourceAlpha
                ca.destinationRGBBlendFactor = b == .add ? .one : .oneMinusSourceAlpha
                ca.sourceAlphaBlendFactor = .one
                ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            do { psoL[name] = try device.makeRenderPipelineState(descriptor: d) } catch { print("pipeline \(name): \(error)") }
        }
        let hdr = MTLPixelFormat.rgba16Float
        make("bg", "fullVS", "bgFS", hdr, nil)
        make("sceneAlpha", "spriteVS", "spriteFS", hdr, .alpha)
        make("sceneAdd", "spriteVS", "spriteFS", hdr, .add)
        make("sceneTerrain", "spriteVS", "terrainFS", hdr, .alpha)
        make("bright", "fullVS", "brightFS", hdr, nil)
        make("blur", "fullVS", "blurFS", hdr, nil)
        make("shafts", "fullVS", "shaftsFS", hdr, nil)
        make("composite", "fullVS", "compositeFS", pixelFormat, nil)
        make("uiAlpha", "spriteVS", "spriteFS", pixelFormat, .alpha)
        make("uiAdd", "spriteVS", "spriteFS", pixelFormat, .add)
        make("uiTerrain", "spriteVS", "terrainFS", pixelFormat, .alpha)
        guard psoL.count == 11 else { return nil }
        var samplersL: [MTLSamplerState] = []

        for (mn, mip) in [(MTLSamplerMinMagFilter.nearest, false), (.linear, false), (.linear, true)] {
            let sd = MTLSamplerDescriptor()
            sd.minFilter = mn
            sd.magFilter = mn
            if mip { sd.mipFilter = .linear }
            sd.sAddressMode = .clampToEdge
            sd.tAddressMode = .clampToEdge
            guard let s = device.makeSamplerState(descriptor: sd) else { return nil }
            samplersL.append(s)
        }

        let fnt = FontAtlas()
        let atl = Atlas(font: fnt)
        func tex(_ w: Int, _ h: Int, _ bytes: UnsafeRawPointer, mips: Bool) -> MTLTexture? {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: mips)
            td.usage = .shaderRead
            guard let t = device.makeTexture(descriptor: td) else { return nil }
            t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: bytes, bytesPerRow: w * 4)
            return t
        }
        guard let at = atl.px.withUnsafeBytes({ tex(Atlas.size, Atlas.size, $0.baseAddress!, mips: false) }),
              let ft = fnt.pixels.withUnsafeBytes({ tex(fnt.size, fnt.height, $0.baseAddress!, mips: true) }) else { return nil }
        font = fnt
        atlas = atl
        atlasTex = at
        fontTex = ft
        pso = psoL
        samplers = samplersL
        if let cb = q.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: ft)
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
        }
    }

    // MARK: terrain texture

    func syncTerrain(_ t: Terrain) {
        if terrainTex == nil || terrainTex!.width != t.w || terrainTex!.height != t.h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: t.w, height: t.h, mipmapped: false)
            d.usage = .shaderRead
            terrainTex = device.makeTexture(descriptor: d)
            t.markAllDirty()
        }
        guard let tex = terrainTex, t.dirtyMax >= t.dirtyMin else { return }
        let y0 = max(0, t.dirtyMin), y1 = min(t.h - 1, t.dirtyMax)
        t.px.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, y0, t.w, y1 - y0 + 1), mipmapLevel: 0,
                        withBytes: raw.baseAddress! + y0 * t.w * 4, bytesPerRow: t.w * 4)
        }
        t.dirtyMin = Int.max
        t.dirtyMax = -1
    }

    // MARK: immediate-mode drawing

    func quad(_ tex: MTLTexture, _ x: Float, _ y: Float, _ w: Float, _ h: Float,
              _ u0: Float, _ v0: Float, _ u1: Float, _ v1: Float, _ c: RGBA,
              samp: Samp = .nearest, blend: Blend = .alpha, pipe: Pipe = .sprite) {
        let L = layer
        if L.cmds.isEmpty || L.cmds[L.cmds.count - 1].tex !== tex || L.cmds[L.cmds.count - 1].samp != samp
            || L.cmds[L.cmds.count - 1].blend != blend || L.cmds[L.cmds.count - 1].pipe != pipe {
            L.cmds.append(DrawCmd(tex: tex, samp: samp, blend: blend, pipe: pipe, start: L.verts.count, count: 0))
        }
        let X = x + offset.x, Y = y + offset.y
        let a = Vtx(pos: SIMD2(X, Y), uv: SIMD2(u0, v0), color: c)
        let b = Vtx(pos: SIMD2(X + w, Y), uv: SIMD2(u1, v0), color: c)
        let d = Vtx(pos: SIMD2(X, Y + h), uv: SIMD2(u0, v1), color: c)
        let e = Vtx(pos: SIMD2(X + w, Y + h), uv: SIMD2(u1, v1), color: c)
        L.verts.append(a); L.verts.append(b); L.verts.append(d)
        L.verts.append(b); L.verts.append(e); L.verts.append(d)
        L.cmds[L.cmds.count - 1].count += 6
    }

    func quadRot(_ tex: MTLTexture, _ cx: Float, _ cy: Float, _ w: Float, _ h: Float, _ ang: Float,
                 _ u0: Float, _ v0: Float, _ u1: Float, _ v1: Float, _ c: RGBA, samp: Samp = .linear, blend: Blend = .alpha) {
        let L = layer
        if L.cmds.isEmpty || L.cmds[L.cmds.count - 1].tex !== tex || L.cmds[L.cmds.count - 1].samp != samp
            || L.cmds[L.cmds.count - 1].blend != blend || L.cmds[L.cmds.count - 1].pipe != .sprite {
            L.cmds.append(DrawCmd(tex: tex, samp: samp, blend: blend, pipe: .sprite, start: L.verts.count, count: 0))
        }
        let co = cos(ang), si = sin(ang)
        func P(_ dx: Float, _ dy: Float) -> SIMD2<Float> {
            SIMD2(cx + offset.x + dx * co - dy * si, cy + offset.y + dx * si + dy * co)
        }
        let hw = w / 2, hh = h / 2
        let a = Vtx(pos: P(-hw, -hh), uv: SIMD2(u0, v0), color: c)
        let b = Vtx(pos: P(hw, -hh), uv: SIMD2(u1, v0), color: c)
        let d = Vtx(pos: P(-hw, hh), uv: SIMD2(u0, v1), color: c)
        let e = Vtx(pos: P(hw, hh), uv: SIMD2(u1, v1), color: c)
        L.verts.append(a); L.verts.append(b); L.verts.append(d)
        L.verts.append(b); L.verts.append(e); L.verts.append(d)
        L.cmds[L.cmds.count - 1].count += 6
    }

    func spriteRot(_ r: Region, _ cx: Float, _ cy: Float, scale: Float = 1, angle: Float, color: RGBA = WHITE, blend: Blend = .alpha) {
        let s = Float(Atlas.size)
        quadRot(atlasTex, cx, cy, Float(r.w) / r.s * scale, Float(r.h) / r.s * scale, angle,
                Float(r.x) / s, Float(r.y) / s, Float(r.x + r.w) / s, Float(r.y + r.h) / s, color, blend: blend)
    }

    func rectRot(_ cx: Float, _ cy: Float, _ w: Float, _ h: Float, _ angle: Float, _ c: RGBA) {
        let s = Float(Atlas.size)
        let u = (Float(atlas.white.x) + 8) / s, v = (Float(atlas.white.y) + 8) / s
        quadRot(atlasTex, cx, cy, w, h, angle, u, v, u, v, c, samp: .nearest)
    }

    func sprite(_ r: Region, _ x: Float, _ y: Float, scale: Float = 1, flip: Bool = false, color: RGBA = WHITE,
                blend: Blend = .alpha, smooth: Bool = false) {
        let s = Float(Atlas.size)
        var u0 = Float(r.x) / s, u1 = Float(r.x + r.w) / s
        if flip { swap(&u0, &u1) }
        quad(atlasTex, x, y, Float(r.w) / r.s * scale, Float(r.h) / r.s * scale, u0, Float(r.y) / s, u1, Float(r.y + r.h) / s,
             color, samp: smooth ? .linear : .nearest, blend: blend)
    }

    /// Draw a sprite stretched to an exact size.
    func spriteRect(_ r: Region, _ x: Float, _ y: Float, _ w: Float, _ h: Float, color: RGBA = WHITE, blend: Blend = .alpha) {
        let s = Float(Atlas.size)
        quad(atlasTex, x, y, w, h, Float(r.x) / s, Float(r.y) / s, Float(r.x + r.w) / s, Float(r.y + r.h) / s,
             color, samp: .linear, blend: blend)
    }

    /// Nine-slice panel. `b` is the border in texels; drawn border size is b / region scale.
    func nine(_ r: Region, _ x: Float, _ y: Float, _ w: Float, _ h: Float, b: Int, color: RGBA = WHITE) {
        let s = Float(Atlas.size)
        let bl = Float(b) / r.s
        let xs: [Float] = [x, x + bl, x + w - bl, x + w]
        let ys: [Float] = [y, y + bl, y + h - bl, y + h]
        let us: [Float] = [Float(r.x), Float(r.x + b), Float(r.x + r.w - b), Float(r.x + r.w)].map { $0 / s }
        let vs: [Float] = [Float(r.y), Float(r.y + b), Float(r.y + r.h - b), Float(r.y + r.h)].map { $0 / s }
        for j in 0..<3 {
            for i in 0..<3 {
                quad(atlasTex, xs[i], ys[j], xs[i + 1] - xs[i], ys[j + 1] - ys[j], us[i], vs[j], us[i + 1], vs[j + 1], color, samp: .linear)
            }
        }
    }

    func rect(_ x: Float, _ y: Float, _ w: Float, _ h: Float, _ c: RGBA, blend: Blend = .alpha) {
        let s = Float(Atlas.size)
        let u = (Float(atlas.white.x) + 8) / s, v = (Float(atlas.white.y) + 8) / s
        quad(atlasTex, x, y, w, h, u, v, u, v, c, blend: blend)
    }

    func box(_ x: Float, _ y: Float, _ w: Float, _ h: Float, _ c: RGBA, _ t: Float = 1) {
        rect(x, y, w, t, c); rect(x, y + h - t, w, t, c)
        rect(x, y, t, h, c); rect(x + w - t, y, t, h, c)
    }

    func glow(_ x: Float, _ y: Float, _ radius: Float, _ c: RGBA) {
        spriteRect(atlas.glow, x - radius, y - radius, radius * 2, radius * 2, color: c, blend: .add)
    }

    func terrainQuad(_ t: Terrain, _ x: Float, _ y: Float, _ w: Float, _ h: Float, flat: Bool = false, alpha: Float = 1) {
        guard let tex = terrainTex else { return }
        quad(tex, x, y, w, h, 0, 0, Float(t.w), Float(t.h), RGBA(flat ? 1 : 0, 0, 0, alpha), samp: .linear, pipe: .terrain)
    }

    func addLight(_ x: Float, _ y: Float, _ radius: Float, _ c: RGBA, _ intensity: Float) {
        if lights.count < 32 {
            lights.append(LightU(posRad: SIMD4(x + offset.x, y + offset.y, radius, 0), color: SIMD4(c.x, c.y, c.z, intensity)))
        }
    }

    // MARK: text

    func textWidth(_ s: String, scale: Float = 1) -> Float {
        let em = 10 * scale
        var w: Float = 0
        for ch in s { w += (font.glyphs[ch]?.adv ?? 0.3) * em }
        return w
    }

    func text(_ s: String, _ x: Float, _ y: Float, scale: Float = 1, color: RGBA = WHITE, align: Align = .left,
              shadow: RGBA? = RGBA(0, 0, 0, 0.5), outline: RGBA? = nil) {
        let em = 10 * scale
        let w = textWidth(s, scale: scale)
        let cx = x - (align == .center ? w / 2 : align == .right ? w : 0)
        let base = y + font.capHeight * em
        if let o = outline {
            let k = max(0.6, em * 0.07)
            for (dx, dy) in [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)] as [(Float, Float)] {
                run(s, cx + dx * k, base + dy * k, em, o)
            }
        }
        if let sh = shadow { run(s, cx + em * 0.06, base + em * 0.09, em, sh) }
        run(s, cx, base, em, color)
    }

    private func run(_ s: String, _ x: Float, _ base: Float, _ em: Float, _ c: RGBA) {
        var cx = x
        for ch in s {
            guard let g = font.glyphs[ch] else { cx += 0.3 * em; continue }
            if g.w > 0 {
                quad(fontTex, cx + g.bx * em, base - g.top * em, g.w * em, g.h * em, g.u0, g.v0, g.u1, g.v1, c, samp: .mip)
            }
            cx += g.adv * em
        }
    }

    // MARK: frame encoding

    private func ensureTargets(_ w: Int, _ h: Int) {
        if sceneTex?.width == w && sceneTex?.height == h { return }
        func mk(_ w: Int, _ h: Int) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: max(1, w), height: max(1, h), mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        sceneTex = mk(w, h)
        bloomA = mk(w / 4, h / 4)
        bloomB = mk(w / 4, h / 4)
        brightTex = mk(w / 4, h / 4)
        shaftTex = mk(w / 4, h / 4)
    }

    private func pass(_ cb: MTLCommandBuffer, _ target: MTLTexture, clear: Bool = true) -> MTLRenderCommandEncoder? {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = clear ? .clear : .load
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.02, green: 0.015, blue: 0.01, alpha: 1)
        return cb.makeRenderCommandEncoder(descriptor: rpd)
    }

    private func drawLayer(_ enc: MTLRenderCommandEncoder, _ l: Layer, scene: Bool, _ g: inout Globals) {
        guard !l.verts.isEmpty,
              let buf = device.makeBuffer(bytes: l.verts, length: l.verts.count * MemoryLayout<Vtx>.stride, options: .storageModeShared)
        else { return }
        enc.setVertexBuffer(buf, offset: 0, index: 0)
        enc.setVertexBytes(&g, length: MemoryLayout<Globals>.stride, index: 1)
        enc.setFragmentBytes(&g, length: MemoryLayout<Globals>.stride, index: 1)
        for c in l.cmds where c.count > 0 {
            let name: String
            switch c.pipe {
            case .terrain: name = scene ? "sceneTerrain" : "uiTerrain"
            case .sprite: name = c.blend == .add ? (scene ? "sceneAdd" : "uiAdd") : (scene ? "sceneAlpha" : "uiAlpha")
            }
            enc.setRenderPipelineState(pso[name]!)
            if c.pipe == .terrain {
                enc.setFragmentSamplerState(samplers[1], index: 0)
                enc.setFragmentSamplerState(samplers[0], index: 1)
            } else {
                enc.setFragmentSamplerState(samplers[c.samp.rawValue], index: 0)
            }
            enc.setFragmentTexture(c.tex, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: c.start, vertexCount: c.count)
        }
    }

    func encode(_ cb: MTLCommandBuffer, target: MTLTexture, game: Game) {
        let tw = Float(target.width), th = Float(target.height)
        let H = max(360, 640 * th / tw)
        Renderer.W = 640
        Renderer.H = H
        Renderer.originY = floor(H - 360)
        let s = min(tw / 640, th / H)
        let vw = 640 * s, vh = H * s
        let ss = min(s, 3)
        ensureTargets(Int(640 * ss), Int(H * ss))
        guard let scene = sceneTex, let bA = bloomA, let bB = bloomB, let br = brightTex, let shT = shaftTex else { return }

        world.reset(); ui.reset()
        lights.removeAll(keepingCapacity: true)
        waters.removeAll(keepingCapacity: true)
        layer = world
        offset = SIMD2(0, Renderer.originY)
        drawBackground = true
        globals.screen = SIMD2(640, H)
        globals.origin = SIMD2(0, Renderer.originY)
        game.draw(self)

        var g = globals
        g.counts.x = Float(min(8, waters.count))
        g.counts.y = Float(lights.count)

        // 1. scene
        if let enc = pass(cb, scene) {
            enc.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(scene.width), height: Double(scene.height), znear: 0, zfar: 1))
            if drawBackground {
                enc.setRenderPipelineState(pso["bg"]!)
                enc.setVertexBytes(&g, length: MemoryLayout<Globals>.stride, index: 1)
                enc.setFragmentBytes(&g, length: MemoryLayout<Globals>.stride, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            drawLayer(enc, world, scene: true, &g)
            enc.endEncoding()
        }
        // 2. bloom
        func fullscreen(_ target: MTLTexture, _ name: String, _ src: MTLTexture, dir: SIMD2<Float>?) {
            guard let enc = pass(cb, target) else { return }
            enc.setRenderPipelineState(pso[name]!)
            enc.setVertexBytes(&g, length: MemoryLayout<Globals>.stride, index: 1)
            enc.setFragmentBytes(&g, length: MemoryLayout<Globals>.stride, index: 1)
            enc.setFragmentTexture(src, index: 0)
            enc.setFragmentSamplerState(samplers[1], index: 0)
            if var d = dir { enc.setFragmentBytes(&d, length: MemoryLayout<SIMD2<Float>>.stride, index: 0) }
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        fullscreen(br, "bright", scene, dir: nil)
        fullscreen(shT, "shafts", br, dir: nil)
        fullscreen(bB, "blur", br, dir: SIMD2(1 / Float(bA.width), 0))
        fullscreen(bA, "blur", bB, dir: SIMD2(0, 1 / Float(bA.height)))

        // 3. composite + UI
        guard let enc = pass(cb, target) else { return }
        enc.setViewport(MTLViewport(originX: Double((tw - vw) / 2), originY: Double((th - vh) / 2),
                                    width: Double(vw), height: Double(vh), znear: 0, zfar: 1))
        enc.setRenderPipelineState(pso["composite"]!)
        enc.setVertexBytes(&g, length: MemoryLayout<Globals>.stride, index: 1)
        enc.setFragmentBytes(&g, length: MemoryLayout<Globals>.stride, index: 1)
        enc.setFragmentTexture(scene, index: 0)
        enc.setFragmentTexture(bA, index: 1)
        enc.setFragmentTexture(shT, index: 2)
        enc.setFragmentSamplerState(samplers[1], index: 0)
        var ls = lights.isEmpty ? [LightU(posRad: .zero, color: .zero)] : lights
        enc.setFragmentBytes(&ls, length: ls.count * MemoryLayout<LightU>.stride, index: 2)
        var ws = waters.isEmpty ? [SIMD4<Float>.zero] : Array(waters.prefix(8))
        enc.setFragmentBytes(&ws, length: ws.count * MemoryLayout<SIMD4<Float>>.stride, index: 3)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        drawLayer(enc, ui, scene: false, &g)
        enc.endEncoding()
    }

    func draw(in view: MTKView, game: Game) {
        guard let drawable = view.currentDrawable, let cb = queue.makeCommandBuffer() else { return }
        encode(cb, target: drawable.texture, game: game)
        cb.present(drawable)
        cb.commit()
    }

    /// Renders one frame offscreen and returns BGRA pixels.
    func snapshot(game: Game, width: Int, height: Int) -> [UInt8]? {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let tex = device.makeTexture(descriptor: td), let cb = queue.makeCommandBuffer() else { return nil }
        encode(cb, target: tex, game: game)
        if tex.storageMode == .managed, let blit = cb.makeBlitCommandEncoder() {
            blit.synchronize(resource: tex)
            blit.endEncoding()
        }
        cb.commit()
        cb.waitUntilCompleted()
        var out = [UInt8](repeating: 0, count: width * height * 4)
        out.withUnsafeMutableBytes { raw in
            tex.getBytes(raw.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return out
    }
}
