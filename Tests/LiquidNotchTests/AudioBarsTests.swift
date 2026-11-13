import XCTest
@testable import LiquidNotch

/// The audio-reactive bars' rules (owner, 11-06): the tap runs only while wanted and stops 2 s after; quiet music keeps
/// real levels; the animation comes back only when the tap fails or delivers nothing but silence from the start; the
/// Animated setting never taps.
@MainActor
final class AudioBarsTests: XCTestCase {
    final class FakeSource: AudioSource, @unchecked Sendable {
        let ring = SampleRing()
        let sampleRate = 48_000.0
        var fails = false
        /// Something plays out of this Mac (a Jam or Spotify Connect elsewhere: nothing does).
        var outputPlaying = true
        var starts = 0, stops = 0
        private var phase = 0.0

        func start() throws {
            starts += 1
            if fails { throw SystemAudioTap.Failure.tap(-1) }
        }
        func stop() { stops += 1 }

        func play(hz: Double = 500, amplitude: Float, frames: Int = 1600) {
            var buf = [Float](repeating: 0, count: frames)
            for i in 0..<frames { buf[i] = amplitude * Float(sin(phase)); phase += 2 * .pi * hz / sampleRate }
            buf.withUnsafeBufferPointer { ring.write(left: $0.baseAddress!, right: nil, frames: frames) }
        }
    }

