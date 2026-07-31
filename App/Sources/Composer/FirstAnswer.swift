import Foundation

/// Whichever of two answers arrives first, with the other one dropped.
///
/// The piece that lets ``ComposerAttachmentsModel/within(_:or:_:)`` stop waiting on work that
/// may never finish. A task group cannot do this — it is required to await every child before
/// it returns — so the race is run between two unstructured tasks and settled here, where
/// "first" is decided once and the loser's answer, whenever it turns up, is discarded.
///
/// An actor rather than a lock because the two settlers are on different tasks and the waiter
/// is on a third; the whole contract is that `settle` is safe to call twice and only the first
/// call is heard.
actor FirstAnswer<T: Sendable> {
    private var answer: Result<T, any Error>?
    private var waiter: CheckedContinuation<Result<T, any Error>, Never>?

    /// Offers an answer. The first one wins; later ones are dropped on the floor.
    func settle(_ result: Result<T, any Error>) {
        guard answer == nil else { return }
        answer = result
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: result)
        }
    }

    /// The answer, once there is one.
    ///
    /// At most one caller: this is a race with a single waiter by construction, and a second
    /// `await` on it would park for ever rather than be told it was wrong. Not enforced,
    /// because the only caller is `within` and enforcing it would cost a `fatalError` on a
    /// path a test could not reach.
    func value() async -> Result<T, any Error> {
        if let answer { return answer }
        return await withCheckedContinuation { continuation in
            // No interleaving between the check above and this assignment: both run inside
            // this actor's isolation, and `withCheckedContinuation` calls its body
            // synchronously.
            waiter = continuation
        }
    }
}
