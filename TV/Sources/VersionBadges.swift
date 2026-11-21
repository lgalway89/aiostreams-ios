import SwiftUI

// The web app's version badges (lib/badges.ts): rules saved in its synced settings under
// `versionBadges`, each a pattern matched without regard to case against the version's text,
// shown as a coloured pill on the versions that match.

struct VersionBadge: Hashable {
    var label: String
    var color: Color?
    var background: Color?
    var border: Color?
}

struct VersionBadges {
    private struct Rule {
        var badge: VersionBadge
        var regex: NSRegularExpression
        var anchored: Bool
        var group: String?
    }

    private var rules: [Rule] = []

    init(_ raw: String?) {
        guard let raw, let data = raw.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let badges = parsed["badges"] as? [[String: Any]] else { return }
        let color = { (value: Any?) -> Color? in JSON.color(value).map(Color.init) }
        rules = badges.compactMap { entry in
            guard let label = (entry["label"] as? String)?.trimmingCharacters(in: .whitespaces), !label.isEmpty,
                  let match = (entry["match"] as? String)?.trimmingCharacters(in: .whitespaces), !match.isEmpty,
                  // A badge limited to some fields is left to the web app.
                  (entry["fields"] as? [Any])?.isEmpty ?? true,
                  let regex = try? NSRegularExpression(pattern: match, options: [.caseInsensitive])
            else { return nil }
            return Rule(badge: VersionBadge(label: label, color: color(entry["color"]),
                                            background: color(entry["background"]), border: color(entry["border"])),
                        regex: regex, anchored: match.contains("^") || match.contains("$"),
                        group: entry["group"] as? String)
        }
    }

    var isEmpty: Bool { rules.isEmpty }

    /// In list order, skipping a repeated label and all but the first of a group.
    func matching(_ source: MediaSource) -> [VersionBadge] {
        guard !rules.isEmpty else { return [] }
        let a = source.aiostreams
        let parts = [a?.name ?? source.name, a?.description, a?.filename, a?.resolution, a?.releaseGroup]
            .compactMap { $0 }
            + [a?.quality, a?.encode, a?.visualTags, a?.audioTags, a?.audioChannels, a?.languages, a?.editions]
            .flatMap { $0?.values ?? [] }
        let lines = parts.flatMap { $0.components(separatedBy: .newlines) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let all = lines.joined(separator: " ")
        let found = { (regex: NSRegularExpression, text: String) in
            regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        var seen = Set<String>(), groups = Set<String>(), shown: [VersionBadge] = []
        for rule in rules {
            let key = rule.badge.label.lowercased()
            if seen.contains(key) { continue }
            if let group = rule.group, groups.contains(group) { continue }
            guard found(rule.regex, all) || (rule.anchored && lines.contains { found(rule.regex, $0) }) else { continue }
            seen.insert(key)
            if let group = rule.group { groups.insert(group) }
            shown.append(rule.badge)
        }
        return shown
    }
}

/// Text with every 📒 (the server's mark for its own copy, My Library) drawn as a folder symbol in
/// `folder`, since no yellow folder emoji exists to send.
func folderMarked(_ text: String, folder: Color) -> Text {
    let parts = text.components(separatedBy: "📒")
    var out = Text(parts[0])
    for part in parts.dropFirst() {
        out = out + Text(Image(systemName: "folder.fill")).foregroundColor(folder) + Text(part)
    }
    return out
}

/// One badge as a small pill, in its own colours.
struct VersionBadgePill: View {
    let badge: VersionBadge

    var body: some View {
        folderMarked(badge.label, folder: badge.color ?? .white)
            .font(Theme.font(Theme.sm, .semibold))
            .foregroundStyle(badge.color ?? .white)
            .padding(.horizontal, Theme.px(8))
            .padding(.vertical, Theme.px(2))
            .background(Capsule().fill(badge.background ?? Color.white.opacity(0.12)))
            .overlay(Capsule().stroke(badge.border ?? .clear, lineWidth: Theme.px(1)))
            .lineLimit(1)
    }
}
