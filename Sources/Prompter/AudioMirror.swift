@preconcurrency import AVFoundation

/// Converte o áudio do microfone em estéreo "dual mono" (L = R).
///
/// Microfones de headset costumam chegar como estéreo com sinal em um canal só, o que deixa
/// a voz de um lado. Aqui cada canal tem o nível medido (com suavização); os canais mortos
/// (−20 dB abaixo do mais forte) ficam de fora e os vivos são misturados nos dois lados.
/// Não é thread-safe: use sempre da mesma fila.
final class AudioMirror {
    private var levels: [Float] = []
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var outputDescription: CMAudioFormatDescription?

    func process(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
        guard let input = SpeechFollower.pcmBuffer(from: sample),
              let source = floatPlanar(input) else { return nil }
        let channels = Int(source.format.channelCount), frames = Int(source.frameLength)
        guard channels > 0, frames > 0, let data = source.floatChannelData,
              let format = stereoFormat(sampleRate: source.format.sampleRate),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let left = output.floatChannelData?[0], let right = output.floatChannelData?[1] else { return nil }
        output.frameLength = AVAudioFrameCount(frames)

        // Nível por canal: sobe rápido, desce devagar (~1 s), para não alternar canais entre palavras.
        if levels.count != channels { levels = Array(repeating: 0, count: channels) }
        for c in 0..<channels {
            var sum: Float = 0
            for i in 0..<frames { sum += data[c][i] * data[c][i] }
            let rms = (sum / Float(frames)).squareRoot()
            levels[c] = rms > levels[c] ? rms : levels[c] * 0.97 + rms * 0.03
        }
        let peak = levels.max() ?? 0
        var live = (0..<channels).filter { levels[$0] >= max(peak * 0.1, 1e-5) }
        if live.isEmpty { live = Array(0..<channels) }

        let gain = 1 / Float(live.count)
        for i in 0..<frames {
            var mixed: Float = 0
            for c in live { mixed += data[c][i] }
            mixed *= gain
            left[i] = mixed
            right[i] = mixed
        }
        return makeSample(output, at: CMSampleBufferGetPresentationTimeStamp(sample))
    }

    /// Float32 não intercalado, que permite ler cada canal direto.
    private func floatPlanar(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format.commonFormat == .pcmFormatFloat32, !buffer.format.isInterleaved { return buffer }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
                                         channels: buffer.format.channelCount, interleaved: false) else { return nil }
        if converter?.inputFormat != buffer.format || converter?.outputFormat != target {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter, let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: buffer.frameLength) else { return nil }
        do { try converter.convert(to: out, from: buffer) } catch { return nil }
        return out
    }

    private func stereoFormat(sampleRate: Double) -> AVAudioFormat? {
        if let outputFormat, outputFormat.sampleRate == sampleRate { return outputFormat }
        outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)
        outputDescription = nil
        if let outputFormat {
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: outputFormat.streamDescription, layoutSize: 0, layout: nil,
                                           magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                           formatDescriptionOut: &outputDescription)
        }
        return outputFormat
    }

    private func makeSample(_ buffer: AVAudioPCMBuffer, at time: CMTime) -> CMSampleBuffer? {
        guard let outputDescription else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)),
                                        presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
                                   refcon: nil, formatDescription: outputDescription,
                                   sampleCount: CMItemCount(buffer.frameLength), sampleTimingEntryCount: 1,
                                   sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                   sampleBufferOut: &sample) == noErr, let sample else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: nil,
                                                             blockBufferMemoryAllocator: nil, flags: 0,
                                                             bufferList: buffer.audioBufferList) == noErr else { return nil }
        return sample
    }
}
