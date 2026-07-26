import SwiftUI

extension EnvironmentValues {
    /// The app-wide name/avatar/conversation resolver, injected once near the channel
    /// list and read by every surface that has to *show* an identity. Defaults to
    /// empty, so a surface that has not injected it falls back to short identifiers
    /// rather than rendering a raw key.
    @Entry var entityNames: EntityNames = .empty
}
