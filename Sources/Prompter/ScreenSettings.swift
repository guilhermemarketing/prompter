import CoreGraphics
import Foundation

/// O que o Prompter grava: só a câmera ou a tela com a câmera em destaque.
enum CaptureMode: String, Codable, CaseIterable, Identifiable {
    case camera, screen
    var id: String { rawValue }
    var label: String { self == .camera ? "Câmera" : "Tela" }
}

/// Fonte da gravação de tela.
enum ScreenSource: Codable, Equatable, Hashable {
    case display(id: UInt32)
    case window(id: UInt32, title: String)
    /// Área de uma tela, em pontos, com origem no canto superior esquerdo da tela.
    case area(display: UInt32, x: Double, y: Double, width: Double, height: Double)

    var displayID: UInt32? {
        switch self {
        case .display(let id): id
        case .area(let id, _, _, _, _): id
        case .window: nil
        }
    }
}

enum BubbleShape: String, Codable, CaseIterable, Identifiable {
    case circle, square, rectangle
    var id: String { rawValue }
    var label: String {
        switch self {
        case .circle: "Círculo"
        case .square: "Quadrado"
        case .rectangle: "Retângulo"
        }
    }
    var symbol: String {
        switch self {
        case .circle: "circle"
        case .square: "square"
        case .rectangle: "rectangle"
        }
    }
    /// Largura ÷ altura do recorte da câmera.
    var aspect: CGFloat { self == .rectangle ? 16.0 / 9 : 1 }
}

/// Câmera sobre a tela, em estilo neobrutalista: borda escura grossa e sombra dura.
struct BubbleSettings: Codable, Equatable {
    var visible = true
    var shape: BubbleShape = .circle
    /// Centro normalizado (0…1), origem no canto superior esquerdo do vídeo final.
    var centerX: Double = 0.84
    var centerY: Double = 0.76
    /// Altura relativa à altura do vídeo final.
    var size: Double = 0.28
    var borderColor = RGBAColor(r: 0.07, g: 0.07, b: 0.08)
    var shadowColor = RGBAColor(r: 0, g: 0, b: 0)

    static let sizeRange: ClosedRange<Double> = 0.12...0.6

    /// Retângulo da câmera no vídeo final (coordenadas com origem no topo).
    func frame(in output: CGSize) -> CGRect {
        let height = CGFloat(size) * output.height
        let width = height * shape.aspect
        return CGRect(x: CGFloat(centerX) * output.width - width / 2,
                      y: CGFloat(centerY) * output.height - height / 2, width: width, height: height)
    }

    /// Mantém a câmera inteira dentro do quadro.
    mutating func clamp(in output: CGSize) {
        let f = frame(in: output)
        let halfW = Double(f.width / 2 / output.width), halfH = Double(f.height / 2 / output.height)
        centerX = min(max(centerX, halfW), 1 - halfW)
        centerY = min(max(centerY, halfH), 1 - halfH)
    }
}

/// Arquivos que uma gravação de tela gera. Cada um usa um codificador de vídeo próprio.
enum ScreenOutput: String, Codable, CaseIterable, Identifiable {
    case composite, screen, camera
    var id: String { rawValue }
    var label: String {
        switch self {
        case .composite: "Composição (tela + câmera)"
        case .screen: "Só a tela"
        case .camera: "Só a câmera"
        }
    }
    var fileName: String {
        switch self {
        case .composite: "composição.mov"
        case .screen: "tela.mov"
        case .camera: "câmera.mov"
        }
    }
}

struct ScreenSettings: Codable, Equatable {
    var mode: CaptureMode = .camera
    var source: ScreenSource?
    var showsCursor = true
    /// Arquivos gerados (pelo menos um). O padrão, só a composição, é o mais leve.
    var outputs: Set<ScreenOutput> = [.composite]
    var bubble = BubbleSettings()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ScreenSettings()
        mode = (try? c.decodeIfPresent(CaptureMode.self, forKey: .mode)) ?? d.mode
        source = (try? c.decodeIfPresent(ScreenSource.self, forKey: .source)) ?? d.source
        showsCursor = (try? c.decodeIfPresent(Bool.self, forKey: .showsCursor)) ?? d.showsCursor
        outputs = (try? c.decodeIfPresent(Set<ScreenOutput>.self, forKey: .outputs)).flatMap { $0.isEmpty ? nil : $0 } ?? d.outputs
        bubble = (try? c.decodeIfPresent(BubbleSettings.self, forKey: .bubble)) ?? d.bubble
    }
}
