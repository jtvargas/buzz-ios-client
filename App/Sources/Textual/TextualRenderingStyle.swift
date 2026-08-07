import Foundation

/// The two complete Textual presets exposed by the proof-of-concept setting.
enum TextualRenderingStyle: String, CaseIterable, Identifiable {
    case gitHub
    case `default`

    var id: String { rawValue }

    var name: String {
        switch self {
        case .gitHub: "GitHub"
        case .default: "Default"
        }
    }
}
