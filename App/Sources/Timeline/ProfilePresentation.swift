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
        sheet(item: peer) { target in
            ProfileSheetView(pubkey: target.pubkey, presence: presence, onMessage: nil)
        }
    }
}
