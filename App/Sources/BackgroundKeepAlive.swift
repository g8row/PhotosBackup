import AVFoundation
import CoreLocation
import Foundation

/// How the keep-alive holds the app awake. The same two ways SideStore uses
/// for its background refresh: iOS does not suspend an app that is playing
/// audio or receiving location updates. Neither would pass App Store review,
/// which is why they are opt-in here and only matter to a sideloaded build.
enum KeepAliveMode: String, CaseIterable, Identifiable, Sendable {
    case audio
    case location

    var id: String { rawValue }

    var title: String {
        switch self {
        case .audio: return "Silent Audio"
        case .location: return "Location"
        }
    }

    var detail: String {
        switch self {
        case .audio:
            return "Plays silence mixed with other audio. Another app taking over audio, such as a call, can stop it until the app is opened again."
        case .location:
            return "Asks for coarse location, about 3 km, and ignores it. Holds up through calls and music, but needs location access and iOS shows the location arrow."
        }
    }
}

/// When the keep-alive should be running, kept apart from AVFoundation and
/// CoreLocation so it can be tested.
enum KeepAlivePolicy {
    /// Run only while the user asked for it and the queue has work it can do
    /// by itself, so a finished, paused or offline backup lets the app sleep.
    static func shouldRun(enabled: Bool, queueCanMoveOnItsOwn: Bool, accountUsable: Bool) -> Bool {
        enabled && queueCanMoveOnItsOwn && accountUsable
    }

    /// iOS lets an app start an audio session or background location updates
    /// only from the foreground. A keep-alive that is already running carries
    /// on into the background; one that is not has to wait for the next open.
    static func canStart(isForeground: Bool) -> Bool { isForeground }

    /// How long a pause that can lift by itself (network, connection check)
    /// may last before the keep-alive lets the app sleep.
    static let pauseGrace: TimeInterval = 180

    /// The longest one run may hold the app, so a queue that stops moving
    /// without saying so cannot keep the phone awake all day. Long enough for
    /// a night on the charger; opening the app starts a new run.
    static let maxRun: TimeInterval = 12 * 60 * 60

    /// Keep the screen on only when nothing else keeps the backup going once
    /// it locks (issue #37). With the keep-alive running the phone can sleep,
    /// which costs far less battery than a lit screen.
    static func keepsScreenAwake(isForeground: Bool, queueCanMoveOnItsOwn: Bool, keepAliveRunning: Bool) -> Bool {
        isForeground && queueCanMoveOnItsOwn && !keepAliveRunning
    }
}

/// Keeps the process running after the app leaves the foreground, so the
/// upload queue goes on at the background concurrency limit instead of
/// waiting for a processing window. See `KeepAliveMode`.
@MainActor
final class BackgroundKeepAlive: NSObject {
    /// iOS stopped the keep-alive in a way the app cannot undo from the
    /// background: the audio session was taken over for good, or location
    /// access was revoked. The coordinator treats it like an expired window.
    var onLost: ((String) -> Void)?
    /// Another app temporarily took over audio while the keep-alive waits for
    /// the interruption to end. iOS may suspend the process during the gap, so
    /// the coordinator disarms the crash-loop guard until playback resumes.
    var onSuspended: ((String) -> Void)?
    /// Silent audio resumed after an interruption or route change.
    var onResumed: (() -> Void)?
    /// The user granted location access after the settings prompt.
    var onLocationAuthorized: (() -> Void)?

    private(set) var mode: KeepAliveMode?
    private(set) var isAudioInterrupted = false
    /// True only while the keep-alive is actively holding the process awake.
    var isRunning: Bool {
        guard let mode else { return false }
        switch mode {
        case .audio: return !isAudioInterrupted && (player?.isPlaying == true)
        case .location: return locationManager != nil
        }
    }

    private var player: AVAudioPlayer?
    private var locationManager: CLLocationManager?
    private var observers: [NSObjectProtocol] = []

