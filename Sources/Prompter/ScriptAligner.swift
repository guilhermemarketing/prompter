import Foundation

/// Palavra do roteiro com sua posição no texto original (UTF-16, para TextKit).
struct ScriptWord: Equatable {
    let range: NSRange
    let key: String
}

enum ScriptTokenizer {
    private static let pattern = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+(?:['’\\-][\\p{L}\\p{N}]+)*")

    static func words(in text: String) -> [ScriptWord] {
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let key = normalize(ns.substring(with: match.range))
            return key.isEmpty ? nil : ScriptWord(range: match.range, key: key)
        }
    }

    /// Minúsculas, sem acento e sem pontuação: "Câmera," → "camera".
    static func normalize(_ word: String) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    static func keys(in text: String) -> [String] { words(in: text).map(\.key) }
}

/// Acompanha a fala no roteiro. Recebe as últimas palavras ouvidas e encontra, por
/// alinhamento local (Smith-Waterman) numa janela à frente do cursor, onde a pessoa está.
/// O cursor só avança, então revisões do reconhecedor não fazem o texto tremer.
struct ScriptAligner {
    private(set) var keys: [String]
    /// Quantas palavras do roteiro já foram faladas.
    private(set) var position = 0

    var lookBehind = 3
    var lookAhead = 40
    var historyLength = 8

    init(keys: [String]) { self.keys = keys }

    mutating func reset(to position: Int) {
        self.position = max(0, min(position, keys.count))
    }

    /// Retorna a nova posição (contagem de palavras faladas).
    @discardableResult
    mutating func update(heard: [String]) -> Int {
        let tail = Array(heard.suffix(historyLength))
        guard !tail.isEmpty, !keys.isEmpty else { return position }

        let lo = max(0, position - lookBehind)
        let hi = min(keys.count, position + lookAhead)
        guard lo < hi else { return position }
        let window = Array(keys[lo..<hi])

        // Pontuação local: casamento +2 (+1 extra para palavras longas), erro −1, lacuna −1.
        let rows = tail.count + 1, cols = window.count + 1
        var score = [Double](repeating: 0, count: rows * cols)
        var matches = [Int](repeating: 0, count: rows * cols)
        var best = (score: 0.0, end: -1, matches: 0)

        for i in 1..<rows {
            for j in 1..<cols {
                let same = Self.similar(tail[i - 1], window[j - 1])
                let gain: Double = same ? (window[j - 1].count >= 6 ? 3 : 2) : -1
                let diag = score[(i - 1) * cols + j - 1] + gain
                let up = score[(i - 1) * cols + j] - 1
                let left = score[i * cols + j - 1] - 1
                var value = 0.0, count = 0
                if diag >= up, diag >= left, diag > 0 {
                    value = diag; count = matches[(i - 1) * cols + j - 1] + (same ? 1 : 0)
                } else if up >= left, up > 0 {
                    value = up; count = matches[(i - 1) * cols + j]
                } else if left > 0 {
                    value = left; count = matches[i * cols + j - 1]
                }
                score[i * cols + j] = value
                matches[i * cols + j] = count

                // Só conta alinhamentos que terminam na palavra ouvida mais recente (ou na anterior,
                // já que a última costuma estar incompleta).
                guard i >= rows - 2, same else { continue }
                let end = lo + j - 1
                let distance = Double(max(0, end - position))
                let adjusted = value - distance * 0.04
                if adjusted > best.score { best = (adjusted, end, count) }
            }
        }

        guard best.end >= 0 else { return position }
        // Exige evidência proporcional ao salto: avançar 1–3 palavras com 1 casamento forte,
        // saltos maiores com pelo menos 2 casamentos.
        let jump = best.end + 1 - position
        let required = jump <= 3 ? 1 : (jump <= 12 ? 2 : 3)
        guard best.matches >= required, best.end + 1 > position else { return position }
        position = best.end + 1
        return position
    }

    static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let shorter = min(a.count, b.count)
        guard shorter >= 3 else { return false }
        // Palavra ainda incompleta no resultado volátil ("gravaç" → "gravacao").
        if shorter >= 4, a.hasPrefix(b) || b.hasPrefix(a) { return true }
        let limit = shorter >= 8 ? 2 : (shorter >= 5 ? 1 : 0)
        return limit > 0 && levenshtein(a, b, limit: limit) <= limit
    }

    private static func levenshtein(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a), b = Array(b)
        if abs(a.count - b.count) > limit { return limit + 1 }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + [Int](repeating: 0, count: b.count)
            var rowMin = current[0]
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                rowMin = min(rowMin, current[j])
            }
            if rowMin > limit { return limit + 1 }
            previous = current
        }
        return previous[b.count]
    }
}
