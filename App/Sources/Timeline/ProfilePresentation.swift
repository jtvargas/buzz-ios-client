import SwiftUI

/// The identity a message surface is currently showing a profile for.
///
/// A wrapper rather than a bare `String?` so `sheet(item:)` can key the presentation
/// off it: tapping a second person while the first is open re-presents for the new
/// pubkey instead of leaving the sheet showing whoever was there before.
struct ProfilePeer: Identifiable, Hashable {
    let pubkey: String

    var id: String { pubkey }
}

extension View {
    /// Presents ``ProfileSheetView`` for whoever `peer` names.
    ///
    /// One modifier rather than a `.sheet` per surface: the channel timeline and a
    /// thread both open the same sheet from the same two taps (an avatar and a sender's
    /// name), and a second copy of this call is a second place for the two to drift —
    /// most obviously over `onMessage`, which is deliberately `nil` here. Opening or
    /// creating the direct message is a separate workstream, and
    /// ``ProfileSheetView`` already hides the action rather than offering one that
    /// does nothing; a stub that dismissed and went nowhere would have to be found and
    /// removed later, in however many surfaces had grown one.
    ///
    /// `presence` is passed down rather than observed inside the sheet so the sheet
    /// cannot become a second source of truth for who is online — the row's dot and the
    /// sheet's dot are read from the same model.
    func profileSheet(peer: Binding<ProfilePeer?>, presence: PresenceModel) -> some View {
        modifier(ProfileSheetModifier(peer: peer, presence: presence))
    }
}

/// Presents the sheet and hands its Message action to the app's router.
///
/// A modifier rather than a closure argument at each call site: the router arrives from
/// the environment, and a `View` extension cannot read the environment. Keeping the
/// lookup here means the channel timeline and a thread both get the action — or both get
/// no action, if no router was injected — without either of them knowing the router
/// exists.
private struct ProfileSheetModifier: ViewModifier {
    @Environment(\.directMessageRouter) private var router

    @Binding var peer: ProfilePeer?
    let presence: PresenceModel

    func body(content: Content) -> some View {
        content.sheet(item: $peer) { target in
            ProfileSheetView(
                pubkey: target.pubkey,
                presence: presence,
                // `nil` when no router is injected, which is what makes
                // ``ProfileSheetView`` hide the action instead of offering one that
                // cannot work.
                onMessage: router.map { router in { router.open(with: $0) } }
            )
        }
    }
}
