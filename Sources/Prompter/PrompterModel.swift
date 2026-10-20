import SwiftUI

/// Estado do teleprompter. Dois modos:
/// - tempo: posição = base + velocidade × Δt (sem acumular erro);
/// - voz: o texto segue a última palavra reconhecida (`spokenCount`).
@MainActor
final class PrompterModel: ObservableObject {
    static let fontRange: ClosedRange<Double> = 20...120
    static let speedRange: ClosedRange<Int> = 1...20

    private let defaults = UserDefaults.standard

    @Published var script: String {
        didSet {
            guard script != oldValue else { return }
            defaults.set(script, forKey: "script")
            words = ScriptTokenizer.words(in: script)
            relayout()
            rewind()
        }
    }
    @Published var mirror: Bool { didSet { defaults.set(mirror, forKey: "mirror") } }
    @Published private(set) var fontSize: Double
    @Published private(set) var speed: Int
    @Published var isEditing = false
    @Published private(set) var isPlaying = false
    @Published private(set) var followVoice: Bool
    @Published private(set) var spokenCount = 0

    let layout = PrompterLayout()
    private(set) var words: [ScriptWord] = []

    /// Posição exibida (escrita pela view a cada quadro).
    var displayOffset: CGFloat = 0
    /// Muda quando o desenho do texto precisa ser refeito.
    private(set) var renderVersion = 0
    /// O usuário reposicionou o texto: a escuta deve recomeçar desta palavra.
    var onSeek: ((Int) -> Void)?

    private var base: CGFloat = 0
    private var anchor = Date()
    private var viewWidth: CGFloat = 0

    init() {
        let script = defaults.string(forKey: "script") ?? Self.welcome
        self.script = script
        mirror = defaults.object(forKey: "mirror") as? Bool ?? true
        fontSize = defaults.object(forKey: "fontSize") as? Double ?? 44
        speed = defaults.object(forKey: "speed") as? Int ?? 5
        followVoice = defaults.object(forKey: "followVoice") as? Bool ?? true
        words = ScriptTokenizer.words(in: script)
    }

    // MARK: Geometria

    var columnWidth: CGFloat { max(120, min(viewWidth - 112, CGFloat(fontSize) * 17)) }
    var lineStep: CGFloat { CGFloat(fontSize) * 1.2 }
    var maxOffset: CGFloat { max(0, layout.height - lineStep) }
    var pointsPerSecond: CGFloat { CGFloat(speed) * 6 * CGFloat(fontSize) / 40 }
    var estimatedDuration: TimeInterval { Double(maxOffset / pointsPerSecond) }

    func setViewWidth(_ width: CGFloat) {
        guard abs(width - viewWidth) > 0.5 else { return }
        viewWidth = width
        relayout()
    }

    private func relayout() {
        layout.update(text: script, fontSize: CGFloat(fontSize), width: columnWidth)
        renderVersion += 1
    }

    // MARK: Posição

    func offset(at date: Date) -> CGFloat {
        let elapsed = isPlaying ? CGFloat(date.timeIntervalSince(anchor)) * pointsPerSecond : 0
        return min(max(base + elapsed, 0), maxOffset)
    }

    /// Para onde a view deve ir neste instante.
    func target(at date: Date) -> CGFloat {
        guard followVoice else { return offset(at: date) }
        guard spokenCount < words.count else { return maxOffset }
        return min(layout.lineTop(forCharacter: words[spokenCount].range.location), maxOffset)
    }

    func wordIndex(atOffset y: CGFloat) -> Int {
        let start = layout.lineStart(atY: y + lineStep * 0.4)
        return words.firstIndex { $0.range.location >= start } ?? words.count
    }

    // MARK: Reprodução (controlada pelo AppState)

    func play() {
        guard !isPlaying, !script.isEmpty else { return }
        if followVoice {
            if spokenCount >= words.count { setSpoken(0) }
        } else {
            base = displayOffset >= maxOffset - 1 ? 0 : displayOffset
            anchor = Date()
        }
        isPlaying = true
    }

    func pause() {
        guard isPlaying else { return }
        if !followVoice { base = offset(at: Date()) }
        isPlaying = false
    }

    func setFollowVoice(_ on: Bool) {
        guard on != followVoice else { return }
        followVoice = on
        defaults.set(on, forKey: "followVoice")
        if on {
            setSpoken(wordIndex(atOffset: displayOffset))
        } else {
            base = displayOffset
            anchor = Date()
            layout.setSpoken(upTo: 0)
            renderVersion += 1
        }
    }

    /// Palavras confirmadas pela voz.
    func setSpoken(_ count: Int) {
        let count = min(max(count, 0), words.count)
        spokenCount = count
        if followVoice {
            layout.setSpoken(upTo: count > 0 ? NSMaxRange(words[count - 1].range) : 0)
            renderVersion += 1
        }
    }

    func nudge(_ delta: CGFloat) {
        let y = min(max(displayOffset + delta, 0), maxOffset)
        if followVoice {
            displayOffset = y
            let index = wordIndex(atOffset: y)
            if index != spokenCount {
                setSpoken(index)
                onSeek?(index)
            }
        } else {
            base = y
            anchor = Date()
            displayOffset = y
        }
    }

    func rewind() {
        base = 0
        anchor = Date()
        displayOffset = 0
        setSpoken(0)
        onSeek?(0)
    }

    func adjustSpeed(_ delta: Int) {
        let next = min(max(speed + delta, Self.speedRange.lowerBound), Self.speedRange.upperBound)
        guard next != speed else { return }
        base = offset(at: Date())
        anchor = Date()
        speed = next
        defaults.set(speed, forKey: "speed")
    }

    func adjustFont(_ delta: Double) {
        let next = min(max(fontSize + delta, Self.fontRange.lowerBound), Self.fontRange.upperBound)
        guard next != fontSize else { return }
        // Mantém o mesmo trecho na linha de leitura após o reflow.
        let anchorWord = wordIndex(atOffset: displayOffset)
        fontSize = next
        defaults.set(fontSize, forKey: "fontSize")
        relayout()
        let y = anchorWord < words.count ? min(layout.lineTop(forCharacter: words[anchorWord].range.location), maxOffset) : maxOffset
        displayOffset = y
        base = y
        anchor = Date()
    }

    static let welcome = """
    Bem-vindo ao Prompter.

    Escreva ou cole seu roteiro com ⌘E. Também dá para arrastar um arquivo de texto para a janela.

    Com o modo voz ligado, o texto acompanha a sua fala: as palavras que você já disse ficam apagadas e a próxima linha sobe sozinha. Pode improvisar ou pular um trecho, ele se reencontra.

    No modo tempo, Espaço inicia e pausa a rolagem, e as setas ↑ e ↓ ajustam a velocidade. Em qualquer modo, role no trackpad para reposicionar.

    ⌘R grava. A contagem aparece aqui em cima, perto da câmera. Os vídeos vão para Filmes › Prompter.

    Mantenha o olhar nesta linha. Ela está o mais perto possível da lente.
    """
}
