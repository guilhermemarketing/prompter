import AppKit

/// Layout do roteiro com TextKit: a mesma diagramação serve para desenhar o texto e para
/// saber em que linha está cada palavra (rolagem guiada pela voz).
@MainActor
final class PrompterLayout {
    private let storage = NSTextStorage()
    private let manager = NSLayoutManager()
    private let container = NSTextContainer(size: .zero)
    private(set) var height: CGFloat = 0
    private(set) var width: CGFloat = 0
    private var spokenLocation = 0

    static let dimColor = NSColor.white.withAlphaComponent(0.36)

    init() {
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
    }

    func update(text: String, fontSize: CGFloat, width: CGFloat) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = fontSize * 0.2
        storage.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]))
        self.width = max(width, 60)
        container.size = CGSize(width: self.width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        height = ceil(manager.usedRect(for: container).height)
        let spoken = spokenLocation
        spokenLocation = 0
        setSpoken(upTo: spoken)
    }

    /// Escurece o texto já falado (cor não altera a diagramação).
    func setSpoken(upTo location: Int) {
        let location = min(max(location, 0), storage.length)
        guard location != spokenLocation else { return }
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: NSColor.white, range: NSRange(location: 0, length: storage.length))
        if location > 0 {
            storage.addAttribute(.foregroundColor, value: Self.dimColor, range: NSRange(location: 0, length: location))
        }
        storage.endEditing()
        spokenLocation = location
    }

    /// Topo da linha que contém o caractere.
    func lineTop(forCharacter index: Int) -> CGFloat {
        guard storage.length > 0 else { return 0 }
        let glyph = manager.glyphIndexForCharacter(at: min(max(index, 0), storage.length - 1))
        return manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
    }

    /// Primeiro caractere da linha na altura `y`.
    func lineStart(atY y: CGFloat) -> Int {
        guard storage.length > 0 else { return 0 }
        let glyph = manager.glyphIndex(for: CGPoint(x: 1, y: max(0, y)), in: container)
        var range = NSRange()
        manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range)
        return manager.characterIndexForGlyph(at: range.location)
    }

    /// Desenha o trecho `rect` (coordenadas do texto) com a origem do texto em `origin`.
    func draw(_ rect: CGRect, at origin: CGPoint) {
        let glyphs = manager.glyphRange(forBoundingRect: rect, in: container)
        manager.drawGlyphs(forGlyphRange: glyphs, at: origin)
    }
}
