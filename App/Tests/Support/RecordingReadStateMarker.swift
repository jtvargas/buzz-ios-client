@testable import Hive

/// A ``ReadStateMarking`` double that records every mark-on-view call, so a timeline
/// test can assert exactly when — and up to which message — a visible channel marks
/// itself read, without a live engine.
actor RecordingReadStateMarker: ReadStateMarking {
    private(set) var upTos: [Int64] = []

    /// The frontier of the most recent mark, or `nil` if none yet.
    var lastUpTo: Int64? { upTos.last }

    func markRead(channel _: String, upTo: Int64) async {
        upTos.append(upTo)
    }
}
