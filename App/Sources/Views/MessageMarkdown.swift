import Foundation

/// One drawable piece of a message.
///
/// The split into blocks exists because `AttributedString(markdown:)` — the
/// only markdown parser here, since the project vendors nothing it can do
/// without — is excellent at inline syntax and unusable at block syntax. Asked
/// for full syntax it turns a fenced block into a presentation intent that
/// `Text` then discards, so the code arrives as ordinary prose with its
/// backticks stripped and its newlines collapsed onto one line. Blocks are
/// therefore found here, and the styling *inside* each one is still left to
/// AttributedString.
enum MessageBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case quote(String)
    case list(ordered: Bool, items: [MessageListItem])
    case code(language: String?, code: String)
    case rule
}

struct MessageListItem: Equatable {
    /// What is drawn in the marker column: the model's own "3." for an ordered
    /// list, a bullet for an unordered one. Ordered markers are copied rather
    /// than renumbered — a model that writes 1. 1. 1. usually means it.
    var marker: String
    var text: String
    /// Nesting depth, from the line's own indentation.
    var depth: Int
}

enum MessageMarkdown {
    /// Splits a message into blocks.
    ///
    /// Two properties matter more than completeness here, because this runs on
    /// a half-arrived message every time a token lands:
    ///
    /// - It is one forward pass. Every block but the last is decided by a
    ///   prefix of the text, so nothing already on screen can re-style itself
    ///   when more text arrives.
    /// - An opening fence with no closing fence yet is a code block that runs
    ///   to the end of the text. The tempting alternative — the non-greedy
    ///   ```…``` match the browser chat page uses — leaves a half-written block
    ///   as a paragraph full of backticks and asterisks until the closing fence
    ///   lands, at which point the whole reply reflows. Code that arrives as
    ///   code stays code.
    static func blocks(of text: String) -> [MessageBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MessageBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var items: [MessageListItem] = []
        var itemsAreOrdered = false

        // Only ever one of the three is filling at a time; each branch below
        // closes the others before it starts.
        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
            if !quote.isEmpty {
                blocks.append(.quote(quote.joined(separator: "\n")))
                quote = []
            }
            if !items.isEmpty {
                blocks.append(.list(ordered: itemsAreOrdered, items: items))
                items = []
            }
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            // The last element is the only line still being written: every
            // earlier one was ended by a newline the model has committed to.
            let isUnfinished = index == lines.count - 1
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            // "``" is one keystroke short of a fence, "2." one short of a list
            // item, "#" one short of a heading. Drawing the raw characters and
            // replacing them a token later is exactly the flicker this file
            // exists to prevent, so a delimiter that is still being typed waits
            // until it means something.
            if isUnfinished, isUnfinishedMarker(trimmed) { break }

            if let fence = Fence(opening: trimmed) {
                flush()
                var body: [String] = []
                var scan = index + 1
                var closed = false
                while scan < lines.count {
                    if fence.closes(lines[scan].trimmingCharacters(in: .whitespacesAndNewlines)) {
                        closed = true
                        break
                    }
                    body.append(lines[scan])
                    scan += 1
                }
                blocks.append(.code(
                    // The language is withheld until the fence line ends,
                    // because one read mid-word relabels itself on every token:
                    // s, sw, swi, swif, swift.
                    language: isUnfinished ? nil : fence.language,
                    // A trailing newline is a line the model has not written
                    // yet; rendering it grows the box by a blank row and then
                    // fills it, which reads as a twitch.
                    code: droppingTrailingNewlines(body.joined(separator: "\n"))
                ))
                index = closed ? scan + 1 : lines.count
                continue
            }

            if trimmed.isEmpty {
                flush()
                index += 1
                continue
            }

            if isThematicBreak(trimmed) {
                flush()
                blocks.append(.rule)
                index += 1
                continue
            }

            if let heading = heading(trimmed) {
                flush()
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                if !paragraph.isEmpty || !items.isEmpty { flush() }
                var content = String(trimmed.dropFirst())
                if content.hasPrefix(" ") { content.removeFirst() }
                quote.append(content)
                index += 1
                continue
            }

            if let entry = listItem(line) {
                if !paragraph.isEmpty || !quote.isEmpty { flush() }
                if !items.isEmpty, itemsAreOrdered != entry.ordered { flush() }
                itemsAreOrdered = entry.ordered
                items.append(entry.item)
                index += 1
                continue
            }

            // An indented line under a list item is that item's second line,
            // not a paragraph that has escaped the list.
            if !items.isEmpty, line.hasPrefix("  ") {
                items[items.count - 1].text += "\n" + trimmed
                index += 1
                continue
            }

            if !quote.isEmpty || !items.isEmpty { flush() }
            paragraph.append(line)
            index += 1
        }

