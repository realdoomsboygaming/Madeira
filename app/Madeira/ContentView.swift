import SwiftUI
import UIKit
import QuartzCore
import Metal
import os.log

// 2026-07-03 window-hosted Metal layer.
//
// The presenting CAMetalLayer must NOT be a SwiftUI-hosted view's backing
// layer: on iOS 26/27, SwiftUI's hosting intermittently routes such layers
// through an indirect/snapshot path where direct Metal presentations are
// silently dropped — presented drawables complete with presentedTime==0
// (measured), the screen freezes on stale content, and only full-tree
// re-renders (screenshots) reveal new frames. Which path a given run gets
// appeared random — the "sometimes rendering starts at present #9,
// sometimes never" lottery.
//
// So the layer now lives in MetalHostView, a raw UIView added directly to
// the UIWindow (classic game setup, no SwiftUI management). The SwiftUI-
// hosted MetalBackedView remains as a transparent layout placeholder that
// tracks geometry and handles touch input. The host view sits on top of
// the window but has interaction disabled, so touches fall through to the
// SwiftUI hierarchy (and thus to the placeholder's touch handlers).

/// Raw window-level host for the presenting CAMetalLayer.
final class MetalHostView: UIView {
    // Process-lifetime singleton. The CAMetalLayer is registered with DXMT's
    // swapchain exactly once; if the host were recreated on view teardown
    // (rotation, re-attach) DXMT would keep presenting to the DEAD layer —
    // black surface both ways (2026-07-05 landscape regression). One host,
    // one layer, forever; only its FRAME is re-parented/resized.
    static let shared = MetalHostView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))

    override class var layerClass: AnyClass { return CAMetalLayer.self }
    var metalLayer: CAMetalLayer { return layer as! CAMetalLayer }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false   // touches fall through to SwiftUI
        backgroundColor = .black
        contentScaleFactor = UIScreen.main.scale
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        // 2026-07-03 MeloNX trick: displaySyncEnabled is macOS-public but
        // exists as PRIVATE API on iOS. Disabling it takes our presents out
        // of the display-sync scheduling machinery — the thing that has been
        // silently dropping them (presentedTime==0 on all but occasional
        // frames) at our sub-1Hz game present cadence. MeloNX (shipping
        // Switch emulator) sets exactly this pair on its layer.
        let syncSel = NSSelectorFromString("setDisplaySyncEnabled:")
        if metalLayer.responds(to: syncSel) {
            metalLayer.perform(syncSel, with: NSNumber(value: false))
            LogStore.shared.log("MetalLayer: displaySyncEnabled=false (private API, MeloNX pattern)")
        }
        /* ml651: was hardcoded 60, which contradicted everything around it —
         * FPSOverlay asks the display link for CAFrameRateRange(preferred: 120)
         * while this declared the surface a 60Hz one. Track the screen instead.
         *
         * ⚠️ HYPOTHESIS, NOT A DIAGNOSIS. displaySyncEnabled=false directly above
         * takes our presents out of display-sync scheduling, so this nominal
         * value may well be inert. It is one line and it removes a genuine
         * contradiction; if the A/B shows nothing, the cap is elsewhere and we
         * have eliminated it rather than argued about it. */
        let fpsSel = NSSelectorFromString("setNominalFramesPerSecond:")
        if metalLayer.responds(to: fpsSel) {
            let hz = UIScreen.main.maximumFramesPerSecond
            metalLayer.perform(fpsSel, with: hz as NSNumber)
            LogStore.shared.log("MetalLayer: ml651 nominalFPS=\(hz) (was hardcoded 60; "
                                + "display link asks preferred=120)")
        }
        UIApplication.shared.isIdleTimerDisabled = true
        // Set once so DXMT's swapchain setup never blocks on a zero-sized
        // layer. After this, DXMT's setProps is the ONLY drawableSize
        // writer — per-layout rewrites from the app were a second writer
        // fighting it (pool churn on every SwiftUI layout pass).
        metalLayer.drawableSize = CGSize(width: 800, height: 600)
    }
    required init?(coder: NSCoder) { fatalError() }
}

// SwiftUI-hosted placeholder: geometry + touch input only.
final class MetalBackedView: UIView {
    private static var layerRegistered = false
    var onReady: (() -> Void)?

    static func setPresentationVisible(_ visible: Bool) {
        MetalHostView.shared.isHidden = !visible
        winios_set_compositor_visible(visible ? 1 : 0)
        UIApplication.shared.isIdleTimerDisabled = visible
        JoystickPadState.shared.hidden = !visible
        if visible { TouchControlsHost.attach() }
        else {
            keyboardTarget?.resignFirstResponder()
            TouchControlsHost.hide()
        }
    }

