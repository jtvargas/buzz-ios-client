import SwiftUI

/// What a conversation shows while it is reading history back toward a message the reader
/// asked for from somewhere else — and what it shows when that ends without the message.
///
/// # Why it is centred, and why it is not the pill
///
/// It was a pill above the composer, in the slot `N new messages` uses. That slot is for
/// *offers*: things a reader may take or ignore, sized to be ignorable. This is neither. It
/// reports something already happening because they asked for it, it is the only thing on
/// screen while it happens, and — since it can now be cancelled and retried — it has controls
/// they have to be able to find and hit. A 28pt capsule in the bottom corner is the wrong
/// place and the wrong size for all three.
///
/// Centred, it is also where the eye already is. A reader who has just tapped a search result
/// is looking at the middle of a screen they do not recognise yet, waiting to be taken
/// somewhere.
///
/// # Why it does not block the conversation behind it
///
/// No scrim, and hit testing is off everywhere except the panel itself. The walk loads real
/// history while it runs, and a reader who changes their mind mid-way should be able to scroll
/// the conversation they are already in rather than being held until it finishes. Cancel is
/// there for saying so out loud; scrolling past it is not an error.
struct MessageReachPanel: View {
    let seek: ConversationSeek
    /// Stop the reach. Also the way a finished report is dismissed — by then there is nothing
    /// left running, and "stop telling me" is the same instruction.
    let onCancel: () -> Void
    /// Run it again from where the conversation now stands. Absent for a failure that is a
    /// proof, because a second attempt walks the same ground to the same end.
    let onRetry: () -> Void
    /// Copy the message's own link, then dismiss.
    ///
    /// The owner's, and it is the right offer for this moment specifically: the reader came
    /// here to reference a message, the trip failed, and the link is the whole of what they
    /// wanted anyway — it opens on Desktop, it pastes into a reply, and it costs no fetch. A
    /// dead end that hands you the thing you were reaching for is not a dead end.
    ///
    /// `nil` only where no link can be built, which is a channel or message id this screen
    /// does not have — not a state it reaches from search.
    let onCopyLink: (() -> Void)?

    var body: some View {
        Group {
            switch seek {
            case .none:
                EmptyView()
            case .searching:
                panel {
                    ProgressView()
                        .controlSize(.large)
                    Text("Finding message")
                        .font(.hive(.subheadline, weight: .semibold))
                    Text("Reading back through older messages.")
                        .font(.hive(.caption))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    action("Cancel", role: .cancel, action: onCancel)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Finding message")
                // It appears without the reader doing anything to *this* screen, and it is the
                // only answer to a tap they made on another one.
                .accessibilityAddTraits(.updatesFrequently)
            case let .failed(reason):
                panel {
                    Image(systemName: reason.symbol)
                        .font(.hiveSymbol(.title, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(reason.label)
                        .font(.hive(.subheadline, weight: .semibold))
                        .multilineTextAlignment(.center)
                    Text(reason.detail)
                        .font(.hive(.caption))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    // Stacked rather than in a row. Three controls across 220 points is three
                    // controls nobody can hit, and the order is the order of usefulness: the
                    // thing that might still work, the thing that works regardless, then the
                    // way out.
                    VStack(spacing: 6) {
                        if reason.isWorthRetrying {
                            action("Try again", systemImage: "arrow.clockwise", action: onRetry)
                        }
                        if let onCopyLink {
                            action("Copy Link", systemImage: "link", action: onCopyLink)
                        }
                        action("Dismiss", role: .cancel, action: onCancel)
                    }
                    .padding(.top, 2)
                }
            }
        }
        .animation(.smooth(duration: 0.2), value: seek)
    }

    /// The square itself.
    ///
    /// A fixed width rather than a hugging one, so the panel does not change size between
    /// "Finding message" and whichever ending it lands on — a surface that resizes under a
    /// button the reader is reaching for is a surface that moves the button.
    @ViewBuilder
    private func panel(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 10) {
            content()
        }
        .padding(20)
        .frame(width: 240)
        .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
        .transition(.scale(scale: 0.92).combined(with: .opacity))
    }

    private func action(
        _ title: String,
        systemImage: String? = nil,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Label {
                Text(title)
            } icon: {
                if let systemImage { Image(systemName: systemImage) }
            }
            .font(.hive(.caption, weight: .semibold))
            // Full width so the stacked controls read as one column of equal offers rather
            // than as three differently-sized guesses at what the reader wants.
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .controlSize(.small)
    }
}

extension ConversationSeekFailure {
    /// The glyph over the words.
    var symbol: String {
        switch self {
        case .notFound: "magnifyingglass"
        case .unreachable: "wifi.exclamationmark"
        }
    }

    /// The second line: what actually happened, in the reader's terms rather than the walk's.
    var detail: String {
        switch self {
        case .notFound:
            "It is not in this conversation."
        case .unreachable:
            // Covers both of the ways this happens — a relay that did not answer in time, and
            // a message this device never stored — because from here they are the same fact:
            // the stretch of conversation it sits in is not on this phone.
            "The messages around it did not load."
        }
    }

    /// Whether **Try again** is offered.
    ///
    /// Only for ``unreachable``. ``notFound`` is a proof — the message is in this device's log,
    /// every row at or after its place is loaded, and it is not among them — and a button that
    /// cannot change its own answer is worse than no button, because pressing it and getting
    /// the same thing reads as the app being broken rather than as the message being absent.
    var isWorthRetrying: Bool { self == .unreachable }
}
