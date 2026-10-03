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

// MARK: - Status Item
//
// macOS 27 moved menu bar rendering into MenuBarAgent. A custom `statusItem.view`
// is now snapshotted once and never receives events, so we drive the standard
// button instead and catch scrolls with NSEvent monitors.

final class VolumeStatusItem {
    /// Carries a continuous volume delta (in percentage points).
    var onScroll: ((Double) -> Void)?
    var onRightClick: (() -> Void)?

    let item: NSStatusItem

    /// Volume-% applied per point of trackpad travel. Higher = faster.
    private let trackpadSensitivity: Double = 0.30 //Adjust trackpad sensitivity (value is % volume change per point of finger travel)
    /// Volume-% per line of mouse-wheel travel. macOS scales this by spin speed,
    /// so fast spins accelerate just like the trackpad.
    private let wheelSensitivity: Double = 2.0 //Adjust mouse wheel sensitivity (value is % volume change per line of scroll)
    private let iconPt: CGFloat = 15      // SF Symbol point size — controls glyph height
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    /// Fixed icon canvas fitting the widest/tallest symbol, so the item never resizes.
    private var iconSlot: NSSize = .zero
    private var monitors: [Any] = []

    /// All symbols the icon can display — used to measure the widest one.
    private static let allSymbols = [
        "speaker.slash.fill", "speaker.fill",
        "speaker.wave.1.fill", "speaker.wave.3.fill",
    ]

    init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let sizes = Self.allSymbols.compactMap { symbol($0)?.size }
        iconSlot = NSSize(width:  ceil(sizes.map(\.width).max()  ?? iconPt),
                          height: ceil(sizes.map(\.height).max() ?? iconPt))

        if let button = item.button {
            button.imagePosition = .imageLeft
            button.target = self
            button.action = #selector(buttonClicked)
            button.sendAction(on: [.rightMouseUp])
        }

        // macOS 27+: scrolls over the item are delivered to MenuBarAgent, so only a
        // global monitor sees them. macOS ≤ 26: they reach our own status window.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] e in
            self?.handleScroll(e)
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] e in
            self?.handleScroll(e)
            return e
        }) { monitors.append(m) }
    }

    deinit { monitors.forEach(NSEvent.removeMonitor) }

    private func symbol(_ name: String) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: iconPt, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
    }

    func update(volume: Int) {
        guard let button = item.button else { return }

        // Icon left-anchored in a fixed canvas: the speaker body stays put while wave
        // arcs extend right into the reserved space.
        if let sym = symbol(symbolName(for: volume)) {
            let slot = iconSlot
            let img = NSImage(size: slot, flipped: false) { r in
                sym.draw(in: NSRect(x: 0, y: (r.height - sym.size.height) / 2,
                                    width: sym.size.width, height: sym.size.height))
                return true
            }
            img.isTemplate = true
            button.image = img
        }

        // Pad with figure spaces (digit-width) so "5%" takes the same room as "100%".
        let text = "\(volume)%"
        let pad = String(repeating: "\u{2007}", count: max(0, 4 - text.count))
        button.attributedTitle = NSAttributedString(string: text + pad,
                                                    attributes: [.font: font])
        button.setAccessibilityLabel("Volume \(volume)%")
    }

    private func handleScroll(_ event: NSEvent) {
        guard event.momentumPhase == [],                     // ignore inertia overshoot
              let button = item.button, let window = button.window,
              window.convertToScreen(button.convert(button.bounds, to: nil))
                  .contains(NSEvent.mouseLocation)
        else { return }

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

    @objc private func buttonClicked() { onRightClick?() }

    /// Shows `menu` anchored to the status item (one-shot, so left-click stays inert).
    func popUp(_ menu: NSMenu) {
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: VolumeStatusItem!

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

        statusItem = VolumeStatusItem()

        // Scroll: accumulate fractionally, commit only when the rounded value changes.
        statusItem.onScroll = { [weak self] delta in
            guard let self else { return }
            self.preciseVolume = max(0, min(100, self.preciseVolume + delta))
            // Keep CoreAudio's echo from clobbering our gesture for a moment.
            self.suppressRefreshUntil = Date().addingTimeInterval(0.3)

            let newVol = Int(self.preciseVolume.rounded())
            guard newVol != self.cachedVolume else { return }   // no whole-% change yet
            self.cachedVolume = newVol
            setVolume(newVol)
            self.statusItem.update(volume: newVol)
        }

        statusItem.onRightClick = { [weak self] in
            guard let self else { return }
            let menu = NSMenu()
            let quit = NSMenuItem(title: "Quit VolumeScroll",
                                  action: #selector(self.quit), keyEquivalent: "")
            quit.target = self
            menu.addItem(quit)
            self.statusItem.popUp(menu)
        }

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
        statusItem.update(volume: v)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

// MARK: - Entry Point

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()