    // Hardware keyboard bridge: the view becomes first responder so the iOS
    // software keyboard appears, and each typed character is forwarded to
    // Wine as a virtual-key sequence (winios_post_key → send_hardware_message
    // → WM_KEYDOWN/WM_CHAR). Lets the user type into Windows dialogs (e.g.
    // Run) directly instead of relying on the browse list.
    static weak var keyboardTarget: MetalBackedView?
    override var canBecomeFirstResponder: Bool { true }
    static func toggleKeyboard() {
        guard let v = keyboardTarget else { return }
        if v.isFirstResponder { v.resignFirstResponder() }
        else { v.becomeFirstResponder() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Multi-touch REQUIRED: with it off, a fast double-tap's second
        // touch (landing before the first lift is processed) is silently
        // swallowed — drag-arm never fired (2026-07-06). Two-finger
        // scroll/right-click need it too.
        self.isMultipleTouchEnabled = true
        self.isUserInteractionEnabled = true
        self.backgroundColor = .clear
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    // Visibility-stall postmortem (2026-07-03): the intermittent "presents
    // count but the screen stays black until a bg/fg or screenshot" state
    // was probed exhaustively — drawable leaks, present pacing, panel idle,
    // SwiftUI hosting, display-sync, CADisplayLink, transaction nudges and
    // view re-attach kicks were all eliminated (none changed it; only true
    // scene-level lifecycle events land pending frames, ~1-2 each). The one
    // robust correlate is present cadence: 60 FPS content always displays,
    // ~1 FPS content mostly doesn't. Resolution path: raise game FPS (perf
    // work), with a steady-rate re-present in DXMT as fallback insurance.

    /// Largest 4:3 rect (the 1024×768 logical surface's aspect) that fits
    /// centered in our bounds. The window-level host view gets THIS frame,
    /// not our full bounds — otherwise landscape stretches the game to the
    /// display edges (2026-07-05). Touch mapping uses the same rect so
    /// letterboxing never skews input.
    private func gameRect() -> CGRect {
        let gw: CGFloat = 1024, gh: CGFloat = 768
        let scale = min(bounds.width / gw, bounds.height / gh)
        let w = gw * scale, h = gh * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2,
                      width: max(w, 1), height: max(h, 1))
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let w = window else { return }   // detach: leave the host be
        MetalBackedView.keyboardTarget = self  // keyboard button targets the live view
        // SwiftUI ancestors attach gesture recognizers that can delay or
        // cancel raw touch delivery (double-tap timing is exactly what
        // they punish). Defuse them for our subtree.
        var v: UIView? = self
        while let s = v {
            s.gestureRecognizers?.forEach {
                $0.cancelsTouchesInView = false
                $0.delaysTouchesBegan = false
                $0.delaysTouchesEnded = false
            }
            v = s.superview
        }
        let host = MetalHostView.shared
        if host.superview !== w {
            host.removeFromSuperview()
            w.addSubview(host)
        }
        host.frame = convert(gameRect(), to: w)
        // S2 desktop mode: the winios compositor renders the wine virtual
        // desktop aspect-fit inside THIS placeholder's area, exactly like
        // the games' Metal layer — never over the whole phone screen.
        let full = convert(bounds, to: w)
        winios_set_compositor_frame(full.minX, full.minY, full.width, full.height)
        if !Self.layerRegistered {
            Self.layerRegistered = true
            madeira_display_set_layer(host.metalLayer)
            LogStore.shared.log("MetalLayer registered with DXMT shim (window-hosted singleton)", level: .success)
        }
        Self.setPresentationVisible(true)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            let callback = self.onReady
            self.onReady = nil
            callback?()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let w = window {
            MetalHostView.shared.frame = convert(gameRect(), to: w)
            let full = convert(bounds, to: w)
            winios_set_compositor_frame(full.minX, full.minY, full.width, full.height)
        }
    }

    // Map touch point in view-local UI points to the 1024×768 logical
    // surface DXMT swapchains use, then post to winios.drv. Coordinates
    // are relative to the aspect-fit gameRect (letterbox borders clamp).
    private func mapTouch(_ touch: UITouch) -> (Int32, Int32) {
        let p = touch.location(in: self)
        let r = gameRect()
        let x = Int32(min(max((p.x - r.minX) * 1024 / r.width, 0), 1023))
        let y = Int32(min(max((p.y - r.minY) * 768 / r.height, 0), 767))
        return (x, y)
    }

    // ==================================================================
    // S2 desktop mode: trackpad-style pointer.
    //   one finger move       — cursor moves relative (like a laptop pad)
    //   single tap            — left click
    //   double tap            — double click (two rapid clicks)
    //   double tap + hold     — drag (button held while moving), lift = drop
    //   two-finger drag       — scroll wheel
    //   two-finger tap        — right click
    // Cursor position lives here (desktop px); wine + the rendered arrow
    // follow via winios_pointer / winios_cursor_move.
    // ==================================================================
    private static var cursor = CGPoint(x: 480, y: 270)
    private var lastPanPoint = CGPoint.zero
    private var touchStartPoint = CGPoint.zero
    private var touchStartTime: TimeInterval = 0
    private var movedBeyondSlop = false
    private var dragActive = false
    private var dragTouch: UITouch?          // the finger that owns the drag
    private var touchGeneration = 0          // invalidates pending long-press timers
    private var twoFingerActive = false
    private var twoFingerMoved = false
    private var twoFingerStartTime: TimeInterval = 0
    private var lastTwoFingerY: CGFloat = 0
    private var scrollAccum: CGFloat = 0
    // ml641: relative motion is scaled by a float sensitivity, so the integer
    // delta we hand to wine loses a fraction every event. At low sensitivity
    // that truncation is the whole signal — carry the remainder or slow drags
    // simply do nothing.
    private var relCarryX: CGFloat = 0
    private var relCarryY: CGFloat = 0

    private let F_MOVE: UInt32 = 0x1, F_LDOWN: UInt32 = 0x2, F_LUP: UInt32 = 0x4
    private let F_RDOWN: UInt32 = 0x8, F_RUP: UInt32 = 0x10
    private let F_WHEEL: UInt32 = 0x800, F_ABS: UInt32 = 0x8000

    private var desktopMode: Bool {
        guard let v = getenv("MADEIRA_DESKTOP") else { return false }
        return v.pointee == 49  // '1'
    }
    private func envInt(_ name: String, _ def: Int) -> Int {
        guard let v = getenv(name), let i = Int(String(cString: v)) else { return def }
        return i
    }
    private func postPointer(_ flags: UInt32, data: Int32 = 0) {
        winios_pointer(Int32(Self.cursor.x), Int32(Self.cursor.y), flags, UInt32(bitPattern: data))
    }
    private func avgPoint(_ touches: [UITouch]) -> CGPoint {
        var x: CGFloat = 0, y: CGFloat = 0
        for t in touches { let p = t.location(in: self); x += p.x; y += p.y }
        let n = CGFloat(max(touches.count, 1))
        return CGPoint(x: x / n, y: y / n)
    }
    private func activeTouches(_ event: UIEvent?) -> [UITouch] {
        (event?.allTouches ?? []).filter { $0.phase != .ended && $0.phase != .cancelled }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard desktopMode else {
            guard let t = touches.first else { return }
            let (x, y) = mapTouch(t)
            winios_post_touch_down(x, y)
            return
        }
        let now = Date().timeIntervalSinceReferenceDate
        let active = activeTouches(event)
        touchGeneration += 1
        if active.count >= 2 {
            twoFingerActive = true
            twoFingerMoved = false
            twoFingerStartTime = now
            lastTwoFingerY = avgPoint(active).y
            scrollAccum = 0
            // a drag started by the first finger stays active; harmless
            return
        }
        guard let t = touches.first else { return }
        let p = t.location(in: self)
        touchStartPoint = p
        lastPanPoint = p
        touchStartTime = now
        movedBeyondSlop = false
        relCarryX = 0; relCarryY = 0   // ml641: never carry motion across a lift
        // long-press → drag: hold still for 0.5s, haptic confirms, then move
        // the window; release drops. (Replaced double-tap-hold — it raced
        // Windows' double-click detection: wine saw WM_LBUTTONDBLCLK.)
        let gen = touchGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.touchGeneration == gen, !self.dragActive,
                  !self.movedBeyondSlop, !self.twoFingerActive,
                  // ml643: in mouse-look the finger is the CAMERA, not a pointer.
                  // Holding still to line up a shot must not press the mouse.
                  !InputSettings.shared.relative else { return }
            self.dragActive = true
            self.dragTouch = t
            self.postPointer(self.F_LDOWN)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            fputs("[trackpad] long-press drag armed\n", stderr)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard desktopMode else {
            guard let t = touches.first else { return }
            let (x, y) = mapTouch(t)
            winios_post_touch_move(x, y)
            return
        }
        let active = activeTouches(event)
        if twoFingerActive {
            guard active.count >= 2 else { return }
            let avg = avgPoint(active)
            let dy = avg.y - lastTwoFingerY
            lastTwoFingerY = avg.y
            if abs(dy) > 2 { twoFingerMoved = true }
            scrollAccum += dy
            // 14pt of finger travel = one wheel notch. ml641 flipped the sign:
            // on a touchscreen the content follows the finger, so dragging UP
            // scrolls DOWN through the document. It was mouse-wheel sense before.
            while scrollAccum <= -14 { scrollAccum += 14; postPointer(F_WHEEL, data: -120) }
            while scrollAccum >= 14 { scrollAccum -= 14; postPointer(F_WHEEL, data: 120) }
            return
        }
        let t: UITouch
        if dragActive, let d = dragTouch {
            guard touches.contains(d) else { return }  // only the old tap finger moved
            t = d
        } else {
            guard let f = touches.first else { return }
            t = f
        }
        let p = t.location(in: self)
        let dx = p.x - lastPanPoint.x, dy = p.y - lastPanPoint.y
        lastPanPoint = p
        if hypot(p.x - touchStartPoint.x, p.y - touchStartPoint.y) > 10 { movedBeyondSlop = true }

        /* ml641 RELATIVE (mouse-look) MODE.
         *
         * Absolute input is what made the camera spin. We post a POSITION; wine
         * turns it into the delta the game reads as
         *     x - desktop_shm->cursor.x            (queue_ios.c:2290)
         * A game that locks the cursor calls ClipCursor, and update_desktop_cursor_pos
         * then CLAMPS desktop_shm->cursor into that rect, pinning it. Our own
         * Self.cursor keeps wandering across the full 1024x768, so the subtraction
         * yields (wandering - pinned): a huge delta that never converges and is
         * re-sent on every event. Spin rate depends on WHERE the finger is, not how
         * fast it moves.
         *
         * Posting device motion instead makes that impossible to reproduce: wine
         * computes cursor.x + dx, so the delta is exactly dx no matter what the
         * game does to the cursor. No F_ABS, and Self.cursor is deliberately not
         * touched — in this mode it has no meaning.
         *
         * Sign follows PUBG/Fortnite: drag right -> view turns right -> the world
         * slides left, so a target to the RIGHT of the crosshair is pulled onto it
         * by dragging RIGHT. That is the same sign as a mouse. Negate both terms
         * for content-drag (finger-follows-world) feel. */
        if InputSettings.shared.relative {
            let sens = CGFloat(InputSettings.shared.sensRel)
            relCarryX += dx * sens
            relCarryY += dy * sens
            let ix = Int32(max(-30000, min(30000, relCarryX)))
            let iy = Int32(max(-30000, min(30000, relCarryY)))
            relCarryX -= CGFloat(ix)
            relCarryY -= CGFloat(iy)
            if ix != 0 || iy != 0 { winios_pointer(ix, iy, F_MOVE, 0) }
            return
        }

        let sens = CGFloat(InputSettings.shared.sensAbs)   // desktop px per view pt
        let maxX = CGFloat(envInt("MADEIRA_SCREEN_W", 1024) - 1)
        let maxY = CGFloat(envInt("MADEIRA_SCREEN_H", 768) - 1)
        Self.cursor.x = min(max(Self.cursor.x + dx * sens, 0), maxX)
        Self.cursor.y = min(max(Self.cursor.y + dy * sens, 0), maxY)
        postPointer(F_MOVE | F_ABS)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard desktopMode else {
            guard let t = touches.first else { return }
            let (x, y) = mapTouch(t)
            winios_post_touch_up(x, y)
            return
        }
        let now = Date().timeIntervalSinceReferenceDate
        if twoFingerActive {
            if activeTouches(event).isEmpty {
                if !twoFingerMoved && now - twoFingerStartTime < 0.40
                    && !InputSettings.shared.relative {   // ml643: see touchesBegan
                    postPointer(F_RDOWN)
                    postPointer(F_RUP)
                }
                twoFingerActive = false
            }
            return
        }
        touchGeneration += 1   // cancel any pending long-press
        if dragActive {
            if let d = dragTouch, !touches.contains(d) {
                fputs("[trackpad] ended: non-drag finger up (drag continues)\n", stderr)
                return
            }
            fputs("[trackpad] ended: drag drop\n", stderr)
            postPointer(F_LUP)
            dragActive = false
            dragTouch = nil
            return
        }
        // stationary release before the 0.5s drag threshold = click.
        // ml643: NOT in relative mode — every small aim adjustment would fire the
        // weapon. Left/right click are on-screen buttons there instead.
        if !movedBeyondSlop && now - touchStartTime < 0.5 && !InputSettings.shared.relative {
            fputs("[trackpad] ended: click\n", stderr)
            postPointer(F_LDOWN)
            postPointer(F_LUP)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard desktopMode else {
            guard let t = touches.first else { return }
            let (x, y) = mapTouch(t)
            winios_post_touch_up(x, y)
            return
        }
        fputs("[trackpad] CANCELLED (dragActive=\(dragActive))\n", stderr)
        touchGeneration += 1
        if dragActive { postPointer(F_LUP); dragActive = false }
        dragTouch = nil
        twoFingerActive = false
    }
}

/// Arrow-key button with press/hold/release semantics. DragGesture with
/// zero minimum distance fires onChanged at touch-down (key down once)
/// and onEnded at lift (key up) — unlike Button, which only taps.
struct HoldKeyView: View {
    let label: String
    let vk: Int32
    var big = false   // landscape D-pad: thumb-sized
    @State private var isDown = false

    var body: some View {
        Text(label)
            .font(.system(size: big ? 22 : 14, weight: .semibold, design: .monospaced))
            .foregroundColor(.white)
            .frame(minWidth: big ? 56 : 34, minHeight: big ? 56 : 30)
            .background(Color.white.opacity(isDown ? 0.35 : 0.15))
            .cornerRadius(big ? 12 : 6)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isDown {
                            isDown = true
                            winios_post_key(vk, 1)
                        }
                    }
                    .onEnded { _ in
                        isDown = false
                        winios_post_key(vk, 0)
                    }
            )
    }
}

