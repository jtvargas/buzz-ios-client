@testable import Hive
import Testing

/// The emoji picker's catalog. Every assertion here is about the *list* rather than about
/// the grid, and that is the point: the list is several hundred characters typed into a
/// source file, where a dropped variation selector or a stray space is invisible on the page
/// and draws as a tofu box or a bare letter on the device.
@Suite("Emoji catalog", .timeLimit(.minutes(1)))
struct EmojiCatalogTests {
    @Test("every entry is exactly one grapheme cluster")
    func entriesAreSingleCharacters() {
        // The check that catches a mangled literal. `❤️` without its variation selector is
        // still one character; `✅ ` with a trailing space is two, and `1️⃣` broken apart is
        // three. Any of those renders as something nobody chose.
        for section in EmojiCatalog.sections {
            for emoji in section.emoji {
                #expect(emoji.count == 1, "\(section.name): \(emoji.unicodeScalars.map(\.value))")
            }
        }
    }

    @Test("every entry is an emoji rather than a letter that happens to be nearby")
    func entriesAreEmoji() {
        for section in EmojiCatalog.sections {
            for emoji in section.emoji {
                let isEmoji = emoji.unicodeScalars.contains { $0.properties.isEmoji }
                #expect(isEmoji, "\(section.name): \(emoji)")
            }
        }
    }

    @Test("no section repeats an entry")
    func sectionsHaveNoRepeats() {
        // A repeat inside one section is a duplicate id in the grid's `ForEach`, which
        // SwiftUI answers by dropping rows rather than by complaining.
        for section in EmojiCatalog.sections {
            #expect(Set(section.emoji).count == section.emoji.count, "\(section.name)")
        }
    }

    @Test("every section has a name and something in it")
    func sectionsArePopulated() {
        #expect(!EmojiCatalog.sections.isEmpty)
        for section in EmojiCatalog.sections {
            #expect(!section.name.isEmpty)
            #expect(!section.emoji.isEmpty, "\(section.name)")
        }
    }

    @Test("an empty query gives every section back untouched")
    func emptyQueryIsEverything() {
        #expect(EmojiCatalog.sections(matching: "") == EmojiCatalog.sections)
        #expect(EmojiCatalog.sections(matching: "   ") == EmojiCatalog.sections)
    }

    @Test("a query narrows to the emoji whose names carry it")
    func queryNarrows() {
        let matches = EmojiCatalog.sections(matching: "heart").flatMap(\.emoji)
        #expect(matches.contains("❤️"))
        #expect(!matches.contains("🚗"))
        #expect(matches.count < EmojiCatalog.all.count)
    }

    @Test("every token has to match, so a second word narrows further")
    func everyTokenMustMatch() {
        let one = EmojiCatalog.sections(matching: "face").flatMap(\.emoji)
        let two = EmojiCatalog.sections(matching: "face tears").flatMap(\.emoji)
        #expect(two.count < one.count)
        #expect(two.contains("😂"))
    }

    @Test("a query nothing answers gives no sections at all")
    func unmatchedQueryIsEmpty() {
        // What ``EmojiPickerView`` draws its "no results" state from.
        #expect(EmojiCatalog.sections(matching: "zzzzqqqq").isEmpty)
    }

    @Test("the name behind an emoji is searchable text, not ICU's wrapper")
    func namesAreStripped() {
        let name = EmojiCatalog.unicodeName(of: "😀")
        #expect(!name.contains("\\N{"))
        #expect(!name.contains("}"))
        #expect(name.contains("grinning"))
        // Lower-cased and hyphen-free, so `type-1-2` and `type 1 2` are one query.
        #expect(name == name.lowercased())
    }

    @Test("a name is what VoiceOver is given for a cell, so every entry has one")
    func everyEntryIsNamed() {
        for emoji in EmojiCatalog.all {
            #expect(!EmojiCatalog.unicodeName(of: emoji).isEmpty, "\(emoji)")
        }
    }
}
