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
    /// Volume-% per mouse-wheel detent.
    private let wheelStep: Double = 2 //Adjust mouse wheel sensitivity (value is % volume change per wheel step)
    private let iconPt: CGFloat = 13
    private let gap: CGFloat    = 3
    private let hPad: CGFloat   = 5

    override init(frame: NSRect) {
        super.init(frame: frame)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)
        addSubview(label)
    }
    required init?(coder: NSCoder) { nil }

    func update(volume: Int) {
        let cfg = NSImage.SymbolConfiguration(pointSize: iconPt, weight: .regular)
        iconView.image = NSImage(systemSymbolName: symbolName(for: volume),
                                 accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        label.stringValue = "\(volume)%"
        label.sizeToFit()

        let w = ceil(hPad + iconPt + gap + label.frame.width + hPad)
        onResize?(w)
        layoutContent()
    }

    private func layoutContent() {
        let midY = bounds.midY
        iconView.frame = NSRect(x: hPad, y: midY - iconPt/2, width: iconPt, height: iconPt)
        label.frame    = NSRect(x: hPad + iconPt + gap,
                                y: midY - label.frame.height/2,
                                width: label.frame.width, height: label.frame.height)
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.momentumPhase == [] else { return }   // ignore inertia overshoot
        if event.hasPreciseScrollingDeltas {
            // Trackpad: map finger travel directly to a continuous volume delta.
            // Negated so swiping up = louder (natural direction).
            let delta = -Double(event.scrollingDeltaY) * trackpadSensitivity
            guard delta != 0 else { return }
            onScroll?(delta)
        } else {
            // Mouse wheel: one detent = one fixed step.
            let d = event.deltaY
            if d > 0.5       { onScroll?( wheelStep) }
            else if d < -0.5 { onScroll?(-wheelStep) }
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
