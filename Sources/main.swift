import AppKit
import MetalKit

func NSAppTerminate() { NSApp.terminate(nil) }

final class GameView: MTKView {
    var game: Game!
    private var tracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    /// View point -> game coordinates (640 wide; y = 0 at the top of the 360-tall layout, negative in the extra sky).
    private func logical(_ e: NSEvent) -> SIMD2<Float> {
        let p = convert(e.locationInWindow, from: nil)
        let bw = Float(bounds.width), bh = Float(bounds.height)
        let H = max(360, 640 * bh / bw)
        let s = min(bw / 640, bh / H)
        let ox = (bw - 640 * s) / 2, oy = (bh - H * s) / 2
        return SIMD2((Float(p.x) - ox) / s, (bh - Float(p.y) - oy) / s - floor(H - 360))
    }

    override func mouseDown(with e: NSEvent) { game.mouseDown(logical(e), right: false) }
    override func rightMouseDown(with e: NSEvent) { game.mouseDown(logical(e), right: true) }
    override func mouseUp(with e: NSEvent) { game.mouseUp() }
    override func rightMouseUp(with e: NSEvent) { game.mouseUp() }
    override func mouseMoved(with e: NSEvent) { game.mouseMoved(logical(e)) }
    override func mouseDragged(with e: NSEvent) { game.mouseMoved(logical(e)) }
    override func mouseExited(with e: NSEvent) { game.mouse = SIMD2(-100, -100) }
    override func scrollWheel(with e: NSEvent) { game.scroll(Float(e.scrollingDeltaX), Float(e.scrollingDeltaY)) }
    override func keyDown(with e: NSEvent) {
        if e.modifierFlags.contains(.command) { super.keyDown(with: e); return }
        game.keyDown(e.keyCode, e.charactersIgnoringModifiers ?? "", repeat: e.isARepeat)
    }
    override func keyUp(with e: NSEvent) { game.keyUp(e.keyCode) }
}

final class ViewDelegate: NSObject, MTKViewDelegate {
    let renderer: Renderer
    let game: Game
    var last = CACurrentMediaTime()
    init(renderer: Renderer, game: Game) { self.renderer = renderer; self.game = game }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = min(0.1, now - last)
        last = now
        game.update(dt: dt)
        renderer.draw(in: view, game: game)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var viewDelegate: ViewDelegate!

    func applicationDidFinishLaunching(_ note: Notification) {
        guard let device = MTLCreateSystemDefaultDevice() else { fatalError("Metal is not available on this Mac") }
        guard let renderer = Renderer(device: device, pixelFormat: .bgra8Unorm) else { fatalError("Renderer setup failed") }
        audio = Audio()
        let game = Game()
        game.setScreen(.splash)

        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 720)
        let view = GameView(frame: frame, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 120
        view.framebufferOnly = true
        view.game = game
        viewDelegate = ViewDelegate(renderer: renderer, game: game)
        view.delegate = viewDelegate

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "GroundhogZ"
        window.contentView = view
        window.contentMinSize = NSSize(width: 640, height: 360)
        window.collectionBehavior = [.fullScreenPrimary]
        window.acceptsMouseMovedEvents = true
        window.backgroundColor = .black
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
        // always start in fullscreen
        if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

func buildMenu() {
    let main = NSMenu()
    let appItem = NSMenuItem()
    main.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "About GroundhogZ", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Hide GroundhogZ", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit GroundhogZ", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    let winItem = NSMenuItem()
    main.addItem(winItem)
    let winMenu = NSMenu(title: "Window")
    let fs = NSMenuItem(title: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
    fs.keyEquivalentModifierMask = [.command, .control]
    winMenu.addItem(fs)
    winMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    winItem.submenu = winMenu
    NSApp.mainMenu = main
}

// MARK: entry point

let args = CommandLine.arguments
func argValue(_ k: String) -> String? {
    guard let i = args.firstIndex(of: k), i + 1 < args.count else { return nil }
    return args[i + 1]
}

if let p = argValue("--icon") { makeIcon(p); exit(0) }
if let p = argValue("--atlas") { dumpAtlas(p); exit(0) }
if args.contains("--verify") { runVerify(argValue); exit(0) }
if args.contains("--sim") { runSim(args, value: argValue); exit(0) }
if let p = argValue("--snapshot") { runSnapshot(p, args, value: argValue); exit(0) }

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
buildMenu()
app.run()
