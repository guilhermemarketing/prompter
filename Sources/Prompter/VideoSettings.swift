import CoreGraphics
import CoreImage
import Foundation

enum AspectRatio: String, CaseIterable, Codable, Identifiable {
    case landscape = "16:9"
    case portrait = "9:16"
    case feed = "4:5"

    var id: String { rawValue }

    /// Largura ÷ altura.
    var value: CGFloat {
        switch self {
        case .landscape: 16.0 / 9
        case .portrait: 9.0 / 16
        case .feed: 4.0 / 5
        }
    }

    var next: AspectRatio {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

enum Resolution: String, CaseIterable, Codable, Identifiable {
    case hd = "HD"
    case qhd = "2K"
    case uhd = "4K"

    var id: String { rawValue }
    /// Lado curto do vídeo (1080, 1440, 2160).
    var shortSide: Int {
        switch self {
        case .hd: 1080
        case .qhd: 1440
        case .uhd: 2160
        }
    }
    /// Lado longo equivalente em 16:9 (1920, 2560, 3840).
    var longSide: Int { shortSide * 16 / 9 }
}

enum ChromaBackground: String, CaseIterable, Codable, Identifiable {
    case none, green, blue, red

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "Sem fundo"
        case .green: "Verde"
        case .blue: "Azul"
        case .red: "Vermelho"
        }
    }

    /// Cores de chroma key de referência (verde e azul de estúdio).
    var rgb: (r: CGFloat, g: CGFloat, b: CGFloat)? {
        switch self {
        case .none: nil
        case .green: (0, 177 / 255, 64 / 255)
        case .blue: (0, 71 / 255, 187 / 255)
        case .red: (220 / 255, 20 / 255, 30 / 255)
        }
    }
}

/// Estilo aplicado à pessoa recortada (funciona com ou sem fundo chroma).
enum ChromaStyle: String, CaseIterable, Codable, Identifiable {
    case plain, cel, sticker

    var id: String { rawValue }
    var label: String {
        switch self {
        case .plain: "Liso"
        case .cel: "Cel-shading"
        case .sticker: "Adesivo"
        }
    }
}

/// Cor sRGB com opacidade; opacidade 0 desliga o elemento.
struct RGBAColor: Codable, Equatable, Hashable {
    var r: Double, g: Double, b: Double, a: Double = 1

    static let black = RGBAColor(r: 0, g: 0, b: 0)
    static let white = RGBAColor(r: 1, g: 1, b: 1)
}

/// Cores de um estilo: contorno, borda e sombra.
struct StyleColors: Codable, Equatable, Hashable {
    var outline: RGBAColor
    var border: RGBAColor
    var shadow: RGBAColor

    /// Cel-shading: linhas quase pretas, sem borda externa, sombras em violeta escuro.
    static let celDefault = StyleColors(outline: RGBAColor(r: 0.06, g: 0.06, b: 0.08),
                                        border: RGBAColor(r: 1, g: 1, b: 1, a: 0),
                                        shadow: RGBAColor(r: 0.2, g: 0.16, b: 0.42, a: 0.55))
    /// Adesivo: borda branca, contorno preto, sombra dura escura.
    static let stickerDefault = StyleColors(outline: .black, border: .white,
                                            shadow: RGBAColor(r: 0, g: 0, b: 0, a: 0.75))
}

/// Ajustes finos de cor. Faixas da interface: −1…1, exceto nitidez (0…1) e matiz (−180…180°).
struct ImageAdjustments: Codable, Equatable, Hashable {
    var contrast: Double = 0
    var brightness: Double = 0
    var sharpness: Double = 0
    var hue: Double = 0
    var blacks: Double = 0
    var whites: Double = 0
    var shadows: Double = 0

    static let neutral = ImageAdjustments()
    var isNeutral: Bool { self == .neutral }
    var hasToneCurve: Bool { blacks != 0 || whites != 0 || shadows != 0 }

    init(contrast: Double = 0, brightness: Double = 0, sharpness: Double = 0, hue: Double = 0,
         blacks: Double = 0, whites: Double = 0, shadows: Double = 0) {
        self.contrast = contrast
        self.brightness = brightness
        self.sharpness = sharpness
        self.hue = hue
        self.blacks = blacks
        self.whites = whites
        self.shadows = shadows
    }

