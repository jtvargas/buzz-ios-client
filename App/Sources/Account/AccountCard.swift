import SwiftUI

/// A titled card: a heading with an optional control on the right, an optional line of
/// explanation, and rows.
///
/// The account screen's chrome, factored out so the two cards on it — which differ only in
/// what they hold — cannot drift apart in padding, corner or divider placement.
struct AccountCard<Accessory: View, Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    private static var cornerRadius: CGFloat { 16 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.hive(.headline, weight: .semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.hive(.footnote))
                            .foregroundStyle(.secondary)
                            // So a long line wraps rather than compressing the heading
                            // beside it at a large text size.
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                accessory
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()
            content
        }
        .background(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}

/// One labelled row inside a card: a small caption over whatever the row is about.
///
/// The caption is above rather than beside the value, because half of these values are
/// keys and handles — long, monospaced, and unreadable in the half-width a leading label
/// would leave them.
struct AccountFieldRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.hive(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(.rect)
    }
}

/// The value shown when a profile field has never been set. Its own type so the two
/// screens that draw one cannot disagree about the wording or the colour.
struct AccountUnsetValue: View {
    let value: String?

    var body: some View {
        Text(value ?? "Not set")
            .font(.hive(.body))
            .foregroundStyle(value == nil ? .secondary : .primary)
    }
}
