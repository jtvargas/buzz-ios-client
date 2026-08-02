import BuzzKit
import SwiftUI

/// The community you are about to be in, shown the moment an address resolves to a host.
///
/// Its job is to turn a line of text into a place. Before this, both ways into a community
/// showed the reader nothing but the URL they had just pasted back at them — so a link to the
/// wrong host, or to no host at all, looked exactly like a link to the right one until the
/// join failed.
///
/// What it shows is deliberately narrow, because it is all a relay will actually back:
///
/// - the **icon**, the one per-community field in a Buzz relay's information document;
/// - the **name**, derived from the host by the same rule Buzz Desktop uses, so the phone and
///   the laptop agree about the community they are both looking at;
/// - **`Verified community`**, which means a real Buzz relay answered at that host over TLS,
///   and means nothing more than that. Not that the invite is good — that is settled at the
///   claim, which is the only place it can be.
///
/// It never shows the relay's own `name` or `description`, which are the same string on every
/// Buzz deployment (§ ``BuzzKit/RelayInfo``); showing them would label every community alike.
struct CommunityCard: View {
    let name: String
    let icon: RelayIcon?
    let isChecking: Bool
    let isVerified: Bool

    var body: some View {
        HStack(spacing: 14) {
            iconView
                .frame(width: 56, height: 56)
                .clipShape(.rect(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.hive(.title3, weight: .semibold))
                    .lineLimit(1)
                standing
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .combine)
        .animation(.default, value: isVerified)
        .animation(.default, value: isChecking)
    }

    /// The one line under the name. Every state says something: a card that went quiet after
    /// `Checking…` is the same dead end this screen exists to stop having.
    @ViewBuilder
    private var standing: some View {
        if isChecking {
            Label("Checking…", systemImage: "ellipsis")
                .font(.hive(.footnote))
                .foregroundStyle(.secondary)
        } else if isVerified {
            Label("Verified community", systemImage: "checkmark.seal.fill")
                .font(.hive(.footnote))
                .foregroundStyle(.green)
        } else {
            // Not red, and not a refusal: a relay can be perfectly real and still not serve
            // this document, and the join is not gated on it.
            Label("Couldn't check this one", systemImage: "questionmark.circle")
                .font(.hive(.footnote))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case let .inline(data):
            if let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                placeholder
            }
        case let .remote(url):
            AsyncImage(url: url) { phase in
                if case let .success(image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    placeholder
                }
            }
        case nil:
            placeholder
        }
    }

    /// A community whose owner never set an icon still reads as a place rather than a hole.
    private var placeholder: some View {
        ZStack {
            Color.hiveAccent.opacity(0.16)
            Image(systemName: "person.3.fill")
                .font(.hiveSymbol(fixedSize: 24))
                .foregroundStyle(Color.hiveAccent)
        }
    }
}
