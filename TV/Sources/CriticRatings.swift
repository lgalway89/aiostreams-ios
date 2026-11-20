import SwiftUI

/// Rotten Tomatoes, Metacritic and Letterboxd scores for a title, from PublicMetaDB: the free
/// source AIOMetadata's critic ratings use (addon/lib/ratingProviders/publicMetaDb.ts), read by
/// the title's TMDB id. No key; one small request per title, kept for the app's session.
actor CriticRatings {
    static let shared = CriticRatings()

    struct Score: Hashable {
        /// tomatoes, tomatoesAudience, metacritic, letterboxd
        let source: String
        /// Out of 100.
        let value: Double
    }

    private var cache: [String: [Score]] = [:]
    private var inflight: [String: Task<[Score], Never>] = [:]

    private static let labels = ["RT": "tomatoes", "PC": "tomatoesAudience", "MC": "metacritic", "LB": "letterboxd"]
    private static let order = ["tomatoes", "tomatoesAudience", "metacritic", "letterboxd"]

    func scores(tmdbId: String, series: Bool) async -> [Score] {
        let key = "\(series ? "tv" : "movie"):\(tmdbId)"
        if let known = cache[key] { return known }
        if let running = inflight[key] { return await running.value }
        let task = Task { await Self.fetch(tmdbId: tmdbId, kind: series ? "tv" : "movie") }
        inflight[key] = task
        let found = await task.value
        inflight[key] = nil
        cache[key] = found
        return found
    }

    private static func fetch(tmdbId: String, kind: String) async -> [Score] {
        guard Int(tmdbId) != nil else { return [] }
        let filter = "(media_type=\"\(kind)\" && (tmdb_id=\(tmdbId))) && label!~\"overall\""
        var parts = URLComponents(string: "https://api.publicmetadb.com/api/collections/ratings/records")!
        parts.queryItems = [
            URLQueryItem(name: "perPage", value: "100"),
            URLQueryItem(name: "skipTotal", value: "1"),
            URLQueryItem(name: "fields", value: "label,score,updated"),
            URLQueryItem(name: "filter", value: filter),
        ]
        guard let url = parts.url else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("AIOStreams-tvOS (critic ratings)", forHTTPHeaderField: "User-Agent")
        struct Row: Decodable {
            let label: String?
            let score: Double?
            let updated: String?
        }
        struct Page: Decodable { let items: [Row]? }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let page = try? JSONDecoder().decode(Page.self, from: data) else { return [] }
        // Sources can be listed more than once: the value most rows agree on, the newest on a tie.
        var tally: [String: [Double: (count: Int, latest: String)]] = [:]
        for row in page.items ?? [] {
            guard let label = row.label?.trimmingCharacters(in: .whitespaces).uppercased(),
                  let source = labels[label], let score = row.score, score > 0, score <= 100 else { continue }
            let value = (score * 10).rounded() / 10
            var seen = tally[source]?[value] ?? (0, "")
            seen.count += 1
            seen.latest = max(seen.latest, row.updated ?? "")
            tally[source, default: [:]][value] = seen
        }
        return order.compactMap { source in
            guard let best = tally[source]?.max(by: { a, b in
                a.value.count != b.value.count ? a.value.count < b.value.count : a.value.latest < b.value.latest
            }) else { return nil }
            return Score(source: source, value: best.key)
        }
    }
}

/// The critic scores in a line of facts: `🍅 96%  🍿 87%  MC 96  LB 4.2`.
struct CriticScoresView: View {
    let item: Item
    @State private var scores: [CriticRatings.Score] = []

    private var tmdbId: String? {
        guard let ids = item.providerIds else { return nil }
        return ids.first { $0.key.lowercased() == "tmdb" }?.value
    }

    var body: some View {
        HStack(spacing: Theme.px(10)) {
            ForEach(scores, id: \.source) { score in
                HStack(spacing: Theme.px(4)) {
                    Text(Self.mark(score))
                        .font(Theme.font(Theme.xs, .bold))
                        .foregroundStyle(Self.colour(score))
                    Text(Self.text(score))
                }
            }
        }
        .task(id: "\(item.id):\(tmdbId ?? "")") {
            guard let tmdbId, !item.isEpisode else { scores = []; return }
            let found = await CriticRatings.shared.scores(tmdbId: tmdbId, series: item.isSeries)
            if !Task.isCancelled { scores = found }
        }
    }

    private static func mark(_ score: CriticRatings.Score) -> String {
        switch score.source {
        case "tomatoes": return score.value >= 60 ? "🍅" : "🤢"
        case "tomatoesAudience": return "🍿"
        case "metacritic": return "MC"
        default: return "LB"
        }
    }

    private static func colour(_ score: CriticRatings.Score) -> Color {
        switch score.source {
        case "metacritic":
            return score.value >= 61 ? Color(red: 0.4, green: 0.8, blue: 0.2)
                : score.value >= 40 ? Color(red: 1, green: 0.8, blue: 0.2) : Color(red: 1, green: 0, blue: 0)
        case "letterboxd": return Color(red: 0, green: 0.88, blue: 0.33)
        default: return .white
        }
    }

    private static func text(_ score: CriticRatings.Score) -> String {
        switch score.source {
        case "tomatoes", "tomatoesAudience": return "\(Int(score.value.rounded()))%"
        case "letterboxd": return String(format: "%.1f", score.value / 20)
        default: return "\(Int(score.value.rounded()))"
        }
    }
}
