@preconcurrency import AVFoundation
import NaturalLanguage
import Speech

/// Transcrição on-device (SpeechAnalyzer) ligada ao alinhador do roteiro.
/// `append` pode ser chamado de qualquer fila; os callbacks chegam na main.
final class SpeechFollower: @unchecked Sendable {
    enum Failure: LocalizedError {
        case unsupportedLanguage(String)
        case noAudioFormat
        var errorDescription: String? {
            switch self {
            case .unsupportedLanguage(let id): L("O reconhecimento de voz não suporta o idioma \(id).", "Speech recognition doesn't support the language \(id).")
            case .noAudioFormat: L("Formato de áudio do reconhecimento indisponível.", "Speech recognition audio format unavailable.")
            }
        }
    }

    /// Nova contagem de palavras faladas.
    var onPosition: ((Int) -> Void)?
    /// Texto bruto ouvido (finalizado + volátil), útil para depuração.
    var onHeard: ((String) -> Void)?
    /// Texto reconhecido como saiu do transcritor (com acentos e maiúsculas) e se é final.
    var onTranscript: ((String, Bool) -> Void)?

    private let lock = NSLock()
    private var aligner = ScriptAligner(keys: [])
    private var finalized: [String] = []
    private var volatile: [String] = []
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    private var targetFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    var isRunning: Bool { lock.withLock { continuation != nil } }

    /// Idioma do roteiro, detectado pelo próprio texto (padrão: português do Brasil).
    static func locale(for script: String) -> Locale {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(script)
        switch recognizer.dominantLanguage {
        case .english?: return Locale(identifier: "en-US")
        case .spanish?: return Locale(identifier: "es-ES")
        case .french?: return Locale(identifier: "fr-FR")
        case .italian?: return Locale(identifier: "it-IT")
        case .german?: return Locale(identifier: "de-DE")
        default: return Locale(identifier: "pt-BR")
        }
    }

    /// Prepara modelo (baixa na primeira vez) e começa a ouvir a partir de `position`.
    func start(script: String, from position: Int, onPreparing: (() -> Void)? = nil) async throws {
        await stop()
        let words = ScriptTokenizer.words(in: script)
        lock.withLock {
            aligner = ScriptAligner(keys: words.map(\.key))
            aligner.reset(to: position)
            finalized = []
            volatile = []
        }

        let wanted = Self.locale(for: script)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else {
            throw Failure.unsupportedLanguage(wanted.identifier)
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onPreparing?()
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw Failure.noAudioFormat
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber],
                                      options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        // Vocabulário do roteiro: ajuda com nomes próprios e termos técnicos.
        let context = AnalysisContext()
        var seen = Set<String>()
        let vocabulary = (script as NSString).components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count >= 4 && seen.insert($0.lowercased()).inserted }
        context.contextualStrings[.general] = Array(vocabulary.prefix(300))
        try? await analyzer.setContext(context)
        try await analyzer.prepareToAnalyze(in: format)

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .bufferingNewest(200))
        lock.withLock {
            self.analyzer = analyzer
            self.targetFormat = format
            self.converter = nil
            self.continuation = continuation
        }

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    self?.handle(text: String(result.text.characters), isFinal: result.isFinal)
                }
            } catch {}
        }
        try await analyzer.start(inputSequence: stream)
    }

    func stop() async {
        let (analyzer, continuation) = lock.withLock { () -> (SpeechAnalyzer?, AsyncStream<AnalyzerInput>.Continuation?) in
            defer { self.analyzer = nil; self.continuation = nil }
            return (self.analyzer, self.continuation)
        }
        continuation?.finish()
        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
        resultsTask = nil
    }

    /// Reposiciona o cursor (ex.: o usuário rolou o texto à mão).
    func reset(to position: Int) {
        lock.withLock {
            aligner.reset(to: position)
            finalized = []
            volatile = []
        }
    }

    // MARK: Áudio

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let (continuation, target) = lock.withLock({ () -> (AsyncStream<AnalyzerInput>.Continuation, AVAudioFormat)? in
            guard let c = self.continuation, let t = self.targetFormat else { return nil }
            return (c, t)
        }) else { return }

        if buffer.format == target {
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, output.frameLength > 0 {
            continuation.yield(AnalyzerInput(buffer: output))
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard isRunning, let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        append(pcm)
    }

    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }

    // MARK: Resultados

    private func handle(text: String, isFinal: Bool) {
        let keys = ScriptTokenizer.keys(in: text)
        let (old, new, heard) = lock.withLock { () -> (Int, Int, String) in
            if isFinal {
                finalized.append(contentsOf: keys)
                finalized = Array(finalized.suffix(32))
                volatile = []
            } else {
                volatile = keys
            }
            let old = aligner.position
            let new = aligner.update(heard: finalized + volatile)
            return (old, new, (finalized.suffix(8) + volatile).joined(separator: " "))
        }
        DispatchQueue.main.async { [self] in
            onTranscript?(text, isFinal)
            onHeard?(heard)
            if new != old { onPosition?(new) }
        }
    }
}
