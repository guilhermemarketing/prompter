import CoreImage

/// Compõe a pessoa recortada sobre o fundo, no estilo escolhido.
/// Dilatações (bordas, contornos e sombra) são feitas na máscara de baixa resolução do Vision
/// e só depois ampliadas: o custo independe da resolução do vídeo.
enum ChromaStylizer {
    /// - Parameters:
    ///   - person: quadro já corrigido (luz e cor), em espaço linear.
    ///   - background: cor chroma ou o próprio quadro.
    ///   - lowMask: máscara da pessoa na resolução nativa do Vision (0…1).
    ///   - celStrength: força do cel-shading nas cores (0…1); contornos ficam sempre inteiros.
    ///   - stickerBorder/stickerOutline: espessuras do adesivo em px a 1080p.
    static func composite(person: CIImage, background: CIImage, lowMask: CIImage, extent: CGRect,
                          style: ChromaStyle, colors: StyleColors, colorSpace: CGColorSpace,
                          celStrength: Double = 1, stickerBorder: Double = 26, stickerOutline: Double = 7) -> CIImage {
        let unit = extent.height / 1080            // 1 px em 1080p
        let maskScale = extent.height / lowMask.extent.height

        switch style {
        case .plain:
            let mask = harden(upscale(lowMask, to: extent), gain: 1.6, bias: -0.3)
            return person.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: mask,
            ])

