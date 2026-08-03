import SwiftUI

/// The sheet behind the Direct Messages heading's `+`: everyone this account could message,
/// filtered as you type, up to eight of them picked, and one button that starts it.
///
/// # Why it takes people rather than a directory
///
/// Its whole input is `[DirectMessagePerson]` — a plain array of resolved values. It holds no
/// ``EntityNames``, no store, and no engine, so the mapping from an identity to a name stays
/// at the call site where it already lives, and everything this sheet decides is testable
/// without any of them (see ``DirectMessagePicker`` and `NewDirectMessageTests`). It is also
/// what lets a fixture launch draw it on a simulator with no relay in reach.
///
/// # Why it does not navigate
///
/// It reports the people who were chosen and dismisses; the open and the push happen in the
/// sheet's `onDismiss`. A push started from inside a dismissing sheet races the modal
/// transition and UIKit resolves that race by dropping the push — the same rule
/// ``CreateChannelSheet`` follows, for the same reason.
///
/// # Chips *and* checkmarks
///
/// Both, because either alone loses half the state. A checkmark says whether the row under
/// the finger is picked; it cannot say who else is, because the filter that found the second
/// person has hidden the first. The chips are the standing answer to "who is in this
/// message so far", and tapping one takes that person back out — the only way to unpick
/// somebody the filter has scrolled out of reach.
struct NewDirectMessageSheet: View {
    /// Called with the chosen pubkeys, lowercase hex, in the order they were picked —
    /// immediately before this dismisses.
    let chosen: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var picker: DirectMessagePicker

    init(
        people: [DirectMessagePerson],
        maxSelection: Int,
        chosen: @escaping ([String]) -> Void
    ) {
        self.init(
            picker: DirectMessagePicker(people: people, maxSelection: maxSelection),
            chosen: chosen
        )
    }

    /// The designated initialiser, taking the state directly. Used by the fixture launch and
    /// the previews to open the sheet already filtered or already holding a selection —
    /// states that otherwise exist only after somebody has typed and tapped.
    init(picker: DirectMessagePicker, chosen: @escaping ([String]) -> Void) {
        _picker = State(initialValue: picker)
        self.chosen = chosen
    }

