import Foundation

/// Plain, Sendable snapshot of a TipEntry — SwiftData model objects aren't
/// Sendable, so this is what actually crosses the await boundary below.
struct TipEntrySnapshot: Sendable {
    let date: Date
    let amountCents: Int
    let note: String?
}

enum InsightsError: LocalizedError {
    case missingAPIKey
    case notEnoughData
    case network(String)
    case api(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Insights isn't configured for this build."
        case .notEnoughData: "Log a few more shifts before analyzing patterns."
        case .network(let message): "Network error: \(message)"
        case .api(let message): message
        }
    }
}

/// The one place in the app that talks to the network. Opt-in only — this
/// runs solely when the user taps "Analyze My Tips," never automatically.
/// Uses a single app-wide key baked in at build time (see Secrets.local.xcconfig,
/// gitignored) — there is no per-user "bring your own key" option.
enum InsightsService {
    private static let recentWindowDays = 180
    private static let minimumEntries = 5

    private static var apiKey: String? {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "OpenAIAPIKey") as? String,
              !key.isEmpty
        else { return nil }
        return key
    }

    static func analyze(entries: [TipEntrySnapshot], scheduleFrequency: PayFrequency) async throws -> String {
        guard let apiKey else {
            throw InsightsError.missingAPIKey
        }
        guard entries.count >= minimumEntries else {
            throw InsightsError.notEnoughData
        }

        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .day, value: -recentWindowDays, to: .now) ?? .distantPast
        let recent = entries.filter { $0.date >= cutoff }.sorted { $0.date < $1.date }

        let rows: [[String: Any]] = recent.map { entry in
            let weekday = calendar.component(.weekday, from: entry.date)
            return [
                "date": entry.date.formatted(.iso8601.year().month().day()),
                "weekday": calendar.weekdaySymbols[weekday - 1],
                "amount": Double(entry.amountCents) / 100,
                "note": entry.note ?? ""
            ]
        }

        let payload: [String: Any] = [
            "pay_frequency": scheduleFrequency.displayName,
            "entries": rows
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let payloadString = String(data: payloadData, encoding: .utf8) ?? "{}"

        let systemPrompt = """
        You are a data analyst helping a restaurant server understand their tip income patterns. \
        You will receive their logged tip entries as JSON (date, weekday, amount in dollars, optional note). \
        Identify concrete patterns: which days of the week or dates in the month earn the most, any trend \
        over time, and one practical, specific observation they could act on. Be concise: 3 to 5 short \
        paragraphs or bullet points, plain language, no fluff, no disclaimers about being an AI.
        """

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-4o-mini",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": payloadString]
            ],
            "temperature": 0.3
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw InsightsError.network(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw InsightsError.network("No response from server.")
        }
        guard httpResponse.statusCode == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }
                .flatMap { $0["message"] as? String } ?? "Request failed (\(httpResponse.statusCode))."
            throw InsightsError.api(message)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw InsightsError.api("Couldn't read the response.")
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
