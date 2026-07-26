import Foundation
@testable import Hive
import Testing
import UIKit

/// The loader's fetch strategy, asserted through the URLs it actually asks for.
///
/// Every request is served by ``StubAvatarProtocol`` from bytes this file builds, so
/// nothing here touches a network — but the *decisions* under test (prefer the thumbnail,
/// fall back once, then stop asking) are exactly the ones that only show up in request
/// traffic.
@Suite("Avatar loader")
struct AvatarLoaderTests {
    static let digest = "d30e51a434671057056169000e6c181056fc4c63232056eeda5cc7094189828e"

    static var originalPath: String { "/media/\(digest).png" }
    static var thumbnailPath: String { "/media/\(digest).thumb.jpg" }

    /// A loader whose session answers only from the stub, and whose caches start empty so
    /// one test's hit cannot become another's.
    static func makeLoader() -> AvatarLoader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubAvatarProtocol.self]
        return AvatarLoader(
            session: URLSession(configuration: configuration),
            cache: AvatarImageCache()
        )
    }

    static func url(host: String) -> URL {
        URL(string: "https://\(host)\(StubAvatarProtocol.hostSuffix)\(originalPath)")!
    }
}

// MARK: - Fetch strategy

extension AvatarLoaderTests {
    @Test("a small avatar is fetched from the thumbnail, and the original is never asked for")
    func prefersThumbnail() async throws {
        let host = "prefers-thumb" + StubAvatarProtocol.hostSuffix
        StubAvatarProtocol.register(
            host: host,
            responses: [Self.thumbnailPath: AvatarRenderingTests.pngData(size: 320)]
        )

        let image = await Self.makeLoader().image(for: Self.url(host: "prefers-thumb"), pixelSize: 108)

        #expect(image != nil)
        #expect(image?.size == CGSize(width: 108, height: 108))
        #expect(StubAvatarProtocol.requestedPaths(host: host) == [Self.thumbnailPath])
    }

    @Test("a request larger than the thumbnail goes straight to the original")
    func skipsThumbnailWhenTooSmall() async throws {
        let host = "skips-thumb" + StubAvatarProtocol.hostSuffix
        StubAvatarProtocol.register(
            host: host,
            responses: [Self.originalPath: AvatarRenderingTests.pngData(size: 512)]
        )

        let image = await Self.makeLoader().image(for: Self.url(host: "skips-thumb"), pixelSize: 400)

        #expect(image != nil)
        // Not even an attempt at the thumbnail: at 400 px it would have to be upscaled.
        #expect(StubAvatarProtocol.requestedPaths(host: host) == [Self.originalPath])
    }

    @Test("a blob with no thumbnail falls back to the original exactly once")
    func fallsBackOnceWhenThumbnailIsMissing() async throws {
        let host = "no-thumb" + StubAvatarProtocol.hostSuffix
        StubAvatarProtocol.register(
            host: host,
            responses: [Self.originalPath: AvatarRenderingTests.pngData(size: 512)]
        )

        let image = await Self.makeLoader().image(for: Self.url(host: "no-thumb"), pixelSize: 108)

        #expect(image != nil)
        // Two requests, in this order, and no third: the fallback is single-shot, and the
        // original is fetched directly rather than having a thumbnail re-derived from it.
        #expect(StubAvatarProtocol.requestedPaths(host: host) == [Self.thumbnailPath, Self.originalPath])
    }
}

// MARK: - Failure suppression

extension AvatarLoaderTests {
    @Test("a source that 404s is not requested again on the next pass")
    func remembersNotFound() async throws {
        let host = "all-missing" + StubAvatarProtocol.hostSuffix
        StubAvatarProtocol.register(host: host, responses: [:])
        let loader = Self.makeLoader()
        let url = Self.url(host: "all-missing")

        #expect(await loader.image(for: url, pixelSize: 108) == nil)
        let afterFirst = StubAvatarProtocol.requestedPaths(host: host)
        #expect(afterFirst == [Self.thumbnailPath, Self.originalPath])

        // The second pass — a row scrolling back in — must not put anything on the wire.
        #expect(await loader.image(for: url, pixelSize: 108) == nil)
        #expect(StubAvatarProtocol.requestedPaths(host: host) == afterFirst)

        // Nor at another size: a missing blob is missing at every size.
        #expect(await loader.image(for: url, pixelSize: 288) == nil)
        #expect(StubAvatarProtocol.requestedPaths(host: host) == afterFirst)

        // And clearing the record is what makes a retry a real retry.
        await loader.retryFailures()
        #expect(await loader.image(for: url, pixelSize: 108) == nil)
        #expect(StubAvatarProtocol.requestedPaths(host: host).count > afterFirst.count)
    }

