import BuzzKit
@testable import Hive
import Testing
import UIKit

/// What opening the viewer on a particular picture actually carries: the whole group, and
/// which of it was tapped.
///
/// The one rule worth pinning is identity — ``MessageMediaViewerSubject/id`` has to name
/// the *tapped* picture, not the group's first one, because it is both the
/// `fullScreenCover(item:)` key and the zoom transition's source id. Get it wrong and a
/// gallery opened on its third picture zooms in from the first one's frame instead.
@Suite("Message media viewer subject")
struct MessageMediaViewerSubjectTests {
    static func media(_ url: String) -> MessageMedia {
        MessageMedia(url: url, kind: .image)
    }
}

extension MessageMediaViewerSubjectTests {
    @Test("a single attachment's subject is a gallery of one, keyed on that one picture")
    func singleAttachmentIsAGalleryOfOne() {
        let only = Self.media("https://relay.example/media/a.png")
        let subject = MessageMediaViewerSubject(media: [only], startIndex: 0, preview: nil)

        #expect(subject.id == only.url)
        #expect(subject.media == [only])
    }

    @Test("the id names whichever picture was tapped, not the group's first")
    func idNamesTheTappedPicture() {
        let group = [
            Self.media("https://relay.example/media/a.png"),
            Self.media("https://relay.example/media/b.png"),
            Self.media("https://relay.example/media/c.png"),
        ]

        for index in group.indices {
            let subject = MessageMediaViewerSubject(media: group, startIndex: index, preview: nil)
            #expect(subject.id == group[index].url)
        }
    }

    @Test("the preview belongs to the tapped picture and only reaches the viewer for that page")
    func previewBelongsToTheTappedPicture() {
        let group = [Self.media("https://relay.example/media/a.png"), Self.media("https://relay.example/media/b.png")]
        let bitmap = UIImage()
        let subject = MessageMediaViewerSubject(media: group, startIndex: 1, preview: bitmap)

        #expect(subject.preview === bitmap)
        #expect(subject.startIndex == 1)
        #expect(subject.media[subject.startIndex].url == group[1].url)
    }
}
