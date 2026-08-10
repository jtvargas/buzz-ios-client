#if DEBUG
import BuzzKit
import SwiftUI
import UIKit

enum InAppNotificationFixture {
    /// What the fixture host should stand up.
    enum Mode: String {
        /// The card over an ordinary screen.
        case plain
        /// The card over a **presented Quick Look**, which is the one thing an overlay inside
        /// the app's own view tree can never be above. This is the shape the owner reported as
        /// broken on a phone, driven here so the answer is a picture rather than a theory.
        case overPreview
    }

    static var requested: Mode? {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-fixtureInAppNotificationOverPreview") { return .overPreview }
        if arguments.contains("-fixtureInAppNotification") { return .plain }
        return nil
    }

    static let notification = InAppNotification(entry: ActivityEntry(
        id: "fixture-thread",
        category: .mention,
        categories: [.mention, .activity],
        channelID: "fixture-channel",
        channelName: "ios-development",
        isDirectMessage: false,
        latest: ActivityEvent(
            id: "fixture-message",
            pubkey: "maya-fixture-pubkey",
            authorName: "Maya Chen",
            authorPicture: nil,
            kind: 9,
            content: "@JT The latest iOS build is ready — tap to review the thread.",
            createdAt: 0
        ),
        eventCount: 1,
        unreadCount: 1,
        rootID: "fixture-thread"
    ))

    /// A one-page PDF on disk, so the preview under the card is the real Quick Look reading a
    /// real document rather than an empty controller.
    static func makePreviewDocument() -> URL? {
        let url = FileManager.default.temporaryDirectory.appending(path: "fixture-preview.pdf")
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = UIGraphicsPDFRenderer(bounds: page).pdfData { context in
            context.beginPage()
            context.cgContext.setFillColor(UIColor.white.cgColor)
            context.cgContext.fill(page)
            let title = "Fixture document"
            title.draw(
                at: CGPoint(x: 72, y: 96),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 36, weight: .semibold),
                    .foregroundColor: UIColor.black,
                ]
            )
        }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

struct InAppNotificationFixtureHost: View {
    let mode: InAppNotificationFixture.Mode

    @State private var window = InAppNotificationWindowController()
    @State private var previewURL: URL?

    var body: some View {
        NavigationStack {
            List {
                Section("Channels") {
                    Label("general", systemImage: "number")
                    Label("ios-development", systemImage: "number")
                    Label("design", systemImage: "number")
                }
                Section("Direct Messages") {
                    Label("Jarvis", systemImage: "person.fill")
                }
                Section("Agents") {
                    Label("Fizz", systemImage: "sparkles")
                }
            }
            .hiveScreenGround()
            .conversationTitle(
                mark: .community(name: "Buzz", iconData: nil),
                title: "Buzz",
                actionHint: "Double tap to switch community"
            ) {}
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    AccountAvatarButton(
                        state: .running,
                        picture: nil,
                        seed: "fixture-owner",
                        monogram: "JT"
                    ) {}
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        // The shipping path exactly: the scene is reported by a view, and the card is handed
        // to the window by something that is not a view. Driving it any other way here would
        // make the fixture prove something the app does not do.
        .background(InAppNotificationScenePresenter(controller: window))
        .background(FileQuickLookPresenter(url: $previewURL))
        .task {
            // Settle first, so the presenter has been in the window once and the controller
            // knows the scene. Without this the fixture reproduces a *different* failure —
            // an app that had never drawn a frame before the preview went up — and would go
            // on failing after the bug it is aimed at was fixed.
            try? await Task.sleep(for: .seconds(1))
            if mode == .overPreview {
                previewURL = InAppNotificationFixture.makePreviewDocument()
                // Long enough for the present animation to finish, so the picture is of a
                // settled preview rather than of one still on its way up.
                try? await Task.sleep(for: .seconds(3))
            }
            // Raised and left up: the fixture is a picture of a state, so the card has no
            // clock. The model's five-second retirement is exercised on a phone, and it was
            // measured over a live preview once — it renders and the card does not get stuck.
            raise(InAppNotificationFixture.notification)
        }
    }

    /// Mirrors what ``InAppNotificationModel`` does on a tap and a swipe, minus the navigation
    /// there is no app here to perform.
    private func raise(_ notification: InAppNotification?) {
        window.show(notification, open: { _ in raise(nil) }, dismiss: { raise(nil) })
    }
}
#endif