    /// Start, or switch to, `mode`. Throws when iOS refuses, for example an
    /// audio session that cannot be activated or location access denied.
    func start(_ mode: KeepAliveMode) throws {
        if self.mode == mode, isRunning { return }
        // Check location authorization before stopping an active audio
        // keep-alive, so opening the permission prompt does not drop audio
        // before the user has even answered.
        if mode == .location {
            let status = (locationManager ?? CLLocationManager()).authorizationStatus
            switch status {
            case .authorizedAlways, .authorizedWhenInUse: break
            case .notDetermined: throw KeepAliveError.locationNotYetAllowed
            default: throw KeepAliveError.locationDenied
            }
        }
        stop()
        switch mode {
        case .audio: try startAudio()
        case .location: try startLocation()
        }
        self.mode = mode
    }

    func stop() {
        player?.stop()
        player = nil
        isAudioInterrupted = false
        if mode == .audio {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        locationManager?.stopUpdatingLocation()
        locationManager?.delegate = nil
        locationManager = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        mode = nil
    }

    /// Ask for location access up front, from the settings toggle, so the
    /// prompt does not appear the first time a backup starts.
    func requestLocationAuthorizationIfNeeded() {
        let manager = locationManager ?? CLLocationManager()
        if manager.authorizationStatus == .notDetermined {
            manager.delegate = self
            pendingAuthorizationManager = manager
            manager.requestWhenInUseAuthorization()
        }
    }

    /// Holds the manager while the permission prompt is up; a released manager
    /// dismisses it.
    private var pendingAuthorizationManager: CLLocationManager?

    // MARK: Audio

    private func startAudio() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
        let player = try AVAudioPlayer(data: Self.silentWAV)
        player.numberOfLoops = -1
        // Not zero: iOS may treat a player at zero volume as not playing.
        player.volume = 0.01
        guard player.prepareToPlay(), player.play() else {
            throw KeepAliveError.audioDidNotStart
        }
        self.player = player
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: session, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let options = AVAudioSession.InterruptionOptions(
                rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            Task { @MainActor in self?.audioInterrupted(type, options: options) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                            object: session, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            Task { @MainActor in self?.audioRouteChanged(reason) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: session, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resumeAudio(after: "the system audio service restarted") }
        })
    }

    /// Disconnecting headphones or Bluetooth audio causes iOS to pause
    /// `AVAudioPlayer` automatically. Restart playback right away so iOS does
    /// not silently suspend the process while `mode` still reads `.audio`.
    private func audioRouteChanged(_ reason: AVAudioSession.RouteChangeReason?) {
        guard mode == .audio, !isAudioInterrupted, reason == .oldDeviceUnavailable else { return }
        guard player?.isPlaying != true else { return }
        resumeAudio(after: "an audio output disconnected")
    }

    private func audioInterrupted(_ type: AVAudioSession.InterruptionType?,
                                  options: AVAudioSession.InterruptionOptions) {
        guard mode == .audio else { return }
        switch type {
        case .began:
            isAudioInterrupted = true
            DiagnosticEventLog.shared.record("keepalive", "Another app took over audio; the keep-alive waits for it to finish")
            onSuspended?("another app took over audio")
        case .ended where options.contains(.shouldResume):
            resumeAudio(after: "the audio interruption ended")
        case .ended:
            // iOS says not to resume, such as when another app keeps playing.
            // Taking the audio back anyway is what Apple asks apps not to do.
            stop()
            onLost?("another app kept the audio after its interruption ended")
        default:
            break
        }
    }

    /// A call or another app's audio pauses the player. iOS allows a
    /// `.mixWithOthers` session to reactivate from the background once the
    /// interruption ends; if it refuses, the keep-alive is lost.
    private func resumeAudio(after reason: String) {
        guard mode == .audio else { return }
        do {
            player?.stop()
            player = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            try startAudio()
            isAudioInterrupted = false
            DiagnosticEventLog.shared.record("keepalive", "Resumed the silent audio after \(reason)")
            onResumed?()
        } catch {
            let message = "Could not resume the silent audio after \(reason): \(error.localizedDescription)"
            stop()
            onLost?(message)
        }
    }

