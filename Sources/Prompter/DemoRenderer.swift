@preconcurrency import AVFoundation
import AppKit

/// Modo demonstração (uso de desenvolvimento): `--demo-render ROTEIRO.txt VOZ.(aiff|wav|m4a) PASTA`.
/// Toca a voz no reconhecimento em tempo real, como se viesse do microfone, registra quando o
/// texto avança e depois desenha a rolagem quadro a quadro em PNGs (para gerar o GIF do README).
/// Não abre câmera nem microfone e não toca nas preferências do usuário.
@MainActor
enum DemoRenderer {
    static var isRequested: Bool { arguments != nil }

    private static var arguments: (script: URL, audio: URL, output: URL)? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--demo-render"), args.count > i + 3 else { return nil }
        return (URL(fileURLWithPath: args[i + 1]), URL(fileURLWithPath: args[i + 2]),
                URL(fileURLWithPath: args[i + 3], isDirectory: true))
    }

    private struct Event { let time: Double; let position: Int?; let caption: String? }

    static let size = CGSize(width: 960, height: 540)
    static let scale: CGFloat = 1
    static let fps = 15.0

    static func run() {
        guard let (scriptURL, audioURL, output) = arguments else { return }
        Task { @MainActor in
            // Sem App Nap: em segundo plano o macOS desacelera o laço dos quadros.
            let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Prompter demo")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            do {
                try await render(scriptURL: scriptURL, audioURL: audioURL, output: output)
                print("demo: pronto em \(output.path)")
            } catch {
                print("demo: falhou: \(error)")
            }
            NSApp.terminate(nil)
        }
    }

    private static func render(scriptURL: URL, audioURL: URL, output: URL) async throws {
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let defaults = UserDefaults(suiteName: "marketing.gui.prompter.demo")!
        defaults.removePersistentDomain(forName: "marketing.gui.prompter.demo")
        defaults.set(52.0, forKey: "fontSize")
        defaults.set(true, forKey: "followVoice")
        let model = PrompterModel(defaults: defaults)
        model.script = script

        // 1. Voz em tempo real → linha do tempo de posições e legendas.
        var events: [Event] = []
        var finalText = "", liveText = ""
        var start = CACurrentMediaTime()
        let follower = SpeechFollower()
        follower.onPosition = { position in
            MainActor.assumeIsolated { events.append(Event(time: CACurrentMediaTime() - start, position: position, caption: nil)) }
        }
        follower.onTranscript = { text, isFinal in
            MainActor.assumeIsolated {
                if isFinal { finalText += " " + text; liveText = "" } else { liveText = text }
                let words = (finalText + " " + liveText).split(whereSeparator: \.isWhitespace)
                events.append(Event(time: CACurrentMediaTime() - start, position: nil,
                                    caption: words.suffix(7).joined(separator: " ")))
            }
        }
        try await follower.start(script: script, from: 0)

        let file = try AVAudioFile(forReading: audioURL)
        let format = file.processingFormat
        let chunk = AVAudioFrameCount(format.sampleRate / 10)
        let begin = CACurrentMediaTime()
        start = begin
        var fed = 0.0
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
            try file.read(into: buffer, frameCount: chunk)
            follower.append(buffer)
            fed += Double(buffer.frameLength) / format.sampleRate
            let wait = fed - (CACurrentMediaTime() - begin)
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
        }
        let duration = fed + 1.5
        if let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate * 1.5)) {
            silence.frameLength = silence.frameCapacity
            follower.append(silence)
        }
        try await Task.sleep(for: .seconds(1.5))
        await follower.stop()
        print("demo: \(events.filter { $0.position != nil }.count) avanços, posição final \(events.compactMap(\.position).last ?? 0)/\(model.words.count)")

        // 2. Quadros: o mesmo PrompterTextView do app, avançado em passos fixos.
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        model.rewind()
        let view = PrompterTextView(model: model, reading: ReadingLine(fraction: 0.36, minimum: 64))
        view.frame = CGRect(origin: .zero, size: CGSize(width: size.width, height: size.height - 120))
        view.layout()
        var next = 0, caption = ""
        let total = Int((duration + 1) * fps)
        for frame in 0..<total {
            let t = Double(frame) / fps
            while next < events.count, events[next].time <= t {
                if let position = events[next].position { model.setSpoken(position) }
                if let text = events[next].caption { caption = text }
                next += 1
            }
            view.step(1 / fps)
            let image = draw(view: view, caption: caption, listening: t < fed + 0.3)
            try write(image, to: output.appendingPathComponent(String(format: "frame_%05d.png", frame)))
        }
    }

    private static func draw(view: PrompterTextView, caption: String, listening: Bool) -> CGImage {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.scaleBy(x: scale, y: scale)
        // Coordenadas com origem no topo, como a view (isFlipped).
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)

        let colors = [NSColor(srgbRed: 0.06, green: 0.06, blue: 0.08, alpha: 1).cgColor,
                      NSColor(srgbRed: 0.12, green: 0.12, blue: 0.16, alpha: 1).cgColor]
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])

        context.saveGState()
        context.translateBy(x: 0, y: 24)
        view.layer?.render(in: context)
        context.restoreGState()

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let bar = CGRect(x: 0, y: size.height - 96, width: size.width, height: 96)
        NSColor.black.withAlphaComponent(0.55).setFill()
        bar.fill()
        let dot = CGRect(x: 40, y: bar.minY + 55, width: 18, height: 18)
        (listening ? NSColor.systemRed : NSColor.systemGray).setFill()
        NSBezierPath(ovalIn: dot).fill()
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17, weight: .semibold),
                                                    .foregroundColor: NSColor.white.withAlphaComponent(0.6)]
        NSAttributedString(string: L("VOCÊ FALA", "YOU SAY"), attributes: label).draw(at: CGPoint(x: 72, y: bar.minY + 18))
        let spoken: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 26, weight: .medium),
                                                     .foregroundColor: NSColor.white]
        NSAttributedString(string: caption.isEmpty ? "…" : "“\(caption)”", attributes: spoken)
            .draw(at: CGPoint(x: 72, y: bar.minY + 44))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }

    private static func write(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try data.write(to: url)
    }
}
