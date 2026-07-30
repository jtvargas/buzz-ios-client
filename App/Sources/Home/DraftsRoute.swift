/// The Drafts screen as a pushed value, so it goes through `navigationDestination(item:)`
/// like every other push in this stack rather than through a `Bool`.
///
/// Its own file, beside ``DraftsView``, for the reason ``ThreadsRoute`` sits beside the
/// screen it opens: the value and the screen are one thing.
struct DraftsRoute: Hashable, Identifiable {
    var id: String { "drafts" }
}
