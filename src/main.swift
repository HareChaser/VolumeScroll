import Cocoa
import CoreAudio

// MARK: - CoreAudio Volume
//
// 'vmvc' = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
// Using the raw four-char-code so we don't need to import AudioToolbox.
private let kVirtualMainVolSel: AudioObjectPropertySelector = 0x766D7663

private func defaultOutputDevice() -> AudioDeviceID {
    var id   = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope:    kAudioObjectPropertyScopeGlobal,
        mElement:  kAudioObjectPropertyElementMain
    )
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                               &addr, 0, nil, &size, &id)
    return id
}

/// Returns 0 when the system is muted (F10 / menu-bar mute button).
func getVolume() -> Int {
    let dev = defaultOutputDevice()

    // Mute state
    var muted    = UInt32(0)
    var muteSize = UInt32(MemoryLayout<UInt32>.size)
    var muteAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope:    kAudioDevicePropertyScopeOutput,
        mElement:  kAudioObjectPropertyElementMain
    )
    if AudioObjectGetPropertyData(dev, &muteAddr, 0, nil, &muteSize, &muted) == noErr,
       muted != 0 { return 0 }

    // Volume scalar (0.0 – 1.0)
    var vol     = Float32(0)
    var volSize = UInt32(MemoryLayout<Float32>.size)
    var volAddr = AudioObjectPropertyAddress(
        mSelector: kVirtualMainVolSel,
        mScope:    kAudioDevicePropertyScopeOutput,
        mElement:  kAudioObjectPropertyElementMain
    )
    guard AudioObjectGetPropertyData(dev, &volAddr, 0, nil, &volSize, &vol) == noErr
    else { return 50 }
    return Int((vol * 100).rounded())
}

func setVolume(_ volume: Int) {
    let dev  = defaultOutputDevice()
    var vol  = Float32(max(0, min(100, volume))) / 100
    let size = UInt32(MemoryLayout<Float32>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kVirtualMainVolSel,
        mScope:    kAudioDevicePropertyScopeOutput,
        mElement:  kAudioObjectPropertyElementMain
    )
    AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &vol)
}

func symbolName(for volume: Int) -> String {
    switch volume {
    case 0:       return "speaker.slash.fill"
    case 1...33:  return "speaker.fill"
    case 34...66: return "speaker.wave.1.fill"
    default:      return "speaker.wave.3.fill"
    }
}

// MARK: - Custom Status Bar View

class VolumeBarView: NSView {
    /// Carries a continuous volume delta (in percentage points).
    var onScroll: ((Double) -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    var onResize: ((CGFloat) -> Void)?

    private let iconView = NSImageView()
    private let label: NSTextField = {
        let tf = NSTextField(labelWithString: "")
        tf.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        return tf
    }()

    /// Volume-% applied per point of trackpad travel. Higher = faster.
    private let trackpadSensitivity: Double = 0.30 //Adjust trackpad sensitivity (value is % volume change per point of finger travel)
    /// Volume-% per line of mouse-wheel travel. macOS scales this by spin speed,
    /// so fast spins accelerate just like the trackpad.
    private let wheelSensitivity: Double = 2.0 //Adjust mouse wheel sensitivity (value is % volume change per line of scroll)
    private let iconPt: CGFloat = 15      // SF Symbol point size — controls glyph height
    private let gap: CGFloat    = 2       // space between icon and number
    private let hPad: CGFloat   = 2       // inner left/right margin (menu bar adds its own spacing)
    /// Natural size of the current symbol image (width varies; height stays consistent).
    private var iconSize: NSSize = .zero
    /// Fixed slot widths so the layout never changes size.
    private var iconSlotW: CGFloat  = 0   // widest of all speaker symbols
    private var labelW: CGFloat     = 0   // width of "100%" — reserved at all times

    /// All symbols the icon can display — used to measure the widest one.
    private static let allSymbols = [
        "speaker.slash.fill", "speaker.fill",
        "speaker.wave.1.fill", "speaker.wave.3.fill",
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Frame matches the symbol's natural size, so nothing gets squished.
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)
        addSubview(label)
        setupMetrics()
    }
    required init?(coder: NSCoder) { nil }