/// Shared state for the expanded thumbstick pad. The pad cannot be drawn by
/// SwiftUI in place: the game surface is a raw window-level UIView
/// (MetalHostView.shared) sitting ABOVE the entire SwiftUI hierarchy, so a
/// SwiftUI pad centred on the key row gets sliced off wherever it overlaps —
/// no zIndex can fix that, because zIndex only orders siblings *within*
/// SwiftUI. So the pad is hosted in the window too, added after (and thus
/// above) the Metal view, and driven from the SwiftUI button through this.
final class JoystickPadState: ObservableObject {
    static let shared = JoystickPadState()
    @Published var held = false
    @Published var dir: Int = -1
    @Published var center: CGPoint = .zero      // window coordinates
    /// ml641: driven by the pointer panel. The pad is NOT a sibling of the key
    /// row — it lives in its own UIWindow one level up (that is the whole point
    /// of this class), so the row's .transition(.opacity) cannot reach it and it
    /// stayed visible while every other button faded. It has to fade itself.
    @Published var hidden = false
}

/// Window-level host for the pad. Transparent and non-interactive: the
/// SwiftUI button keeps the gesture, this only draws.
enum JoystickPadHost {
    /// Own UIWindow, one level above the app's. Being a sibling subview of
    /// MetalHostView is NOT enough: that view re-adds itself to the window on
    /// every didMoveToWindow (rotation, re-attach) and DXMT/CoreAnimation can
    /// reorder around it, so any subview ordering we impose is only true until
    /// the next layout. A higher windowLevel cannot be undone by anything
    /// inside the app window, so the pad is unconditionally on top.
    ///
    /// Deliberately NOT solved by changing the game surface: the CAMetalLayer
    /// is window-level precisely because SwiftUI hosting silently dropped
    /// presents on iOS 26/27 (see MetalHostView) — that is a rendering
    /// correctness fix and must not be traded away for z-ordering.
    private static var overlay: PassthroughWindow?

    static func attach(to scene: UIWindowScene) {
        if overlay == nil {
            let w = PassthroughWindow(windowScene: scene)
            w.windowLevel = .normal + 100
            w.backgroundColor = .clear
            w.isHidden = false                 // never becomes key: see PassthroughWindow
            let host = UIHostingController(rootView: JoystickPadOverlay())
            host.view.backgroundColor = .clear
            host.view.isUserInteractionEnabled = false
            w.rootViewController = host
            overlay = w
        }
        overlay?.frame = scene.coordinateSpace.bounds
    }
}

/// Transparent, fully click-through window: hitTest always returns nil, so
/// touches fall through to the app window underneath and the pad can never
/// steal input from the game surface or the SwiftUI controls.
final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

/// The expanded pad, drawn in window space at the button's location.
struct JoystickPadOverlay: View {
    @ObservedObject private var s = JoystickPadState.shared

    var body: some View {
        GeometryReader { _ in
            // THE one and only joystick face — idle ring and expanded pad are
            // the same view, never two that swap. That identity is what makes
            // it seamless: the diameter and the knob offset are plain animated
            // properties, so releasing lets the knob spring back to centre and
            // keep wiggling after the ring has already shrunk. Two faces
            // cross-fading (one in the button, one here) cannot do that — the
            // wiggle dies with the copy that gets faded out.
            //
            // Fixed-size box at a CONSTANT offset. Deliberately not
            // .position() + .transition(.scale): .position expands the view to
            // fill the parent (so a .center anchor means mid-screen), and an
            // offset that changes in the same transaction as `held` gets
            // animated too — which is what made the pad fly in from the top.
            // Here the only animatable quantities belong to the face itself.
            JoystickFace(held: s.held, dir: s.dir)
                .frame(width: JoystickFace.padRadius * 2,
                       height: JoystickFace.padRadius * 2)
                .offset(x: s.center.x - JoystickFace.padRadius,
                        y: s.center.y - JoystickFace.padRadius)
                .opacity(s.center == .zero ? 0 : 1)
        }
        // MUST ignore the safe area. s.center comes from the button's .global
        // frame, which is measured from the WINDOW origin; without this the
        // overlay's hosting view is inset by the safe area, the offset above
        // is measured from below the status bar, and the pad lands ~59pt too
        // low — roughly one pad radius, which is exactly why it appeared to
        // sit under the game strip instead of centred on the button.
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .opacity(s.hidden ? 0 : 1)
        .animation(.easeInOut(duration: 0.28), value: s.hidden)
        .animation(.spring(response: 0.32, dampingFraction: 0.62), value: s.held)
        .animation(.spring(response: 0.22, dampingFraction: 0.58), value: s.dir)
    }
}