        case .sticker:
            let border = CGFloat(stickerBorder) * unit, line = CGFloat(stickerOutline) * unit
            let offset = CGPoint(x: 16 * unit, y: -18 * unit)
            let personMask = harden(upscale(lowMask, to: extent), gain: 3, bias: -1)
            let borderMask = harden(upscale(dilate(lowMask, by: border / maskScale), to: extent), gain: 3, bias: -1)
            let lineMask = harden(upscale(dilate(lowMask, by: (border + line) / maskScale), to: extent), gain: 3, bias: -1)
            let shadowMask = lineMask.transformed(by: CGAffineTransform(translationX: offset.x, y: offset.y))
                .cropped(to: extent)
            var result = background
            result = fill(colors.shadow, mask: shadowMask, over: result, extent: extent, colorSpace: colorSpace)
            result = fill(colors.outline, mask: lineMask, over: result, extent: extent, colorSpace: colorSpace)
            result = fill(colors.border, mask: borderMask, over: result, extent: extent, colorSpace: colorSpace)
            return person.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: result, kCIInputMaskImageKey: personMask,
            ])

        case .cel:
            let outline = 15 * unit, halo = 7 * unit
            let personMask = harden(upscale(lowMask, to: extent), gain: 3, bias: -1)
            let outlineMask = harden(upscale(dilate(lowMask, by: outline / maskScale), to: extent), gain: 3, bias: -1)
            let haloMask = harden(upscale(dilate(lowMask, by: (outline + halo) / maskScale), to: extent), gain: 3, bias: -1)
            let toon = toonShade(person, extent: extent, unit: unit, strength: celStrength,
                                 colors: colors, colorSpace: colorSpace)
            var result = background
            result = fill(colors.border, mask: haloMask, over: result, extent: extent, colorSpace: colorSpace)
            result = fill(colors.outline, mask: outlineMask, over: result, extent: extent, colorSpace: colorSpace)
            return toon.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: result, kCIInputMaskImageKey: personMask,
            ])
        }
    }

    /// Cores chapadas (posterização), sombras tingidas e linhas internas grossas.
    private static func toonShade(_ image: CIImage, extent: CGRect, unit: CGFloat, strength: Double,
                                  colors: StyleColors, colorSpace: CGColorSpace) -> CIImage {
        // Em espaço perceptual: as faixas da posterização ficam uniformes ao olho.
        let perceptual = image.applyingFilter("CILinearToSRGBToneCurve")
            .applyingFilter("CIMedianFilter")
        let flat = perceptual.applyingFilter("CIColorPosterize", parameters: ["inputLevels": 6])

        // Sombra: tons abaixo de ~40% recebem a cor de sombra (multiplicada).
        let luma = perceptual.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: -7 * 0.2126, y: -7 * 0.7152, z: -7 * 0.0722, w: 0),
            "inputGVector": CIVector(x: -7 * 0.2126, y: -7 * 0.7152, z: -7 * 0.0722, w: 0),
            "inputBVector": CIVector(x: -7 * 0.2126, y: -7 * 0.7152, z: -7 * 0.0722, w: 0),
            "inputBiasVector": CIVector(x: 0.4 * 7, y: 0.4 * 7, z: 0.4 * 7, w: 0),
        ]).applyingFilter("CIColorClamp")
        // Multiplicação em espaço linear, como a cor de sombra é interpretada.
        let flatLinear = flat.applyingFilter("CISRGBToneCurveToLinear")
        var result = flatLinear
        if colors.shadow.a > 0 {
            let tint = CIImage(color: CIColor(red: colors.shadow.r, green: colors.shadow.g, blue: colors.shadow.b,
                                              alpha: 1, colorSpace: colorSpace)
                               ?? CIColor(red: colors.shadow.r, green: colors.shadow.g, blue: colors.shadow.b))
                .cropped(to: extent)
            let multiplied = tint.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: flatLinear])
            result = multiplied.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: flatLinear, kCIInputMaskImageKey: scale(luma, by: colors.shadow.a),
            ])
        }

        // Força: mistura o original com o cartoon. As linhas vêm depois, sempre inteiras.
        let amount = min(max(strength, 0), 1)
        if amount < 0.999 {
            result = amount <= 0.001 ? image : image.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: result, kCIInputTimeKey: amount,
            ])
        }

        // Linhas internas: bordas da luminância em meia resolução, engrossadas e ampliadas.
        if colors.outline.a > 0 {
            let half = perceptual.clampedToExtent()
                .transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.2 * unit])
                .applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 6])
            let gray = half.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
                "inputGVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
                "inputBVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
            ])
            let lines = harden(gray, gain: 4, bias: -1.2)
                .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: max(1, 2 * unit)])
                .transformed(by: CGAffineTransform(scaleX: 2, y: 2))
                .cropped(to: extent)
            result = fill(colors.outline, mask: lines, over: result, extent: extent, colorSpace: colorSpace)
        }
        return result.cropped(to: extent)
    }

    // MARK: Máscaras

    static func upscale(_ mask: CIImage, to extent: CGRect) -> CIImage {
        mask.transformed(by: CGAffineTransform(scaleX: extent.width / mask.extent.width,
                                               y: extent.height / mask.extent.height))
            .cropped(to: extent)
    }

    /// Dilatação circular na resolução da máscara.
    /// Dilatação circular na resolução da máscara, seguida de um desfoque mínimo: sem ele,
    /// os degraus dos pixels grandes da máscara viram serrilhado ao ampliar.
    static func dilate(_ mask: CIImage, by radius: CGFloat) -> CIImage {
        guard radius > 0.3 else { return mask }
        return mask.clampedToExtent()
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: radius])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.2])
            .cropped(to: mask.extent)
    }

    /// Contraste na máscara: `valor × gain + bias`, limitado a 0…1.
    static func harden(_ mask: CIImage, gain: CGFloat, bias: CGFloat) -> CIImage {
        mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
        ]).applyingFilter("CIColorClamp")
    }

    private static func scale(_ mask: CIImage, by factor: Double) -> CIImage {
        guard factor < 1 else { return mask }
        let f = CGFloat(factor)
        return mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: f, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: f, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: f, w: 0),
        ])
    }

    /// Pinta `color` sobre `base` onde a máscara indica, respeitando a opacidade da cor.
    static func fill(_ color: RGBAColor, mask: CIImage, over base: CIImage,
                     extent: CGRect, colorSpace: CGColorSpace) -> CIImage {
        guard color.a > 0.001 else { return base }
        let ciColor = CIColor(red: color.r, green: color.g, blue: color.b, alpha: 1, colorSpace: colorSpace)
            ?? CIColor(red: color.r, green: color.g, blue: color.b)
        return CIImage(color: ciColor).cropped(to: extent).applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: base, kCIInputMaskImageKey: scale(mask, by: color.a),
        ])
    }
}
