import NostrCore
import SwiftUI

/// Orchestrates the target-side pairing UI: scan (or paste) a QR, compare the SAS,
/// then progress to a completed transfer. Owns a ``PairingModel`` and renders its
/// current screen. On completion the model starts the engine, which flips the app
/// to its running state and unwinds onboarding.
struct PairingFlowView: View {
    /// Whether this view is the root of its own presentation rather than a step pushed onto
    /// the add-a-community hub.
    ///
    /// The communities list opens the scanner *directly* (§ ``AppEnvironment/CommunitySheet/scan``),
    /// so there is nothing behind it to go back to and a system Back button would be pointing at
    /// a screen the reader never saw. That entry point supplies its own dismissal instead — the
    /// same close button the media viewer uses, because it is the phone's own control for
    /// "this was presented, put it away".
    ///
    /// False on the onboarding route, where the hub really is one pop behind and Back is right.
    var isPresentedDirectly = false

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var model: PairingModel?
    @State private var cameraAuthorized = false
    @State private var scannerID = 0
    @State private var pasteLink = ""

    var body: some View {
        Group {
            if let model {
                screen(for: model)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The comb, on the one onboarding route that was still a black screen. The camera is
        // clipped to its square (§ ``scanning(_:)``), so the lattice is what fills the rest —
        // which is the owner's ask, and also what makes the viewfinder read as a window cut
        // into the screen rather than as the screen itself.
        .background { HoneycombBackground() }
        .navigationTitle("Scan to Pair")
        .navigationBarTitleDisplayMode(.inline)
        // Otherwise the bar's own material lays a grey band across the top of the lattice —
        // the same call ``IdentityWizardScaffold`` makes for the same reason.
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .toolbar {
            if isPresentedDirectly {
                ToolbarItem(placement: .topBarLeading) {
                    // `role: .close` is the phone's own dismissal control — the circular
                    // glyph the media viewer draws (§ ``MessageMediaViewer/closeButton``),
                    // supplied by the toolbar here rather than hand-built, so it arrives
                    // already the right size and already carrying the Close accessibility
                    // label. No `.tint` override: in a bar the accent is where it belongs.
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .task {
            if model == nil { model = makeModel() }
            cameraAuthorized = await QRScannerView.requestAccess()
        }
    }

    private func makeModel() -> PairingModel {
        PairingModel(
            makeSession: { uri in
                try TargetPairingSession(uri: uri, handler: environment.pairingImporter())
            },
            onImported: { _ = await environment.completePairing() }
        )
    }

    @ViewBuilder
    private func screen(for model: PairingModel) -> some View {
        switch model.screen {
        case .scanning:
            scanning(model)
        case .connecting:
            progress("Connecting to your desktop…")
        case let .comparing(sasCode):
            SASComparisonView(
                sasCode: sasCode,
                onConfirm: model.confirmSAS,
                onCancel: { model.cancel() }
            )
        case .transferring:
            progress("Transferring your identity…")
        case .completed:
            completed
        case let .failed(message):
            failure(model, message: message)
        case .cancelled:
            cancelled(model)
        }
    }

    // MARK: - Scanning

    @ViewBuilder
    private func scanning(_ model: PairingModel) -> some View {
        VStack(spacing: 16) {
            if cameraAuthorized {
                QRScannerView { model.submitScan($0) }
                    .id(scannerID)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.tint, lineWidth: 2))
                    .padding(.horizontal)
                Text("Point the camera at the pairing QR on your desktop.")
                    .font(.hive(.footnote))
                    .foregroundStyle(.secondary)
            } else {
                ContentUnavailableView(
                    "Camera unavailable",
                    systemImage: "camera.fill",
                    description: Text("Allow camera access, or paste the pairing link below.")
                )
            }

            if let scanError = model.scanError {
                Text(scanError)
                    .font(.hive(.footnote))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button("Scan again") { scannerID += 1; pasteLink = "" }
                    .buttonStyle(.glass)
            }

            pasteFallback(model)
        }
        .padding()
        .animation(.default, value: model.scanError)
    }

    private func pasteFallback(_ model: PairingModel) -> some View {
        VStack(spacing: 8) {
            Text("Or paste the pairing link")
                .font(.hive(.caption))
                .foregroundStyle(.secondary)
            HStack {
                TextField("nostrpair://…", text: $pasteLink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(10)
                    .glassEffect(.regular, in: .rect(cornerRadius: 10))
                Button("Pair") { model.submitScan(pasteLink) }
                    .buttonStyle(.glassProminent)
                    .disabled(pasteLink.isEmpty)
            }
        }
    }

    // MARK: - Other screens

    private func progress(_ label: String) -> some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text(label).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var completed: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.hiveSymbol(fixedSize: 56))
                .foregroundStyle(.green)
            Text("You're paired!")
                .font(.hive(.title3, weight: .semibold))
            Text("Your identity is now on this device.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failure(_ model: PairingModel, message: String) -> some View {
        VStack(spacing: 20) {
            ContentUnavailableView {
                Label("Pairing failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
            Button("Try Again") {
                scannerID += 1
                model.scanAgain()
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .padding()
    }

    private func cancelled(_ model: PairingModel) -> some View {
        VStack(spacing: 20) {
            ContentUnavailableView(
                "Pairing cancelled",
                systemImage: "xmark.circle",
                description: Text("You can scan again or go back.")
            )
            HStack {
                Button("Scan Again") { scannerID += 1; model.scanAgain() }
                    .buttonStyle(.glass)
                // Same call, two different truths about where it lands: a pop back to the
                // hub when this was pushed, and closing the sheet when it was not. The
                // label follows the destination rather than the code.
                Button(isPresentedDirectly ? "Close" : "Back") { dismiss() }
                    .buttonStyle(.glassProminent)
            }
            .controlSize(.large)
        }
        .padding()
    }
}
