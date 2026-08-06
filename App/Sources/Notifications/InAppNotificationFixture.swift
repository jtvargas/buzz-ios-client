#if DEBUG
import BuzzKit
import SwiftUI

enum InAppNotificationFixture {
    static var requested: Bool {
        ProcessInfo.processInfo.arguments.contains("-fixtureInAppNotification")
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
}

struct InAppNotificationFixtureHost: View {
    @State private var showsBanner = true

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
        .overlay(alignment: .top) {
            if showsBanner {
                InAppNotificationBanner(notification: InAppNotificationFixture.notification) {} dismiss: {
                    withAnimation(.spring(duration: 0.42, bounce: 0.16)) { showsBanner = false }
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 12)
                .safeAreaPadding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
}
#endif
