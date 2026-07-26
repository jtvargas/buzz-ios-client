import Foundation

/// A bounded, expiring record of avatar sources that just failed, so a row scrolling in
/// and out of a list does not keep re-requesting artwork that is not coming.
///
/// # Why it expires instead of sticking
///
/// Avatars on this relay live on a tailnet-only host, so *every* avatar fails while the
/// device is off the tailnet. A permanent negative cache would then pin the whole app to
/// monograms for the rest of the launch, long after the network came back — trading a
/// request storm for a stuck UI. So the reason a load failed decides how long it is
/// remembered: a 404, or bytes no decoder can read, is a property of the blob and worth
/// remembering for a while; a transport error is a property of the moment and is
/// forgotten quickly.
///
/// A plain value type rather than an actor or a class: it is owned by ``AvatarLoader``,
/// which already serialises access, and being a `struct` makes the eviction and expiry
/// rules testable without any concurrency at all.
struct AvatarFailureCache: Sendable {
    /// Why a load produced no image.
    enum Reason: Sendable, Equatable {
        /// The server answered, and the answer was "no such blob".
        case notFound
        /// Bytes arrived and no decoder could turn them into an image.
        case undecodable
        /// The request never completed: offline, off-tailnet, TLS, DNS, timeout.
        case transport

        /// How long a failure of this kind suppresses further requests.
        ///
        /// Ten minutes for the deterministic answers — a 404 and an unreadable payload
        /// will both still be true on the next scroll pass — and thirty seconds for a
        /// transport error, which is long enough to absorb a whole scroll gesture (the
        /// storm this exists to stop) and short enough that walking back onto the tailnet
        /// fills the avatars in without a relaunch.
        var lifetime: TimeInterval {
            switch self {
            case .notFound, .undecodable: 600
            case .transport: 30
            }
        }
    }

    /// The most failures remembered at once.
    ///
    /// The same order as the image cache's count limit — a few screens of rows — so a
    /// long scroll through a workspace whose media host is unreachable cannot grow this
    /// without bound. Eviction is first-recorded-first-out; re-recording a key refreshes
    /// its expiry but does not move it in the queue, which keeps `record` O(1).
    static let capacity = 256

    private var expiries: [String: Date] = [:]
    private var order: [String] = []

    /// How many failures are currently held, expired or not. For tests and for reasoning
    /// about the bound; callers should ask ``isSuppressed(_:now:)``.
    var count: Int { order.count }

    /// Remembers that `key` failed, and evicts down to ``capacity`` if that pushed it
    /// over.
    mutating func record(_ key: String, reason: Reason, now: Date = .now) {
        if expiries.updateValue(now.addingTimeInterval(reason.lifetime), forKey: key) == nil {
            order.append(key)
        }
        evictIfNeeded()
    }

    /// Whether `key` failed recently enough that it should not be requested again.
    ///
    /// Expired entries answer `false` and are left in place: they are already inside the
    /// bound, so sweeping them eagerly would buy nothing but work.
    func isSuppressed(_ key: String, now: Date = .now) -> Bool {
        guard let expiry = expiries[key] else { return false }
        return expiry > now
    }

    /// Forgets every failure — the hook for "the user asked to retry".
    mutating func removeAll() {
        expiries.removeAll()
        order.removeAll()
    }

    private mutating func evictIfNeeded() {
        guard order.count > Self.capacity else { return }
        let excess = order.count - Self.capacity
        for key in order.prefix(excess) { expiries.removeValue(forKey: key) }
        order.removeFirst(excess)
    }
}
