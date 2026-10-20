import Foundation

/// Tabela 3D pronta para o Core Image (RGBA Float32, R varia mais rápido).
struct LUTCube {
    let dimension: Int
    let data: Data
}

struct LUTInfo: Codable, Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    /// Arquivo copiado para Application Support; nil nos LUTs de fábrica.
    let fileName: String?
    var builtIn: Bool { fileName == nil }
}

/// LUTs de fábrica e importados (.cube). `cube(for:)` é thread-safe e roda na fila de captura;
/// importar e remover acontecem na main.
final class LUTLibrary: ObservableObject {
    static let shared = LUTLibrary()

    static let builtIns: [LUTInfo] = [
        LUTInfo(id: "builtin.vibrant", name: L("Vibrante", "Vibrant"), fileName: nil),
        LUTInfo(id: "builtin.cinema", name: "Cinema", fileName: nil),
        LUTInfo(id: "builtin.noir", name: "Noir", fileName: nil),
        LUTInfo(id: "builtin.pop", name: "Pop", fileName: nil),
        LUTInfo(id: "builtin.midsommar", name: "Midsommar", fileName: nil),
    ]

    @Published private(set) var imported: [LUTInfo] = []
    var all: [LUTInfo] { Self.builtIns + imported }

    private let lock = NSLock()
    private var cache: [String: LUTCube] = [:]
    private var known: [String: LUTInfo] = [:]
    private let defaultsKey = "importedLUTs"

    static var folder: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Prompter/LUTs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([LUTInfo].self, from: data) {
            imported = saved.filter { FileManager.default.fileExists(atPath: Self.folder.appendingPathComponent($0.fileName ?? "").path) }
        }
        lock.withLock { for info in all { known[info.id] = info } }
    }

    func name(for id: String?) -> String? {
        guard let id else { return nil }
        return lock.withLock { known[id]?.name }
    }

    /// Tabela pronta para o filtro; gerada (fábrica) ou lida do disco (importado) uma única vez.
    func cube(for id: String) -> LUTCube? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[id] { return cached }
        guard let info = known[id] else { return nil }
        let cube: LUTCube?
        if info.builtIn {
            cube = BuiltInLUTs.make(id)
        } else if let file = info.fileName,
                  let text = try? String(contentsOf: Self.folder.appendingPathComponent(file), encoding: .utf8) {
            cube = try? CubeParser.parse(text).cube
        } else {
            cube = nil
        }
        if let cube { cache[id] = cube }
        return cube
    }

    /// Valida, copia para a biblioteca e retorna o LUT importado.
    @discardableResult
    func importCube(from url: URL) throws -> LUTInfo {
        let text = try String(contentsOf: url, encoding: .utf8)
        let parsed = try CubeParser.parse(text)
        let id = "file.\(UUID().uuidString)"
        let fileName = "\(id).cube"
        try FileManager.default.copyItem(at: url, to: Self.folder.appendingPathComponent(fileName))
        let name = parsed.title?.isEmpty == false ? parsed.title! : url.deletingPathExtension().lastPathComponent
        let info = LUTInfo(id: id, name: name, fileName: fileName)
        lock.withLock {
            known[id] = info
            cache[id] = parsed.cube
        }
        imported.append(info)
        persist()
        return info
    }

    func remove(_ info: LUTInfo) {
        guard let file = info.fileName else { return }
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(file))
        lock.withLock {
            known[info.id] = nil
            cache[info.id] = nil
        }
        imported.removeAll { $0.id == info.id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(imported) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

// MARK: - Leitor .cube (Adobe/Resolve)

enum CubeParser {
    enum Failure: LocalizedError {
        case oneDimensional, missingSize, unsupportedSize(Int), wrongCount(expected: Int, found: Int)
        var errorDescription: String? {
            switch self {
            case .oneDimensional: L("LUTs 1D não são suportados; use um LUT 3D (.cube).", "1D LUTs aren't supported; use a 3D LUT (.cube).")
            case .missingSize: L("Arquivo sem LUT_3D_SIZE.", "File has no LUT_3D_SIZE.")
            case .unsupportedSize(let n): L("Tamanho \(n)³ não suportado (use de 2 a 64).", "Size \(n)³ isn't supported (use 2 to 64).")
            case .wrongCount(let e, let f): L("Esperava \(e) cores e encontrou \(f).", "Expected \(e) colors but found \(f).")
            }
        }
    }

    static func parse(_ text: String) throws -> (title: String?, cube: LUTCube) {
        var size = 0
        var title: String?
        var values: [Float] = []

        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            switch parts[0].uppercased() {
            case "TITLE":
                title = String(line.dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: " \t\""))
            case "LUT_3D_SIZE":
                size = Int(parts.count > 1 ? parts[1] : "") ?? 0
            case "LUT_1D_SIZE":
                throw Failure.oneDimensional
            case "DOMAIN_MIN", "DOMAIN_MAX", "LUT_3D_INPUT_RANGE":
                continue   // faixa de entrada; os LUTs usuais usam 0…1
            default:
                guard parts.count >= 3, let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]) else { continue }
                values.append(contentsOf: [r, g, b, 1])
            }
        }
        guard size > 0 else { throw Failure.missingSize }
        guard (2...64).contains(size) else { throw Failure.unsupportedSize(size) }
        let expected = size * size * size
        guard values.count == expected * 4 else { throw Failure.wrongCount(expected: expected, found: values.count / 4) }
        return (title, LUTCube(dimension: size, data: values.withUnsafeBufferPointer { Data(buffer: $0) }))
    }
}

