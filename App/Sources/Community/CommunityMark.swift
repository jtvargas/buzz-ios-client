import Foundation
import BuzzKit
import SwiftUI
import UIKit

/// The small identity mark shared by the community card and the community switcher.
///
/// A relay-owned picture is clipped to the same pointy-top hexagon as the channel-list
/// symbol. When there is no picture, the community still gets a stable visual identity from
/// its name: initials on a light accent wash, rather than a solid tile that competes with the
/// pressed shortcut cards around it.
struct CommunityMark: View {
    let name: String
    let icon: RelayIcon?
    let iconData: Data?
    let size: CGFloat

    init(name: String, icon: RelayIcon? = nil, iconData: Data? = nil, size: CGFloat = 40) {
        self.name = name
        self.icon = icon
        self.iconData = iconData
        self.size = size
    }

    var body: some View {
        content
            .frame(width: size, height: size)
            .clipShape(PointyHexagon())
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        switch icon {
        case let .inline(data):
            if let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                initials
            }
        case let .remote(url):
            AsyncImage(url: url) { phase in
                if case let .success(image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    initials
                }
            }
        case nil:
            if let iconData, let image = UIImage(data: iconData) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                initials
            }
        }
    }

    /// Keeps malformed or stale cached bytes from making a mark disappear. The same initials
    /// rule is used for a relay that never published an icon and for a cache that cannot be
    /// decoded by the image framework.
    @ViewBuilder
    private var initials: some View {
        ZStack {
            Color.hiveAccent.opacity(Self.tint)
            Text(Self.initials(for: name))
                .font(.hive(.title3, weight: .semibold))
                .foregroundStyle(Color.hiveAccent)
        }
    }

    /// The tile a community with no icon sits on.
    ///
    /// This read ``PressFeedback/pressedFill`` until 2026-08-04, which was a coincidence of
    /// number rather than a shared idea: both wanted the accent laid on faintly, so one of them
    /// borrowed the other's constant. They then stopped agreeing — the press wash was taken to
    /// 0.08 so it could go back on a list row without being read as the resume mark — and this
    /// tile would have faded with it for no reason anyone asked for. **A resting surface and a
    /// press are not the same value and must not share one**; this is the strength that is
    /// right for a mark that is on screen the whole time.
    private static let tint: Double = 0.14

    /// Returns up to two uppercase initials, one for each of the first two name words.
    ///
    /// A one-word community such as JT's `Hive` therefore reads as `H`, while a name with
    /// two words remains distinguishable without shrinking the mark into a label. Exposed as
    /// a pure rule because rendered text is not a useful unit-test seam.
    nonisolated static func initials(for name: String) -> String {
        let words = name
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(2)
        let initials = words.compactMap { word in word.first(where: \.isLetter) }
        if !initials.isEmpty { return String(initials).uppercased() }
        return name.first(where: \.isLetter).map { String($0).uppercased() } ?? "?"
    }
}

/// A regular pointy-top hexagon, matching the `hexagon.fill` symbol used in the channel list.
///
/// `clipShape(.rect(cornerRadius:))` cannot express the community mark: its rounded corners
/// make an icon read like an avatar or a card. Keeping the path as a real `Shape` also means
/// both image and initials use exactly the same boundary at every size.
struct PointyHexagon: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()

        for index in 0 ..< 6 {
            let angle = (-90 + Double(index) * 60) * .pi / 180
            let point = CGPoint(
                x: center.x + radius * CGFloat(cos(angle)),
                y: center.y + radius * CGFloat(sin(angle))
            )
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }
}
