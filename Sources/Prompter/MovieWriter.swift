@preconcurrency import AVFoundation

/// Grava quadros já processados num .mov: HEVC + AAC, ou ProRes 422 HQ + PCM 24-bit (Superior ProRes).
/// Não é thread-safe: use sempre da mesma fila.
final class MovieWriter {
    enum Failure: LocalizedError {
        case noFrames
        var errorDescription: String? { L("Nenhum quadro de vídeo foi recebido.", "No video frames were received.") }
    }

    let url: URL
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audio: AVAssetWriterInput?
    private(set) var hasStarted = false
    private var startTime = CMTime.invalid
    private var lastVideoTime = CMTime.negativeInfinity
    /// Áudio à espera do codificador. Nunca se descarta áudio: um bloco perdido adiantaria todo o
    /// áudio seguinte, porque o gravador emenda os blocos sem respeitar lacunas no carimbo.
    private var pendingAudio: [CMSampleBuffer] = []
    /// Fim do último áudio já entregue, na linha do tempo do arquivo.
    private var audioEnd = CMTime.invalid
    // Diagnóstico (registrado ao finalizar).
    private var notReadyEvents = 0, maxQueue = 0, silenceInserted = 0.0, skippedOverlap = 0

    /// - Parameters:
    ///   - size: dimensões do vídeo; por padrão, as da configuração. A taxa escala pela área.
    ///   - startTime: início comum (relógio do host) para arquivos que precisam sair sincronizados;
    ///     amostras anteriores são descartadas. Sem ele, o arquivo começa no primeiro quadro.
    init(url: URL, settings: VideoSettings, size customSize: CGSize? = nil,
         audioFormat: CMFormatDescription?, startTime fixedStart: CMTime? = nil) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let size = customSize.map { CGSize(width: CGFloat(Int($0.width) & ~1), height: CGFloat(Int($0.height) & ~1)) }
            ?? settings.outputSize
        let reference = settings.outputSize.width * settings.outputSize.height
        let bitrate = Int(Double(settings.bitrate) * Double(size.width * size.height / max(reference, 1)))
        var videoSettings: [String: Any] = [
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                // sRGB (IEC 61966-2-1), igual à prévia: o arquivo aparece como foi visto ao gravar.
                AVVideoTransferFunctionKey: kCVImageBufferTransferFunction_sRGB as String,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        if settings.usesProRes {
            // ProRes tem taxa própria (intra-frame); não aceita propriedades de compressão.
            videoSettings[AVVideoCodecKey] = AVVideoCodecType.proRes422HQ
        } else {
            videoSettings[AVVideoCodecKey] = AVVideoCodecType.hevc
            videoSettings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: max(bitrate, 1_000_000),
                AVVideoExpectedSourceFrameRateKey: settings.frameRate,
                AVVideoMaxKeyFrameIntervalKey: settings.frameRate * 2,
            ]
        }
        video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        video.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
        writer.add(video)

