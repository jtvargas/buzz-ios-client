import SwiftUI

/// The mobile client's local One Light / One Dark syntax maps. Keeping the palette and
/// tokeniser separate means a future full parser can replace the scanner without
/// changing `RichCodeBlock` or its callers.
enum RichCodeTheme {
    case light
    case dark

    var keyword: Color { color(light: 0xA626A4, dark: 0xC678DD) }
    var type: Color { color(light: 0x0184BC, dark: 0x56B6C2) }
    var number: Color { color(light: 0x986801, dark: 0xD19A66) }
    var string: Color { color(light: 0x50A14F, dark: 0x98C379) }
    var comment: Color { color(light: 0xA0A1A7, dark: 0x5C6370) }
    var function: Color { color(light: 0x4078F2, dark: 0x61AFEF) }
    var classTitle: Color { color(light: 0xC18401, dark: 0xE5C07B) }
    var name: Color { color(light: 0xE45649, dark: 0xE06C75) }
    var plain: Color { color(light: 0x383A42, dark: 0xABB2BF) }

    private func color(light: UInt, dark: UInt) -> Color {
        let value = self == .light ? light : dark
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

enum RichCodeHighlighter {
    static let fontSize: CGFloat = 13

    /// Produces styled text for the eight languages actively used in Buzz channels.
    /// Unknown languages and incomplete strings/comment blocks deliberately receive no
    /// token styling, matching mobile's `highlight.parse` fallback rather than guessing.
    ///
    /// Memoised on `(code, language, theme)`. ``RichCodeBlock`` is a plain value view, so
    /// its body runs again every time the row holding it is re-evaluated — including the
    /// re-evaluations driven by traffic elsewhere in the channel — and a scan is a walk
    /// over the whole block. The scan is pure, so those three inputs can only ever
    /// produce this text.
    static func highlight(_ code: String, language: String?, theme: RichCodeTheme) -> AttributedString {
        let key = cacheKey(code, language: language, theme: theme)
        if let cached = cache.object(forKey: key) { return cached.text }
        let text = scan(code, language: language, theme: theme)
        cache.setObject(Memo(text), forKey: key, cost: code.utf8.count)
        return text
    }

    /// The memoised text for these inputs, or nil if they have not been scanned — or have
    /// been evicted since. Exists so a test can see the memo; nothing ships against it.
    static func memoisedText(_ code: String, language: String?, theme: RichCodeTheme) -> AttributedString? {
        cache.object(forKey: cacheKey(code, language: language, theme: theme))?.text
    }

    private static func scan(_ code: String, language: String?, theme: RichCodeTheme) -> AttributedString {
        guard let language = Language(language) else { return AttributedString(code) }
        var scanner = Scanner(code, language: language)
        guard let runs = scanner.runs() else { return AttributedString(code) }

        var output = AttributedString()
        for run in runs {
            var fragment = AttributedString(String(scanner.characters[run.range]))
            fragment.foregroundColor = color(for: run.kind, theme: theme)
            if run.kind == Token.comment {
                fragment.font = Font.hiveMono(fixedSize: fontSize, italic: true)
            }
            output.append(fragment)
        }
        return output
    }

    /// Bounded by the weight of the source it holds rather than by a count, since one
    /// long block costs what many short ones do. `NSCache` evicts under memory pressure
    /// on its own; a miss only costs the scan that used to run unconditionally.
    ///
    /// `nonisolated(unsafe)` because `NSCache` documents its own thread safety but is not
    /// annotated `Sendable`, so the compiler cannot see it. Both halves of the assertion
    /// hold here: the container synchronises its own access, and ``Memo`` is a `let` over
    /// a value type, so nothing reachable through it can be mutated after it is stored.
    /// This is a cache of a pure function — the worst a race could produce is the same
    /// text computed twice.
    nonisolated(unsafe) private static let cache: NSCache<NSString, Memo> = {
        let cache = NSCache<NSString, Memo>()
        cache.totalCostLimit = 1 << 20
        return cache
    }()

    /// The language is length-prefixed rather than separated by a delimiter, so the join
    /// cannot be spelled by the fields themselves — a fence body is arbitrary text and
    /// there is no character it is guaranteed not to contain. Two distinct inputs sharing
    /// a key would mean one block drawn in another's colours.
    private static func cacheKey(_ code: String, language: String?, theme: RichCodeTheme) -> NSString {
        let language = language ?? ""
        return "\(theme == .light ? "L" : "D")\(language.utf8.count):\(language)\(code)" as NSString
    }

    /// A reference box, because `NSCache` holds objects and `AttributedString` is a value.
    private final class Memo: Sendable {
        let text: AttributedString

        init(_ text: AttributedString) {
            self.text = text
        }
    }

    private static func color(for kind: Token, theme: RichCodeTheme) -> Color {
        switch kind {
        case .keyword: theme.keyword
        case .type: theme.type
        case .number: theme.number
        case .string: theme.string
        case .comment: theme.comment
        case .function: theme.function
        case .classTitle: theme.classTitle
        case .name: theme.name
        case .plain: theme.plain
        }
    }
}

private extension RichCodeHighlighter {
    enum Token: Equatable {
        case keyword, type, number, string, comment, function, classTitle, name, plain
    }

    struct Run {
        let range: Range<Int>
        let kind: Token
    }

    enum Language {
        case swift, javaScript, json, bash, python, rust, sql

        init?(_ raw: String?) {
            switch raw?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
            case "swift": self = .swift
            case "ts", "tsx", "js", "jsx", "javascript", "typescript":
                self = .javaScript
            case "json": self = .json
            case "sh", "bash", "zsh", "shell": self = .bash
            case "py", "python": self = .python
            case "rs", "rust": self = .rust
            case "sql", "sqlite", "postgresql": self = .sql
            default: return nil
            }
        }
    }

    struct Scanner {
        let characters: [Character]
        let language: Language
        private var position = 0
        private var classNameFollows = false

        init(_ source: String, language: Language) {
            characters = Array(source)
            self.language = language
        }

        mutating func runs() -> [Run]? {
            var output: [Run] = []
            var plainStart = 0

            func append(_ end: Int, _ token: Token) {
                if plainStart < position { output.append(Run(range: plainStart ..< position, kind: .plain)) }
                output.append(Run(range: position ..< end, kind: token))
                position = end
                plainStart = end
            }

            while position < characters.count {
                if let end = commentEnd() {
                    append(end, .comment)
                } else if blockCommentStartsHere() {
                    // An opener with no closer, handled exactly as an unterminated string
                    // is: give the whole block back unstyled rather than guess where the
                    // comment was meant to end. This is the branch the type's own
                    // documentation already claimed — "incomplete strings/comment blocks
                    // deliberately receive no token styling" — and without it the scanner
                    // read on past the opener and coloured the code around it.
                    return nil
                } else if let end = stringEnd() {
                    append(end, language == .json && nextNonWhitespace(after: end) == ":" ? .name : .string)
                } else if stringStartsHere() {
                    return nil
                } else if characters[position].isNumber {
                    append(numberEnd(), .number)
                } else if isIdentifierStart(characters[position]) {
                    let end = identifierEnd()
                    let word = String(characters[position ..< end])
                    append(end, token(for: word, endingAt: end))
                } else {
                    position += 1
                }
            }
            if plainStart < characters.count {
                output.append(Run(range: plainStart ..< characters.count, kind: .plain))
            }
            return output
        }

        private mutating func token(for word: String, endingAt end: Int) -> Token {
            let comparable = language == .sql ? word.uppercased() : word
            if keywords.contains(comparable) {
                classNameFollows = ["class", "struct", "enum", "interface"].contains(word.lowercased())
                return .keyword
            }
            if classNameFollows {
                classNameFollows = false
                return .classTitle
            }
            if literals.contains(comparable) || isType(word) { return .type }
            if nextNonWhitespace(after: end) == "(" { return .function }
            return language == .json && nextNonWhitespace(after: end) == ":" ? .name : .plain
        }

        private var keywords: Set<String> {
            switch language {
            case .swift: [
                "import", "let", "var", "func", "return", "if", "else", "guard", "for",
                "while", "in", "switch", "case", "class", "struct", "enum", "protocol",
                "extension", "public", "private", "internal", "async", "await", "throw",
                "throws", "try",
            ]
            case .javaScript: [
                "const", "let", "var", "function", "return", "if", "else", "for", "while",
                "import", "from", "export", "class", "interface", "type", "async", "await",
                "new", "switch", "case",
            ]
            case .json: []
            case .bash: ["if", "then", "else", "fi", "for", "in", "do", "done", "case", "esac", "function"]
            case .python: [
                "def", "class", "return", "if", "elif", "else", "for", "while", "in", "import",
                "from", "as", "try", "except", "with", "lambda", "async", "await",
            ]
            case .rust: [
                "fn", "let", "mut", "pub", "use", "mod", "struct", "enum", "impl", "trait",
                "match", "if", "else", "for", "while", "in", "return", "async", "await",
            ]
            case .sql: [
                "SELECT", "FROM", "WHERE", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "ON",
                "INSERT", "INTO", "UPDATE", "DELETE", "CREATE", "TABLE", "ALTER", "DROP",
                "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "AS", "AND", "OR", "NOT", "NULL",
            ]
            }
        }

        private var literals: Set<String> {
            language == .sql
                ? ["TRUE", "FALSE", "NULL"]
                : ["true", "false", "nil", "null", "None", "True", "False"]
        }

        private func isType(_ word: String) -> Bool {
            ["String", "Int", "Double", "Float", "Bool", "Array", "Dictionary", "Optional", "Void", "Any", "Self"]
                .contains(word)
                || (language != .json && word.first?.isUppercase == true)
        }

        private func commentEnd() -> Int? {
            let line = language == .bash || language == .python ? "#" : language == .sql ? "--" : "//"
            if starts(line) { return characters[position...].firstIndex(of: "\n") ?? characters.count }
            if language != .bash, language != .python, starts("/*") {
                guard let close = index(of: "*/", after: position + 2) else { return nil }
                return close + 2
            }
            return nil
        }

        /// Whether a `/* … */` opener sits at `position` in a language that has them.
        /// Only reached once ``commentEnd()`` has already declined, so in practice this
        /// is true exactly when the opener has no closer after it.
        private func blockCommentStartsHere() -> Bool {
            guard language != .bash, language != .python else { return false }
            return starts("/*")
        }

        private func stringStartsHere() -> Bool {
            guard position < characters.count else { return false }
            return characters[position] == "\""
                || characters[position] == "'"
                || (language == .javaScript && characters[position] == "`")
        }

        private func stringEnd() -> Int? {
            guard stringStartsHere() else { return nil }
            let quote = characters[position]
            var index = position + 1
            while index < characters.count {
                if characters[index] == "\\" { index += 2; continue }
                if characters[index] == quote { return index + 1 }
                index += 1
            }
            return nil
        }

        private func numberEnd() -> Int {
            var index = position
            while index < characters.count,
                  characters[index].isNumber || ".xXaAbBcCdDeEfF+-".contains(characters[index]) {
                index += 1
            }
            return index
        }

        private func identifierEnd() -> Int {
            var index = position
            while index < characters.count, isIdentifierPart(characters[index]) { index += 1 }
            return index
        }

        private func nextNonWhitespace(after index: Int) -> Character? {
            characters[index...].first { !$0.isWhitespace }
        }

        private func starts(_ text: String) -> Bool {
            let candidate = Array(text)
            guard position + candidate.count <= characters.count else { return false }
            return characters[position ..< position + candidate.count].elementsEqual(candidate)
        }

        private func index(of text: String, after index: Int) -> Int? {
            let candidate = Array(text)
            // The bound has to be checked against `index`, not against the source: an
            // opener found in the last few characters leaves a start position past the
            // last place a closer could begin, and `index ... last` is then inverted —
            // a trap rather than a nil. `starts("/*")` needs only two characters to
            // match, so `a/*b` reaches here with nowhere left to search.
            let last = characters.count - candidate.count
            guard index <= last else { return nil }
            return (index ... last).first { start in
                characters[start ..< start + candidate.count].elementsEqual(candidate)
            }
        }

        private func isIdentifierStart(_ character: Character) -> Bool {
            character.isLetter || character == "_"
        }
        private func isIdentifierPart(_ character: Character) -> Bool {
            isIdentifierStart(character) || character.isNumber
        }
    }
}
