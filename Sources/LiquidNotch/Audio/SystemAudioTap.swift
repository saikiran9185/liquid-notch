import CoreAudio
import Foundation
import OSLog
import Synchronization

/// The latest mono samples: the audio thread writes them, the analysis queue reads the newest ones. No locks, and no
/// allocations after `init`.
final class SampleRing: @unchecked Sendable {
    let capacity: Int
    private let mask: Int
    private let buffer: UnsafeMutablePointer<Float>
    private let written = Atomic<Int>(0)

    init(capacity: Int = 16_384) {
        precondition(capacity > 0 && capacity & (capacity - 1) == 0, "a power of two")
        self.capacity = capacity
        mask = capacity - 1
        buffer = .allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
    }

    deinit { buffer.deallocate() }

    /// Samples written so far (it only grows).
    var total: Int { written.load(ordering: .acquiring) }

    /// Audio thread: `frames` frames of `channels` interleaved samples, mixed to mono.
    func write(interleaved p: UnsafePointer<Float>, frames: Int, channels: Int) {
        let w = written.load(ordering: .relaxed), c = max(channels, 1), k = 1 / Float(c)
        for f in 0..<frames {
            var sum: Float = 0
            for ch in 0..<c { sum += p[f * c + ch] }
            buffer[(w + f) & mask] = sum * k
        }
        written.store(w + frames, ordering: .releasing)
    }

    /// Audio thread: one buffer per channel (up to two used), mixed to mono.
    func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>?, frames: Int) {
        let w = written.load(ordering: .relaxed)
        for f in 0..<frames { buffer[(w + f) & mask] = right.map { (left[f] + $0[f]) * 0.5 } ?? left[f] }
        written.store(w + frames, ordering: .releasing)
    }

    /// Copies the newest `count` samples (fewer at the very start) into `out`; returns how many.
    func latest(into out: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let w = written.load(ordering: .acquiring), n = min(count, w, capacity)
        for i in 0..<n { out[i] = buffer[(w - n + i) & mask] }
        return n
    }
}

/// Where the bars' samples come from (a fake in the tests).
protocol AudioSource: AnyObject, Sendable {
    var sampleRate: Double { get }
    var ring: SampleRing { get }
    /// Something plays out of this Mac now (any app's sound on the default output). Read on the analysis queue.
    var outputPlaying: Bool { get }
    func start() throws
    func stop()
}

/// Everything the Mac plays, through a Core Audio process tap (macOS 14.2+; no Screen Recording, only the System Audio
/// Recording permission, asked with `NSAudioCaptureUsageDescription`). Read through a private aggregate device that
/// holds only the tap: no output device is in it, so the default output device, the route and AirPods' microphone are
/// never touched (owner, 11-06), and the tap leaves the sound unmuted.
final class SystemAudioTap: AudioSource, @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case tap(OSStatus), aggregate(OSStatus), format(OSStatus), unsupported, ioProc(OSStatus), start(OSStatus), routeChanged
        var description: String {
            switch self {
            case .tap(let e): "creating the tap failed (\(e))"
            case .aggregate(let e): "creating the aggregate device failed (\(e))"
            case .format(let e): "reading the tap's format failed (\(e))"
            case .unsupported: "the tap's format isn't 32-bit float"
            case .ioProc(let e): "creating the IO proc failed (\(e))"
            case .start(let e): "starting the device failed (\(e))"
            case .routeChanged: "the default output device changed while starting"
            }
        }
    }

    private static let log = Logger(subsystem: "com.fellipe.liquidnotch", category: "audio")
    let ring = SampleRing()
    private(set) var sampleRate = 48_000.0
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    func start() throws {
        guard tapID == AudioObjectID(kAudioObjectUnknown) else { return }
        let output = Self.defaultOutput()
        do {
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            description.uuid = UUID()
            description.name = "Liquid Notch music bars"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            var tap = AudioObjectID(kAudioObjectUnknown)
            var err = AudioHardwareCreateProcessTap(description, &tap)
            guard err == noErr else { throw Failure.tap(err) }
            tapID = tap

            let properties: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Liquid Notch music bars",
                kAudioAggregateDeviceUIDKey: "com.fellipe.liquidnotch.bars.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                                   kAudioSubTapDriftCompensationKey: true]],
            ]
            var aggregate = AudioObjectID(kAudioObjectUnknown)
            err = AudioHardwareCreateAggregateDevice(properties as CFDictionary, &aggregate)
            guard err == noErr else { throw Failure.aggregate(err) }
            aggregateID = aggregate

            var format = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            err = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format)
            guard err == noErr else { throw Failure.format(err) }
            guard format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else { throw Failure.unsupported }
            sampleRate = format.mSampleRate
            let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0

            // The audio thread: copy into the ring, nothing else (no locks, no allocations, no logging).
            let ring = self.ring
            var proc: AudioDeviceIOProcID?
            err = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, nil) { _, input, _, _, _ in
                let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                guard list.count > 0, let first = list[0].mData else { return }
                if interleaved {
                    let channels = Int(list[0].mNumberChannels)
                    let frames = Int(list[0].mDataByteSize) / (MemoryLayout<Float>.size * max(channels, 1))
                    ring.write(interleaved: first.assumingMemoryBound(to: Float.self), frames: frames, channels: channels)
                } else {
                    let frames = Int(list[0].mDataByteSize) / MemoryLayout<Float>.size
                    let right = list.count > 1 ? list[1].mData?.assumingMemoryBound(to: Float.self) : nil
                    ring.write(left: first.assumingMemoryBound(to: Float.self), right: right.map { UnsafePointer($0) }, frames: frames)
                }
            }
            guard err == noErr, let proc else { throw Failure.ioProc(err) }
            procID = proc
            err = AudioDeviceStart(aggregate, proc)
            guard err == noErr else { throw Failure.start(err) }
            // It never sets the default output device; check anyway, and back out if anything moved it.
            guard Self.defaultOutput() == output else { throw Failure.routeChanged }
            Self.log.notice("audio: tap running at \(Int(self.sampleRate)) Hz, \(interleaved ? "interleaved" : "planar", privacy: .public)")
        } catch {
            Self.log.error("audio: \(String(describing: error), privacy: .public)")
            stop()
            throw error
        }
    }

    func stop() {
        if let procID, aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != AudioObjectID(kAudioObjectUnknown) { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != AudioObjectID(kAudioObjectUnknown) { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }

    /// Whether any app is playing through the default output device (`kAudioDevicePropertyDeviceIsRunningSomewhere`). The
    /// tap's own aggregate device holds no output device, so it doesn't count. True when it can't tell.
    var outputPlaying: Bool {
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(Self.defaultOutput(), &address, 0, nil, &size, &running) == noErr else { return true }
        return running != 0
    }

    /// The system's default output device (read only: nothing here ever sets it).
    static func defaultOutput() -> AudioObjectID {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }
}