/// The joystick face itself, shared by the in-row idle ring and the expanded
/// window-level pad so both look identical and animate the same way.
struct JoystickFace: View {
    var held: Bool
    var dir: Int
    /// ml646: the portrait pad grows out of a key-sized ring when you hold it.
    /// An overlay stick is a PERMANENT control — it must be full size at rest
    /// with only the knob moving, so size is decoupled from press here rather
    /// than faked by passing held:true (which would also kill the knob travel
    /// and the press styling).
    var alwaysExpanded = false
    private var expanded: Bool { held || alwaysExpanded }

    static let idleDiameter: CGFloat = 22
    static let padRadius: CGFloat = 58
    private var idleDiameter: CGFloat { Self.idleDiameter }
    private var padRadius: CGFloat { Self.padRadius }
    private let knobTravelRatio: CGFloat = 0.30

    @ViewBuilder private var interior: some View {
        Circle().fill(.ultraThinMaterial)
    }

    private func knobOffset(_ d: CGFloat) -> CGSize {
        guard dir >= 0, expanded else { return .zero }
        let travel = d * knobTravelRatio
        let a = Double(dir) * 45.0 * .pi / 180.0
        return CGSize(width: travel * CGFloat(sin(a)), height: -travel * CGFloat(cos(a)))
    }

    var body: some View {
        let d = expanded ? padRadius * 2 : idleDiameter
        return ZStack {
            interior
            Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: expanded ? 2 : 1.5)
            Circle()
                .fill(Color.white)
                .frame(width: d * 0.42, height: d * 0.42)
                .overlay(
                    // Roundness cue. It reads at key size but turns into a
                    // smudge on the big pad, so it fades out as the ring
                    // springs open rather than scaling up with it.
                    Circle()
                        .trim(from: 0.55, to: 0.70)
                        .stroke(Color.black.opacity(0.38),
                                style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                        .padding(d * 0.075)
                        .opacity(expanded ? 0 : 1)
                )
                .offset(knobOffset(d))
        }
        .frame(width: d, height: d)
    }
}

/// On-screen thumbstick. Idle it is a key-sized ring with a white knob;
/// press and hold and it expands into a pad you can steer. Travel snaps to
/// eight d-pad directions, each mapped to the arrow keys Windows games
/// already understand — diagonals simply hold two keys at once — so this
/// needs no new input path: it posts through the same winios_post_key queue
/// as the key buttons, and key state is edge-triggered (only the keys that
/// actually changed are sent on each snap).
///
/// The pad expands DOWNWARD. It must never grow up into the game strip:
/// that surface is a raw window-level UIView (MetalHostView.shared) drawn
/// over SwiftUI, so anything overlapping it is simply covered.
struct JoystickKeyView: View {
    @State private var held = false
    @State private var dir: Int = -1        // -1 = centred, else 0=up then clockwise
    @State private var center: CGPoint = .zero
    @State private var hosted = false       // overlay window up: it draws the face

    private let deadzone: CGFloat = 14      // pt of travel before a direction registers

    private let vkUp: Int32 = 0x26, vkRight: Int32 = 0x27
    private let vkDown: Int32 = 0x28, vkLeft: Int32 = 0x25

    private func keys(for d: Int) -> [Int32] {
        switch d {
        case 0: return [vkUp]
        case 1: return [vkUp, vkRight]
        case 2: return [vkRight]
        case 3: return [vkDown, vkRight]
        case 4: return [vkDown]
        case 5: return [vkDown, vkLeft]
        case 6: return [vkLeft]
        case 7: return [vkUp, vkLeft]
        default: return []
        }
    }

    /// Release what is no longer held, press what newly is — never a blanket
    /// release/re-press, which would make a held direction stutter as the
    /// thumb wanders inside one sector.
    private func apply(_ next: Int) {
        guard next != dir else { return }
        let old = Set(keys(for: dir)), new = Set(keys(for: next))
        for vk in old.subtracting(new) { winios_post_key(vk, 0) }
        for vk in new.subtracting(old) { winios_post_key(vk, 1) }
        dir = next
        JoystickPadState.shared.dir = next
    }

    private func snap(_ t: CGSize) -> Int {
        let d = (t.width * t.width + t.height * t.height).squareRoot()
        if d < deadzone { return -1 }
        // Screen y grows downward; measure clockwise from "up".
        var a = atan2(t.width, -t.height) * 180 / .pi
        if a < 0 { a += 360 }
        return Int((a + 22.5) / 45.0) % 8
    }

    var body: some View {
        // The idle ring lives in the row (inset inside the 34x30 button so it
        // has breathing room). The EXPANDED pad is drawn by the window-level
        // host at this same centre — see JoystickPadState — so it springs out
        // of the button in place and is never clipped by the game surface.
        Color.clear
            .frame(width: 34, height: 30)
            .background(Color.white.opacity(held ? 0.30 : 0.15))
            .cornerRadius(6)
            .overlay { if !hosted { JoystickFace(held: false, dir: -1) } }
            .background(
                GeometryReader { geo in
                    Color.clear.onAppear {
                        center = CGPoint(x: geo.frame(in: .global).midX,
                                         y: geo.frame(in: .global).midY)
                        JoystickPadState.shared.center = center
                        if let scene = UIApplication.shared.connectedScenes
                            .compactMap({ $0 as? UIWindowScene }).first {
                            JoystickPadHost.attach(to: scene)
                            hosted = true
                        }
                    }
                    .onChange(of: geo.frame(in: .global)) { f in
                        center = CGPoint(x: f.midX, y: f.midY)
                        JoystickPadState.shared.center = center
                    }
                }
            )
            .animation(.spring(response: 0.32, dampingFraction: 0.62), value: held)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !held {
                            held = true
                            if let scene = UIApplication.shared.connectedScenes
                                .compactMap({ $0 as? UIWindowScene }).first {
                                JoystickPadHost.attach(to: scene)
                            }
                            JoystickPadState.shared.center = center
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) {
                                JoystickPadState.shared.held = true
                            }
                        }
                        apply(snap(g.translation))
                    }
                    .onEnded { _ in
                        apply(-1)                        // releases every held arrow
                        held = false
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) {
                            JoystickPadState.shared.held = false
                        }
                    }
            )
    }
}

// SwiftUI wrapper around the placeholder view.
// iOS software-keyboard → Wine key events. Each character is mapped to a
// US-layout virtual-key (+ shift where needed) and posted as a down/up pair;
// the message queue's ToUnicode then produces the right WM_CHAR. Paths need
// the full symbol set (":" "\" "-" "." "_"), so the table is comprehensive.
extension MetalBackedView: UIKeyInput {
    var hasText: Bool { false }

