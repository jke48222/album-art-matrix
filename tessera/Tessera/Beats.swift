// The beat, measured rather than looked up.
//
// No service knows the tempo of everything this phone plays: Deezer's bpm
// field is empty for most of the library, Spotify closed theirs, and lyric
// timestamps proved too hand-jittered to derive it from. But the song is
// PLAYING, out loud, in the room. So the app listens: ten seconds of the
// actual audio, an onset-strength envelope, and an autocorrelation sweep
// over 60 to 200 bpm. Tempo is the one thing a phone microphone in a noisy
// room can still measure well, because it is a rate, not a pitch.
//
// The measured tempo is folded into 82.5...165 (half- and double-time are
// the same groove) and remembered per track, so each song is measured once.
// Deezer remains the fallback for the tracks it does know, for when the
// music is in headphones and the room is silent.

import Foundation
import AVFoundation
import Accelerate

struct BeatReading: Codable, Equatable {
    var bpm: Double          // folded into 82.5...165
    var confidence: Double
    var source: String       // "mic" | "deezer"

    /// One revolution per bar: the record turns like a record, at the song's
    /// own rate. 120 bpm lands on 30 rpm, a ballad drifts near 20.
    var rpm: Double { (bpm / 4 * 100).rounded() / 100 }
}

@MainActor
@Observable
final class BeatBook {
    enum Phase: Equatable {
        case idle
        case listening
        case locked(BeatReading)
        case missed
    }

    private(set) var phase: Phase = .idle
    private(set) var track: String = ""
    private var generation = 0

    private var cache: [String: BeatReading] = [:]
    private static let cacheKey = "beats.cache"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let saved = try? JSONDecoder().decode([String: BeatReading].self, from: data) {
            cache = saved
        }
    }

    private func remember(_ key: String, _ r: BeatReading) {
        cache[key] = r
        while cache.count > 300 { cache.removeValue(forKey: cache.keys.first!) }
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
    }

    static func key(_ title: String?, _ artist: String?) -> String {
        "\(title ?? "")|\(artist ?? "")"
    }

    /// Point the book at a track. Answers from memory if it can; otherwise
    /// goes quiet and waits for measure().
    func retune(title: String?, artist: String?) {
        let k = Self.key(title, artist)
        guard k != track else { return }
        track = k
        generation += 1
        if let hit = cache[k] { phase = .locked(hit) }
        else { phase = .idle }
    }

    /// Measure the current track: microphone first, Deezer if the room gave
    /// nothing. The generation guard means a track change mid-listen just
    /// abandons the result instead of pinning it to the wrong song.
    func measure(title: String?, artist: String?) {
        let k = Self.key(title, artist)
        track = k
        generation += 1
        let gen = generation
        if let hit = cache[k] { phase = .locked(hit); return }
        phase = .listening

        Task { [weak self] in
            // No track name just means no cache row and no Deezer to ask:
            // a room with a record player in it still has a tempo.
            var reading = await BeatListener.measure()
            if reading == nil, k != "|" {
                reading = await Self.askDeezer(title: title, artist: artist)
            }
            guard let self, self.generation == gen else { return }
            if let reading {
                if k != "|" { self.remember(k, reading) }
                self.phase = .locked(reading)
            } else {
                self.phase = .missed
            }
        }
    }

    // MARK: Deezer

    /// The fallback bookkeeper. Sparse for anything recent, but free, quick,
    /// and right when it answers at all.
    private static func askDeezer(title: String?, artist: String?) async -> BeatReading? {
        guard let title, let artist,
              let q = "\(artist) \(title)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string: "https://api.deezer.com/search?q=\(q)")
        else { return nil }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6
        let session = URLSession(configuration: cfg)

        guard let (data, _) = try? await session.data(from: searchURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["data"] as? [[String: Any]] else { return nil }

        // Prefer a hit whose artist agrees; a title-only match on a common
        // word pulls up covers and karaoke versions with the wrong tempo.
        let mine = artist.lowercased()
        let pick = rows.first {
            (($0["artist"] as? [String: Any])?["name"] as? String)?.lowercased()
                .contains(mine.prefix(12)) == true
        } ?? rows.first
        guard let pick, let id = pick["id"] as? Int,
              let trackURL = URL(string: "https://api.deezer.com/track/\(id)"),
              let (td, _) = try? await session.data(from: trackURL),
              let tj = try? JSONSerialization.jsonObject(with: td) as? [String: Any],
              let bpm = tj["bpm"] as? Double, bpm > 40
        else { return nil }
        return BeatReading(bpm: Self.fold(bpm), confidence: 0.5, source: "deezer")
    }

    nonisolated static func fold(_ bpm: Double) -> Double {
        var b = bpm
        while b >= 165 { b /= 2 }
        while b < 82.5 { b *= 2 }
        return b
    }
}

// MARK: - The listener

/// Ten seconds of room, one number out. Runs entirely off the main thread;
/// the session mixes with others so the music never so much as ducks.
enum BeatListener {
    static let window = 10.0     // seconds of audio to judge

    static func measure() async -> BeatReading? {
        guard await askPermission() else { return nil }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch { return nil }
        defer {
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 8000 else { return nil }

        let sink = SampleSink(target: Int(window * fmt.sampleRate))
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buffer, _ in
            guard let ch = buffer.floatChannelData?[0] else { return }
            sink.push(ch, count: Int(buffer.frameLength))
        }
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            return nil
        }
        let filled = await sink.wait(timeout: window + 4)
        input.removeTap(onBus: 0)
        engine.stop()
        guard filled else { return nil }

