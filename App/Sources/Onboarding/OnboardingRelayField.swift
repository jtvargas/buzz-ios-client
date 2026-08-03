import SwiftUI

/// The relay row on the onboarding hero: one line when the address is settled, an editor when
/// it is not.
///
/// It collapses because the relay is the one thing on this screen a reader has usually already
/// been handed — prefilled on a fresh install, carried over on every launch after — and a text
/// field is a question. Collapsed it still *names* the relay, because "which community am I
/// about to join" is the question this screen most often got wrong: the card above answers it
/// by name, this answers it by address, and between them there is no state where a reader is
/// connecting somewhere they cannot see.
///
/// Opening and closing is the caller's to decide (``OnboardingView`` opens it whenever the
/// address stops being usable), so the row never folds an unanswered question out of sight.
struct OnboardingRelayField: View {
    @Binding var relayURLString: String
    @Binding var isExpanded: Bool
    /// The note under the field — every state of the address says something, including the
    /// ones that are nobody's mistake (§ ``OnboardingView``).
    let note: String
    /// Whether the note is a refusal, so it can be drawn as one.
    let isRefused: Bool
    @FocusState.Binding var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if isExpanded {
                editor
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var header: some View {
        Button {
            isExpanded.toggle()
            if isExpanded { isFocused = true }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.hiveAccent)
                Text("Relay")
                    .foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 8)
                if !isExpanded {
                    Text(collapsedLabel)
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Image(systemName: "chevron.down")
                    .font(.hive(.caption2, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
            }
            .font(.hive(.footnote, weight: .medium))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Relay, \(isExpanded ? "editing" : collapsedLabel)")
        .accessibilityHint(isExpanded ? "Collapses the relay field" : "Opens the relay field")
    }

    private var editor: some View {
        Group {
            TextField("wss://relay.example", text: $relayURLString)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .focused($isFocused)
                .font(.hive(.subheadline))
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(.white.opacity(0.07), in: .rect(cornerRadius: 11))
            // Says why the routes below are dead, at the moment they are. A disabled control
            // with no explanation is the one state a reader cannot get out of.
            Text(note)
                .font(.hive(.caption2))
                .foregroundStyle(isRefused ? Color.red : .white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What the collapsed row shows on the right: the host alone, because the scheme is the
    /// same on every relay worth naming and `wss://` spends a third of the line saying so.
    private var collapsedLabel: String {
        guard let relay = CommunityAddress(relayURLString).relayURLString,
              let host = URL(string: relay)?.host()
        else { return relayURLString.isEmpty ? "Not set" : relayURLString }
        return host
    }
}
