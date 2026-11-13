import Accelerate
import AudioToolbox
import CoreAudio
import Foundation

/// Spectrum bands for the left and right channels, shared between the audio thread and the view.
final class Spectrum: @unchecked Sendable {
    static let bandCount = 56
    private let lock = NSLock()
    private var bands = [[Float]](repeating: [Float](repeating: 0, count: bandCount), count: 2)

    /// Channel 0 is left, 1 is right.
    func read(_ ch: Int) -> [Float] { lock.lock(); defer { lock.unlock() }; return bands[ch] }
    func write(_ ch: Int, _ b: [Float]) { lock.lock(); bands[ch] = b; lock.unlock() }
    /// Lets the wave fall to rest when the audio stops.
    func decay() { lock.lock(); bands = bands.map { $0.map { $0 * 0.92 } }; lock.unlock() }
}

/// Taps Music's audio output (Core Audio process tap, macOS 14.2+) and turns it into spectrum bands.
/// Nothing is recorded or stored: each block of samples is analysed and dropped.
final class AudioTap: @unchecked Sendable {
    let spectrum = Spectrum()
    private(set) var pid: pid_t = 0
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "edge-nowplaying.audio", qos: .userInteractive)

    // FFT state, touched only on `queue`
    private let n = 2048
    private lazy var log2n = vDSP_Length(log2(Double(n)))
    private lazy var fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    private lazy var window: [Float] = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
    private var rings = [[Float]](repeating: [], count: 2)
    private var smooth = [[Float]](repeating: [Float](repeating: 0, count: Spectrum.bandCount), count: 2)
    private var peakDb: Float = -30
    private var sampleRate: Double = 48_000
    private var edges: [Int] = []

    var running: Bool { procID != nil }

    /// Starts tapping the process with this pid; returns false if Core Audio refuses.
    @discardableResult
    func start(pid: pid_t) -> Bool {
        if running && pid == self.pid { return true }
        stop()
        guard let proc = Self.processObject(for: pid) else { NSLog("no audio process for pid %d", pid); return false }
        self.pid = pid

        let desc = CATapDescription(stereoMixdownOfProcesses: [proc])
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr else { NSLog("process tap refused"); return false }

        var fmt = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &fmt)
        sampleRate = fmt.mSampleRate > 0 ? fmt.mSampleRate : 48_000
        edges = Self.bandEdges(n: n, rate: sampleRate)

        // The aggregate device needs a real device as its clock: the current output.
        guard let outUID = Self.defaultOutputUID() else { NSLog("no output device"); stop(); return false }
        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Edge Now Playing tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        guard AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggregateID) == noErr else { stop(); return false }

        let channels = Int(max(fmt.mChannelsPerFrame, 1))
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            self?.consume(input, channels: channels)
        }
        guard status == noErr, AudioDeviceStart(aggregateID, procID) == noErr else { NSLog("tap start failed"); stop(); return false }
        NSLog("tap started on pid %d (%.0f Hz, %d ch, output %@)", pid, sampleRate, channels, outUID)
        return true
    }

    func stop() {
        if let p = procID { AudioDeviceStop(aggregateID, p); AudioDeviceDestroyIOProcID(aggregateID, p) }
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil; aggregateID = AudioObjectID(kAudioObjectUnknown); tapID = AudioObjectID(kAudioObjectUnknown); pid = 0
    }

    private static func defaultOutputUID() -> String? {
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr else { return nil }
        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &uid) == noErr else { return nil }
        return uid as String
    }

    private static func processObject(for pid: pid_t) -> AudioObjectID? {
        var p = pid, obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let r = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &p, &size, &obj)
        return r == noErr && obj != kAudioObjectUnknown ? obj : nil
    }

    /// Log-spaced FFT bin edges from 35 Hz to 16 kHz.
    private static func bandEdges(n: Int, rate: Double) -> [Int] {
        let lo = 35.0, hi = min(16_000, rate / 2 - 1)
        return (0...Spectrum.bandCount).map { i in
            let f = lo * pow(hi / lo, Double(i) / Double(Spectrum.bandCount))
            return max(1, min(n / 2 - 1, Int(f / rate * Double(n))))
        }
    }

    private func consume(_ input: UnsafePointer<AudioBufferList>, channels: Int) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = abl.first, let data = first.mData else { return }
        if abl.count > 1 {   // one buffer per channel
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            let l = abl[0].mData!.assumingMemoryBound(to: Float.self)
            let r = abl[1].mData!.assumingMemoryBound(to: Float.self)
            rings[0].append(contentsOf: UnsafeBufferPointer(start: l, count: frames))
            rings[1].append(contentsOf: UnsafeBufferPointer(start: r, count: frames))
        } else {             // interleaved; mono feeds both sides
            let p = data.assumingMemoryBound(to: Float.self)
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
            for i in 0..<frames {
                rings[0].append(p[i * channels])
                rings[1].append(p[i * channels + min(1, channels - 1)])
            }
        }
        while rings[0].count >= n && rings[1].count >= n {
            let db = (0..<2).map { bandsDb(Array(rings[$0].prefix(n))) }
            // Automatic gain from the louder channel, so left and right stay comparable.
            peakDb = max(db.flatMap { $0 }.max() ?? -90, peakDb - 0.05)
            let range: Float = 45
            for ch in 0..<2 {
                for b in 0..<Spectrum.bandCount {
                    let v = min(max((db[ch][b] - (peakDb - range)) / range, 0), 1)
                    smooth[ch][b] += (v - smooth[ch][b]) * (v > smooth[ch][b] ? 0.4 : 0.06)   // rise fast, fall slowly
                }
                spectrum.write(ch, smooth[ch])
                rings[ch].removeFirst(n / 2)   // 50% overlap
            }
        }
    }

    /// Power per band in dB for one block of samples.
    private func bandsDb(_ samples: [Float]) -> [Float] {
        var x = vDSP.multiply(samples, window)
        var re = [Float](repeating: 0, count: n / 2), im = [Float](repeating: 0, count: n / 2)
        var power = [Float](repeating: 0, count: n / 2)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                x.withUnsafeMutableBufferPointer { xp in
                    xp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n / 2))
            }
        }
        return (0..<Spectrum.bandCount).map { b in
            let lo = edges[b], hi = max(edges[b + 1], lo + 1)
            var sum: Float = 0
            for k in lo..<hi { sum += power[k] }
            return 10 * log10(sum / Float(hi - lo) / Float(n * n) + 1e-12)
        }
    }
}
