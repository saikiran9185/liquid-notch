import Foundation
import Observation
import OSLog
import QuartzCore

/// The music bars driven by what the Mac plays (owner, 11-06). The tap runs only while the setting is Real Audio, a song
/// plays and the bars are on the island; it stops 2 s after any of that ends (a skip or a quick pause doesn't restart
/// it). The analysis runs on its own queue at `fps` and hands four levels to the main thread.
///
/// Quiet music keeps real levels (the bars keep a small minimum height). The bars fall back to the animation only when
/// the tap can't start, or when it delivers nothing but exact zeros for 3 s from the start (what a denied permission
/// delivers: there's no public way to ask). After silent capture, retry only when the user explicitly checks permission.
@MainActor @Observable
final class AudioBars {
    enum Mode: String, CaseIterable { case realAudio, animated }
    enum State: Equatable { case off, starting, listening, live, failed(String) }

    var mode: Mode {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
            if mode == .animated { stopNow() } else { update(wanted: wanted) }
        }
    }
    private(set) var state: State = .off
    /// One level per bar, 0…1 (real levels only while `showsReal`). Not observed: it changes 30 times a second, and the
    /// bars read it on their own display link, so nothing else in the notch redraws for it (owner, 11-06).
    @ObservationIgnored private(set) var levels: [Double] = [0, 0, 0, 0]
    /// Every analysis frame's onset strength (`AudioSpectrum.onset`), when it was analysed (`CACurrentMediaTime`) and the
    /// frames a second: the desktop strip's beat tracking (`BeatTracker`, 11-07).
    @ObservationIgnored var onOnset: ((Double, Double, Double) -> Void)?
    /// The bars follow the audio right now; otherwise they animate.
    var showsReal: Bool { mode == .realAudio && state == .live }

    /// Analysis rate: 30 unless 60 looks better (owner asked to keep 30 and compare); `defaults write
    /// com.fellipe.liquidnotch bars.fps 60` to try it.
    @ObservationIgnored let fps: Double
    @ObservationIgnored var makeSource: () -> AudioSource = { SystemAudioTap() }
    @ObservationIgnored var schedule: Schedule = IslandDirector.taskSchedule
    @ObservationIgnored var clock: () -> Double = { CACurrentMediaTime() }
    /// Tests run starting, stopping and the analysis inline and drive `pump()` themselves.
    @ObservationIgnored var inline = false

    nonisolated static let modeKey = "bars.mode"
    /// The tap has delivered real audio at least once (Setup shows the permission as allowed).
    nonisolated static let heardKey = "bars.heard"
    /// A silent tap usually means capture was denied. Do not trigger another system prompt on every playback;
    /// Setup's explicit Allow action is the only retry after this point.
    nonisolated static let retrySuppressedKey = "bars.retrySuppressed"
    /// The old block (any silent start, a Jam's included) was cleared once (11-12).
    nonisolated static let blockCheckedKey = "bars.blockChecked"
    nonisolated static let permissionCheckCompleted = Notification.Name("LiquidNotchAudioPermissionCheckCompleted")
    private static let log = Logger(subsystem: "com.fellipe.liquidnotch", category: "audio")

    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var failedThisTime: Bool
    @ObservationIgnored private var permissionObserver: NSObjectProtocol?
    @ObservationIgnored private var source: AudioSource?
    @ObservationIgnored private var analyzer: AudioAnalyzer?
    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private var stopLater: Scheduled?
    @ObservationIgnored private var startedAt = 0.0
    @ObservationIgnored private let queue = DispatchQueue(label: "com.fellipe.liquidnotch.bars", qos: .userInitiated)

    init() {
        mode = Mode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "") ?? .realAudio
        // Up to 1.1.1 any silent start blocked the bars for good, a Jam's included: clear that once.
        if !UserDefaults.standard.bool(forKey: Self.blockCheckedKey) {
            UserDefaults.standard.removeObject(forKey: Self.retrySuppressedKey)
            UserDefaults.standard.set(true, forKey: Self.blockCheckedKey)
        }
        failedThisTime = UserDefaults.standard.bool(forKey: Self.retrySuppressedKey)
        let f = UserDefaults.standard.double(forKey: "bars.fps")
        fps = f == 60 ? 60 : 30
        permissionObserver = NotificationCenter.default.addObserver(forName: Self.permissionCheckCompleted, object: nil, queue: .main) { [weak self] note in
            guard let self, let heard = note.userInfo?["heard"] as? Bool else { return }
            MainActor.assumeIsolated {
                self.failedThisTime = !heard
                UserDefaults.standard.set(!heard, forKey: Self.retrySuppressedKey)
                if heard { self.update(wanted: self.wanted) }
            }
        }
    }

    /// Whether the bars should follow the audio now: a song plays and the bars are on the island.
    func update(wanted now: Bool) {
        let rising = now && !wanted
        wanted = now
        if rising && !UserDefaults.standard.bool(forKey: Self.retrySuppressedKey) { failedThisTime = false }
        guard mode == .realAudio else { return }
        if now {
            stopLater?.cancel(); stopLater = nil
            if source == nil && state != .starting && !failedThisTime { start() }
        } else if source != nil && stopLater == nil {
            stopLater = schedule(2) { [weak self] in self?.stopLater = nil; self?.stopNow() }
        }
    }

    private func start() {
        let source = makeSource()
        state = .starting
        startedAt = clock()
        let inline = self.inline
        run { [weak self] in
            let error: String? = { do { try source.start(); return nil } catch { return String(describing: error) } }()
            Self.onMain(inline) { self?.started(source, error: error) }
        }
    }

    private func started(_ source: AudioSource, error: String?) {
        if let error {
            fail(error)
            return
        }
        guard wanted, mode == .realAudio else { run { source.stop() }; state = .off; return }   // no longer wanted
        self.source = source
        analyzer = AudioAnalyzer(source: source)
        state = .listening
        startedAt = clock()
        guard !inline else { return }
        timer = Self.analysisTimer(queue: queue, fps: fps, analyzer: analyzer!) { [weak self] frame in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(frame) } }
        }
    }

    /// The analysis timer, on the bars' queue. Made outside the main actor: a handler written in a main-actor method is
    /// main-actor code to Swift 6, and running it on this queue trapped (the crash of 11-06, 21:18).
    private nonisolated static func analysisTimer(queue: DispatchQueue, fps: Double, analyzer: AudioAnalyzer,
                                                  deliver: @escaping @Sendable (AudioAnalyzer.Frame) -> Void) -> DispatchSourceTimer {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1 / fps, leeway: .milliseconds(2))
        let dt = Float(1 / fps)
        t.setEventHandler { deliver(analyzer.analyze(dt: dt)) }
        t.resume()
        return t
    }

    /// Setup's Allow…: a tap for a few seconds makes macOS ask for System Audio Recording; if audio plays meanwhile and
    /// comes through, the row shows Allowed.
    nonisolated static func askPermission() {
        DispatchQueue.global(qos: .userInitiated).async {
            let tap = SystemAudioTap()
            guard (try? tap.start()) != nil else {
                NotificationCenter.default.post(name: permissionCheckCompleted, object: nil, userInfo: ["heard": false])
                return
            }
            Thread.sleep(forTimeInterval: 4)
            let out = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
            defer { out.deallocate() }
            let n = tap.ring.latest(into: out, count: 4096)
            let heard = UnsafeBufferPointer(start: out, count: n).contains(where: { $0 != 0 })
            if heard {
                UserDefaults.standard.set(true, forKey: heardKey)
            }
            tap.stop()
            NotificationCenter.default.post(name: permissionCheckCompleted, object: nil, userInfo: ["heard": heard])
        }
    }

    /// The app is quitting: stop the tap now.
    func shutdown() {
        wanted = false
        stopNow()
    }

    /// Tests: one analysis step, inline.
    func pump() {
        guard let analyzer else { return }
        received(analyzer.analyze(dt: Float(1 / fps)))
    }

    private func received(_ frame: AudioAnalyzer.Frame) {
        guard source != nil else { return }
        if frame.silent && state != .live {
            // Nothing plays out of this Mac (a Spotify Jam, or the song on another device): silence is expected, not a
            // denied permission. Keep listening (the bars animate meanwhile) and start the 3 s again.
            if !frame.outputPlaying { startedAt = clock(); return }
            // Sound plays here but only zeros reach the tap: no permission, most likely.
            if clock() - startedAt >= 3 { fail("only silence from the tap (System Audio Recording not allowed?)") }
            return
        }
        if state != .live {
            state = .live
            failedThisTime = false
            UserDefaults.standard.set(false, forKey: Self.retrySuppressedKey)
            UserDefaults.standard.set(true, forKey: Self.heardKey)
            Self.log.notice("audio: live")
        }
        levels = frame.levels.map(Double.init)
        onOnset?(Double(frame.onset), frame.at ?? clock(), fps)
    }

    private func fail(_ why: String) {
        Self.log.error("audio: falling back to the animation: \(why, privacy: .public)")
        failedThisTime = true
        if why.contains("only silence") {
            UserDefaults.standard.set(true, forKey: Self.retrySuppressedKey)
        }
        stopNow()
        state = .failed(why)
    }

    /// Stops the tap now (it was no longer wanted, the setting changed, or it failed).
    private func stopNow() {
        stopLater?.cancel(); stopLater = nil
        timer?.cancel(); timer = nil
        analyzer = nil
        if let source { run { source.stop() } }
        source = nil
        if case .failed = state {} else { state = .off }
        levels = [0, 0, 0, 0]
    }

    private func run(_ work: @escaping @Sendable () -> Void) {
        if inline { work() } else { queue.async(execute: work) }
    }

    private nonisolated static func onMain(_ inline: Bool, _ work: @escaping @MainActor @Sendable () -> Void) {
        if inline { MainActor.assumeIsolated { work() } } else { DispatchQueue.main.async { MainActor.assumeIsolated { work() } } }
    }
}

