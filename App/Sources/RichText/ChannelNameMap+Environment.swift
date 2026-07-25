import SwiftUI

extension EnvironmentValues {
    /// The app-wide `#channel` name→id map, injected once near the channel list and
    /// read by the render path to resolve `#`-references. Defaults to empty, so a
    /// surface that has not injected it simply renders `#name` as plain text — the
    /// same safe "unmatched" behaviour as an unknown name.
    @Entry var channelNameMap: ChannelNameMap = .empty
}
