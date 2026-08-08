/// A screen the search results can push: a conversation, or a thread.
///
/// # Why a thread is an element of the path rather than a binding beside it
///
/// Because a `NavigationStack(path:)` has to have exactly one driver. Every other stack in
/// the app pairs a typed path with a `navigationDestination(item:)` for the thread, which
/// works because nothing there re-renders the stack's owner while a pop is in flight. This
/// tab is the exception: its search field belongs to the **tab bar**, which is the thing the
/// stack hides on a push — so on the way back the field is torn down and re-presented in the
/// middle of the gesture, and the owner re-renders with it.
///
/// A path-driven pop survives that, because the array *is* the answer and re-applying it pops
/// again. An item-driven pop does not: it has to be written back through a binding, and a
/// re-render that lands between the write and the transition finishing restores the value —
/// the reader sees the screen start to leave and spring back, which is what was reported.
/// Folding the thread into the path leaves nothing for the re-render to disagree with.
///
/// It also makes the tab bar's own rule a function of one thing (`path.isEmpty`) instead of
/// two, which is what that rule always wanted — see ``ChannelListTabBar``.
enum SearchRoute: Hashable {
    case conversation(ConversationRoute)
    case thread(ThreadRoute)
}

extension SearchRoute {
    /// `path` with this screen opened, keeping ``ConversationRoute/pushed(onto:)``'s rule
    /// about not stacking a conversation on itself.
    ///
    /// A thread is always appended. Two threads in one channel are two different destinations,
    /// and a thread is reachable *from* the conversation it lives in — pushing the same thread
    /// twice needs the reader to go back through it, which is a journey they chose.
    func pushed(onto path: [SearchRoute]) -> [SearchRoute] {
        guard case let .conversation(route) = self else { return path + [self] }
        guard case let .conversation(top)? = path.last, top.channel.id == route.channel.id else {
            var updated = path.filter {
                guard case let .conversation(existing) = $0 else { return true }
                return existing.channel.id != route.channel.id
            }
            updated.append(self)
            return updated
        }
        return path
    }
}

extension [SearchRoute] {
    /// The conversations on this stack, in order — what ``RecentPlaces`` reads to name where
    /// the reader is.
    var conversations: [ConversationRoute] {
        compactMap {
            guard case let .conversation(route) = $0 else { return nil }
            return route
        }
    }

    /// The thread on top of this stack, if the top of it is one.
    ///
    /// The top rather than any of them, because this answers "where is the reader now": a
    /// thread further down is a place they have already left.
    var openedThread: ThreadRoute? {
        guard case let .thread(route)? = last else { return nil }
        return route
    }
}