// MARK: - LUTs de fábrica

/// Looks gerados por função sobre valores de exibição (0…1), amostrados em 33³.
enum BuiltInLUTs {
    typealias RGB = (r: Double, g: Double, b: Double)

    static func make(_ id: String, dimension n: Int = 33) -> LUTCube? {
        let transform: (RGB) -> RGB
        switch id {
        case "builtin.vibrant": transform = vibrant
        case "builtin.cinema": transform = cinema
        case "builtin.noir": transform = noir
        case "builtin.pop": transform = pop
        case "builtin.midsommar": transform = midsommar
        default: return nil
        }
        var values = [Float]()
        values.reserveCapacity(n * n * n * 4)
        let step = 1 / Double(n - 1)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let c = transform((Double(r) * step, Double(g) * step, Double(b) * step))
                    values.append(contentsOf: [Float(clamp(c.r)), Float(clamp(c.g)), Float(clamp(c.b)), 1])
                }
            }
        }
        return LUTCube(dimension: n, data: values.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    // Cores vivas, protegendo o que já é saturado (vibrância) e contraste leve.
    static func vibrant(_ c: RGB) -> RGB {
        let s = saturation(c)
        return curve(saturate(c, 1 + 0.5 * (1 - s)), 0.12)
    }

    // Teal & orange: sombras frias, realces quentes, pretos levemente erguidos.
    static func cinema(_ c: RGB) -> RGB {
        var x = curve(c, 0.22)
        let l = luma(x), shadow = (1 - l) * (1 - l), highlight = l * l
        x = (x.r - 0.04 * shadow + 0.06 * highlight,
             x.g + 0.02 * shadow + 0.015 * highlight,
             x.b + 0.07 * shadow - 0.05 * highlight)
        return lift(saturate(x, 0.88), 0.03)
    }

    // P&B de alto contraste com filtro vermelho suave (céus escuros, pele clara).
    static func noir(_ c: RGB) -> RGB {
        var l = 0.36 * c.r + 0.54 * c.g + 0.10 * c.b
        l = smooth(l, 0.5)
        l = clamp((l - 0.03) / 0.95)
        return (l, l, l)
    }

    // Saturado e com punch, realces limpos.
    static func pop(_ c: RGB) -> RGB {
        let x = curve(saturate(c, 1.5), 0.28)
        return (x.r + 0.015, x.g + 0.01, x.b + 0.02)
    }

    // Claro e solar: médios abertos, pretos lavados, calor amarelado, contraste baixo.
    static func midsommar(_ c: RGB) -> RGB {
        var x: RGB = (pow(c.r, 0.82), pow(c.g, 0.82), pow(c.b, 0.86))
        let l = luma(x), mid = 4 * l * (1 - l)
        x = (x.r + 0.045 * l, x.g + 0.04 * l + 0.02 * mid, x.b - 0.04 * l)
        x = curve(saturate(x, 1.12), -0.1)
        return lift(x, 0.07)
    }

    // MARK: Utilitários

    static func luma(_ c: RGB) -> Double { 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }
    static func saturation(_ c: RGB) -> Double { max(c.r, c.g, c.b) - min(c.r, c.g, c.b) }
    static func saturate(_ c: RGB, _ k: Double) -> RGB {
        let l = luma(c)
        return (l + (c.r - l) * k, l + (c.g - l) * k, l + (c.b - l) * k)
    }
    /// Curva em S (k > 0 aumenta o contraste, k < 0 suaviza).
    static func smooth(_ x: Double, _ k: Double) -> Double {
        let v = clamp(x)
        return v + k * (v * v * (3 - 2 * v) - v)
    }
    static func curve(_ c: RGB, _ k: Double) -> RGB { (smooth(c.r, k), smooth(c.g, k), smooth(c.b, k)) }
    static func lift(_ c: RGB, _ amount: Double) -> RGB {
        (amount + c.r * (1 - amount), amount + c.g * (1 - amount), amount + c.b * (1 - amount))
    }
    static func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
}
