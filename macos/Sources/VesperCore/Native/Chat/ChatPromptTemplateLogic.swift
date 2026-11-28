import Foundation

/// Pure logic for reusable prompt templates / custom `/` and `#` commands.
public enum ChatPromptTemplateLogic {
    /// Normalizes a user-provided label or slug into a valid lowercase command trigger
    /// (letters, digits, hyphens, starting with a letter, max 48 characters).
    public static func normalizeSlug(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while s.hasPrefix("/") || s.hasPrefix("#") {
            s.removeFirst()
        }
        var out = ""
        var prevHyphen = false
        for scalar in s.unicodeScalars {
            if (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") {
                if out.isEmpty && !(scalar >= "a" && scalar <= "z") {
                    continue
                }
                out.unicodeScalars.append(scalar)
                prevHyphen = false
            } else if !out.isEmpty && !prevHyphen {
                out.append("-")
                prevHyphen = true
            }
            if out.count >= 48 { break }
        }
        while out.hasSuffix("-") {
            out.removeLast()
        }
        return out
    }

    /// Suggests a short title and slug from an existing chat message body.
    public static func suggestFromMessage(_ body: String) -> (title: String, slug: String) {
        let firstLine = body
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? "Saved Prompt"
        let cleanTitle = firstLine.count > 48
            ? String(firstLine.prefix(48)).trimmingCharacters(in: .whitespaces)
            : firstLine
        let words = cleanTitle
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(3)
            .joined(separator: "-")
        let slug = normalizeSlug(words)
        return (
            title: cleanTitle.isEmpty ? "Saved Prompt" : cleanTitle,
            slug: slug.isEmpty ? "saved-prompt" : slug
        )
    }

    /// Returns templates applicable to the current persona and space, deduplicating by slug
    /// in favor of the most specific scope: Persona+Space > Space > Persona > Personal.
    public static func applicableTemplates(
        _ templates: [API.PromptTemplate],
        personaId: String?,
        spaceId: String?
    ) -> [API.PromptTemplate] {
        let filtered = templates.filter { tpl in
            let pMatch = tpl.personaId?.value == nil || tpl.personaId?.value == personaId
            let sMatch = tpl.spaceId?.value == nil || tpl.spaceId?.value == spaceId
            return pMatch && sMatch
        }
        var bestBySlug: [String: API.PromptTemplate] = [:]
        for tpl in filtered {
            let key = tpl.slug.lowercased()
            if let existing = bestBySlug[key] {
                if specificityScore(tpl) > specificityScore(existing) {
                    bestBySlug[key] = tpl
                }
            } else {
                bestBySlug[key] = tpl
            }
        }
        return bestBySlug.values.sorted { a, b in
            if a.slug != b.slug { return a.slug < b.slug }
            return a.title < b.title
        }
    }

    /// Matches applicable templates for a completion query typed after `/` or `#`.
    public static func matchingTemplates(
        _ templates: [API.PromptTemplate],
        query: String,
        personaId: String?,
        spaceId: String?
    ) -> [API.PromptTemplate] {
        let pool = applicableTemplates(templates, personaId: personaId, spaceId: spaceId)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return pool }
        let prefix = pool.filter { $0.slug.lowercased().hasPrefix(q) }
        let contains = pool.filter { tpl in
            !tpl.slug.lowercased().hasPrefix(q)
                && (tpl.slug.lowercased().contains(q)
                    || tpl.title.lowercased().contains(q)
                    || tpl.description.lowercased().contains(q))
        }
        return prefix + contains
    }

    /// Parses a `#slug [arg]` single-line prompt template invocation (in addition to `/slug [arg]`).
    public static func parseHashTrigger(_ text: String) -> ChatParsedCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#"), !trimmed.hasPrefix("##"), !trimmed.contains("\n") else { return nil }
        let rest = trimmed.dropFirst()
        guard let first = rest.first, first.isASCII, first.isLetter else { return nil }
        var idx = rest.startIndex
        while idx < rest.endIndex {
            let ch = rest[idx]
            if ch.isASCII && (ch.isLetter || ch.isNumber || ch == "-") {
                idx = rest.index(after: idx)
            } else {
                break
            }
        }
        let name = String(rest[..<idx]).lowercased()
        guard !name.isEmpty else { return nil }
        if idx == rest.endIndex {
            return ChatParsedCommand(name: name, arg: "")
        }
        let sep = rest[idx]
        guard sep == " " || sep == "\t" else { return nil }
        let arg = String(rest[idx...]).trimmingCharacters(in: .whitespaces)
        return ChatParsedCommand(name: name, arg: arg)
    }

    /// Detects an active `#query` menu at the start of a single-line composer draft.
    public static func hashMenuQuery(for text: String) -> String? {
        guard text.hasPrefix("#"), !text.hasPrefix("##"), !text.contains("\n") else { return nil }
        let rest = text.dropFirst()
        if rest.contains(where: { $0 == " " || $0 == "\t" }) { return nil }
        let query = String(rest)
        guard query.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        return query
    }

    /// True if the template body references `{{input}}` (with optional whitespace inside braces).
    public static func hasInputPlaceholder(_ body: String) -> Bool {
        body.range(of: #"\{\{\s*input\s*\}\}"#, options: .regularExpression) != nil
    }

    /// Expands `{{input}}` and `{{clipboard}}` placeholders in a template body.
    /// If `input` is non-empty and the template has no `{{input}}` placeholder, appends it cleanly.
    public static func expand(body: String, input: String, clipboard: String?) -> String {
        let cleanInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanClipboard = (clipboard ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let hadInputPlaceholder = hasInputPlaceholder(body)

        var result = body.replacingOccurrences(
            of: #"\{\{\s*input\s*\}\}"#,
            with: cleanInput,
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\{\{\s*clipboard\s*\}\}"#,
            with: cleanClipboard,
            options: .regularExpression
        )
        if !hadInputPlaceholder && !cleanInput.isEmpty {
            result = result.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + cleanInput
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Human-readable scope badge for a template in the composer completion menu and Settings.
    public static func scopeLabel(
        template: API.PromptTemplate,
        personas: [API.Persona],
        spaces: [API.ChatSpace]
    ) -> String {
        let pName = template.personaId?.value.flatMap { pid in personas.first(where: { $0.id == pid })?.name }
        let sName = template.spaceId?.value.flatMap { sid in spaces.first(where: { $0.id == sid })?.name }
        switch (pName, sName) {
        case (let p?, let s?): return "\(p) · \(s)"
        case (let p?, nil): return p
        case (nil, let s?): return s
        case (nil, nil): return "Personal"
        }
    }

    private static func specificityScore(_ tpl: API.PromptTemplate) -> Int {
        var score = 0
        if tpl.personaId?.value != nil { score += 1 }
        if tpl.spaceId?.value != nil { score += 2 }
        return score
    }
}