    /// Measures the fixed slot widths once. The icon slot fits the widest symbol;
    /// the label slot fits "100%", so neither shifts as the volume changes.
    private func setupMetrics() {
        let cfg = NSImage.SymbolConfiguration(pointSize: iconPt, weight: .regular)
        let widest = Self.allSymbols.compactMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg)?.size.width
        }.max() ?? iconPt
        iconSlotW = ceil(widest)

        // Reserve the 3-digit "100%" width permanently so the item never resizes.
        let probe = NSTextField(labelWithString: "100%")
        probe.font = label.font
        probe.sizeToFit()
        labelW = ceil(probe.frame.width)
    }

    func update(volume: Int) {
        let cfg = NSImage.SymbolConfiguration(pointSize: iconPt, weight: .regular)
        let img = NSImage(systemSymbolName: symbolName(for: volume),
                          accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        iconView.image = img
        iconSize = img?.size ?? NSSize(width: iconPt, height: iconPt)

        label.stringValue = "\(volume)%"
        label.sizeToFit()

        // Width is built entirely from fixed slots, so it's constant at all volumes.
        let w = hPad + iconSlotW + gap + labelW + hPad
        onResize?(w)
        layoutContent()
    }

    private func layoutContent() {
        let midY = bounds.midY
        // Icon left-anchored in its slot: the speaker body stays put while wave
        // arcs extend right into the reserved space.
        iconView.frame = NSRect(x: hPad,
                                y: midY - iconSize.height/2,
                                width: iconSize.width,
                                height: iconSize.height)
        // Label left-aligned in its fixed "100%" slot, so the item never resizes.
        label.frame    = NSRect(x: hPad + iconSlotW + gap,
                                y: midY - label.frame.height/2,
                                width: labelW, height: label.frame.height)
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.momentumPhase == [] else { return }   // ignore inertia overshoot
        if event.hasPreciseScrollingDeltas {
            // Trackpad: continuous finger travel. Negated so swiping up = louder.
            let delta = -Double(event.scrollingDeltaY) * trackpadSensitivity
            guard delta != 0 else { return }
            onScroll?(delta)
        } else {
            // Mouse wheel: velocity-proportional — macOS scales scrollingDeltaY by
            // spin speed, so fast spins move faster instead of a flat per-detent step.
            // Currently logically this is the same calculation as the trackpad, but separate in case we want to tweak sensitivities independently later.
            let delta = -Double(event.scrollingDeltaY) * wheelSensitivity
            guard delta != 0 else { return }
            onScroll?(delta)
        }
    }

    override func rightMouseDown(with event: NSEvent) { onRightClick?(event) }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var barView: VolumeBarView!

    /// Integer volume currently shown — only changes (display + system) happen on whole-% crossings.
    private var cachedVolume = 50
    /// Fractional volume accumulator so sub-1% trackpad movement is never lost.
    private var preciseVolume: Double = 50
    /// While scrolling we trust our own value; ignore CoreAudio echo until this time.
    private var suppressRefreshUntil = Date.distantPast
    /// Coalesces rapid CoreAudio notifications (e.g. smooth slider drags).
    private var pendingRefresh: DispatchWorkItem?
    /// Tracks which device we're already listening to, to avoid duplicate listeners.
    private var observedDeviceID: AudioDeviceID = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let barH = NSStatusBar.system.thickness
        statusItem = NSStatusBar.system.statusItem(withLength: 60)
        barView    = VolumeBarView(frame: NSRect(x: 0, y: 0, width: 60, height: barH))

        // Scroll: accumulate fractionally, commit only when the rounded value changes.
        barView.onScroll = { [weak self] delta in
            guard let self else { return }
            self.preciseVolume = max(0, min(100, self.preciseVolume + delta))
            // Keep CoreAudio's echo from clobbering our gesture for a moment.
            self.suppressRefreshUntil = Date().addingTimeInterval(0.3)

            let newVol = Int(self.preciseVolume.rounded())
            guard newVol != self.cachedVolume else { return }   // no whole-% change yet
            self.cachedVolume = newVol
            setVolume(newVol)
            self.barView.update(volume: newVol)
        }

        barView.onRightClick = { [weak self] event in
            guard let self else { return }
            let menu = NSMenu()
            let quit = NSMenuItem(title: "Quit VolumeScroll",
                                  action: #selector(self.quit), keyEquivalent: "")
            quit.target = self
            menu.addItem(quit)
            NSMenu.popUpContextMenu(menu, with: event, for: self.barView)
        }

        barView.onResize = { [weak self] w in
            guard let self else { return }
            self.statusItem.length       = w
            self.barView.frame.size.width = w
        }

        statusItem.view = barView   // deprecated but the only way to capture scroll events

        setupAudioObservers()
        hardRefresh()
    }

    // MARK: - CoreAudio Observers

    private func setupAudioObservers() {
        // 1. Watch for default-output-device changes (headphone plug/unplug, AirPlay switch…)
        var sysAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &sysAddr, .main
        ) { [weak self] _, _ in
            self?.reregisterDeviceListeners()
            self?.scheduleRefresh()
        }

        reregisterDeviceListeners()
    }

    /// Attaches volume + mute listeners to the current default output device.
    /// Safe to call multiple times — skips if the device hasn't changed.
    private func reregisterDeviceListeners() {
        var id   = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &id) == noErr,
              id != 0, id != observedDeviceID
        else { return }
        observedDeviceID = id

        // Volume changes (F11/F12, system slider, other apps)
        var volAddr = AudioObjectPropertyAddress(
            mSelector: kVirtualMainVolSel,
            mScope:    kAudioDevicePropertyScopeOutput,
            mElement:  kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(id, &volAddr, .main) { [weak self] _, _ in
            self?.scheduleRefresh()
        }

        // Mute toggle (F10, Control Center mute button)
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope:    kAudioDevicePropertyScopeOutput,
            mElement:  kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(id, &muteAddr, .main) { [weak self] _, _ in
            self?.scheduleRefresh()
        }
    }

    // MARK: - Refresh

    /// Debounced: coalesces a burst of CoreAudio notifications into one UI update.
    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.hardRefresh() }
        pendingRefresh = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
    }

    /// Reads the real volume from CoreAudio and syncs the display + caches.
    private func hardRefresh() {
        // Mid-gesture: trust our own accumulator, ignore the hardware echo.
        if Date() < suppressRefreshUntil { return }
        let v = getVolume()
        cachedVolume  = v
        preciseVolume = Double(v)
        barView.update(volume: v)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

// MARK: - Entry Point

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()