    // US-keyboard VK + shift for a character. Returns nil for chars we can't map.
    private static func vkForChar(_ ch: Character) -> (Int32, Bool)? {
        if ch == "\n" || ch == "\r" { return (0x0D, false) }   // VK_RETURN
        if ch == "\t" { return (0x09, false) }                 // VK_TAB
        if ch == " " { return (0x20, false) }                  // VK_SPACE
        if ch.isLetter, let up = ch.uppercased().first?.asciiValue, up >= 0x41, up <= 0x5A {
            return (Int32(up), ch.isUppercase)                 // VK_A..VK_Z
        }
        if let a = ch.asciiValue, a >= 0x30, a <= 0x39 {
            return (Int32(a), false)                           // VK_0..VK_9 (unshifted)
        }
        let table: [Character: (Int32, Bool)] = [
            "!": (0x31, true), "@": (0x32, true), "#": (0x33, true), "$": (0x34, true),
            "%": (0x35, true), "^": (0x36, true), "&": (0x37, true), "*": (0x38, true),
            "(": (0x39, true), ")": (0x30, true),
            "-": (0xBD, false), "_": (0xBD, true),
            "=": (0xBB, false), "+": (0xBB, true),
            "[": (0xDB, false), "{": (0xDB, true),
            "]": (0xDD, false), "}": (0xDD, true),
            "\\": (0xDC, false), "|": (0xDC, true),
            ";": (0xBA, false), ":": (0xBA, true),
            "'": (0xDE, false), "\"": (0xDE, true),
            ",": (0xBC, false), "<": (0xBC, true),
            ".": (0xBE, false), ">": (0xBE, true),
            "/": (0xBF, false), "?": (0xBF, true),
            "`": (0xC0, false), "~": (0xC0, true),
        ]
        return table[ch]
    }

    func insertText(_ text: String) {
        for ch in text {
            guard let (vk, shift) = MetalBackedView.vkForChar(ch) else { continue }
            if shift { winios_post_key(0x10, 1) }   // VK_SHIFT down
            winios_post_key(vk, 1)
            winios_post_key(vk, 0)
            if shift { winios_post_key(0x10, 0) }    // VK_SHIFT up
        }
    }

    func deleteBackward() {
        winios_post_key(0x08, 1)   // VK_BACK down
        winios_post_key(0x08, 0)
    }

    // Traits: keep iOS from rewriting path characters.
    var keyboardType: UIKeyboardType { get { .asciiCapable } set {} }
    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
    var smartDashesType: UITextSmartDashesType { get { .no } set {} }
    var spellCheckingType: UITextSpellCheckingType { get { .no } set {} }
}

/// Pointer settings, persisted to the app container.
///
/// ml641. Two independent sensitivities, because the two modes mean different
/// things and a single slider would fight itself:
///   • absolute  — trackpad gain, desktop px per view pt. This IS the old
///     hardcoded `sens = 2.0`, so the default reproduces today's desktop feel
///     exactly.
///   • relative  — mouse counts per view pt for mouse-look. What the right value
///     is depends on the GAME's own sensitivity and FOV, which we cannot see, so
///     it has to be calibrated by hand once. See the comment in touchesMoved.
///
/// Stored as JSON in Documents/ rather than UserDefaults: that is the container
/// we already know survives reinstall (verified), and it can be pulled and
/// edited with the same devicectl command we use for the log.
final class InputSettings: ObservableObject {
    static let shared = InputSettings()

    @Published var relative: Bool  = false { didSet { save() } }
    @Published var sensAbs:  Double = 2.0  { didSet { save() } }
    @Published var sensRel:  Double = 2.0  { didSet { save() } }
    /// ml649: heavy diagnostics. Default OFF so the shipped default is the fast
    /// path; flip it on only when a run needs to be explainable.
    @Published var diagnostics = false { didSet { madeira_set_diag_enabled(diagnostics ? 1 : 0); save() } }

    /// didSet fires for assignments made in init() because the properties are
    /// already initialised by then; without this the first launch would write
    /// the defaults back over a file it had only half-read.
    private var loading = false

    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("madeira-input.json")
    }

    private init() {
        loading = true
        if let d = try? Data(contentsOf: Self.url),
           let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            relative = j["relative"] as? Bool   ?? false
            sensAbs  = j["sensAbs"]  as? Double ?? 2.0
            sensRel  = j["sensRel"]  as? Double ?? 2.0
            diagnostics = j["diagnostics"] as? Bool ?? false
        }
        loading = false
        madeira_set_diag_enabled(diagnostics ? 1 : 0)   // push the restored value down
    }

    private func save() {
        guard !loading else { return }
        let j: [String: Any] = ["relative": relative, "sensAbs": sensAbs, "sensRel": sensRel, "diagnostics": diagnostics]
        guard let d = try? JSONSerialization.data(withJSONObject: j) else { return }
        try? d.write(to: Self.url, options: .atomic)
    }
}

struct MadeiraMetalView: UIViewRepresentable {
    var onReady: (() -> Void)? = nil
    func makeUIView(context: Context) -> MetalBackedView {
        let view = MetalBackedView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.onReady = onReady
        return view
    }
    func updateUIView(_ uiView: MetalBackedView, context: Context) {}
    static func dismantleUIView(_ uiView: MetalBackedView, coordinator: ()) {
        if MetalBackedView.keyboardTarget === uiView {
            MetalBackedView.setPresentationVisible(false)
            MetalBackedView.keyboardTarget = nil
        }
    }
}

struct SetupGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {   /* ml658: see the note on the main body */
            List {
                Section("Requirements") {
                    if StikJITHelper.usesJailbreakSupport {
                        guideRow(
                            icon: "cpu",
                            title: "Automatic JIT (jailbreak)",
                            detail: "Madeira enables the in-process JIT path at launch. No SideStore or StikDebug action is required. Tweak injection must be enabled for Madeira."
                        )
                    } else if StikJITHelper.usesLegacyJIT {
                        guideRow(
                            icon: "cpu",
                            title: "JIT Compilation",
                            detail: "Required for x86 code translation. On iOS 16, enable JIT for Madeira from SideStore before launching the app."
                        )
                    } else {
                        guideRow(
                            icon: "cpu",
                            title: "JIT Compilation",
                            detail: "Required for x86 code translation. On iOS 26, assign the 'universal' or 'MeloNX' JIT script to Madeira in StikDebug."
                        )
                    }
                    guideRow(
                        icon: "memorychip",
                        title: "Increased Memory Limit",
                        detail: StikJITHelper.usesJailbreakSupport
                            ? "Madeira requests the maximum Jetsam limit automatically through the jailbreak memorystatus API."
                            : "Raises the Jetsam memory threshold. Included in the app entitlements. If not detected, use GetMoreRam to inject it."
                    )
                    guideRow(
                        icon: "arrow.up.left.and.arrow.down.right",
                        title: "Extended Virtual Addressing",
                        detail: "The extended-virtual-addressing entitlement is included for signing systems that permit it. A jailbreak can preserve or inject restricted entitlements; otherwise this row may remain unavailable."
                    )
                }

                Section("Setup Steps") {
                    if StikJITHelper.usesJailbreakSupport {
                        stepRow(number: 1, text: "Install Madeira with jailbreak tweak injection enabled")
                        stepRow(number: 2, text: "Launch Madeira; it automatically enables JIT and requests the memory-limit override")
                        stepRow(number: 3, text: "Tap 'Enable JIT' only if you want to retry the jailbreak setup")
                    } else {
                        stepRow(number: 1, text: "Install Madeira via SideStore or Xcode")
                        stepRow(number: 2, text: "Install GetMoreRam and run it to inject memory entitlements into your App ID")
                        stepRow(number: 3, text: "Reinstall Madeira with the same IPA to apply injected entitlements")
                    }
                    if StikJITHelper.usesJailbreakSupport {
                        stepRow(number: 4, text: "Verify the JIT and Memory+ badges, then tap 'Test JIT'")
                    } else if StikJITHelper.usesLegacyJIT {
                        stepRow(number: 4, text: "In SideStore, long-press Madeira and choose 'Enable JIT'")
                    } else {
                        stepRow(number: 4, text: "In StikDebug, assign the 'universal' JIT script to Madeira and launch it")
                    }
                    stepRow(number: 5, text: "Launch Madeira and tap 'Test JIT' to verify")
                }

                Section("About") {
                    Text("Madeira is a proof-of-concept for running x86 Windows games on iOS using FEX-Emu, Wine, and Metal-based graphics translation.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Setup Guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func guideRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).fontWeight(.medium)
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func stepRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption).fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.subheadline)
        }
        .padding(.vertical, 2)
    }
}