/// The analysis queue's side: reads the newest samples and runs the spectrum. Used only on that queue (or inline).
final class AudioAnalyzer: @unchecked Sendable {
    struct Frame: Sendable {
        let levels: [Float]
        /// Every sample was exactly zero.
        let silent: Bool
        /// Something played out of this Mac (only read while silent; true otherwise).
        var outputPlaying = true
        /// How much new sound this frame brought (`AudioSpectrum.onset`).
        var onset: Float = 0
        /// When it was analysed (`CACurrentMediaTime`), nil from tests' frames.
        var at: Double?
    }

    private let source: AudioSource
    private var spectrum: AudioSpectrum
    private let scratch: UnsafeMutablePointer<Float>

    init(source: AudioSource) {
        self.source = source
        spectrum = AudioSpectrum(sampleRate: source.sampleRate)
        scratch = .allocate(capacity: spectrum.size)
        scratch.initialize(repeating: 0, count: spectrum.size)
    }

    deinit { scratch.deallocate() }

    func analyze(dt: Float) -> Frame {
        let n = source.ring.latest(into: scratch, count: spectrum.size)
        let levels = spectrum.process(UnsafeBufferPointer(start: scratch, count: n), dt: dt)
        let silent = spectrum.silent
        return Frame(levels: levels, silent: silent, outputPlaying: silent ? source.outputPlaying : true,
                     onset: spectrum.onset, at: CACurrentMediaTime())
    }
}