        flush()
        return blocks
    }

    // MARK: - Line shapes

    private struct Fence {
        let marker: Character
        let length: Int
        let language: String?

        init?(opening line: String) {
            guard let first = line.first, first == "`" || first == "~" else { return nil }
            let run = line.prefix { $0 == first }
            guard run.count >= 3 else { return nil }
            marker = first
            length = run.count
            let info = line.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
            language = info.split(separator: " ").first.map(String.init)
        }

        func closes(_ line: String) -> Bool {
            guard let first = line.first, first == marker else { return false }
            return line.count >= length && line.allSatisfy { $0 == marker }
        }
    }

    /// Whether a line is the beginning of a block marker and nothing else yet.
    /// Every one of these becomes a block as soon as the next character lands,
    /// so the cost of waiting is one token and the cost of not waiting is a
    /// line of prose that turns into something else while it is being read.
    private static func isUnfinishedMarker(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        if first == "`" { return line.count < 3 && line.allSatisfy { $0 == "`" } }
        if first == "#" { return line.count <= 6 && line.allSatisfy { $0 == "#" } }
        if "-*+".contains(first) { return line.count == 1 }
        guard first.isNumber else { return false }
        // Digits alone are never held back: a model asked for a number answers
        // with one, and a reply that ends on "42" must not wait for a character
        // that is never coming.
        let rest = line.drop { $0.isNumber }
        return rest == "." || rest == ")"
    }

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count)
        // CommonMark wants a space, and so do we: "#1" and "#swift" are things
        // models write in prose.
        guard rest.first == " " else { return nil }
        return (hashes.count, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        let bare = line.filter { !$0.isWhitespace }
        guard bare.count >= 3, let first = bare.first, "-*_".contains(first) else { return false }
        return bare.allSatisfy { $0 == first }
    }

    private static func listItem(_ line: String) -> (item: MessageListItem, ordered: Bool)? {
        var indent = 0
        var rest = Substring(line)
        while let character = rest.first, character == " " || character == "\t" {
            indent += character == "\t" ? 4 : 1
            rest = rest.dropFirst()
        }
        let depth = min(indent / 2, 3)

        if let marker = rest.first, "-*+".contains(marker) {
            let body = rest.dropFirst()
            // "**Note**" starts with a bullet character and is not a bullet.
            guard body.first == " " else { return nil }
            let item = MessageListItem(
                marker: bullet(atDepth: depth),
                text: body.trimmingCharacters(in: .whitespaces),
                depth: depth
            )
            return (item, false)
        }

        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let afterDigits = rest.dropFirst(digits.count)
        guard let punctuation = afterDigits.first, punctuation == "." || punctuation == ")" else { return nil }
        let body = afterDigits.dropFirst()
        guard body.first == " " else { return nil }
        let item = MessageListItem(
            marker: "\(digits)\(punctuation)",
            text: body.trimmingCharacters(in: .whitespaces),
            depth: depth
        )
        return (item, true)
    }

    private static func bullet(atDepth depth: Int) -> String {
        switch depth {
        case 0: "•"
        case 1: "◦"
        default: "▪"
        }
    }

    private static func droppingTrailingNewlines(_ code: String) -> String {
        var code = code
        while code.hasSuffix("\n") { code.removeLast() }
        return code
    }

    /// Closes an inline span the model has not finished yet.
    ///
    /// Without this a half-typed `` `identifier` `` shows its own backtick as
    /// prose for as long as the word takes to arrive and then snaps into code
    /// when the closing one lands — the same flicker the block split avoids,
    /// one line further down. Only code delimiters get this treatment: a
    /// dangling `**` could be emphasis or two asterisks, but a dangling
    /// backtick is never anything but code.
    static func closingUnfinishedCode(_ prose: String) -> String {
        guard !prose.hasSuffix("`") else { return prose }
        var runs: [Int] = []
        var run = 0
        for character in prose {
            if character == "`" {
                run += 1
            } else if run > 0 {
                runs.append(run)
                run = 0
            }
        }
        if run > 0 { runs.append(run) }
        guard !runs.count.isMultiple(of: 2), let opening = runs.last else { return prose }
        return prose + String(repeating: "`", count: opening)
    }
}