// ============================================================================
// ml643 — LANDSCAPE TOUCH CONTROLS (pass 1: overlay, editor, persistence)
//
// This is the L2 layer from reference_swiftui_liquid_glass_ux_layers.md: glass
// elements composited over the game canvas, repositionable.
//
// 🔑 Everything here MUST live in its own UIWindow. MetalHostView is a raw
// window-level UIView above the whole SwiftUI hierarchy, so a control drawn in
// the normal content tree gets sliced off wherever it overlaps the game surface
// — and zIndex cannot fix that, because zIndex only orders siblings *within*
// SwiftUI. Same reason JoystickPadHost exists; see its comment.
// ============================================================================

/// What a control does when pressed. Codable with associated values so the
/// whole layout round-trips through JSON.
enum ControlAction: Codable, Equatable, Hashable {
    case none
    case key(Int32)          // Windows virtual-key code
    case mouseLeft
    case mouseRight
    case joystickWASD        // renders as a stick, posts W/A/S/D
    case joystickArrows      // renders as a stick, posts the arrow keys
    case keyboardToggle      // raises the iOS keyboard, as in portrait
    case pad(String)         // ml645: Xbox button. NOT WIRED — see the panel.

    /// The four keys a stick drives, up/right/down/left. nil for non-sticks.
    var stickKeys: [Int32]? {
        switch self {
        case .joystickWASD:   return [0x57, 0x44, 0x53, 0x41]   // W D S A
        case .joystickArrows: return [0x26, 0x27, 0x28, 0x25]   // up right down left
        default: return nil
        }
    }
    var isPad: Bool { if case .pad = self { return true }; return false }

    var label: String {
        switch self {
        case .none:            return "—"
        case .mouseLeft:       return "L"
        case .mouseRight:      return "R"
        case .keyboardToggle:  return "⌨"
        case .joystickWASD:    return "WASD"
        case .joystickArrows:  return "↕"
        case .pad(let n):      return n
        case .key(let vk):     return ControlAction.keyLabel(vk)
        }
    }

    /// Minimal for pass 1 — the full VK table arrives with the mapping panel.
    static func keyLabel(_ vk: Int32) -> String {
        switch vk {
        case 0x0D: return "⏎"
        case 0x20: return "␣"
        case 0x1B: return "Esc"
        case 0x09: return "⇥"
        case 0x10: return "⇧"
        case 0x11: return "Ctl"
        case 0x12: return "Alt"
        case 0x25: return "←"
        case 0x26: return "↑"
        case 0x27: return "→"
        case 0x28: return "↓"
        default:
            if vk >= 0x30, vk <= 0x5A, let u = UnicodeScalar(UInt32(vk)) {
                return String(Character(u))
            }
            return String(format: "%02X", vk)
        }
    }
}

/// One on-screen control.
///
/// Position is NORMALISED (0–1 of the screen), never points: the device gets
/// rotated and the logical surface can change size, and a layout stored in
/// absolute coordinates scatters the first time either happens.
struct TouchControl: Codable, Identifiable, Equatable {
    var id = UUID()
    var nx: Double = 0.5
    var ny: Double = 0.5
    var scale: Double = 1.0
    var action: ControlAction = .mouseLeft   // usable the moment it is created
}

final class TouchControlsModel: ObservableObject {
    static let shared = TouchControlsModel()
    static let baseDiameter: CGFloat = 64

    @Published var controls: [TouchControl] = [] { didSet { save() } }
    @Published var visible = true               { didSet { save() } }
    @Published var editing = false              // transient, never persisted
    @Published var selected: UUID?              // transient

    private var loading = false
    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("madeira-controls.json")
    }

    private struct Saved: Codable { var controls: [TouchControl]; var visible: Bool }

    private init() {
        loading = true
        if let d = try? Data(contentsOf: Self.url),
           let s = try? JSONDecoder().decode(Saved.self, from: d) {
            controls = s.controls
            visible  = s.visible
        }
        loading = false
    }

    private func save() {
        guard !loading else { return }
        guard let d = try? JSONEncoder().encode(Saved(controls: controls, visible: visible))
        else { return }
        try? d.write(to: Self.url, options: .atomic)
    }

    func index(of id: UUID?) -> Int? {
        guard let id else { return nil }
        return controls.firstIndex { $0.id == id }
    }

    /// ml644: does this WINDOW point land on something interactive?
    ///
    /// Hit-test geometrically, never by walking the UIView hierarchy. SwiftUI
    /// does not back each Button with its own UIView — the entire overlay is one
    /// _UIHostingView and taps are routed by SwiftUI's own gesture machinery. So
    /// `super.hitTest` returns that same hosting view for EVERY point, buttons
    /// included, and ml643's "is it the root view?" test therefore rejected every
    /// touch in the window. Nothing responded, and edit mode — whose branch
    /// captured everything — could never be entered to mask it.
    func hitsInteractive(_ p: CGPoint, in bounds: CGRect) -> Bool {
        // Leave the play screen's navigation bar accessible above the editor.
        // Padded generously; a few points of slop costs nothing and a missed tap
        // costs a build.
        let barW: CGFloat = 2 * 44 + 10
        if CGRect(x: bounds.midX - barW / 2 - 10, y: 94,
                  width: barW + 20, height: 68).contains(p) { return true }
        guard visible else { return false }
        for c in controls {
            let r = Self.baseDiameter * CGFloat(c.scale) / 2
            let cx = CGFloat(c.nx) * bounds.width
            let cy = CGFloat(c.ny) * bounds.height
            if hypot(p.x - cx, p.y - cy) <= r { return true }
        }
        return false
    }
}

/// Click-through EXCEPT where a control actually is.
///
/// PassthroughWindow (the joystick pad's) returns nil unconditionally because it
/// only ever draws. This one has to take input, so it discriminates: a hit that
/// lands on the hosting root view means empty space, and empty space belongs to
/// the game underneath — mouse-look must keep working between the buttons.
final class ControlsWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let m = TouchControlsModel.shared
        // Edit mode owns the whole screen: drags and the scale pinch must not
        // leak through and swing the camera while you are arranging buttons.
        if m.editing { return super.hitTest(point, with: event) }
        // Portrait draws nothing here, so it must consume nothing.
        guard bounds.width > bounds.height else { return nil }
        guard m.hitsInteractive(point, in: bounds) else { return nil }
        return super.hitTest(point, with: event)
    }
}

enum TouchControlsHost {
    private static var window: ControlsWindow?

    static func hide() {
        TouchControlsModel.shared.editing = false
        TouchControlsModel.shared.selected = nil
        window?.isHidden = true
    }

    static func attach() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
                        ?? scenes.first else { return }
        if window == nil {
            // ml644: orientationDidChangeNotification is NOT posted unless
            // generation has been switched on, so without this the overlay would
            // keep a portrait-sized frame after the first rotation.
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            let w = ControlsWindow(windowScene: scene)
            // Above the joystick pad's +100. A higher windowLevel is the only
            // ordering nothing inside the app window can undo.
            w.windowLevel = .normal + 101
            w.backgroundColor = .clear
            w.isHidden = false        // deliberately never made key
            let host = UIHostingController(rootView: TouchControlsOverlay())
            host.view.backgroundColor = .clear
            w.rootViewController = host
            window = w
        }
        window?.frame = scene.coordinateSpace.bounds
        window?.isHidden = false
        fputs("[controls] ml644 overlay attached frame=\(window?.frame ?? .zero) " +
              "controls=\(TouchControlsModel.shared.controls.count)\n", stderr)
    }
}