    /// Tolera presets salvos antes de existirem pretos, brancos e sombras.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contrast = (try? c.decodeIfPresent(Double.self, forKey: .contrast)) ?? 0
        brightness = (try? c.decodeIfPresent(Double.self, forKey: .brightness)) ?? 0
        sharpness = (try? c.decodeIfPresent(Double.self, forKey: .sharpness)) ?? 0
        hue = (try? c.decodeIfPresent(Double.self, forKey: .hue)) ?? 0
        blacks = (try? c.decodeIfPresent(Double.self, forKey: .blacks)) ?? 0
        whites = (try? c.decodeIfPresent(Double.self, forKey: .whites)) ?? 0
        shadows = (try? c.decodeIfPresent(Double.self, forKey: .shadows)) ?? 0
    }
}

enum QualityPreset: String, CaseIterable, Codable, Identifiable {
    case economy, recommended
    case superiorHEVC
    /// ProRes; o valor bruto "superior" mantém compatibilidade com ajustes já salvos.
    case superior
    case custom

    var id: String { rawValue }
    var label: String {
        switch self {
        case .economy: "Econômica"
        case .recommended: "Recomendada"
        case .superiorHEVC: "Superior HEVC"
        case .superior: "Superior ProRes"
        case .custom: "Personalizado"
        }
    }
    var detail: String {
        switch self {
        case .economy: "Web, arquivos leves"
        case .recommended: "Reels e redes sociais"
        case .superiorHEVC: "HEVC + AAC visualmente sem perdas: máxima qualidade para redes e YouTube"
        case .superior: "ProRes 422 HQ + PCM 24-bit: para edição profissional"
        case .custom: "Taxa escolhida por você"
        }
    }
}

struct VideoSettings: Codable, Equatable {
    var aspect: AspectRatio = .landscape
    var resolution: Resolution = .hd
    var frameRate: Int = 30
    var background: ChromaBackground = .none
    var autoLight = false
    var adjustments = ImageAdjustments()
    var quality: QualityPreset = .recommended
    var customMbps: Double = 50
    var chromaStyle: ChromaStyle = .plain
    var celColors: StyleColors = .celDefault
    var stickerColors: StyleColors = .stickerDefault
    /// Força do cel-shading na imagem (0…1); contornos ficam sempre inteiros.
    var celStrength: Double = 1
    /// Espessuras do adesivo em px a 1080p (escalam com a resolução).
    var stickerBorderWidth: Double = 26
    var stickerOutlineWidth: Double = 7
    /// LUT ativo (id da `LUTLibrary`) e intensidade 0…1.
    var lutID: String? = nil
    var lutIntensity: Double = 1

    static let stickerBorderRange: ClosedRange<Double> = 0...80
    static let stickerOutlineRange: ClosedRange<Double> = 0...30

    static let frameRates = [24, 30, 60]
    /// Teto da especificação DCI para cinema digital.
    static let cinemaCeilingMbps: Double = 250

    init() {}

