import Foundation

/// What pressing a piece of interactive text should do.
///
/// # Why a target is carried as a URL
///
/// The only run of a SwiftUI `Text` that can be pressed is one carrying a `link`
/// attribute — a custom attribute is inert, and a gesture of our own is not an
/// option: measured in a harness, a `DragGesture(minimumDistance: 0)` on the text
/// swallows the row's own tap (so plain text stops opening the thread), and the same
/// gesture on the row stops the message list scrolling at all. So every interactive
/// range — mention, channel, web link, email, internal link — becomes a `link`, and
/// the surface decodes the URL back into one of these cases.
///
/// That also means mentions inherit the arbitration links already had: a link inside
/// a message row claims the tap in the row's `OpenURLAction` (see
/// ``TimelineRowView``), so pressing one never also opens the thread.
///
/// Identity travels in the URL, never the visible name: a mention's URL carries the
/// pubkey the message's own `p` tags resolved to, so renaming a profile can never
/// re-point a tap.
enum RichTextTarget: Hashable, Sendable {
    /// A person or an agent — opens their profile sheet.
    case user(pubkey: String)
    /// A `#`-channel reference — navigates to that conversation.
    case channel(id: String)
    /// An ordinary web link.
    case web(URL)
    /// A `mailto:` link, whether authored or detected in plain text.
    case mail(URL)
    /// Buzz's own message link, as Desktop writes it:
    /// `buzz://message?channel=<uuid>&id=<eventId>[&thread=<rootId>]`.
    case message(channel: String, event: String, thread: String?)

    /// The private scheme the two identity cases travel under. Not a scheme anything
    /// outside this app answers, and deliberately not one a message author can spell:
    /// The markdown inline builder strips it from authored markdown, so a link only ever
    /// carries it when *this* app attached it to a resolved token.
    static let entityScheme = "hive-entity"

    /// Buzz's own deep-link scheme (`buzz://…`), read from Desktop's `deep_link.rs`.
    static let internalScheme = "buzz"

    /// Whether a link found in message content may be made tappable.
    ///
    /// The rule is "this app can actually route it", which is exactly what decoding a
    /// target proves — so a `buzz://join?…` (a pairing flow with nowhere to go here)
    /// and a truncated `buzz://message?channel=…` with no message id both stay plain
    /// text rather than becoming links that look pressable and do nothing.
    ///
    /// The one case decoding allows and this does not: the private entity scheme.
    /// A message author writing `[Ada](hive-entity://user/…)` would otherwise hand
    /// themselves a mention pointing at whoever they liked.
    static func isAllowedAuthoredLink(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() != entityScheme else { return false }
        return RichTextTarget(url: url) != nil
    }

    /// The URL that carries this target inside an `AttributedString`.
    var url: URL? {
        switch self {
        case let .user(pubkey):
            Self.entityURL(host: "user", value: pubkey)
        case let .channel(id):
            Self.entityURL(host: "channel", value: id)
        case let .web(url), let .mail(url):
            url
        case let .message(channel, event, thread):
            Self.messageURL(channel: channel, event: event, thread: thread)
        }
    }

    /// The target a pressed link describes, or `nil` when the URL is not one this app
    /// routes (which leaves it to the system's own handling).
    init?(url: URL) {
        let scheme = url.scheme?.lowercased()
        switch scheme {
        case Self.entityScheme:
            guard let value = Self.entityValue(url) else { return nil }
            switch url.host?.lowercased() {
            case "user": self = .user(pubkey: value)
            case "channel": self = .channel(id: value)
            default: return nil
            }
        case Self.internalScheme:
            guard let message = Self.message(from: url) else { return nil }
            self = message
        case "mailto":
            self = .mail(url)
        case "http", "https":
            self = .web(url)
        default:
            return nil
        }
    }

    // MARK: - URL forms

    /// Decodes `buzz://message?channel=…&id=…[&thread=…]`, Desktop's own message
    /// link. Both the channel and the message id are required: without either there
    /// is nothing to navigate to, and a half-copied link should stay plain text.
    private static func message(from url: URL) -> RichTextTarget? {
        guard url.host?.lowercased() == "message",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            let found = items.first { $0.name == name }?.value
            return (found?.isEmpty ?? true) ? nil : found
        }
        guard let channel = value("channel"), let event = value("id") else { return nil }
        return .message(channel: channel, event: event, thread: value("thread"))
    }

    /// `hive-entity://<host>/<percent-encoded value>`.
    ///
    /// Built through `URLComponents` rather than string interpolation because a
    /// channel id is workspace data, not a constant, and an unencoded one would
    /// silently produce a different URL (or none).
    private static func entityURL(host: String, value: String) -> URL? {
        guard !value.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = entityScheme
        components.host = host
        components.path = "/\(value)"
        return components.url
    }

    /// The single path component of an entity URL, decoded.
    private static func entityValue(_ url: URL) -> String? {
        let value = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        return value.isEmpty ? nil : value
    }

    private static func messageURL(channel: String, event: String, thread: String?) -> URL? {
        var components = URLComponents()
        components.scheme = internalScheme
        components.host = "message"
        var items = [
            URLQueryItem(name: "channel", value: channel),
            URLQueryItem(name: "id", value: event),
        ]
        if let thread, !thread.isEmpty {
            items.append(URLQueryItem(name: "thread", value: thread))
        }
        components.queryItems = items
        return components.url
    }
}