struct TouchControlsOverlay: View {
    @ObservedObject private var m = TouchControlsModel.shared
    @State private var pinchBase: Double?

    var body: some View {
        GeometryReader { geo in
            // Landscape only; portrait keeps the existing key row and joystick.
            let landscape = geo.size.width > geo.size.height
            ZStack(alignment: .top) {
                if landscape {
                    if m.visible || m.editing {
                        ForEach(m.controls) { c in
                            TouchControlButton(control: c, screen: geo.size)
                        }
                    }
                    topBar
                    if m.editing, let i = m.index(of: m.selected) {
                        MappingPanel(control: m.controls[i], screen: geo.size)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .contentShape(Rectangle())
            .gesture(scalePinch)
        }
        .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            glassButton("gamecontroller", dim: !m.visible) { m.visible.toggle() }
            glassButton(m.editing ? "checkmark" : "pencil") {
                m.editing.toggle()
                if !m.editing { m.selected = nil }
            }
            if m.editing {
                glassButton("plus") {
                    var c = TouchControl()
                    // Stagger, so repeated adds do not stack invisibly.
                    c.nx = 0.5 + Double(m.controls.count % 3) * 0.06
                    c.ny = 0.5 + Double(m.controls.count % 2) * 0.06
                    m.controls.append(c)
                    m.selected = c.id
                }
                .transition(.opacity.combined(with: .scale))
            }
        }
        .padding(.top, 104)
        .animation(.easeInOut(duration: 0.22), value: m.editing)
    }

    /// Pinch anywhere scales the SELECTED control. With nothing selected it does
    /// nothing rather than guessing which one you meant.
    private var scalePinch: some Gesture {
        MagnificationGesture()
            .onChanged { v in
                guard m.editing, let i = m.index(of: m.selected) else { return }
                if pinchBase == nil { pinchBase = m.controls[i].scale }
                m.controls[i].scale = min(max((pinchBase ?? 1) * Double(v), 0.5), 3.0)
            }
            .onEnded { _ in pinchBase = nil }
    }

    private func glassButton(_ system: String, dim: Bool = false,
                             _ action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeInOut(duration: 0.22)) { action() }
        } label: {
            // Stroke only — never a .fill variant.
            Image(systemName: system)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.white.opacity(dim ? 0.35 : 1.0))
                .frame(width: 44, height: 44)
                .background(GlassShape(circle: true))
        }
        .buttonStyle(.plain)
    }
}

/// Shared control backing, available on every supported iOS version.
struct GlassShape: View {
    var circle = false
    var body: some View {
        if circle { Circle().fill(.ultraThinMaterial) }
        else { RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial) }
    }
}

struct TouchControlButton: View {
    let control: TouchControl
    let screen: CGSize
    @ObservedObject private var m = TouchControlsModel.shared
    @State private var isDown = false
    @State private var dragBase: CGPoint?
    @State private var stickDir: Int = -1

    private var diameter: CGFloat { TouchControlsModel.baseDiameter * CGFloat(control.scale) }
    private var isStick: Bool { control.action.stickKeys != nil }
    private var isSelected: Bool { m.editing && m.selected == control.id }