    @Test("bytes that arrive but do not decode are remembered too")
    func remembersUndecodable() async throws {
        let host = "garbage" + StubAvatarProtocol.hostSuffix
        StubAvatarProtocol.register(
            host: host,
            responses: [Self.thumbnailPath: Data(repeating: 0x41, count: 256)]
        )
        let loader = Self.makeLoader()
        let url = Self.url(host: "garbage")

        #expect(await loader.image(for: url, pixelSize: 108) == nil)
        let afterFirst = StubAvatarProtocol.requestedPaths(host: host)
        #expect(afterFirst == [Self.thumbnailPath])

        #expect(await loader.image(for: url, pixelSize: 108) == nil)
        #expect(StubAvatarProtocol.requestedPaths(host: host) == afterFirst)
    }
}

// MARK: - Data URIs

extension AvatarLoaderTests {
    @Test("the owner's SVG avatar resolves through the loader without a request")
    func resolvesInlineSVG() async throws {
        let host = "inline" + StubAvatarProtocol.hostSuffix
        StubAvatarProtocol.register(host: host, responses: [:])
        let url = try #require(URL(string: AvatarSourceTests.ownerAvatar))
        let loader = Self.makeLoader()

        let image = try #require(await loader.image(for: url, pixelSize: 108))
        #expect(image.size == CGSize(width: 108, height: 108))
        #expect(StubAvatarProtocol.requestedPaths(host: host).isEmpty)

        // A second ask at the same size is a cache hit, and a synchronous one — which is
        // what lets a row scrolling back in draw its picture in the first frame.
        #expect(loader.cachedImage(for: url, pixelSize: 108) != nil)
        // A different size is a different entry, so the two do not collide.
        #expect(loader.cachedImage(for: url, pixelSize: 288) == nil)
        #expect(await loader.image(for: url, pixelSize: 288) != nil)
        #expect(loader.cachedImage(for: url, pixelSize: 288) != nil)
    }

    @Test("a raster data URI decodes through ImageIO, and a broken one fails cleanly")
    func decodesRasterAndRejectsGarbage() throws {
        let png = AvatarRenderingTests.pngData(size: 256).base64EncodedString()
        let raster = try #require(DataURI(string: "data:image/png;base64,\(png)"))
        guard case let .image(image) = AvatarLoader.decode(raster, pixelSize: 108) else {
            Issue.record("a real PNG data URI should decode")
            return
        }
        #expect(image.size == CGSize(width: 108, height: 108))

        let svg = try #require(DataURI(string: AvatarSourceTests.ownerAvatar))
        guard case .image = AvatarLoader.decode(svg, pixelSize: 108) else {
            Issue.record("the owner's SVG avatar should render")
            return
        }

        // A mediatype that lies about raster bytes still renders, because the payload
        // sniffs as XML.
        let mislabelled = try #require(DataURI(string: "data:image/png,%3Csvg%20viewBox%3D" +
            "%220%200%208%208%22%3E%3Crect%20width%3D%228%22%20height%3D%228%22%20" +
            "fill%3D%22%23000%22%2F%3E%3C%2Fsvg%3E"))
        guard case .image = AvatarLoader.decode(mislabelled, pixelSize: 32) else {
            Issue.record("a mislabelled SVG payload should still render")
            return
        }

        let broken = try #require(DataURI(string: "data:image/png;base64,QUFBQUFBQUE="))
        guard case .failed(.undecodable) = AvatarLoader.decode(broken, pixelSize: 108) else {
            Issue.record("eight bytes of 'A' are not an image and do not sniff as XML")
            return
        }
    }

    @Test("the XML sniff only fires for documents that open like one")
    func sniffsXML() {
        #expect(AvatarLoader.looksLikeXML(Data("<svg/>".utf8)))
        #expect(AvatarLoader.looksLikeXML(Data("  \n<?xml version='1.0'?>".utf8)))
        #expect(AvatarLoader.looksLikeXML(Data("<html/>".utf8)) == false)
        #expect(AvatarLoader.looksLikeXML(Data()) == false)
        #expect(AvatarLoader.looksLikeXML(Data([0x89, 0x50, 0x4E, 0x47])) == false)
    }
}