    /// One second of 8 kHz, 16-bit mono silence as a WAV file.
    static let silentWAV: Data = {
        let sampleRate: UInt32 = 8000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let dataSize = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1)) // PCM
        append(channels); append(sampleRate)
        append(sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)) // byte rate
        append(channels * (bitsPerSample / 8)) // block align
        append(bitsPerSample)
        data.append(contentsOf: Array("data".utf8)); append(dataSize)
        data.append(Data(count: Int(dataSize)))
        return data
    }()

    // MARK: Location

    private func startLocation() throws {
        let manager = CLLocationManager()
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            break
        case .notDetermined:
            throw KeepAliveError.locationNotYetAllowed
        default:
            throw KeepAliveError.locationDenied
        }
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = CLLocationDistanceMax
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        // Apple requires the blue indicator for When-In-Use background updates;
        // when the user has granted Always, hide it just like SideStore does.
        manager.showsBackgroundLocationIndicator = manager.authorizationStatus != .authorizedAlways
        manager.startUpdatingLocation()
        locationManager = manager
    }
}

extension BackgroundKeepAlive: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Unknown location is transient; only denial ends the keep-alive.
        guard (error as? CLError)?.code == .denied else { return }
        Task { @MainActor [weak self] in
            guard let self, self.mode == .location else { return }
            self.stop()
            self.onLost?("location access was turned off")
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self else { return }
            if status != .notDetermined {
                self.pendingAuthorizationManager?.delegate = nil
                self.pendingAuthorizationManager = nil
            }
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                self.onLocationAuthorized?()
                return
            }
            guard self.mode == .location, status == .denied || status == .restricted else { return }
            self.stop()
            self.onLost?("location access was turned off")
        }
    }
}

enum KeepAliveError: LocalizedError {
    case audioDidNotStart
    case locationNotYetAllowed
    case locationDenied

    var errorDescription: String? {
        switch self {
        case .audioDidNotStart: return "iOS would not start the silent audio"
        case .locationNotYetAllowed: return "location access has not been granted yet"
        case .locationDenied: return "location access is off for this app in Settings"
        }
    }
}

/// Optional significant-location-change monitor (arrival home / travel) that
/// lets iOS wake the app in the background to discover and hand off new photos
/// even when the app has not been opened recently. Coordinates are ignored.
@MainActor
final class SignificantLocationWakeMonitor: NSObject {
    var onLocationWake: (() -> Void)?
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?

    private(set) var isMonitoring = false
    private var manager: CLLocationManager?

    var authorizationStatus: CLAuthorizationStatus {
        (manager ?? CLLocationManager()).authorizationStatus
    }

    func requestAlwaysAuthorizationIfNeeded() {
        let manager = ensureManager()
        let status = manager.authorizationStatus
        if status == .notDetermined || status == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled else {
            if isMonitoring {
                manager?.stopMonitoringSignificantLocationChanges()
                isMonitoring = false
                DiagnosticEventLog.shared.record("location", "Stopped significant-location wake monitoring")
            }
            return
        }
        guard CLLocationManager.significantLocationChangeMonitoringAvailable() else { return }
        let manager = ensureManager()
        guard manager.authorizationStatus == .authorizedAlways else {
            if isMonitoring {
                manager.stopMonitoringSignificantLocationChanges()
                isMonitoring = false
            }
            return
        }
        guard !isMonitoring else { return }
        manager.allowsBackgroundLocationUpdates = true
        manager.startMonitoringSignificantLocationChanges()
        isMonitoring = true
        DiagnosticEventLog.shared.record("location", "Enabled significant-location wake monitoring for unattended photo discovery")
    }

    private func ensureManager() -> CLLocationManager {
        if let manager { return manager }
        let created = CLLocationManager()
        created.delegate = self
        manager = created
        return created
    }
}

extension SignificantLocationWakeMonitor: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in
            self?.onLocationWake?()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.onAuthorizationChange?(status)
        }
    }
}
