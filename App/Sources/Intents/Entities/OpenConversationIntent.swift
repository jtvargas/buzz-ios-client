import AppIntents

/// Opens one indexed channel in the community Hive has mounted.
struct OpenConversationIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Conversation"
    static let description = IntentDescription(
        "Opens a Hive channel in the active community.",
        categoryName: "Navigation"
    )
    static let openAppWhenRun = true

    @Parameter(title: "Conversation")
    var conversation: ConversationEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$conversation)")
    }

    @Dependency
    private var environment: AppEnvironment

    @Dependency
    private var navigator: AppNavigator

    @MainActor
    func perform() async throws -> some IntentResult {
        try Self.validate(conversation.id, activeCommunityID: environment.communities.activeID)
        navigator.request(.conversation(conversation.id))
        return .result()
    }

    static func validate(_ id: EntityID, activeCommunityID: Community.ID?) throws {
        guard id.community == activeCommunityID else { throw ConversationEntityError.otherCommunity }
    }
}
