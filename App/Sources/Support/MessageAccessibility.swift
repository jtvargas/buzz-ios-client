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
    static func status(isOnline: Bool, isEdited: Bool, delivery: Delivery) -> String {
        var parts: [String] = []
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
