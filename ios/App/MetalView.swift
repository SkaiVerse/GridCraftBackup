import UIKit
import QuartzCore

/// The drawing surface. Catches the pointer, fingers, scrolling, pinching and the keyboard,
/// and hands them to the Rust core.
final class MetalView: UIView, UIKeyInput, UIGestureRecognizerDelegate {

    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    // Hooks the view controller fills in.
    var onOpenFiles: (() -> Void)?
    var onSave: ((String, Data) -> Void)?
    var onOpenURL: ((String) -> Void)?
    var onCopyText: ((String) -> Void)?
    var onCopyHTML: ((String, String) -> Void)?
    var onPasteText: (() -> String?)?
    var onPasteHTML: (() -> String?)?
    var onPickPicture: (() -> Void)?
    var onPrint: ((Data) -> Void)?
    /// True while a picker or alert is showing, so the view doesn't grab the keyboard back.
    var suspendFocus = false

    private var handle: UnsafeMutableRawPointer?
    private var startFailed = false
    private var link: CADisplayLink?
    private var softKeyboard = false
    private let emptyInput = UIView(frame: .zero)
    private var scratch: UnsafeMutablePointer<CChar>?
    private var activeTouch: UITouch?
    private var pointerButton: Int32 = 0
    private var held: (hid: UInt32, mods: UInt32, text: String?, start: CFTimeInterval, last: CFTimeInterval)?

