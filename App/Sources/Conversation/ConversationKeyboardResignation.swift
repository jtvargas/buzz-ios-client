import UIKit

/// Synchronously removes the active responder before a conversation navigation state change.
///
/// SwiftUI's focus binding is observed on a later update pass. Navigation must first end
/// editing on the owning window, so UIKit cannot carry the responder into the transition
/// while SwiftUI is still holding the old focus value.
enum ConversationKeyboardResignation {
    @MainActor
    static func resignActiveResponder() -> Bool {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        return window?.endEditing(true) ?? false
    }
}
