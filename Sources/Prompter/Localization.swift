import Foundation

/// Idioma da interface: português quando o sistema (ou o app, em Ajustes do Sistema › Geral › Idioma
/// e Região › Aplicativos) está em português; inglês em qualquer outro idioma. O macOS resolve a
/// escolha contra as localizações do pacote (en.lproj, pt.lproj; região de desenvolvimento: en).
enum AppLanguage {
    static let isPortuguese = (Bundle.main.preferredLocalizations.first ?? "en").hasPrefix("pt")
}

/// Texto da interface nos dois idiomas, lado a lado no código.
func L(_ portuguese: String, _ english: String) -> String {
    AppLanguage.isPortuguese ? portuguese : english
}
