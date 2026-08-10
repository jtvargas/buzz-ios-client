import Foundation

public extension ChannelListRow {
    /// Flutter-parity compact lifetime text for the channel's trailing indicator.
    /// A deadline wins over the configured TTL because it says how much time is
    /// actually left; TTL is the fallback when no absolute deadline was published.
    func ephemeralLifetimeLabel(at now: Date = Date()) -> String? {
        if let ttlDeadline {
            let remaining = Int64(ceil(TimeInterval(ttlDeadline) - now.timeIntervalSince1970))
            if remaining <= 0 { return "Cleanup due" }
            if remaining <= 60 { return "1m left" }
            if remaining < 3_600 { return "\(Self.roundedUp(remaining, by: 60))m left" }
            if remaining < 86_400 { return "\(Self.roundedUp(remaining, by: 3_600))h left" }
            return "\(Self.roundedUp(remaining, by: 86_400))d left"
        }

        guard let ttlSeconds else { return nil }
        if ttlSeconds < 60 { return "\(max(1, ttlSeconds))s TTL" }
        if ttlSeconds < 3_600 { return "\(Self.roundedUp(ttlSeconds, by: 60))m TTL" }
        if ttlSeconds < 86_400 { return "\(Self.roundedUp(ttlSeconds, by: 3_600))h TTL" }
        return "\(Self.roundedUp(ttlSeconds, by: 86_400))d TTL"
    }

    private static func roundedUp(_ value: Int64, by unit: Int64) -> Int64 {
        max(1, (value + unit - 1) / unit)
    }
}
