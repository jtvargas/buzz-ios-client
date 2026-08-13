import SwiftUI

/// How the sidebar's sections and rows get resolved, and when.
///
/// Outside ``ChannelListView``'s own file for the reason ``ChannelListView+Chrome`` is:
/// that file sits a few lines under SwiftLint's `file_length` error ceiling, and a
/// derivation with an explanation attached does not fit there without pushing the next
/// person into it.
extension ChannelListView {
    /// Resolves the sections and rows into ``ChannelListView/sidebar``, once per change of
    /// its inputs.
    ///
    /// Deliberately does **not** read the presence roster: presence is consulted inside
    /// each row instead, so a heartbeat invalidates the small views that draw a dot rather
    /// than re-deriving every section (§9). That is also what makes the result cheap to
    /// *hold* — nothing high-frequency is an input, so holding it cannot go stale in a way
    /// a reader would notice.
    ///
    /// `names` is passed in rather than read here: ``ChannelListView/entityNames`` is
    /// `fileprivate` to the main file, and widening it to reach across would be a worse
    /// trade than handing over the one value already in hand at each call site.
    func rebuildSidebar(names: EntityNames) {
        sidebar = SidebarContent.build(
            channels: model.visibleChannels, names: names, starred: starred.ids
        )
    }
}
