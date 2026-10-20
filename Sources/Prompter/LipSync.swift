@preconcurrency import AVFoundation
import Vision

/// Sincronia labial automática: mede numa gravação o atraso entre a boca (Vision) e a voz e,
/// se a medição for confiável, desloca o áudio sem recodificar.
///
/// Método: abertura interna dos lábios ÷ largura externa (por quadro) e envelope da voz (5 ms),
/// os dois filtrados na faixa silábica (~0,5–6 Hz); o atraso com maior correlação, de −100 a
/// +300 ms, é o desvio. Na fala natural a boca se move antes do som: num vídeo avaliado por uma
/// pessoa como natural, o medidor marca −75 ms, que é a referência.
enum LipSync {
    struct Estimate {
        /// Quanto o vídeo está atrasado em relação à voz (s), já descontada a antecipação natural.
        let residual: Double
        let correlation: Double
        /// Altura do pico em relação aos atrasos distantes: quanto maior, mais nítido.
        let sharpness: Double
        var isReliable: Bool { correlation >= 0.2 && sharpness >= 0.12 }
    }

    /// Antecipação natural da boca em relação ao som, na escala deste medidor.
    static let naturalLead = -0.075

    static func estimate(_ url: URL, maxSeconds: Double = 120) async -> Estimate? {
        let asset = AVURLAsset(url: url)
        guard let video = try? await asset.loadTracks(withMediaType: .video).first,
              let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: maxSeconds, preferredTimescale: 600))
        let videoOut = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ])
        let audioOut = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: 48_000,
        ])
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)
        reader.add(audioOut)
        guard reader.startReading() else { return nil }

        let request = VNDetectFaceLandmarksRequest()
        var times: [Double] = [], mouth: [Double] = [], pcm: [Float] = []
        var videoDone = false, audioDone = false
        while !(videoDone && audioDone) {
            if !videoDone {
                if let sample = videoOut.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) {
                    times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
                    mouth.append(mouthOpening(buffer, request: request))
                } else { videoDone = true }
            }
            if !audioDone {
                if let sample = audioOut.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
                    var length = 0
                    var pointer: UnsafeMutablePointer<CChar>?
                    CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
                    if let pointer {
                        pointer.withMemoryRebound(to: Float.self, capacity: length / 4) {
                            pcm.append(contentsOf: UnsafeBufferPointer(start: $0, count: length / 4))
                        }
                    }
                } else { audioDone = true }
            }
        }
        return analyze(times: times, mouth: mouth, pcm: pcm, sampleRate: 48_000)
    }

    private static func mouthOpening(_ buffer: CVPixelBuffer, request: VNDetectFaceLandmarksRequest) -> Double {
        try? VNImageRequestHandler(cvPixelBuffer: buffer).perform([request])
        guard let face = request.results?.first, face.confidence > 0.5,
              let inner = face.landmarks?.innerLips, let outer = face.landmarks?.outerLips else { return .nan }
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        let ip = inner.pointsInImage(imageSize: size), op = outer.pointsInImage(imageSize: size)
        guard let top = ip.map(\.y).max(), let bottom = ip.map(\.y).min(),
              let right = op.map(\.x).max(), let left = op.map(\.x).min(), right - left > 10 else { return .nan }
        return Double((top - bottom) / (right - left))
    }

    static func analyze(times: [Double], mouth: [Double], pcm: [Float], sampleRate: Double) -> Estimate? {
        // Voz: passa-alta simples e envelope log a 200 Hz.
        let rate = 200.0, hop = Int(sampleRate / rate)
        // Pelo menos ~5 s de vídeo e de voz.
        guard pcm.count > hop * 1000, times.count > 150 else { return nil }
        var envelope: [Double] = []
        var previous: Float = 0
        for i in stride(from: 0, to: pcm.count - hop, by: hop) {
            var energy: Float = 0
            for k in 0..<hop { let x = pcm[i + k] - previous; previous = pcm[i + k]; energy += x * x }
            envelope.append(log(Double(energy / Float(hop)) + 1e-9))
        }
        // Boca reamostrada a 200 Hz.
        var resampled = [Double](repeating: .nan, count: envelope.count)
        var j = 0
        for i in envelope.indices {
            let t = Double(i) / rate
            while j + 1 < times.count, times[j + 1] < t { j += 1 }
            guard j + 1 < times.count, times[j] <= t, !mouth[j].isNaN, !mouth[j + 1].isNaN else { continue }
            resampled[i] = mouth[j] + (mouth[j + 1] - mouth[j]) * (t - times[j]) / (times[j + 1] - times[j])
        }
        let a = band(envelope), m = band(resampled)
        let lags = Array(-20...60)     // −100…+300 ms em passos de 5 ms
        let curve = lags.map { correlation(a, m, lag: $0) }
        guard let best = curve.indices.filter({ !curve[$0].isNaN }).max(by: { curve[$0] < curve[$1] }) else { return nil }
        let far = curve.indices.filter { abs($0 - best) > 30 && !curve[$0].isNaN }.map { curve[$0] }
        let sharpness = curve[best] - (far.isEmpty ? 0 : far.reduce(0, +) / Double(far.count))
        let lag = Double(lags[best]) * 0.005
        return Estimate(residual: lag - naturalLead, correlation: curve[best], sharpness: sharpness)
    }

    /// Faixa silábica: média móvel de 85 ms menos média de 600 ms.
    private static func band(_ x: [Double]) -> [Double] {
        let fast = movingAverage(x, 8), slow = movingAverage(x, 60)
        return x.indices.map { fast[$0].isNaN || slow[$0].isNaN ? .nan : fast[$0] - slow[$0] }
    }

    private static func movingAverage(_ x: [Double], _ r: Int) -> [Double] {
        var out = [Double](repeating: .nan, count: x.count)
        var sum = 0.0, count = 0
        for i in 0..<(x.count + r) {
            if i < x.count, !x[i].isNaN { sum += x[i]; count += 1 }
            let leaving = i - 2 * r - 1
            if leaving >= 0, leaving < x.count, !x[leaving].isNaN { sum -= x[leaving]; count -= 1 }
            let center = i - r
            if center >= 0, center < x.count, count > r { out[center] = sum / Double(count) }
        }
        return out
    }

    private static func correlation(_ a: [Double], _ m: [Double], lag: Int) -> Double {
        var sa = 0.0, sm = 0.0, n = 0.0
        var pairs: [(Double, Double)] = []
        pairs.reserveCapacity(a.count)
        for i in a.indices {
            let k = i + lag
            guard k >= 0, k < m.count, !a[i].isNaN, !m[k].isNaN else { continue }
            pairs.append((a[i], m[k]))
            sa += a[i]; sm += m[k]; n += 1
        }
        guard n > 1000 else { return .nan }
        let ma = sa / n, mm = sm / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for (x, y) in pairs { sxy += (x - ma) * (y - mm); sxx += (x - ma) * (x - ma); syy += (y - mm) * (y - mm) }
        return sxy / (sxx * syy).squareRoot()
    }

    // MARK: Correção do arquivo

    /// Desloca o áudio em `seconds` (positivo = atrasa o áudio) sem recodificar e substitui o arquivo.
    static func shiftAudio(in url: URL, by seconds: Double) async throws {
        let asset = AVURLAsset(url: url)
        guard let video = try await asset.loadTracks(withMediaType: .video).first,
              let audio = try await asset.loadTracks(withMediaType: .audio).first else { return }
        let videoRange = try await video.load(.timeRange), audioRange = try await audio.load(.timeRange)
        let composition = AVMutableComposition()
        guard let v = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let a = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return }
        try v.insertTimeRange(videoRange, of: video, at: .zero)
        let shift = CMTime(seconds: abs(seconds), preferredTimescale: 48_000)
        if seconds >= 0 {
            try a.insertTimeRange(audioRange, of: audio, at: shift)
        } else {
            let trimmed = CMTimeRange(start: audioRange.start + shift, duration: audioRange.duration - shift)
            try a.insertTimeRange(trimmed, of: audio, at: .zero)
        }
        if let transform = try? await video.load(.preferredTransform) { v.preferredTransform = transform }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".sincronizando-\(UUID().uuidString).mov")
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { return }
        try await export.export(to: temporary, as: .mov)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }
}
