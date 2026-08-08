import BuzzKit
import Foundation

// swiftlint:disable type_body_length
/// Serialises the parsed document tree into semantic HTML for ``MarkdownDocumentWebView``.
///
/// The markdown parser remains the only place syntax is understood. This type translates its
/// typed result: headings become headings, lists stay lists, and boxed content keeps the native
/// HTML layout that makes one web selection flow through the whole document.
enum MarkdownDocumentHTML {
    struct Palette {
        let colorScheme: String
        let background: String
        let foreground: String
        let secondary: String
        let border: String
        let codeGround: String
        let accent: String
    }

    static func document(for message: RichMessage, palette: Palette) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <!-- `user-scalable=no` is what turns off double-tap-to-zoom, which fires on the same
             gesture as double-tap-to-select-a-word and made selecting one impossible. WKWebView
             honours the limit (Safari has not since iOS 10) as long as nothing sets
             `ignoresViewportScaleLimits`. Nothing is lost by it: the document is laid out at
             `width=device-width` so it wraps rather than needing to be panned, and text size
             still follows the reader through `-apple-system-body`. -->
        <meta name="viewport"
              content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
        <style>\(baseCSS(palette))\(proseCSS(palette))\(boxedCSS(palette))</style>
        </head>
        <body>\(body(for: message))</body>
        </html>
        """
    }

    static func body(for message: RichMessage) -> String {
        var renderer = Renderer()
        return message.blocks.map { renderer.block($0) }.joined(separator: "\n")
    }

    private static func baseCSS(_ palette: Palette) -> String {
        """
        :root { color-scheme: \(palette.colorScheme); }
        * { box-sizing: border-box; }
        html, body { background: \(palette.background); }
        body {
          margin: 0;
          padding: 12px 20px 40px;
          color: \(palette.foreground);
          font: -apple-system-body;
          line-height: 1.5;
          overflow-wrap: anywhere;
          -webkit-text-size-adjust: 100%;
        }
        p, blockquote, ul, ol, pre, .table-scroll { margin: 0 0 16px; }
        .source-blank-line { height: 1.5em; }
        a { color: \(palette.accent); text-decoration: none; }
        a:active { text-decoration: underline; }
        ::selection { background: color-mix(in srgb, \(palette.accent) 35%, transparent); }
        """
    }

    private static func proseCSS(_ palette: Palette) -> String {
        """
        h1, h2, h3, h4, h5, h6 {
          margin: 24px 0 16px;
          font-weight: 600;
          line-height: 1.25;
        }
        h1 { font-size: 2em; }
        h2 { font-size: 1.5em; }
        h3 { font-size: 1.25em; }
        h4 { font-size: 1em; }
        h5 { font-size: .875em; }
        h6 { color: \(palette.secondary); font-size: .85em; }
        h1, h2 { padding-bottom: .3em; border-bottom: 1px solid \(palette.border); }
        h1:first-child, h2:first-child, h3:first-child { margin-top: 0; }
        ul, ol { padding-left: 2em; }
        li { padding-left: .25em; }
        li + li { margin-top: .25em; }
        li > ul, li > ol { margin-top: .25em; margin-bottom: 0; }
        blockquote {
          padding: 0 1em;
          color: \(palette.secondary);
          border-left: .25em solid \(palette.border);
        }
        """
    }

    private static func boxedCSS(_ palette: Palette) -> String {
        """
        code, pre { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
        code {
          padding: .15em .35em;
          border-radius: 6px;
          background: \(palette.codeGround);
          font-size: 85%;
        }
        pre {
          overflow-x: auto;
          padding: 16px;
          border-radius: 8px;
          background: \(palette.codeGround);
          line-height: 1.45;
          white-space: pre;
          overflow-wrap: normal;
        }
        pre code { padding: 0; background: transparent; font-size: 85%; }
        hr { height: 1px; margin: 24px 0; border: 0; background: \(palette.border); }
        .table-scroll { width: 100%; overflow-x: auto; }
        table { border-spacing: 0; border-collapse: collapse; width: max-content; min-width: 100%; }
        th, td { padding: 6px 13px; border: 1px solid \(palette.border); }
        th { font-weight: 600; }
        img, video { display: block; max-width: 100%; height: auto; margin: 0 0 16px; border-radius: 8px; }
        input { accent-color: \(palette.accent); }
        """
    }

    private struct Renderer {
        private var headingCounts: [String: Int] = [:]

        // Exhaustive serialization of the renderer-neutral block model.
        // swiftlint:disable:next cyclomatic_complexity
        mutating func block(_ block: RichBlock) -> String {
            switch block {
            case let .paragraph(text):
                return "<p>\(inline(text))</p>"
            case let .heading(level, text):
                let level = min(max(level, 1), 6)
                return "<h\(level) id=\"\(headingID(for: text))\">\(inline(text))</h\(level)>"
            case let .quote(blocks):
                let content: String
                if case let .paragraph(text)? = blocks.count == 1 ? blocks.first : nil {
                    content = inline(text)
                } else {
                    content = blocks.map { block($0) }.joined(separator: "\n")
                }
                return "<blockquote>\(content)</blockquote>"
            case let .code(code, info):
                let languageClass = info.map {
                    " class=\"language-\(attribute($0.highlightLanguage))\""
                } ?? ""
                return "<pre><code\(languageClass)>\(text(code))</code></pre>"
            case let .bulletList(items):
                return list(items, orderedStart: nil)
            case let .orderedList(start, items):
                return list(items, orderedStart: start)
            case let .table(table):
                return tableHTML(table)
            case .rule:
                return "<hr>"
            case .sourceBlankLine:
                return "<div class=\"source-blank-line\" aria-hidden=\"true\"></div>"
            case let .media(items):
                return items.map(media).joined(separator: "\n")
            case let .linkPreview(preview):
                return "<p><a href=\"\(attribute(preview.url.absoluteString))\">\(text(preview.title))</a></p>"
            }
        }

        private mutating func list(_ items: [RichListItem], orderedStart: Int?) -> String {
            let tag = orderedStart == nil ? "ul" : "ol"
            let start = orderedStart.map { $0 == 1 ? "" : " start=\"\($0)\"" } ?? ""
            let rows = items.map { item -> String in
                let marker = markerHTML(item.marker)
                let content: String
                if case let .paragraph(text)? = item.blocks.count == 1 ? item.blocks.first : nil {
                    content = inline(text)
                } else {
                    content = item.blocks.map { block($0) }.joined(separator: "\n")
                }
                return "<li>\(marker)\(content)</li>"
            }.joined(separator: "\n")
            return "<\(tag)\(start)>\n\(rows)\n</\(tag)>"
        }

        private func markerHTML(_ marker: RichListMarker?) -> String {
            guard let marker else { return "" }
            let checked: Bool
            let kind: String
            switch marker {
            case let .checkbox(value):
                checked = value
                kind = "checkbox"
            case let .radio(value):
                checked = value
                kind = "radio"
            }
            return "<input type=\"\(kind)\" disabled\(checked ? " checked" : "")> "
        }

        /// Every closure here declares `-> String`, and that is load-bearing rather than style.
        ///
        /// GRDB's `SQL` is `ExpressibleByStringInterpolation` and carries its own
        /// `joined(separator:) -> SQL` on `Collection where Element == SQL`. With the return type
        /// left to inference, `["<tr>…</tr>"].joined(separator: "\n")` type-checks as *either*
        /// `String` or `SQL`, and the solver picked `SQL` — which then interpolated into the
        /// surrounding literal as its own `description`, so every table in every document
        /// rendered as `SQL(elements: [GRDB.SQL.Element.sql("", []), …])` instead of rows. It
        /// compiles clean either way; only the output is wrong. ``list(_:orderedStart:)`` above
        /// already carries the same annotation for the same reason.
        private func tableHTML(_ table: RichTable) -> String {
            let header: String
            if table.hasHeader {
                let cells = table.header.enumerated().map { index, cell -> String in
                    "<th style=\"text-align:\(alignment(table.alignments[index]))\">\(inline(cell))</th>"
                }.joined()
                header = "<thead><tr>\(cells)</tr></thead>"
            } else {
                header = ""
            }
            let rows = table.rows.map { row -> String in
                let cells = row.enumerated().map { index, cell -> String in
                    "<td style=\"text-align:\(alignment(table.alignments[index]))\">\(inline(cell))</td>"
                }.joined()
                return "<tr>\(cells)</tr>"
            }.joined(separator: "\n")
            return "<div class=\"table-scroll\"><table>\(header)<tbody>\(rows)</tbody></table></div>"
        }

        private func alignment(_ alignment: RichTableAlignment) -> String {
            switch alignment {
            case .leading: "left"
            case .center: "center"
            case .trailing: "right"
            }
        }

        private func media(_ media: MessageMedia) -> String {
            let source = attribute(media.url)
            let alt = attribute(media.alt ?? "")
            switch media.kind {
            case .image:
                return "<img src=\"\(source)\" alt=\"\(alt)\">"
            case .video:
                let poster = media.posterURL.map { " poster=\"\(attribute($0))\"" } ?? ""
                return "<video controls preload=\"metadata\" src=\"\(source)\"\(poster)>\(alt)</video>"
            }
        }

        private func inline(_ attributed: AttributedString) -> String {
            attributed.runs.map { run in
                let visible = String(attributed[run.range].characters)
                if let imageURL = run.imageURL {
                    return "<img src=\"\(attribute(imageURL.absoluteString))\" alt=\"\(attribute(visible))\">"
                }

                var html = text(visible).replacingOccurrences(of: "\n", with: "<br>")
                let intent = run.inlinePresentationIntent
                if intent?.contains(.code) == true { html = "<code>\(html)</code>" }
                if intent?.contains(.stronglyEmphasized) == true { html = "<strong>\(html)</strong>" }
                if intent?.contains(.emphasized) == true { html = "<em>\(html)</em>" }
                if intent?.contains(.strikethrough) == true { html = "<del>\(html)</del>" }
                if run.underline == true { html = "<u>\(html)</u>" }
                if let link = run.link {
                    html = "<a href=\"\(attribute(link.absoluteString))\">\(html)</a>"
                }
                return html
            }.joined()
        }

        private mutating func headingID(for text: AttributedString) -> String {
            let base = slug(String(text.characters))
            let count = headingCounts[base, default: 0]
            headingCounts[base] = count + 1
            return count == 0 ? base : "\(base)-\(count)"
        }

        private func slug(_ value: String) -> String {
            var result = ""
            var pendingDash = false
            for scalar in value.lowercased().unicodeScalars {
                if CharacterSet.alphanumerics.contains(scalar) {
                    if pendingDash, !result.isEmpty { result.append("-") }
                    result.unicodeScalars.append(scalar)
                    pendingDash = false
                } else if CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar == "-" {
                    pendingDash = true
                }
            }
            return result.isEmpty ? "section" : result
        }

        private func text(_ value: String) -> String { escaped(value, quotes: false) }
        private func attribute(_ value: String) -> String { escaped(value, quotes: true) }

        /// Raw HTML is deliberately escaped here. Remote markdown never becomes executable
        /// markup; only the semantic nodes produced by the trusted parser can create elements.
        private func escaped(_ value: String, quotes: Bool) -> String {
            var result = value
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            if quotes {
                result = result
                    .replacingOccurrences(of: "\"", with: "&quot;")
                    .replacingOccurrences(of: "'", with: "&#39;")
            }
            return result
        }
    }
}
// swiftlint:enable type_body_length
