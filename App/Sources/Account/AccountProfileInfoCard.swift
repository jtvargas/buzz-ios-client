import SwiftUI

/// The two facts a person writes about themselves: their display name and their bio.
///
/// # Why the fields are behind an Edit button
///
/// Both are published to a relay for everyone in the workspace to read. Live text fields
/// on arrival — which is what this screen used to be — invite an accidental edit to the
/// name other people see you by, with nothing to undo it. Read-only rows, one Edit that
/// turns them into fields, and a Cancel that puts back what was published: the change
/// stays deliberate, and it stays reversible right up to Save.
struct AccountProfileInfoCard: View {
    let model: ProfileModel

    @State private var isEditing = false

    var body: some View {
        @Bindable var model = model
        AccountCard(title: "Profile info") {
            accessory
        } content: {
            if isEditing {
                editingRows($model)
            } else {
                readingRows
            }
        }
        // The card changes height when it swaps, and an unanimated swap at that size reads
        // as the screen jumping rather than as a mode changing.
        .animation(.snappy(duration: 0.25), value: isEditing)
    }

    @ViewBuilder
    private var accessory: some View {
        if isEditing {
            Button("Cancel") {
                model.revertTextEdits()
                isEditing = false
            }
            .font(.hive(.subheadline))
        } else {
            Button {
                isEditing = true
            } label: {
                Label("Edit", systemImage: "pencil")
                    .font(.hive(.subheadline, weight: .medium))
            }
            // Nothing to edit until the projection has been read: an Edit here would open
            // fields seeded with empty strings, and a Save would clear the profile.
            .disabled(!model.hasLoaded)
        }
    }

    // MARK: - Reading

    @ViewBuilder
    private var readingRows: some View {
        AccountFieldRow(label: "Display name") {
            AccountUnsetValue(value: model.publishedDisplayName)
        }
        Divider()
        AccountFieldRow(label: "Profile description") {
            AccountUnsetValue(value: model.publishedAbout)
        }
    }

    // MARK: - Editing

    @ViewBuilder
    private func editingRows(_ model: Bindable<ProfileModel>) -> some View {
        AccountFieldRow(label: "Display name") {
            TextField("Your name", text: model.draftDisplayName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .font(.hive(.body))
        }
        Divider()
        AccountFieldRow(label: "Profile description") {
            TextField(
                "Say something about yourself",
                text: model.draftAbout,
                axis: .vertical
            )
            .lineLimit(1 ... 4)
            .font(.hive(.body))
        }
        Divider()
        saveRow
    }

    private var saveRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task {
                    await model.save()
                    // The fields stay open on a failure, holding what was typed — the one
                    // state where closing would lose an edit that was never published.
                    if model.saveError == nil { isEditing = false }
                }
            } label: {
                Group {
                    if model.isSaving {
                        ProgressView()
                    } else {
                        Text("Save Changes").font(.hive(.body, weight: .semibold))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.glassProminent)
            .disabled(model.isSaving || !model.hasUnsavedTextEdits)

            if let saveError = model.saveError {
                Text(saveError)
                    .font(.hive(.footnote))
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