    /// Decodifica tolerando campos ausentes (ajustes salvos por versões anteriores).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = VideoSettings()
        aspect = (try? c.decodeIfPresent(AspectRatio.self, forKey: .aspect)) ?? d.aspect
        resolution = (try? c.decodeIfPresent(Resolution.self, forKey: .resolution)) ?? d.resolution
        frameRate = (try? c.decodeIfPresent(Int.self, forKey: .frameRate)) ?? d.frameRate
        background = (try? c.decodeIfPresent(ChromaBackground.self, forKey: .background)) ?? d.background
        autoLight = (try? c.decodeIfPresent(Bool.self, forKey: .autoLight)) ?? d.autoLight
        adjustments = (try? c.decodeIfPresent(ImageAdjustments.self, forKey: .adjustments)) ?? d.adjustments
        quality = (try? c.decodeIfPresent(QualityPreset.self, forKey: .quality)) ?? d.quality
        customMbps = (try? c.decodeIfPresent(Double.self, forKey: .customMbps)) ?? d.customMbps
        chromaStyle = (try? c.decodeIfPresent(ChromaStyle.self, forKey: .chromaStyle)) ?? d.chromaStyle
        celColors = (try? c.decodeIfPresent(StyleColors.self, forKey: .celColors)) ?? d.celColors
        stickerColors = (try? c.decodeIfPresent(StyleColors.self, forKey: .stickerColors)) ?? d.stickerColors
        celStrength = (try? c.decodeIfPresent(Double.self, forKey: .celStrength)) ?? d.celStrength
        stickerBorderWidth = (try? c.decodeIfPresent(Double.self, forKey: .stickerBorderWidth)) ?? d.stickerBorderWidth
        stickerOutlineWidth = (try? c.decodeIfPresent(Double.self, forKey: .stickerOutlineWidth)) ?? d.stickerOutlineWidth
        lutID = (try? c.decodeIfPresent(String.self, forKey: .lutID)) ?? d.lutID
        lutIntensity = (try? c.decodeIfPresent(Double.self, forKey: .lutIntensity)) ?? d.lutIntensity
    }

    /// Dimensões exatas do arquivo final (sempre pares).
    var outputSize: CGSize {
        let short = resolution.shortSide
        switch aspect {
        case .landscape: return CGSize(width: resolution.longSide, height: short)
        case .portrait: return CGSize(width: short, height: resolution.longSide)
        case .feed: return CGSize(width: short, height: short * 5 / 4)
        }
    }

    var usesProRes: Bool { quality == .superior }
    /// Precisa da máscara de pessoa (fundo chroma ou estilo de recorte).
    var needsPersonMask: Bool { background != .none || chromaStyle != .plain }
    var styleColors: StyleColors { chromaStyle == .sticker ? stickerColors : celColors }

    /// Taxa de vídeo em Mbps. Econômica e Recomendada partem de valores HEVC a 30 fps em 16:9
    /// e escalam pela área do quadro e pelo fps; Superior é a taxa nominal do ProRes 422 HQ.
    var videoMbps: Double {
        let size = outputSize
        let fullFrame = Double(resolution.longSide * resolution.shortSide)
        let area = Double(size.width * size.height) / fullFrame
        let motion = pow(Double(frameRate) / 30, 0.75)
        switch quality {
        case .economy:
            let base: Double = switch resolution { case .hd: 5; case .qhd: 8; case .uhd: 16 }
            return (base * area * motion * 10).rounded() / 10
        case .recommended:
            let base: Double = switch resolution { case .hd: 16; case .qhd: 26; case .uhd: 50 }
            return (base * area * motion).rounded()
        case .superiorHEVC:
            // ~0,8 bit/pixel em 1080p30: margem para gradientes e texturas sem artefatos visíveis.
            let base: Double = switch resolution { case .hd: 50; case .qhd: 80; case .uhd: 150 }
            return (base * area * motion).rounded()
        case .superior:
            return (220 * Double(size.width * size.height) / (1920 * 1080) * Double(frameRate) / 29.97).rounded()
        case .custom:
            return min(max(customMbps, 1), Self.cinemaCeilingMbps)
        }
    }

    var bitrate: Int { Int(videoMbps * 1_000_000) }

    /// Espaço em disco aproximado por minuto (vídeo + áudio).
    var megabytesPerMinute: Double {
        let audioMbps = usesProRes ? 2.3 : (quality == .superiorHEVC ? 0.32 : 0.2)
        return (videoMbps + audioMbps) * 60 / 8
    }

    /// Maior retângulo centrado com a proporção pedida.
    static func centerCrop(_ rect: CGRect, aspect: CGFloat) -> CGRect {
        var crop = rect
        if rect.width / rect.height > aspect {
            crop.size.width = (rect.height * aspect).rounded(.down)
            crop.origin.x = rect.minX + ((rect.width - crop.width) / 2).rounded(.down)
        } else {
            crop.size.height = (rect.width / aspect).rounded(.down)
            crop.origin.y = rect.minY + ((rect.height - crop.height) / 2).rounded(.down)
        }
        return crop
    }
}

/// Preset de cor: os de fábrica vêm prontos; os do usuário ficam salvos.
struct ColorPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var adjustments: ImageAdjustments
    var builtIn = false

    static let builtIns: [ColorPreset] = [
        .init(name: "Natural", adjustments: .neutral, builtIn: true),
        .init(name: "Nítido", adjustments: .init(contrast: 0.1, sharpness: 0.5, blacks: -0.1), builtIn: true),
        .init(name: "Contraste", adjustments: .init(contrast: 0.3, brightness: -0.04, sharpness: 0.25, blacks: -0.25, whites: 0.2), builtIn: true),
        .init(name: "Suave", adjustments: .init(contrast: -0.15, brightness: 0.05, shadows: 0.3), builtIn: true),
        .init(name: "Luminoso", adjustments: .init(contrast: 0.05, brightness: 0.12, sharpness: 0.2, whites: 0.25, shadows: 0.2), builtIn: true),
        .init(name: "Cinema", adjustments: .init(contrast: 0.22, brightness: -0.08, sharpness: 0.15, hue: -3, blacks: 0.25, whites: -0.15), builtIn: true),
    ]
}