        if let audioFormat, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat)?.pointee {
            let channels = min(max(Int(asbd.mChannelsPerFrame), 1), 2)
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
            let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
            let audioSettings: [String: Any] = settings.usesProRes
                ? [ // Áudio sem perdas para acompanhar o ProRes.
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: channels,
                    AVLinearPCMBitDepthKey: 24,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                    AVChannelLayoutKey: layoutData,
                ]
                : [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: min(asbd.mSampleRate, 48_000),
                    AVNumberOfChannelsKey: channels,
                    AVEncoderBitRateKey: settings.quality == .superiorHEVC
                        ? (channels == 1 ? 256_000 : 320_000)
                        : (channels == 1 ? 128_000 : 192_000),
                    AVChannelLayoutKey: layoutData,
                ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings, sourceFormatHint: audioFormat)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audio = input
            } else {
                audio = nil
            }
        } else {
            audio = nil
        }
        if let fixedStart, writer.startWriting() {
            writer.startSession(atSourceTime: fixedStart)
            startTime = fixedStart
            hasStarted = true
        }
    }

    func append(video buffer: CVPixelBuffer, at time: CMTime) {
        if !hasStarted {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: time)
            startTime = time
            hasStarted = true
        }
        defer { flushAudio() }
        guard writer.status == .writing, video.isReadyForMoreMediaData, time >= startTime,
              time > lastVideoTime else { return }
        if adaptor.append(buffer, withPresentationTime: time) { lastVideoTime = time }
    }

    func append(audio sample: CMSampleBuffer) {
        guard hasStarted, audio != nil, writer.status == .writing,
              CMSampleBufferGetPresentationTimeStamp(sample) + Self.duration(of: sample) > startTime else { return }
        if !(audio?.isReadyForMoreMediaData ?? true) { notReadyEvents += 1 }
        pendingAudio.append(sample)
        maxQueue = max(maxQueue, pendingAudio.count)
        // Salvaguarda de memória (~20 s de áudio); com o codificador saudável a fila fica perto de zero.
        if pendingAudio.count > 1000 { pendingAudio.removeFirst(pendingAudio.count - 1000) }
        flushAudio()
    }

    /// Entrega o áudio em fila enquanto o codificador aceitar. Lacunas no carimbo viram silêncio
    /// e trechos já cobertos são pulados: o áudio fica sempre no lugar certo da linha do tempo.
    private func flushAudio() {
        guard let audio else { return }
        while let next = pendingAudio.first, writer.status == .writing, audio.isReadyForMoreMediaData {
            let expected = audioEnd.isValid ? audioEnd : startTime
            let pts = CMSampleBufferGetPresentationTimeStamp(next)
            let duration = Self.duration(of: next)
            let gap = pts - expected
            if gap.seconds > 0.002 {
                let chunk = CMTimeMinimum(gap, CMTime(value: 1, timescale: 1))
                if let silence = Self.silence(like: next, at: expected, duration: chunk), audio.append(silence) {
                    audioEnd = expected + chunk
                    silenceInserted += chunk.seconds
                } else {
                    audioEnd = pts      // sem como preencher: segue do carimbo
                }
                continue
            }
            pendingAudio.removeFirst()
            if (pts + duration - expected).seconds <= 0.002 { skippedOverlap += 1; continue }   // já coberto
            if audio.append(next) { audioEnd = expected + duration }
        }
    }

    private static func duration(of sample: CMSampleBuffer) -> CMTime {
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              asbd.mSampleRate > 0 else { return CMSampleBufferGetDuration(sample) }
        return CMTime(value: CMTimeValue(CMSampleBufferGetNumSamples(sample)), timescale: CMTimeScale(asbd.mSampleRate))
    }

    /// Silêncio no mesmo formato PCM do áudio capturado.
    private static func silence(like sample: CMSampleBuffer, at time: CMTime, duration: CMTime) -> CMSampleBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(max(1, (duration.seconds * asbd.mSampleRate).rounded()))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        for b in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            if let data = b.mData { memset(data, 0, Int(b.mDataByteSize)) }
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(asbd.mSampleRate)),
                                        presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
                                   refcon: nil, formatDescription: description, sampleCount: CMItemCount(frames),
                                   sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
                                   sampleSizeArray: nil, sampleBufferOut: &out) == noErr, let out,
              CMSampleBufferSetDataBufferFromAudioBufferList(out, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                             flags: 0, bufferList: buffer.audioBufferList) == noErr else { return nil }
        return out
    }

    func finish(_ completion: @escaping (Error?) -> Void) {
        guard hasStarted else {
            writer.cancelWriting()
            completion(Failure.noFrames)
            return
        }
        // Esvazia a fila de áudio antes de fechar (até ~3 s de espera pelo codificador).
        let deadline = Date().addingTimeInterval(3)
        while !pendingAudio.isEmpty, writer.status == .writing, Date() < deadline {
            flushAudio()
            if !pendingAudio.isEmpty { usleep(5_000) }
        }
        screenLog.info("gravador \(self.url.lastPathComponent, privacy: .public): codificador de áudio indisponível \(self.notReadyEvents)x, fila máx \(self.maxQueue), silêncio inserido \(String(format: "%.3f", self.silenceInserted), privacy: .public) s, sobreposições puladas \(self.skippedOverlap)")
        video.markAsFinished()
        audio?.markAsFinished()
        writer.finishWriting { [writer] in
            completion(writer.status == .completed ? nil : writer.error)
        }
    }
}