        let samples = sink.drain()
        let rate = fmt.sampleRate
        let result = await Task.detached(priority: .userInitiated) {
            analyze(samples, rate: rate)
        }.value
        guard let result else { return nil }
        return BeatReading(bpm: BeatBook.fold(result.bpm),
                           confidence: result.confidence, source: "mic")
    }

    private static func askPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default:
            return await AVAudioApplication.requestRecordPermission()
        }
    }

    /// Fills once, resumes once, no matter how the race between the tap and
    /// the timeout lands.
    private final class SampleSink: @unchecked Sendable {
        private var buf: [Float]
        private var count = 0
        private let target: Int
        private let lock = NSLock()
        private var waiter: CheckedContinuation<Bool, Never>? = nil

        init(target: Int) {
            self.target = target
            buf = [Float](repeating: 0, count: target)
        }

        func push(_ p: UnsafePointer<Float>, count n: Int) {
            lock.lock()
            let take = min(n, target - count)
            if take > 0 {
                buf.withUnsafeMutableBufferPointer { dst in
                    dst.baseAddress!.advanced(by: count).update(from: p, count: take)
                }
                count += take
            }
            let full = count >= target
            let w = full ? waiter : nil
            if full { waiter = nil }
            lock.unlock()
            w?.resume(returning: true)
        }

        func wait(timeout: Double) async -> Bool {
            await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                lock.lock()
                if count >= target { lock.unlock(); c.resume(returning: true); return }
                waiter = c
                lock.unlock()
                Task.detached { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
                    guard let self else { return }
                    self.lock.lock()
                    let w = self.waiter
                    self.waiter = nil
                    self.lock.unlock()
                    w?.resume(returning: false)
                }
            }
        }

        func drain() -> [Float] {
            lock.lock(); defer { lock.unlock() }
            return Array(buf[0..<count])
        }
    }

    // MARK: DSP

    /// Spectral-flux onset envelope, then a comb sweep. The envelope answers
    /// "when did anything new happen", which survives melody, reverb, and a
    /// dishwasher far better than any pitch-domain trick.
    nonisolated static func analyze(_ x: [Float], rate: Double) -> (bpm: Double, confidence: Double)? {
        var rms: Float = 0
        vDSP_rmsqv(x, 1, &rms, vDSP_Length(x.count))
        guard rms > 0.004 else { return nil }        // a silent room is not a tempo

        let nfft = 2048, hop = 512
        let half = nfft / 2
        guard x.count > nfft * 8 else { return nil }

        var window = [Float](repeating: 0, count: nfft)
        vDSP_hann_window(&window, vDSP_Length(nfft), Int32(vDSP_HANN_NORM))
        guard let setup = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }

        var re = [Float](repeating: 0, count: half)
        var im = [Float](repeating: 0, count: half)
        var windowed = [Float](repeating: 0, count: nfft)
        var mags = [Float](repeating: 0, count: half)
        var prev = [Float](repeating: 0, count: half)
        var diff = [Float](repeating: 0, count: half)
        var flux: [Float] = []
        flux.reserveCapacity((x.count - nfft) / hop + 1)

        var i = 0
        while i + nfft <= x.count {
            x.withUnsafeBufferPointer { xp in
                vDSP_vmul(xp.baseAddress! + i, 1, window, 1, &windowed, 1, vDSP_Length(nfft))
            }
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    windowed.withUnsafeBufferPointer { wp in
                        wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, 11, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
                }
            }
            vDSP_vsub(prev, 1, mags, 1, &diff, 1, vDSP_Length(half))   // mags - prev
            var lo: Float = 0, hi: Float = .greatestFiniteMagnitude
            vDSP_vclip(diff, 1, &lo, &hi, &diff, 1, vDSP_Length(half))
            var s: Float = 0
            vDSP_sve(diff, 1, &s, vDSP_Length(half))
            flux.append(s)
            prev = mags
            i += hop
        }

        // Zero-mean, half-rectified, exactly as the validated prototype.
        var mean: Float = 0
        vDSP_meanv(flux, 1, &mean, vDSP_Length(flux.count))
        var negMean = -mean
        vDSP_vsadd(flux, 1, &negMean, &flux, 1, vDSP_Length(flux.count))
        var zero: Float = 0, big: Float = .greatestFiniteMagnitude
        vDSP_vclip(flux, 1, &zero, &big, &flux, 1, vDSP_Length(flux.count))

        let fps = rate / Double(hop)
        guard Double(flux.count) > fps * 4 else { return nil }

        var norm: Float = 0
        vDSP_dotpr(flux, 1, flux, 1, &norm, vDSP_Length(flux.count))
        guard norm > 0 else { return nil }

        // Correlation at a fractional lag; the integer-rounded version read
        // consistently 1.5 percent slow in the prototype.
        func comb(_ lag: Double) -> Double {
            let l0 = Int(lag)
            let frac = Float(lag - Double(l0))
            let n = flux.count - l0 - 1
            guard n > 32 else { return 0 }
            var dot: Float = 0
            flux.withUnsafeBufferPointer { f in
                let p = f.baseAddress!
                for j in 0..<n {
                    let shifted = p[j + l0] + (p[j + l0 + 1] - p[j + l0]) * frac
                    dot += p[j] * shifted
                }
            }
            return Double(dot / norm)
        }

        var best = 0.0, bestBpm = 0.0
        var bpm = 60.0
        while bpm <= 200.0 {
            let lag = 60.0 / bpm * fps
            let score = comb(lag) + 0.5 * comb(lag * 2)
            if score > best { best = score; bestBpm = bpm }
            bpm += 0.1
        }
        guard bestBpm > 0, best > 0.18 else { return nil }   // nothing periodic enough to trust
        return (bestBpm, min(1, best))
    }
}
