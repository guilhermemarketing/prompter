import SwiftUI

/// No SDK do macOS 27, `@State` resolve para uma macro cujo plugin só vem com o Xcode.
/// Este alias aponta direto para o property wrapper, o que permite compilar só com o
/// Command Line Tools.
typealias ViewState<Value> = SwiftUI.State<Value>
