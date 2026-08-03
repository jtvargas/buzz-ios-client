import Foundation

/// The machine-readable reason a relay attaches to a rejection.
///
/// NIP-01 defines a small vocabulary of `OK`/`CLOSED` messages shaped as
/// `"<prefix>: <human message>"` — `duplicate:`, `pow:`, `rate-limited:`,
/// `invalid:`, `restricted:`, `auth-required:`, `blocked:`, `error:`. Parsing
/// them into a closed set of cases turns free-text into a decision the retry
/// layer can act on, instead of every call site string-matching one prefix it
/// happens to care about.
///
/// The same message grammar rides on both an `OK(false)` (a publish was
/// refused) and a `CLOSED` (a subscription was refused), so this classifier
/// serves both. Each case keeps the human-readable remainder for logging and
/// display; the associated value of ``unspecified(_:)`` is the whole original
/// string, since no prefix was recognised to strip.
public enum OKReason: Sendable, Equatable {
    /// The relay already has this event; nothing more to do.
    case duplicate(String)
    /// The event's proof of work did not meet the relay's difficulty target.
    case pow(String)
    /// The client is sending too fast and should back off.
    case rateLimited(String)
    /// The event is malformed or fails a consistency rule (bad id, sig, shape).
    case invalid(String)
    /// The action is not permitted for this client — e.g. not a member.
    case restricted(String)
    /// The relay wants a completed NIP-42 handshake first.
    case authRequired(String)
    /// The author or event is blocked by relay policy.
    case blocked(String)
    /// A generic server-side error the relay could not classify further.
    case error(String)
    /// No recognised machine-readable prefix; the value is the raw message.
    case unspecified(String)

    /// How the outbox / subscription layer should treat a rejection.
    ///
    /// These map every case onto one of four actions rather than leaving the
    /// decision to scattered `if` chains, which is what lets one retry policy
    /// drive both publishing and subscriptions.
    public enum Disposition: Sendable, Equatable {
        /// Do not retry: resending the same frame yields the same rejection.
        case terminal
        /// Complete NIP-42 auth, then retry the frame once.
        case reauthThenRetry
        /// Transient; retry later under the backoff policy.
        case retryable
        /// The relay already accepted an equivalent frame; treat as success.
        case alreadyAccepted
    }

    /// Parses a relay's `OK`/`CLOSED` message into a typed reason.
    ///
    /// The prefix is the token up to the first colon; the remainder, with any
    /// leading whitespace trimmed, is the human message. A message with no
    /// colon, or an unrecognised prefix, becomes ``unspecified(_:)`` carrying the
    /// original string untouched.
    public init(message: String) {
        guard let colon = message.firstIndex(of: ":") else {
            self = .unspecified(message)
            return
        }
        let prefix = message[..<colon]
        let remainder = message[message.index(after: colon)...]
        let human = String(remainder.drop(while: \.isWhitespace))

        switch prefix {
        case "duplicate": self = .duplicate(human)
        case "pow": self = .pow(human)
        case "rate-limited": self = .rateLimited(human)
        case "invalid": self = .invalid(human)
        case "restricted": self = .restricted(human)
        case "auth-required": self = .authRequired(human)
        case "blocked": self = .blocked(human)
        case "error": self = .error(human)
        default: self = .unspecified(message)
        }
    }

    /// The retry action this reason implies.
    ///
    /// `invalid`, `restricted` and `blocked` are terminal by nature. `pow` is
    /// terminal too here: this client mines no proof of work, so an identical
    /// resend can never satisfy a difficulty demand and would only hammer the
    /// relay. `auth-required` earns one retry after re-authenticating.
    /// `rate-limited` and an unrecognised reason are transient and retried under
    /// backoff. `duplicate` means the relay already stored the
    /// event, which the caller should treat as a successful publish.
    ///
    /// `error` is transient *except* for the two the relay uses to say the request
    /// itself is the problem — see ``terminalErrorMessages``.
    public var disposition: Disposition {
        switch self {
        case .invalid, .restricted, .blocked, .pow:
            .terminal
        case .authRequired:
            .reauthThenRetry
        case let .error(message):
            Self.isTerminalError(message) ? .terminal : .retryable
        case .rateLimited, .unspecified:
            .retryable
        case .duplicate:
            .alreadyAccepted
        }
    }

    /// The `error:` remainders that an identical retry can never satisfy.
    ///
    /// A generic `error:` is the relay saying *something went wrong*, which is worth trying
    /// again. These two are the relay saying *this request is the problem*: the subscription
    /// budget is already full, or the filter mixes a search term with constraints the relay
    /// cannot serve together. Retrying either on a timer is an infinite loop that also keeps the
    /// budget full — the precise failure this classifier exists to prevent. Matched by prefix on
    /// the human remainder, since the relay appends detail to both.
    static let terminalErrorMessages = ["too many subscriptions", "mixed search"]

    private static func isTerminalError(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return terminalErrorMessages.contains { normalized.hasPrefix($0) }
    }

    // MARK: - Rate-limit retry hint

    /// The wait a `rate-limited:` message asks for, in seconds, when it names one.
    ///
    /// A Buzz relay writes the hint as `retry in 30s` inside the human remainder. It is advisory
    /// and frequently absent, so the caller supplies its own default — see
    /// ``RelayRateLimitGate/defaultRetrySeconds``. Only meaningful on ``rateLimited(_:)``;
    /// every other reason yields `nil` rather than mining an unrelated message for digits.
    public var retryAfterSeconds: Int? {
        guard case let .rateLimited(message) = self else { return nil }
        return Self.parseRetryInSeconds(message)
    }

    /// Built per call rather than held in a `static`: `Regex` is not `Sendable`, and this package
    /// compiles under complete strict concurrency. The cost is irrelevant — the only caller is a
    /// relay refusal, which is rare by construction.
    private static func parseRetryInSeconds(_ message: String) -> Int? {
        let pattern = /retry in (\d+)s/.ignoresCase()
        guard let match = try? pattern.firstMatch(in: message) else { return nil }
        return Int(match.output.1)
    }
}

// MARK: - RelayMessage bridge

public extension RelayMessage {
    /// The classified rejection reason a frame carries, if any.
    ///
    /// An `OK(true)` is an acceptance and carries no rejection, so it yields
    /// `nil`. An `OK(false)` and a `CLOSED` both expose their message through the
    /// same ``OKReason`` grammar. Any other frame is not a verdict and yields
    /// `nil`.
    var rejectionReason: OKReason? {
        switch self {
        case let .ok(_, accepted, message):
            accepted ? nil : OKReason(message: message)
        case let .closed(_, message):
            OKReason(message: message)
        default:
            nil
        }
    }
}