    var body: some View {
        ZStack {
            if control.action.stickKeys != nil {
                // Reuse the portrait pad's face so both look and animate the
                // same; scale it to whatever size this control was pinched to.
                JoystickFace(held: isDown, dir: stickDir, alwaysExpanded: true)
                    .frame(width: JoystickFace.padRadius * 2,
                           height: JoystickFace.padRadius * 2)
                    .scaleEffect(diameter / (JoystickFace.padRadius * 2))
            } else {
                GlassShape(circle: true)
                Text(control.action.label)
                    .font(.system(size: diameter * (control.action.label.count > 2 ? 0.22 : 0.34),
                                  weight: .medium))
                    .foregroundStyle(.white.opacity(control.action.isPad ? 0.45
                                                    : (isDown ? 1.0 : 0.85)))
            }
        }
        .frame(width: diameter, height: diameter)
        .overlay(Circle().stroke(.white.opacity(isSelected ? 0.95
                                                : (isStick ? 0 : 0.28)),
                                 lineWidth: isSelected ? 2 : 1))
        // A stick must not shrink under the thumb; only round buttons do that.
        .scaleEffect(!isStick && isDown ? 0.92 : 1.0)
        .animation(.easeOut(duration: 0.08), value: isDown)
        // ml646: the springy knob, same curve as the portrait pad overlay.
        .animation(.spring(response: 0.22, dampingFraction: 0.58), value: stickDir)
        .overlay(alignment: .topTrailing) {
            if isSelected {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    m.controls.removeAll { $0.id == control.id }
                    m.selected = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(.red.opacity(0.85)))
                }
                .buttonStyle(.plain)
                .offset(x: 8, y: -8)
            }
        }
        .position(x: CGFloat(control.nx) * screen.width,
                  y: CGFloat(control.ny) * screen.height)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if m.editing {
                        m.selected = control.id
                        guard let i = m.index(of: control.id) else { return }
                        if dragBase == nil { dragBase = CGPoint(x: control.nx, y: control.ny) }
                        let b = dragBase ?? .zero
                        m.controls[i].nx = min(max(b.x + Double(v.translation.width  / screen.width),  0.03), 0.97)
                        m.controls[i].ny = min(max(b.y + Double(v.translation.height / screen.height), 0.03), 0.97)
                    } else if let q = control.action.stickKeys {
                        isDown = true
                        applyStick(snap(v.translation), q)
                    } else if !isDown {
                        isDown = true
                        press(true)
                    }
                }
                .onEnded { _ in
                    dragBase = nil
                    if let q = control.action.stickKeys {
                        applyStick(-1, q)          // release every held direction
                        isDown = false
                    } else if isDown {
                        isDown = false
                        press(false)
                    }
                }
        )
    }

    /// 8-way snap. Screen y grows downward, so measure clockwise from "up".
    private func snap(_ t: CGSize) -> Int {
        let d = (t.width * t.width + t.height * t.height).squareRoot()
        if d < diameter * 0.22 { return -1 }        // deadzone scales with the control
        var a = atan2(t.width, -t.height) * 180 / .pi
        if a < 0 { a += 360 }
        return Int((a + 22.5) / 45.0) % 8
    }

    private func stickKeys(_ d: Int, _ q: [Int32]) -> [Int32] {
        switch d {
        case 0: return [q[0]]
        case 1: return [q[0], q[1]]
        case 2: return [q[1]]
        case 3: return [q[2], q[1]]
        case 4: return [q[2]]
        case 5: return [q[2], q[3]]
        case 6: return [q[3]]
        case 7: return [q[0], q[3]]
        default: return []
        }
    }

    /// Release what is no longer held, press what newly is. A blanket
    /// release/re-press would make a held direction stutter as the thumb
    /// wanders inside one sector.
    private func applyStick(_ next: Int, _ q: [Int32]) {
        guard next != stickDir else { return }
        let old = Set(stickKeys(stickDir, q)), new = Set(stickKeys(next, q))
        for vk in old.subtracting(new) { winios_post_key(vk, 0) }
        for vk in new.subtracting(old) { winios_post_key(vk, 1) }
        if stickDir == -1, next != -1 { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        stickDir = next
    }

    /// Haptic on the DOWN edge only — a held movement key would otherwise buzz
    /// continuously for as long as you walk.
    private func press(_ down: Bool) {
        if down { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        switch control.action {
        case .key(let vk):
            winios_post_key(vk, down ? 1 : 0)
        case .mouseLeft:
            winios_pointer(0, 0, down ? 0x0002 : 0x0004, 0)   // LEFTDOWN / LEFTUP
        case .mouseRight:
            winios_pointer(0, 0, down ? 0x0008 : 0x0010, 0)   // RIGHTDOWN / RIGHTUP
        case .keyboardToggle:
            if down { MetalBackedView.toggleKeyboard() }
        case .none, .joystickWASD, .joystickArrows:
            break                                              // sticks drive themselves
        case .pad:
            break     // ml645: no XInput yet — deliberately inert, and labelled so
        }
    }
}

/// ml645 — the mapping panel. Shown for the selected control in edit mode.
struct MappingPanel: View {
    let control: TouchControl
    let screen: CGSize
    @ObservedObject private var m = TouchControlsModel.shared
    @State private var tab = 0                    // 0 keyboard, 1 controller


    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tabButton(0, "keyboard")
                tabButton(1, "gamecontroller")
            }
            Rectangle().fill(.white.opacity(0.15)).frame(height: 1)
            ScrollView {
                (tab == 0 ? AnyView(keyboardTab) : AnyView(controllerTab))
                    .padding(10)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .background(GlassShape())
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.18), lineWidth: 1))
        .position(layout.center)
    }

    private struct Placement { var center: CGPoint; var size: CGSize }

    /// ml646: the panel must NEVER sit under the control it is editing.
    ///
    /// The old version only tried below/above and then clamped, which on a
    /// 390pt-tall landscape phone silently put the panel right on top of any
    /// control near the middle: 240 of panel + 64 of control + gaps does not fit
    /// in 390 either way, so the clamp was the only thing deciding placement.
    ///
    /// Try each side in turn, at shrinking sizes, and take the first that fits
    /// on the screen along the axis it separates on. Clamping the OTHER axis is
    /// then always safe — below/above are separated vertically, so no horizontal
    /// clamp can reintroduce an overlap, and vice versa.
    private var layout: Placement {
        let cx = CGFloat(control.nx) * screen.width
        let cy = CGFloat(control.ny) * screen.height
        let r  = TouchControlsModel.baseDiameter * CGFloat(control.scale) / 2
        let gap: CGFloat = 14, edge: CGFloat = 8

        for size in [CGSize(width: 340, height: 236),
                     CGSize(width: 300, height: 196),
                     CGSize(width: 264, height: 164)] {
            let clampX = min(max(cx, size.width  / 2 + edge), screen.width  - size.width  / 2 - edge)
            let clampY = min(max(cy, size.height / 2 + edge), screen.height - size.height / 2 - edge)
            if cy + r + gap + size.height <= screen.height - edge {
                return Placement(center: CGPoint(x: clampX, y: cy + r + gap + size.height / 2), size: size)
            }
            if cy - r - gap - size.height >= edge {
                return Placement(center: CGPoint(x: clampX, y: cy - r - gap - size.height / 2), size: size)
            }
            if cx + r + gap + size.width <= screen.width - edge {
                return Placement(center: CGPoint(x: cx + r + gap + size.width / 2, y: clampY), size: size)
            }
            if cx - r - gap - size.width >= edge {
                return Placement(center: CGPoint(x: cx - r - gap - size.width / 2, y: clampY), size: size)
            }
        }
        // Nothing fits alongside — smallest panel, corner furthest from the
        // control, so it still cannot cover it.
        let size = CGSize(width: 264, height: 164)
        return Placement(
            center: CGPoint(x: cx < screen.width  / 2 ? screen.width  - size.width  / 2 - edge
                                                      : size.width  / 2 + edge,
                            y: cy < screen.height / 2 ? screen.height - size.height / 2 - edge
                                                      : size.height / 2 + edge),
            size: size)
    }

    private func tabButton(_ i: Int, _ icon: String) -> some View {
        Button { tab = i } label: {
            Image(systemName: icon)                       // stroke, not filled
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.white.opacity(tab == i ? 1.0 : 0.38))
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.plain)
    }

    // ---- catalogues ----
    private var letters: [(String, ControlAction)] {
        (0x41...0x5A).map { (String(UnicodeScalar(UInt8($0))), ControlAction.key(Int32($0))) }
    }
    private var digits: [(String, ControlAction)] {
        (0x30...0x39).map { (String(UnicodeScalar(UInt8($0))), ControlAction.key(Int32($0))) }
    }
    private var fkeys: [(String, ControlAction)] {
        (0...11).map { ("F\($0 + 1)", ControlAction.key(Int32(0x70 + $0))) }
    }
    private var numpad: [(String, ControlAction)] {
        (0...9).map { ("N\($0)", ControlAction.key(Int32(0x60 + $0))) }
        + [("N*", .key(0x6A)), ("N+", .key(0x6B)), ("N−", .key(0x6D)),
           ("N.", .key(0x6E)), ("N/", .key(0x6F))]
    }

    private var keyboardTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            section("Pointer, sticks & special", [
                ("L click", .mouseLeft), ("R click", .mouseRight),
                ("WASD", .joystickWASD), ("Arrows", .joystickArrows),
                ("Keyboard", .keyboardToggle), ("None", .none),
            ])
            section("Letters", letters)
            section("Numbers", digits)
            section("Function", fkeys)
            section("Modifiers & editing", [
                ("Esc", .key(0x1B)), ("Tab", .key(0x09)), ("Caps", .key(0x14)),
                ("Shift", .key(0x10)), ("Ctrl", .key(0x11)), ("Alt", .key(0x12)),
                ("Space", .key(0x20)), ("Enter", .key(0x0D)), ("Bksp", .key(0x08)),
                ("Win", .key(0x5B)),
            ])
            section("Navigation", [
                ("←", .key(0x25)), ("↑", .key(0x26)), ("→", .key(0x27)), ("↓", .key(0x28)),
                ("Ins", .key(0x2D)), ("Del", .key(0x2E)), ("Home", .key(0x24)),
                ("End", .key(0x23)), ("PgUp", .key(0x21)), ("PgDn", .key(0x22)),
            ])
            section("Symbols", [
                ("-", .key(0xBD)), ("=", .key(0xBB)), ("[", .key(0xDB)), ("]", .key(0xDD)),
                ("\\", .key(0xDC)), (";", .key(0xBA)), ("'", .key(0xDE)), (",", .key(0xBC)),
                (".", .key(0xBE)), ("/", .key(0xBF)), ("`", .key(0xC0)),
            ])
            section("Numpad", numpad)
        }
    }

    private var controllerTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("XInput isn't wired up yet. These save with your layout but do "
                 + "nothing when pressed — controller support lands with the Wine HID stack.")
                .font(.system(size: 11))
                .foregroundStyle(.orange.opacity(0.95))
                .fixedSize(horizontal: false, vertical: true)
            section("Face", [("A", .pad("A")), ("B", .pad("B")), ("X", .pad("X")), ("Y", .pad("Y"))])
            section("D-pad", [("D↑", .pad("D↑")), ("D↓", .pad("D↓")),
                              ("D←", .pad("D←")), ("D→", .pad("D→"))])
            section("Bumpers & triggers", [("LB", .pad("LB")), ("RB", .pad("RB")),
                                           ("LT", .pad("LT")), ("RT", .pad("RT"))])
            section("Sticks", [("LS", .pad("LS")), ("RS", .pad("RS")),
                               ("L3", .pad("L3")), ("R3", .pad("R3"))])
            section("System", [("Menu", .pad("Menu")), ("View", .pad("View")),
                               ("Guide", .pad("Guide"))])
        }
    }

    private func section(_ title: String, _ items: [(String, ControlAction)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 6)], spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    chip(it.0, it.1)
                }
            }
        }
    }

    private func chip(_ label: String, _ action: ControlAction) -> some View {
        let on = control.action == action
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if let i = m.index(of: control.id) { m.controls[i].action = action }
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .foregroundStyle(.white.opacity(action.isPad ? 0.55 : 1.0))
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(.white.opacity(on ? 0.36 : 0.12)))
        }
        .buttonStyle(.plain)
    }
}
