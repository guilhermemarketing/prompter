import AppKit
import SwiftUI

/// Onde fica a linha de leitura: fração da altura, com um mínimo em pontos.
struct ReadingLine: Equatable {
    var fraction: CGFloat = 0.3
    var minimum: CGFloat = 64

    static let standard = ReadingLine()
    /// Colada no topo, logo abaixo da câmera.
    static let top = ReadingLine(fraction: 0.12, minimum: 18)
}

struct PrompterText: NSViewRepresentable {
    let model: PrompterModel
    var reading: ReadingLine = .standard

    func makeNSView(context: Context) -> PrompterTextView { PrompterTextView(model: model, reading: reading) }
    func updateNSView(_ view: PrompterTextView, context: Context) {}
}

/// Desenha um bloco do roteiro (~3 telas) numa camada e só move a camada a cada quadro.
/// O bloco é redesenhado quando a rolagem se aproxima da borda ou quando o texto muda
/// (karaoke, fonte, largura).
final class PrompterTextView: NSView {
    private let model: PrompterModel
    private let textLayer = CALayer()
    private let marker = CAShapeLayer()
    private let fade = CAGradientLayer()
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var renderedVersion = -1
    private var chunk = CGRect.zero          // trecho desenhado, em coordenadas do texto
    private var chunkScale: CGFloat = 0

    private let reading: ReadingLine

    init(model: PrompterModel, reading: ReadingLine = .standard) {
        self.model = model
        self.reading = reading
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(textLayer)
        layer?.addSublayer(marker)
        layer?.mask = fade
        textLayer.anchorPoint = .zero
        textLayer.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull()]
        marker.fillColor = NSColor.white.withAlphaComponent(0.45).cgColor
        marker.actions = ["position": NSNull(), "path": NSNull()]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var readingY: CGFloat { max(bounds.height * reading.fraction, reading.minimum) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    override func layout() {
        super.layout()
        MainActor.assumeIsolated { model.setViewWidth(bounds.width) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = bounds
        let reading = readingY / max(bounds.height, 1)
        fade.colors = [0.0, 0.32, 1, 1, 0].map { NSColor.black.withAlphaComponent($0).cgColor }
        fade.locations = [0, reading * 0.55, reading, 0.74, 1].map { NSNumber(value: Double($0)) }
        CATransaction.commit()
        renderedVersion = -1
        update(dt: 0)
    }

    @objc private func tick(_ link: CADisplayLink) {
        let dt = lastTimestamp == 0 ? 0 : link.targetTimestamp - lastTimestamp
        lastTimestamp = link.targetTimestamp
        update(dt: min(dt, 0.1))
    }

    private func update(dt: CFTimeInterval) {
        MainActor.assumeIsolated {
            let model = self.model
            let target = model.target(at: Date())
            var y = model.displayOffset
            if model.followVoice {
                // Aproximação suave (exponencial) da linha da palavra atual.
                y += (target - y) * CGFloat(1 - exp(-dt * 7))
                if abs(target - y) < 0.3 { y = target }
            } else {
                y = target
            }
            model.displayOffset = y
            place(offset: y, model: model)
        }
    }

    @MainActor
    private func place(offset: CGFloat, model: PrompterModel) {
        let scale = window?.backingScaleFactor ?? 2
        let column = model.columnWidth
        let originX = ((bounds.width - column) / 2).rounded()
        let visible = CGRect(x: 0, y: offset - readingY, width: column, height: bounds.height)

        let needsRender = renderedVersion != model.renderVersion || chunkScale != scale
            || chunk.width != column || !chunk.contains(visible.insetBy(dx: 0, dy: 1))
        if needsRender {
            renderChunk(around: visible, column: column, scale: scale, model: model)
        }

        let top = ((readingY - offset + chunk.minY) * scale).rounded() / scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.frame = CGRect(x: originX, y: top, width: chunk.width, height: chunk.height)
        let size = CGFloat(model.fontSize) * 0.26
        let center = CGPoint(x: originX - CGFloat(model.fontSize) * 0.55, y: readingY + CGFloat(model.fontSize) * 0.62)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: center.x - size * 0.5, y: center.y - size * 0.6))
        path.addLine(to: CGPoint(x: center.x + size * 0.5, y: center.y))
        path.addLine(to: CGPoint(x: center.x - size * 0.5, y: center.y + size * 0.6))
        path.closeSubpath()
        marker.path = path
        CATransaction.commit()
    }

    @MainActor
    private func renderChunk(around visible: CGRect, column: CGFloat, scale: CGFloat, model: PrompterModel) {
        let height = max(bounds.height * 3, 600)
        let top = max(0, visible.minY - bounds.height)
        chunk = CGRect(x: 0, y: top, width: column, height: height)
        chunkScale = scale
        renderedVersion = model.renderVersion

        let pixelWidth = Int(ceil(column * scale)), pixelHeight = Int(ceil(height * scale))
        guard pixelWidth > 0, pixelHeight > 0,
              let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        model.layout.draw(chunk, at: CGPoint(x: 0, y: -top))
        NSGraphicsContext.restoreGraphicsState()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textLayer.contents = context.makeImage()
        textLayer.contentsScale = scale
        CATransaction.commit()
    }
}