    var body: some View {
        NavigationStack {
            list
                .listStyle(.plain)
                // Below the rows, not above them. As a top inset this pushed the whole roster
                // down the moment anybody was picked — the reader tapped a name and the list
                // they were reading moved. At the bottom the rows keep their place and pass
                // under the bar instead.
                //
                // `safeAreaInset` rather than `overlay`: an inset also grows the list's
                // content inset, so the last row still scrolls clear of the bar, and the bar
                // is a sibling of the list rather than a view sitting on top of it claiming
                // touches — see ``row(_:)`` for what that has cost this app before.
                .safeAreaInset(edge: .bottom, spacing: 0) { selected }
                .searchable(
                    text: $picker.query,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search people"
                )
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .navigationTitle("New Message")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Start") { start() }
                            .disabled(!picker.canStart)
                    }
                }
        }
        // On the stack rather than on the `List`, so the ground reaches the search drawer and
        // the bottom bar as well as the rows — a sheet otherwise draws `systemBackground`
        // behind everything the list is not.
        //
        // The *sheet* ground, not the screen one: this is presented, and a modal wearing
        // ``ShapeStyle/hiveNight`` is the same near-black as the sidebar behind it.
        .hiveSheetGround()
    }

    // MARK: - The roster

    @ViewBuilder
    private var list: some View {
        List {
            ForEach(picker.results) { person in
                row(person)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .overlay { emptyState }
    }

    private func row(_ person: DirectMessagePerson) -> some View {
        Button {
            picker.toggle(person.pubkey)
        } label: {
            HStack(spacing: 12) {
                AvatarView(
                    url: person.picture,
                    seed: person.pubkey,
                    monogram: person.initials,
                    size: Self.avatar
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(person.name)
                        .font(.hive(.body, weight: .medium))
                        .foregroundStyle(.primary)
                    if let secondary = person.secondary {
                        Text(secondary)
                            .font(.hive(.footnote))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                mark(for: person)
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        // A row's press treatment, which draws no wash and — crucially — starts tracking
        // from SwiftUI's own button rather than from a gesture. A gesture that tracks at
        // touch-down claims the touch away from the list it is inside, and this app has
        // shipped an unscrollable surface that way twice.
        .buttonStyle(.hivePress(.row))
        // At the cap the rows that would be refused stop answering, rather than absorbing a
        // press and doing nothing. The picked ones stay live: unpicking somebody is the only
        // way back from a full sheet.
        .disabled(!picker.canSelect(person.pubkey))
        .opacity(picker.canSelect(person.pubkey) ? 1 : Self.refusedOpacity)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(picker.isSelected(person.pubkey) ? [.isButton, .isSelected] : .isButton)
    }

    private func mark(for person: DirectMessagePerson) -> some View {
        Image(systemName: picker.isSelected(person.pubkey) ? "checkmark.circle.fill" : "circle")
            .font(.hiveSymbol(.title3))
            .foregroundStyle(picker.isSelected(person.pubkey) ? Color.hiveAccent : .secondary)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var emptyState: some View {
        if picker.results.isEmpty {
            if picker.people.isEmpty {
                ContentUnavailableView(
                    "No one to message yet",
                    systemImage: "person.2",
                    description: Text("People appear here once you share a channel with them.")
                )
            } else {
                ContentUnavailableView.search(text: picker.query)
            }
        }
    }

    // MARK: - Who is picked

    /// The chips, and the count under them — a bar floating at the bottom over the roster.
    /// Absent entirely until somebody is picked, so an empty sheet is all list.
    ///
    /// Inset from all three edges and drawn on a material, which is what makes it read as
    /// something resting *over* the rows rather than as the last row of them: the list stays
    /// visible down both sides of it and blurred through it.
    @ViewBuilder
    private var selected: some View {
        if !picker.chips.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(picker.chips) { person in chip(person) }
                    }
                    .padding(.horizontal, 14)
                }
                .scrollIndicators(.hidden)
                Text(countLabel)
                    .font(.hive(.footnote))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
            }
            .padding(.vertical, 12)
            .background(.regularMaterial, in: .rect(cornerRadius: Self.barRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Self.barRadius)
                    .strokeBorder(Color.primary.opacity(Self.barEdge))
            }
            .shadow(color: .black.opacity(Self.barShadow), radius: 12, y: 3)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .animation(.snappy(duration: 0.2), value: picker.selection)
        }
    }

    private func chip(_ person: DirectMessagePerson) -> some View {
        Button {
            picker.deselect(person.pubkey)
        } label: {
            HStack(spacing: 6) {
                Text(person.name)
                    .font(.hive(.subheadline, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .font(.hiveSymbol(.caption2, weight: .bold))
            }
            .foregroundStyle(.primary)
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .padding(.vertical, 7)
            .background(Color.hiveAccent.opacity(Self.chipOpacity), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.hivePress(.control, in: .capsule))
        .accessibilityLabel("\(person.name), selected")
        .accessibilityHint("Removes them from this message")
    }

    /// How many of the allowance is spent. The number counts *other people*: the relay's cap
    /// is eight `p` tags and it merges the author in, so a full sheet is nine in the room.
    private var countLabel: String {
        let spent = "\(picker.selection.count) of \(picker.maxSelection)"
        guard picker.isFull else { return spent }
        return "\(spent) — the most a direct message can include besides you."
    }

    private func start() {
        guard picker.canStart else { return }
        chosen(picker.selection)
        dismiss()
    }

    private static let avatar: CGFloat = 36
    /// How far a row that the cap has ruled out is taken back. Enough to read as unavailable,
    /// not so far that the name under it stops being legible — the reader still has to be
    /// able to see who they would have to unpick somebody for.
    private static let refusedOpacity: CGFloat = 0.4
    private static let chipOpacity: CGFloat = 0.22
    private static let barRadius: CGFloat = 20
    /// A hairline, so the material has an edge where it meets a row of similar weight.
    private static let barEdge: CGFloat = 0.12
    private static let barShadow: CGFloat = 0.35
}

// MARK: - Presentation

extension View {
    /// Presents the new-direct-message sheet, and reports the chosen people *after* the sheet
    /// has finished dismissing.
    ///
    /// The delay is the whole reason this is a modifier rather than two lines at the call
    /// site — see ``View/createChannelSheet(isPresented:engine:open:)``, which parks a created
    /// channel for the same reason: a navigation started while a sheet is dismissing races the
    /// modal transition and UIKit drops it.
    ///
    /// `people` is a closure, not a value: the roster is walked when the sheet opens rather
    /// than on every pass of the body this is attached to. The sidebar's body re-evaluates on
    /// an arriving message, a presence heartbeat, a row being read — none of which are
    /// reasons to rebuild a list nobody is looking at.
    func newDirectMessageSheet(
        isPresented: Binding<Bool>,
        people: @escaping () -> [DirectMessagePerson],
        maxSelection: Int,
        open: @escaping ([String]) -> Void
    ) -> some View {
        modifier(NewDirectMessagePresentation(
            isPresented: isPresented,
            people: people,
            maxSelection: maxSelection,
            open: open
        ))
    }
}

private struct NewDirectMessagePresentation: ViewModifier {
    @Binding var isPresented: Bool
    let people: () -> [DirectMessagePerson]
    let maxSelection: Int
    let open: ([String]) -> Void

    /// Who the sheet chose, held from its callback until the sheet is gone.
    @State private var chosen: [String] = []

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            guard !chosen.isEmpty else { return }
            let peers = chosen
            chosen = []
            open(peers)
        } content: {
            NewDirectMessageSheet(people: people(), maxSelection: maxSelection) { chosen = $0 }
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Nothing typed") {
    NewDirectMessageSheet(picker: DirectMessagePicker.preview(.resting)) { _ in }
}

#Preview("Filtered") {
    NewDirectMessageSheet(picker: DirectMessagePicker.preview(.filtered)) { _ in }
}

#Preview("Three chosen") {
    NewDirectMessageSheet(picker: DirectMessagePicker.preview(.chosen)) { _ in }
}
#endif
