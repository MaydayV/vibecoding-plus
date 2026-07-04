import Foundation

/// Extracts numbered plan options from CLI assistant text.
/// Port of `extractPlanOptions()` in `archive/server/src/server.mjs`.
enum PlanOptionsExtractor {

    private static let maxOptions = 8

    static func extract(from text: String) -> [String] {
        let fromJSON = extractFromJSON(text)
        if !fromJSON.isEmpty { return fromJSON }

        let rawLines = text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !rawLines.isEmpty else { return [] }

        var checklist: [String] = []
        for line in rawLines {
            if let match = line.range(of: #"^[-*]\s*\[[ xX]\]\s+(.+)$"#, options: .regularExpression) {
                let captured = String(line[match]).replacingOccurrences(
                    of: #"^[-*]\s*\[[ xX]\]\s+"#, with: "", options: .regularExpression
                )
                checklist.append(captured)
            }
        }
        if !checklist.isEmpty {
            return collectUnique(checklist)
        }

        var numbered: [String] = []
        var inPlanSection = false
        for line in rawLines {
            if line.range(of: #"^(?:#{1,6}\s*)?(?:\*\*)?(?:plan|方案)(?:\*\*)?\s*[:：]?$"#, options: [.regularExpression, .caseInsensitive]) != nil {
                inPlanSection = true
                continue
            }
            if line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) != nil {
                inPlanSection = false
                continue
            }
            if let match = line.range(of: #"^\d+[.)]\s+(.+)$"#, options: .regularExpression),
               inPlanSection || !numbered.isEmpty {
                let captured = String(line[match]).replacingOccurrences(
                    of: #"^\d+[.)]\s+"#, with: "", options: .regularExpression
                )
                numbered.append(captured)
                continue
            }
            if inPlanSection,
               let match = line.range(of: #"^[-*]\s+(.+)$"#, options: .regularExpression) {
                let captured = String(line[match]).replacingOccurrences(
                    of: #"^[-*]\s+"#, with: "", options: .regularExpression
                )
                numbered.append(captured)
            }
        }

        return collectUnique(numbered)
    }

    // MARK: - Private

    private static func collectUnique(_ options: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for option in options {
            let normalized = normalize(option)
            guard !normalized.isEmpty else { continue }
            let key = normalized.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(normalized)
            if result.count >= maxOptions { break }
        }
        return result
    }

    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractFromJSON(_ text: String) -> [String] {
        let objects = extractJSONObjectStrings(from: text)
        var candidates: [String] = []
        for object in objects {
            guard let data = object.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            for key in ["plan", "Plan", "options", "planOptions"] {
                guard let array = json[key] as? [Any] else { continue }
                for item in array {
                    if let str = item as? String {
                        candidates.append(str)
                    } else if let dict = item as? [String: Any] {
                        candidates.append(flattenPlanObject(dict))
                    }
                }
            }
        }
        return collectUnique(candidates)
    }

    private static func flattenPlanObject(_ object: [String: Any]) -> String {
        for key in ["title", "name", "summary", "description", "text"] {
            if let value = object[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: object),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return ""
    }

    private static func extractJSONObjectStrings(from text: String) -> [String] {
        var results: [String] = []
        var depth = 0
        var start: String.Index?
        for index in text.indices {
            let ch = text[index]
            if ch == "{" {
                if depth == 0 { start = index }
                depth += 1
            } else if ch == "}" {
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0, let begin = start {
                    results.append(String(text[begin...index]))
                    start = nil
                }
            }
        }
        return results
    }
}
