import Foundation
@testable import NostrCore
import Testing

@Suite("EventKind registry and storage classes")
struct EventKindTests {
    @Test("Integer literals build kinds")
    func integerLiteral() {
        let kind: EventKind = 42
        #expect(kind.rawValue == 42)
        #expect(kind == EventKind(rawValue: 42))
    }

    @Test("Named statics carry their spec kind numbers")
    func namedStatics() {
        #expect(EventKind.metadata.rawValue == 0)
        #expect(EventKind.textNote.rawValue == 1)
        #expect(EventKind.channelMessage.rawValue == 9)
        #expect(EventKind.groupDeleteEvent.rawValue == 9005)
        #expect(EventKind.archiveRequest.rawValue == 9035)
        #expect(EventKind.unarchiveRequest.rawValue == 9036)
        #expect(EventKind.membershipList.rawValue == 13534)
        #expect(EventKind.presence.rawValue == 20001)
        #expect(EventKind.typing.rawValue == 20002)
        #expect(EventKind.readState.rawValue == 30078)
        #expect(EventKind.reminder.rawValue == 30300)
        #expect(EventKind.richMessage.rawValue == 40002)
        #expect(EventKind.messageEdit.rawValue == 40003)
        #expect(EventKind.threadSummary.rawValue == 39005)
        #expect(EventKind.windowBounds.rawValue == 39006)
        #expect(EventKind.memberAdded.rawValue == 44100)
        #expect(EventKind.memberRemoved.rawValue == 44101)
    }

    @Test("Encodes and decodes as a bare integer, unknown kinds surviving")
    func codableBareInteger() throws {
        let kinds: [EventKind] = [.textNote, EventKind(rawValue: 987_654), .readState]
        let encoded = try JSONEncoder().encode(kinds)
        #expect(try #require(String(bytes: encoded, encoding: .utf8)) == "[1,987654,30078]")

        let decoded = try JSONDecoder().decode([EventKind].self, from: encoded)
        #expect(decoded == kinds)
        #expect(decoded[1].rawValue == 987_654)
    }

    @Test("Ephemeral range is 20000..<30000")
    func ephemeralBoundaries() {
        #expect(!EventKind(rawValue: 19999).isEphemeral)
        #expect(EventKind(rawValue: 20000).isEphemeral)
        #expect(EventKind(rawValue: 29999).isEphemeral)
        #expect(!EventKind(rawValue: 30000).isEphemeral)
    }

    @Test("Replaceable range is 10000..<20000 plus kinds 0 and 3")
    func replaceableBoundaries() {
        #expect(EventKind(rawValue: 0).isReplaceable)
        #expect(EventKind(rawValue: 3).isReplaceable)
        #expect(!EventKind(rawValue: 9999).isReplaceable)
        #expect(EventKind(rawValue: 10000).isReplaceable)
        #expect(EventKind(rawValue: 19999).isReplaceable)
        #expect(!EventKind(rawValue: 20000).isReplaceable)
    }

    @Test("Addressable range is 30000..<40000")
    func addressableBoundaries() {
        #expect(!EventKind(rawValue: 29999).isAddressable)
        #expect(EventKind(rawValue: 30000).isAddressable)
        #expect(EventKind(rawValue: 39999).isAddressable)
        #expect(!EventKind(rawValue: 40000).isAddressable)
    }

    @Test("Storage classes are mutually exclusive at the boundaries")
    func storageClassesDisjoint() {
        let regular = EventKind(rawValue: 9999)
        #expect(!regular.isEphemeral && !regular.isReplaceable && !regular.isAddressable)

        let ephemeral = EventKind(rawValue: 20000)
        #expect(ephemeral.isEphemeral && !ephemeral.isReplaceable && !ephemeral.isAddressable)

        let addressable = EventKind(rawValue: 30000)
        #expect(addressable.isAddressable && !addressable.isEphemeral && !addressable.isReplaceable)
    }

    @Test("Relay-signed guard covers exactly the relay-authored kinds")
    func relaySignedSet() {
        let relaySigned: [EventKind] = [
            .groupMetadata, .groupAdmins, .groupMembers, .groupRoles,
            .threadSummary, .windowBounds,
            .membershipList, .memberAdded, .memberRemoved,
        ]
        for kind in relaySigned {
            #expect(kind.isRelaySigned, "\(kind) should be relay-signed")
        }

        let clientAuthored: [EventKind] = [
            .metadata, .textNote, .channelMessage, .reaction,
            .richMessage, .messageEdit, .presence, .typing,
            .readState, .reminder, .groupAddUser, .archiveRequest,
        ]
        for kind in clientAuthored {
            #expect(!kind.isRelaySigned, "\(kind) should not be relay-signed")
        }
    }
}