    private var now = 0.0

    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(true, forKey: AudioBars.blockCheckedKey)
        UserDefaults.standard.removeObject(forKey: AudioBars.retrySuppressedKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AudioBars.retrySuppressedKey)
        super.tearDown()
    }

    func testSilentCaptureDoesNotRetryForPlaybackOrRelaunchUntilExplicitPermissionCheck() {
        let src = FakeSource(), s = ManualScheduler(), b = bars(src, s)
        b.update(wanted: true)
        run(b, src, seconds: 4, amplitude: 0)
        b.update(wanted: false)
        b.update(wanted: true)
        XCTAssertEqual(src.starts, 1)
        let relaunched = bars(src, s)
        relaunched.update(wanted: true)
        XCTAssertEqual(src.starts, 1)
        NotificationCenter.default.post(name: AudioBars.permissionCheckCompleted, object: nil, userInfo: ["heard": true])
        XCTAssertGreaterThan(src.starts, 1, "an explicit successful permission check releases the capture block")
        b.shutdown()
        relaunched.shutdown()
    }

    private func bars(_ source: FakeSource, _ s: ManualScheduler) -> AudioBars {
        UserDefaults.standard.removeObject(forKey: AudioBars.modeKey)
        let b = AudioBars()
        b.inline = true
        b.makeSource = { source }
        b.schedule = s.schedule
        b.clock = { [unowned self] in now }
        return b
    }

    private func run(_ b: AudioBars, _ src: FakeSource, seconds: Double, amplitude: Float) {
        for _ in 0..<Int(seconds * 30) {
            if amplitude >= 0 { src.play(amplitude: amplitude) }
            now += 1.0 / 30
            b.pump()
        }
    }

    func testRunsOnlyWhileWanted() {
        let src = FakeSource(), s = ManualScheduler(), b = bars(src, s)
        XCTAssertFalse(b.showsReal)
        b.update(wanted: true)
        XCTAssertEqual(src.starts, 1)
        XCTAssertEqual(b.state, .listening)
        run(b, src, seconds: 0.5, amplitude: 0.5)
        XCTAssertTrue(b.showsReal)
        XCTAssertGreaterThan(b.levels[1], 0.3, "a 500 Hz tone moves the second bar")
        b.update(wanted: false)
        s.advance(1)
        b.update(wanted: true)                 // a quick skip: the tap keeps running
        XCTAssertEqual(src.starts, 1)
        XCTAssertEqual(src.stops, 0)
        b.update(wanted: false)
        s.advance(2.1)
        XCTAssertEqual(src.stops, 1)
        XCTAssertEqual(b.state, .off)
        XCTAssertFalse(b.showsReal)
    }

    // Quiet music keeps real levels, even near silence; it never falls back to the animation.
    func testQuietMusicStaysReal() {
        let src = FakeSource(), s = ManualScheduler(), b = bars(src, s)
        b.update(wanted: true)
        run(b, src, seconds: 1, amplitude: 0.4)
        run(b, src, seconds: 5, amplitude: 0.0005)
        XCTAssertTrue(b.showsReal)
        run(b, src, seconds: 5, amplitude: 0)     // a silent gap after the music: still real (low bars)
        XCTAssertTrue(b.showsReal)
        XCTAssertEqual(src.stops, 0)
    }

    // The animation comes back when the tap can't start, or gives only zeros from the start (no permission); the next
    // time the bars are wanted it tries again.
    func testFallsBackOnlyWhenTheTapFails() {
        let src = FakeSource(), s = ManualScheduler(), b = bars(src, s)
        src.fails = true
        b.update(wanted: true)
        if case .failed = b.state {} else { XCTFail("failed: \(b.state)") }
        XCTAssertFalse(b.showsReal)
        b.update(wanted: true)
        XCTAssertEqual(src.starts, 1, "not again while it's still wanted")
        src.fails = false
        b.update(wanted: false)
        b.update(wanted: true)
        XCTAssertEqual(src.starts, 2, "tried again on the next play")
        run(b, src, seconds: 2.5, amplitude: 0)
        XCTAssertEqual(b.state, .listening)
        run(b, src, seconds: 1, amplitude: 0)
        if case .failed = b.state {} else { XCTFail("only zeros for 3 s: failed, got \(b.state)") }
        XCTAssertEqual(src.stops, 1)
    }

    // A Spotify Jam or a song playing on another device: the player says it plays, but nothing comes out of this Mac.
    // That silence isn't a denied permission: the bars animate meanwhile, never give up for good, and go live as soon as
    // the sound comes here (owner, 11-12: "the bar doesn't work when I'm in a jam").
    func testSilenceWhileNothingPlaysHereIsNotADenial() {
        let src = FakeSource(), s = ManualScheduler(), b = bars(src, s)
        src.outputPlaying = false
        b.update(wanted: true)
        run(b, src, seconds: 6, amplitude: 0)
        XCTAssertEqual(b.state, .listening, "still listening, animating meanwhile")
        XCTAssertFalse(b.showsReal)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: AudioBars.retrySuppressedKey), "never blocked for later songs")
        src.outputPlaying = true
        run(b, src, seconds: 0.5, amplitude: 0.5)
        XCTAssertTrue(b.showsReal, "live once the sound plays here")
        XCTAssertEqual(src.starts, 1)
    }

    // The block a silent start used to leave behind is cleared once, so bars blocked by a Jam come back.
    func testAnOldBlockIsClearedOnce() {
        UserDefaults.standard.removeObject(forKey: AudioBars.blockCheckedKey)
        UserDefaults.standard.set(true, forKey: AudioBars.retrySuppressedKey)
        let src = FakeSource(), s = ManualScheduler(), b = bars(src, s)
        b.update(wanted: true)
        XCTAssertEqual(src.starts, 1, "the old block is gone")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: AudioBars.blockCheckedKey))
        b.shutdown()
    }

    func testAnimatedNeverTaps() {
        let src = FakeSource(), s = ManualScheduler(), b = bars(src, s)
        b.mode = .animated
        b.update(wanted: true)
        XCTAssertEqual(src.starts, 0)
        XCTAssertFalse(b.showsReal)
        b.mode = .realAudio
        XCTAssertEqual(src.starts, 1, "switching back while a song plays starts it")
        b.mode = .animated
        XCTAssertEqual(src.stops, 1, "and switching away stops it at once")
        UserDefaults.standard.removeObject(forKey: AudioBars.modeKey)
    }

    // The real path: starting on the bars' queue and the analysis timer there, levels handed back to the main thread.
    // (Its handler was main-actor code to Swift 6 and trapped on that queue: the crash of 11-06, 21:18.)
    func testTheRealTimerRunsOffTheMainThread() {
        UserDefaults.standard.removeObject(forKey: AudioBars.modeKey)
        let src = FakeSource(), b = AudioBars()
        b.makeSource = { src }
        b.update(wanted: true)
        let deadline = Date().addingTimeInterval(3)
        while !b.showsReal && Date() < deadline {
            src.play(amplitude: 0.5, frames: 800)
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(b.showsReal)
        XCTAssertGreaterThan(b.levels[1], 0.1)
        b.shutdown()
    }

    final class Flag: @unchecked Sendable { var set = false }

    // Only the bars read the levels, on their own display link: level updates notify no observer (nothing else in the
    // notch redraws for them, owner 11-06). Going live still does, so the bars switch from the animation.
    func testLevelsNotifyNobody() {
        let src = FakeSource(), s = ManualScheduler(), b = bars(src, s)
        b.update(wanted: true)
        let levels = Flag(), live = Flag()
        withObservationTracking { _ = b.levels } onChange: { levels.set = true }
        withObservationTracking { _ = b.showsReal } onChange: { live.set = true }
        run(b, src, seconds: 0.5, amplitude: 0.5)
        XCTAssertTrue(b.showsReal)
        XCTAssertTrue(live.set, "going live is observed")
        XCTAssertFalse(levels.set, "level updates aren't")
        XCTAssertGreaterThan(b.levels[1], 0.3)
    }

    // The bars' layout: four bottom-aligned bars 2 pt apart in the 18 × 13 pt slot.
    func testBarsGeometry() {
        let r = BarsView.rects(in: CGSize(width: 18, height: 13), heights: [1, 0.5, 0, 2])
        XCTAssertEqual(r.map(\.minX), [0, 5, 10, 15])
        XCTAssertEqual(r.map(\.width), [3, 3, 3, 3])
        XCTAssertEqual(r.map(\.height), [13, 6.5, 0, 13])
        XCTAssertEqual(r.map(\.maxY), [13, 13, 13, 13])
    }
}
