import BuzzKit

/// VoiceOver status phrasing for a timeline message, kept pure so the label logic is
/// unit-testable without a view.
///
/// Read as the accessibility *value* after the row's combined label (author, time,
/// content), so VoiceOver announces e.g. "Ada, 2 minutes ago, ship it — Online, Edited".
/// A plain delivered message from an offline author has no status and contributes
/// nothing, so the common case stays terse.
enum MessageAccessibility {
    /// The status clause for a message, empty when there is nothing noteworthy (an
    /// author who is offline, an unedited message that delivered).
    ///
    /// - Parameter author: the writer's name, and only for a message whose row does not
    ///   draw one because it continues the block above it. `nil` — the common case — for
    ///   a message that names its author on screen, where the combined label has already
    ///   said it and saying it twice is noise.
    static func status(author: String? = nil, isOnline: Bool, isEdited: Bool, delivery: Delivery) -> String {
        var parts: [String] = []
        if let author { parts.append("From \(author)") }
        if isOnline { parts.append("Online") }
        if isEdited { parts.append("Edited") }
        switch delivery {
        case .pending: parts.append("Sending")
        case .failed: parts.append("Not delivered")
        case .sent: break
        }
        return parts.joined(separator: ", ")
    }
}