    // UITextInputTraits (no autocorrect while typing into cells)
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .default

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        setupGestures()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: MetalView, _) in
            view.pushTheme()
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        link?.invalidate()
        if let h = handle { gc_destroy(h) }
        if let s = scratch { free(s) }
    }

    // MARK: Lifecycle

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            ensureHandle()
            if link == nil {
                let l = CADisplayLink(target: self, selector: #selector(tick))
                l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
                l.add(to: .main, forMode: .common)
                link = l
            }
        } else {
            link?.invalidate()
            link = nil
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        ensureHandle()
        if let h = handle {
            let s = traitCollection.displayScale
            gc_resize(h, UInt32(max(1, bounds.width * s)), UInt32(max(1, bounds.height * s)), Float(s))
        }
    }

    private func ensureHandle() {
        guard handle == nil, !startFailed, window != nil, bounds.width > 1, bounds.height > 1 else { return }
        let s = traitCollection.displayScale
        contentScaleFactor = s
        metalLayer.contentsScale = s
        let layerPtr = Unmanaged.passUnretained(metalLayer).toOpaque()
        handle = gc_create(layerPtr, UInt32(bounds.width * s), UInt32(bounds.height * s), Float(s), makeCallbacks())
        if handle == nil { startFailed = true } else { pushTheme() }
    }

    private func pushTheme() {
        guard let h = handle else { return }
        gc_set_dark(h, traitCollection.userInterfaceStyle == .dark ? 1 : 0)
    }

    func saveState() { if let h = handle { gc_save_state(h) } }
    func setFocused(_ focused: Bool) { if let h = handle { gc_set_focused(h, focused ? 1 : 0) } }

    @objc private func tick() {
        guard let h = handle else { return }
        if !suspendFocus && !isFirstResponder { _ = becomeFirstResponder() }
        repeatHeldKey()
        let flags = gc_frame(h)
        let wants = (flags & 2) != 0
        if wants != softKeyboard {
            softKeyboard = wants
            reloadInputViews()
        }
    }

    // MARK: Callbacks from Rust

    fileprivate static func from(_ p: UnsafeMutableRawPointer?) -> MetalView? {
        p.map { Unmanaged<MetalView>.fromOpaque($0).takeUnretainedValue() }
    }

    fileprivate func stash(_ s: String?) -> UnsafePointer<CChar>? {
        if let old = scratch { free(old) }
        scratch = s.flatMap { strdup($0) }
        return scratch.map { UnsafePointer($0) }
    }

    private func makeCallbacks() -> GCCallbacks {
        let me = Unmanaged.passUnretained(self).toOpaque()
        return GCCallbacks(
            user: me,
            open_files: { u in MetalView.from(u)?.onOpenFiles?() },
            save_file: { u, name, data, len in
                guard let v = MetalView.from(u), let name = name else { return }
                let bytes = (data != nil && len > 0) ? Data(bytes: data!, count: len) : Data()
                v.onSave?(String(cString: name), bytes)
            },
            open_url: { u, url in
                guard let v = MetalView.from(u), let url = url else { return }
                v.onOpenURL?(String(cString: url))
            },
            copy_text: { u, text in
                guard let v = MetalView.from(u), let text = text else { return }
                v.onCopyText?(String(cString: text))
            },
            copy_html: { u, html, text in
                guard let v = MetalView.from(u), let html = html, let text = text else { return }
                v.onCopyHTML?(String(cString: html), String(cString: text))
            },
            paste_text: { u in
                guard let v = MetalView.from(u) else { return nil }
                return v.stash(v.onPasteText?())
            },
            paste_html: { u in
                guard let v = MetalView.from(u) else { return nil }
                return v.stash(v.onPasteHTML?())
            },
            pick_picture: { u in MetalView.from(u)?.onPickPicture?() },
            print_pdf: { u, data, len in
                guard let v = MetalView.from(u), let data = data else { return }
                v.onPrint?(Data(bytes: data, count: len))
            }
        )
    }

    // MARK: Results from the view controller

    func deliverOpened(name: String, data: Data) {
        guard let h = handle else { return }
        name.withCString { n in
            data.withUnsafeBytes { raw in
                gc_open_file(h, n, raw.bindMemory(to: UInt8.self).baseAddress, data.count)
            }
        }
    }

    func deliverPicture(name: String, data: Data) {
        guard let h = handle else { return }
        name.withCString { n in
            data.withUnsafeBytes { raw in
                gc_picture_file(h, n, raw.bindMemory(to: UInt8.self).baseAddress, data.count)
            }
        }
    }

    func saveResult(ok: Bool) { if let h = handle { gc_save_result(h, ok ? 1 : 0) } }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }
    override var inputView: UIView? { softKeyboard ? nil : emptyInput }

    override func resignFirstResponder() -> Bool {
        held = nil
        return super.resignFirstResponder()
    }

    var hasText: Bool { true }

    func insertText(_ text: String) {
        guard let h = handle else { return }
        if text == "\n" {
            gc_key(h, 0x28, 1, 0, 0)
            gc_key(h, 0x28, 0, 0, 0)
        } else {
            text.withCString { gc_text(h, $0) }
        }
    }

    func deleteBackward() {
        guard let h = handle else { return }
        gc_key(h, 0x2A, 1, 0, 0)
        gc_key(h, 0x2A, 0, 0, 0)
    }

    private func modBits(_ f: UIKeyModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.shift) { m |= 1 }
        if f.contains(.control) { m |= 2 }
        if f.contains(.alternate) { m |= 4 }
        if f.contains(.command) { m |= 8 }
        return m
    }

    private func printable(_ s: String) -> String? {
        guard !s.isEmpty else { return nil }
        let ok = s.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) }
        return ok ? s : nil
    }

    /// ⌘C, ⌘X and ⌘V go through the iPad's clipboard.
    private func clipboardShortcut(hid: UInt32, mods: UInt32) -> Bool {
        guard mods == 8, let h = handle else { return false }
        switch hid {
        case 0x06: gc_copy(h); return true
        case 0x1B: gc_cut(h); return true
        case 0x19:
            if let s = UIPasteboard.general.string, !s.isEmpty { s.withCString { gc_paste(h, $0) } }
            return true
        default: return false
        }
    }

    private func handlePress(_ press: UIPress, down: Bool) -> Bool {
        guard let key = press.key, let h = handle else { return false }
        let hid = UInt32(key.keyCode.rawValue)
        if hid >= 0xE0 && hid <= 0xE7 { return true }   // a modifier key on its own
        let mods = modBits(key.modifierFlags)
        if down {
            if clipboardShortcut(hid: hid, mods: mods) { return true }
            gc_key(h, hid, 1, 0, mods)
            var text: String? = nil
            if mods & (8 | 2) == 0 { text = printable(key.characters) }
            if let t = text { t.withCString { gc_text(h, $0) } }
            let now = CACurrentMediaTime()
            held = (hid, mods, text, now, now)
        } else {
            gc_key(h, hid, 0, 0, mods)
            if held?.hid == hid { held = nil }
        }
        return true
    }

    private func repeatHeldKey() {
        guard let k = held, let h = handle else { return }
        let now = CACurrentMediaTime()
        if now - k.start > 0.4 && now - k.last > 0.035 {
            gc_key(h, k.hid, 1, 1, k.mods)
            if let t = k.text { t.withCString { gc_text(h, $0) } }
            held?.last = now
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest = Set<UIPress>()
        for p in presses where !handlePress(p, down: true) { rest.insert(p) }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest = Set<UIPress>()
        for p in presses where !handlePress(p, down: false) { rest.insert(p) }
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        held = nil
        super.pressesCancelled(presses, with: event)
    }

    // ⌘ shortcuts are claimed ahead of the system so ⌘Z, ⌘S, ⌘F and friends reach the app.
    private static let commandKeys: [UIKeyCommand] = {
        let letters = Array("abcdefgijklmnoprstuvxyz0123456789-=[];',./\\`").map { String($0) }
        let specials = [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, UIKeyCommand.inputLeftArrow,
                        UIKeyCommand.inputRightArrow, UIKeyCommand.inputPageUp, UIKeyCommand.inputPageDown,
                        UIKeyCommand.inputHome, UIKeyCommand.inputEnd]
        let mods: [UIKeyModifierFlags] = [.command, [.command, .shift], [.command, .alternate], [.command, .shift, .alternate]]
        var list: [UIKeyCommand] = []
        for input in letters + specials {
            for m in mods {
                let c = UIKeyCommand(input: input, modifierFlags: m, action: #selector(MetalView.commandKey(_:)))
                c.wantsPriorityOverSystemBehavior = true
                list.append(c)
            }
        }
        return list
    }()

    override var keyCommands: [UIKeyCommand]? { MetalView.commandKeys }

    private static func hid(for s: String) -> UInt32? {
        switch s {
        case UIKeyCommand.inputUpArrow: return 0x52
        case UIKeyCommand.inputDownArrow: return 0x51
        case UIKeyCommand.inputLeftArrow: return 0x50
        case UIKeyCommand.inputRightArrow: return 0x4F
        case UIKeyCommand.inputPageUp: return 0x4B
        case UIKeyCommand.inputPageDown: return 0x4E
        case UIKeyCommand.inputHome: return 0x4A
        case UIKeyCommand.inputEnd: return 0x4D
        default: break
        }
        guard s.unicodeScalars.count == 1, let u = s.lowercased().unicodeScalars.first else { return nil }
        switch u {
        case "a"..."z": return 0x04 + (u.value - 97)
        case "1"..."9": return 0x1E + (u.value - 49)
        case "0": return 0x27
        case "-": return 0x2D
        case "=": return 0x2E
        case "[": return 0x2F
        case "]": return 0x30
        case "\\": return 0x31
        case ";": return 0x33
        case "'": return 0x34
        case "`": return 0x35
        case ",": return 0x36
        case ".": return 0x37
        case "/": return 0x38
        default: return nil
        }
    }

    @objc func commandKey(_ cmd: UIKeyCommand) {
        guard let h = handle, let input = cmd.input, let hid = MetalView.hid(for: input) else { return }
        let mods = modBits(cmd.modifierFlags)
        if clipboardShortcut(hid: hid, mods: mods) { return }
        gc_key(h, hid, 1, 0, mods)
        gc_key(h, hid, 0, 0, mods)
    }

    // MARK: Pointer, fingers, scrolling

    private func setupGestures() {
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hoverMoved(_:)))
        addGestureRecognizer(hover)

        let wheel = UIPanGestureRecognizer(target: self, action: #selector(pointerScroll(_:)))
        wheel.allowedScrollTypesMask = .all
        wheel.allowedTouchTypes = []
        wheel.cancelsTouchesInView = false
        wheel.delegate = self
        addGestureRecognizer(wheel)

        let twoFinger = UIPanGestureRecognizer(target: self, action: #selector(twoFingerScroll(_:)))
        twoFinger.minimumNumberOfTouches = 2
        twoFinger.maximumNumberOfTouches = 2
        twoFinger.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        twoFinger.cancelsTouchesInView = false
        twoFinger.delegate = self
        addGestureRecognizer(twoFinger)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.cancelsTouchesInView = false
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        longPress.minimumPressDuration = 0.55
        longPress.allowableMovement = 12
        longPress.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        longPress.cancelsTouchesInView = false
        longPress.delegate = self
        addGestureRecognizer(longPress)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    @objc private func hoverMoved(_ g: UIHoverGestureRecognizer) {
        guard let h = handle else { return }
        switch g.state {
        case .began, .changed:
            let p = g.location(in: self)
            gc_pointer_moved(h, Float(p.x), Float(p.y))
        case .ended, .cancelled:
            gc_pointer_gone(h)
        default: break
        }
    }

    @objc private func pointerScroll(_ g: UIPanGestureRecognizer) {
        guard let h = handle, g.state != .ended, g.state != .cancelled, g.state != .failed else { return }
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        if t != .zero { gc_scroll(h, Float(t.x), Float(t.y), modBits(g.modifierFlags)) }
    }

    @objc private func twoFingerScroll(_ g: UIPanGestureRecognizer) {
        guard let h = handle, g.state != .ended, g.state != .cancelled, g.state != .failed else { return }
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        if t != .zero { gc_scroll(h, Float(t.x), Float(t.y), 0) }
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        guard let h = handle, g.state == .changed else { return }
        gc_zoom(h, Float(g.scale))
        g.scale = 1
    }

    @objc private func longPressed(_ g: UILongPressGestureRecognizer) {
        guard let h = handle, g.state == .began else { return }
        let p = g.location(in: self)
        gc_pointer_button(h, Float(p.x), Float(p.y), 1, 1, 0)
        gc_pointer_button(h, Float(p.x), Float(p.y), 1, 0, 0)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let h = handle else { return }
        let mods = modBits(event?.modifierFlags ?? [])
        for t in touches {
            let p = t.location(in: self)
            if t.type == .indirectPointer {
                pointerButton = (event?.buttonMask.contains(.secondary) ?? false) ? 1 : 0
                gc_pointer_moved(h, Float(p.x), Float(p.y))
                gc_pointer_button(h, Float(p.x), Float(p.y), pointerButton, 1, mods)
            } else if activeTouch == nil {
                activeTouch = t
                gc_pointer_moved(h, Float(p.x), Float(p.y))
                gc_pointer_button(h, Float(p.x), Float(p.y), 0, 1, mods)
            } else if let a = activeTouch {
                // A second finger means scrolling or pinching: drop the selection gesture.
                let q = a.location(in: self)
                gc_pointer_button(h, Float(q.x), Float(q.y), 0, 0, mods)
                gc_pointer_gone(h)
                activeTouch = nil
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let h = handle else { return }
        for t in touches where t.type == .indirectPointer || t === activeTouch {
            let p = t.location(in: self)
            gc_pointer_moved(h, Float(p.x), Float(p.y))
        }
    }

    private func finish(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let h = handle else { return }
        let mods = modBits(event?.modifierFlags ?? [])
        for t in touches {
            let p = t.location(in: self)
            if t.type == .indirectPointer {
                gc_pointer_button(h, Float(p.x), Float(p.y), pointerButton, 0, mods)
            } else if t === activeTouch {
                gc_pointer_button(h, Float(p.x), Float(p.y), 0, 0, mods)
                gc_pointer_gone(h)
                activeTouch = nil
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, with: event) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, with: event) }
}
