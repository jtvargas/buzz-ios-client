import Foundation
import WidgetKit

/// Where the widget's number comes from on each reload: the App Group snapshot for what
/// has been read, the relay for what has been said.
///
/// # Every path returns a timeline
///
/// A reload that fails still costs one from the widget's daily budget, so spending it on
/// an error face buys nothing and loses the number the reader had. Every failure renders
/// the app's last-known count with the timestamp it was taken at, and asks to be woken
/// later rather than sooner.
struct ThreadsTimelineProvider: TimelineProvider {
    /// How long until the next reload after a fetch that worked. A request, not a promise
    /// — iOS decides, and its floor for a frequently-reloaded widget is around fifteen
    /// minutes anyway.
    static let successInterval: TimeInterval = 15 * 60
    /// And after one that did not. Longer, because the common causes — no network, a relay
    /// that is down, a key not yet published — do not resolve in fifteen minutes, and each
    /// attempt spends budget that the recovered case will want.
    static let failureInterval: TimeInterval = 45 * 60

    func placeholder(in _: Context) -> ThreadsEntry {
        ThreadsEntry(
            date: Date(),
            state: .counted(.init(count: 3, communityName: "Buzz", asOf: Date(), isStale: false, isFloor: false))
        )
    }

    /// The gallery preview and the transient state. Deliberately does not hit the network:
    /// this is drawn while the reader is scrolling a picker, and a request there would be
    /// both slow and pointless.
    func getSnapshot(in _: Context, completion: @escaping @Sendable (ThreadsEntry) -> Void) {
        guard let snapshot = ThreadsWidgetSnapshot.load() else {
            completion(ThreadsEntry(date: Date(), state: .needsApp))
            return
        }
        completion(ThreadsEntry(date: Date(), state: .counted(.init(
            count: snapshot.localCount,
            communityName: snapshot.communityName,
            asOf: snapshot.capturedAt,
            isStale: true,
            isFloor: false
        ))))
    }

    /// `@Sendable` is written out rather than inherited. The protocol declares it
    /// (`WidgetKit.swiftinterface`: `completion: @escaping @Sendable …`), but a conformance
    /// that omits the attribute still satisfies the requirement while typing the parameter
    /// as non-`Sendable` locally — and under Swift 6 the fetch below then cannot capture it,
    /// with an error that reads as a problem with the `Task` rather than with the signature.
    func getTimeline(in _: Context, completion: @escaping @Sendable (Timeline<ThreadsEntry>) -> Void) {
        Task {
            completion(await timeline())
        }
    }

    private func timeline() async -> Timeline<ThreadsEntry> {
        let now = Date()
        guard let snapshot = ThreadsWidgetSnapshot.load() else {
            return Timeline(
                entries: [ThreadsEntry(date: now, state: .needsApp)],
                policy: .after(now.addingTimeInterval(Self.failureInterval))
            )
        }

        do {
            let result = try await ThreadsCountFetcher.fetch(snapshot: snapshot)
            return Timeline(
                entries: [ThreadsEntry(date: now, state: .counted(.init(
                    count: result.count,
                    communityName: snapshot.communityName,
                    asOf: now,
                    isStale: false,
                    isFloor: result.isFloor
                )))],
                policy: .after(now.addingTimeInterval(Self.successInterval))
            )
        } catch {
            return Timeline(
                entries: [ThreadsEntry(date: now, state: .counted(.init(
                    count: snapshot.localCount,
                    communityName: snapshot.communityName,
                    asOf: snapshot.capturedAt,
                    isStale: true,
                    isFloor: false
                )))],
                policy: .after(now.addingTimeInterval(Self.failureInterval))
            )
        }
    }
}
