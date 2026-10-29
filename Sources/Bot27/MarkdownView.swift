import SwiftUI

/// Lightweight Markdown: fenced code, headings, lists, tables, and inline styles.
struct MarkdownView: View {
    let text: String

    enum Block {
        case paragraph(String)
        case heading(String, level: Int)
        case item(String, marker: String)
        case code(String, lang: String)
        case table(header: [String], rows: [[String]])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(Self.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case let .paragraph(s):
                    Text(Self.inline(s)).font(.system(size: 14.5)).lineSpacing(3)
                case let .heading(s, level):
                    Text(Self.inline(s))
                        .font(.system(size: level == 1 ? 19 : level == 2 ? 17 : 15, weight: .semibold))
                        .padding(.top, 2)
                case let .item(s, marker):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker).foregroundStyle(Theme.secondary).frame(minWidth: 14, alignment: .trailing)
                        Text(Self.inline(s)).lineSpacing(3)
                    }
                    .font(.system(size: 14.5))
                case let .code(_, lang) where lang == ConnectSpec.fence:
                    Label("Asking to connect…", systemImage: "link")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondary)
                case let .code(_, lang) where lang == MemorySpec.fence:
                    Label("Remembering…", systemImage: "brain")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondary)
                case let .code(_, lang) where lang == JobSpec.fence:
                    // Replaced by a card once the reply finishes.
                    Label("Setting up…", systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondary)
                case let .code(code, lang):
                    CodeBlock(code: code, lang: lang)
                case let .table(header, rows):
                    TableBlock(header: header, rows: rows)
                }
            }
        }
        .foregroundStyle(Theme.text)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]? = nil
        var lang = ""

        var tableLines: [String] = []

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }

        // A table is a header row, a |---| separator, then body rows. Anything else stays text.
        func flushTable() {
            defer { tableLines = [] }
            guard tableLines.count >= 2, isSeparator(tableLines[1]) else {
                paragraph += tableLines
                return
            }
            flush()
            let header = cells(tableLines[0])
            let rows = tableLines.dropFirst(2).map { row in
                let c = cells(row)
                return Array((c + Array(repeating: "", count: max(0, header.count - c.count))).prefix(header.count))
            }
            blocks.append(.table(header: header, rows: rows))
        }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if code == nil, line.hasPrefix("|") {
                tableLines.append(line)
                continue
            }
            flushTable()
            if line.hasPrefix("```") {
                if let body = code {
                    blocks.append(.code(body.joined(separator: "\n"), lang: lang))
                    code = nil
                } else {
                    flush()
                    code = []
                    lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            if code != nil { code!.append(raw); continue }

            if line.isEmpty {
                flush()
            } else if let m = line.firstMatch(of: #/^(#{1,6})\s+(.*)$/#) {
                flush()
                blocks.append(.heading(String(m.2), level: m.1.count))
            } else if let m = line.firstMatch(of: #/^[-*+]\s+(.*)$/#) {
                flush()
                blocks.append(.item(String(m.1), marker: "•"))
            } else if let m = line.firstMatch(of: #/^(\d+)[.)]\s+(.*)$/#) {
                flush()
                blocks.append(.item(String(m.2), marker: "\(m.1)."))
            } else {
                paragraph.append(raw)
            }
        }
        flushTable()
        if let body = code { blocks.append(.code(body.joined(separator: "\n"), lang: lang)) }
        flush()
        return blocks
    }

    static func isSeparator(_ line: String) -> Bool {
        let c = cells(line)
        return !c.isEmpty && c.allSatisfy { $0.wholeMatch(of: #/:?-+:?/#) != nil }
    }

    static func cells(_ line: String) -> [String] {
        var s = Substring(line)
        if s.hasPrefix("|") { s = s.dropFirst() }
        if s.hasSuffix("|") { s = s.dropLast() }
        return s.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

struct TableBlock: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                    self.cell(cell).fontWeight(.semibold)
                }
            }
            .background(Color.black.opacity(0.04))
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        self.cell(cell)
                    }
                }
            }
        }
        .background(Theme.codeBg)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }

    private func cell(_ s: String) -> some View {
        Text(MarkdownView.inline(s))
            .font(.system(size: 13.5))
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CodeBlock: View {
    let code: String
    let lang: String
    @State private var copied = false
    @State private var expanded = false

    private static let foldedLines = 20

    private var lines: [Substring] { code.split(separator: "\n", omittingEmptySubsequences: false) }
    private var long: Bool { lines.count > Self.foldedLines + 5 }
    private var shown: String {
        long && !expanded ? lines.prefix(Self.foldedLines).joined(separator: "\n") : code
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(lang.isEmpty ? "code" : lang)
                Spacer()
                if long {
                    Button {
                        expanded.toggle()
                    } label: {
                        Label(expanded ? "Show less" : "Show all \(lines.count) lines",
                              systemImage: expanded ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    copyToPasteboard(code)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.plain)
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.04))

            ScrollView(.horizontal) {
                Text(shown)
                    .font(.system(size: 13, design: .monospaced))
                    .lineSpacing(3)
                    .padding(14)
            }
        }
        .background(Theme.codeBg)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }
}
