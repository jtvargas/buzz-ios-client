import BuzzKit
@testable import Hive
import Testing
import UIKit

/// What an attachment says about itself — to VoiceOver always, and on screen whenever
/// there is no picture to show.
///
/// This is the whole of the feature for a reader who cannot see it, and the whole of it
/// for anybody at all when a load fails, so it is asserted directly rather than left to a
/// screenshot.
@Suite("Message media description")
struct MessageMediaDescriptionTests {
    static func image(alt: String? = nil) -> MessageMedia {
        MessageMedia(url: "https://relay.example/media/abc.png", kind: .image, alt: alt)
    }

    static func video(alt: String? = nil, url: String = "https://relay.example/media/clip.mp4") -> MessageMedia {
        MessageMedia(url: url, kind: .video, alt: alt)
    }
}

// MARK: - Labels

extension MessageMediaDescriptionTests {
    @Test("alt is the label, verbatim, at every stage of the load")
    func altIsTheLabel() {
        let media = Self.image(alt: "A cat asleep on a warm laptop")
        #expect(MessageMediaDescription.label(for: media, state: .loaded) == "A cat asleep on a warm laptop")
        #expect(MessageMediaDescription.label(for: media, state: .loading)
            == "A cat asleep on a warm laptop, loading")
        #expect(MessageMediaDescription.label(for: media, state: .failed)
            == "A cat asleep on a warm laptop, image unavailable")
    }

    @Test("a picture with no alt still says something, and never says its URL")
    func fallsBackToTheKind() {
        let bare = Self.image()
        #expect(MessageMediaDescription.label(for: bare, state: .loaded) == "Image")
        #expect(MessageMediaDescription.label(for: bare, state: .loading) == "Image, loading")
        #expect(MessageMediaDescription.label(for: bare, state: .failed) == "Image unavailable")
        // Relay media is stored under a 64-character content hash. Reading one aloud is a
        // minute of hexadecimal that describes nothing, so the address never reaches the
        // label at any stage.
        for state in [MessageMediaDescription.LoadState.loading, .loaded, .failed] {
            #expect(MessageMediaDescription.label(for: bare, state: state).contains("http") == false)
        }
    }

    @Test("an alt that is only whitespace is not an alt")
    func ignoresEmptyAlt() {
        // A tag that carried the key and no content. Used verbatim it would leave VoiceOver
        // announcing an empty string, which is indistinguishable from a bug.
        #expect(MessageMediaDescription.label(for: Self.image(alt: "   "), state: .loaded) == "Image")
        #expect(MessageMediaDescription.label(for: Self.image(alt: "\n\t"), state: .failed) == "Image unavailable")
        #expect(MessageMediaDescription.label(for: Self.image(alt: ""), state: .loaded) == "Image")
        // And one that merely has whitespace around it is trimmed, not discarded.
        #expect(MessageMediaDescription.label(for: Self.image(alt: "  a chart  "), state: .loaded) == "a chart")
    }

    @Test("a video says what it is and that it will not play, in that order")
    func describesVideo() {
        #expect(MessageMediaDescription.label(for: Self.video(), state: .loaded) == "Video attachment")
        #expect(MessageMediaDescription.label(for: Self.video(alt: "The demo"), state: .loaded)
            == "The demo, video attachment")
        // The caveat is the *value*, so an author's own description is still the first
        // thing heard and the limitation arrives after it.
        #expect(MessageMediaDescription.value(for: Self.video()) == "Not playable in this version")
        #expect(MessageMediaDescription.value(for: Self.image()) == nil)
    }

    @Test("the hint describes the action, and there is none while a picture is loading")
    func hints() {
        let media = Self.image()
        #expect(MessageMediaDescription.hint(for: media, state: .loaded) == "Shows the picture full screen")
        #expect(MessageMediaDescription.hint(for: media, state: .failed) == "Tries the download again")
        #expect(MessageMediaDescription.hint(for: media, state: .loading) == nil)
        // Nothing can be done to a video placeholder, so promising an action would be a lie.
        #expect(MessageMediaDescription.hint(for: Self.video(), state: .loaded) == nil)
    }
}

// MARK: - Drawn text

extension MessageMediaDescriptionTests {
    @Test("the failure box says what the picture was, and never nothing")
    func failureText() {
        #expect(MessageMediaDescription.placeholderText(for: Self.image(alt: "Q3 chart"), state: .failed) == "Q3 chart")
        #expect(MessageMediaDescription.placeholderText(for: Self.image(), state: .failed) == "Image unavailable")
        #expect(MessageMediaDescription.placeholderText(for: Self.image(alt: " "), state: .failed).isEmpty == false)
        // A picture that is loading or loaded draws no text over itself.
        #expect(MessageMediaDescription.placeholderText(for: Self.image(), state: .loading).isEmpty)
        #expect(MessageMediaDescription.placeholderText(for: Self.image(), state: .loaded).isEmpty)
    }

    @Test("the video box names the file when the author named nothing")
    func videoText() {
        #expect(MessageMediaDescription.placeholderText(for: Self.video(alt: "Standup"), state: .loaded) == "Standup")
        #expect(MessageMediaDescription.placeholderText(for: Self.video(), state: .loaded) == "clip.mp4")
        // Nothing to name at all is still not nothing to say.
        let anonymous = Self.video(url: "https://relay.example")
        #expect(MessageMediaDescription.placeholderText(for: anonymous, state: .loaded) == "Video")
    }

    @Test("a long file name is truncated in the middle, so the extension survives")
    func truncatesFileNames() {
        #expect(MessageMediaDescription.fileName(for: "https://relay.example/media/holiday.mp4") == "holiday.mp4")

        // The shape relay media actually has: a 64-character content hash. Tail truncation
        // would take the extension — the only informative part — so the cut is in the
        // middle, the way the app already draws keys and channel ids.
        let hashed = "https://relay.example/media/" +
            "d30e51a434671057056169000e6c181056fc4c63232056eeda5cc7094189828e.mp4"
        let name = MessageMediaDescription.fileName(for: hashed)
        #expect(name == "d30e51a4346710…28e.mp4")
        #expect(name?.count == 22)
        #expect(name?.hasSuffix(".mp4") == true)

        // A signed URL names the file, not the signature: a query is not part of the path.
        #expect(MessageMediaDescription.fileName(for: "https://relay.example/media/a.png?token=abc") == "a.png")

        // A URL with no name in it has nothing to show.
        #expect(MessageMediaDescription.fileName(for: "https://relay.example") == nil)
        #expect(MessageMediaDescription.fileName(for: "https://relay.example/") == nil)
    }
}

// MARK: - Symbols

extension MessageMediaDescriptionTests {
    @Test("every symbol the media views draw resolves on this SDK")
    func symbolsExist() {
        // A missing SF Symbol is not a build error and not a crash: `Image(systemName:)`
        // draws nothing at all, which in a placeholder whose entire job is to be visible is
        // the one failure mode that would ship unnoticed.
        for name in ["photo", "video", "xmark"] {
            #expect(UIImage(systemName: name) != nil, "SF Symbol '\(name)' is missing")
        }
    }
}
