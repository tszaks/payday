import Foundation

/// One labeled block in the Insights screen, e.g. "Top Earning Days" + body.
struct InsightSection: Codable, Identifiable, Equatable, Sendable {
    let title: String
    let body: String
    var id: String { title }
}

private struct InsightsNarration: Decodable {
    let sections: [InsightSection]
}

/// Raw shape of an OpenAI Responses API reply. Deliberately walks the
/// `output` array rather than assuming `output[0].content[0]` — OpenAI's own
/// docs warn that position isn't guaranteed (reasoning-token items, tool
/// calls, etc. can share the array).
private struct ResponsesEnvelope: Decodable {
    struct OutputItem: Decodable {
        let type: String
        let content: [ContentItem]?
    }
    struct ContentItem: Decodable {
        let type: String
        let text: String?
    }
    let output: [OutputItem]

    var outputText: String? {
        output.first(where: { $0.type == "message" })?.content?
            .first(where: { $0.type == "output_text" })?.text
    }
}

enum InsightsError: LocalizedError {
    case notEnoughData
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notEnoughData: "Log a few more shifts before analyzing patterns."
        case .generationFailed(let message): message
        }
    }
}

/// Narrates facts the stats engine already computed — never does arithmetic
/// itself, never sees raw entries. Calls OpenAI's gpt-5.6-terra over the
/// network; InsightsView falls back to InsightsFactsCopy's deterministic
/// sections whenever this fails (no key, no network, rate limited) — the
/// facts "must stand alone anyway."
enum InsightsService {
    private static let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    private static let model = "gpt-5.6-terra"

    private static var apiKey: String {
        Bundle.main.object(forInfoDictionaryKey: "OpenAIAPIKey") as? String ?? ""
    }

    static var isConfigured: Bool {
        !apiKey.isEmpty
    }

    /// `previousSections` is the last narration shown, if any — passed back
    /// in so each refresh amends it rather than rewriting from scratch.
    /// Wording should settle down and change less over time as patterns
    /// stabilize, not reshuffle on every call.
    static func narrate(facts: InsightsFacts, scheduleFrequency: PayFrequency, previousSections: [InsightSection]?) async throws -> [InsightSection] {
        guard isConfigured else {
            throw InsightsError.generationFailed("No OpenAI API key configured.")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "instructions": instructions,
            "input": promptDescription(for: facts, scheduleFrequency: scheduleFrequency, previousSections: previousSections),
            "reasoning": ["effort": "low"],
            "text": ["format": responseFormat]
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw InsightsError.generationFailed("OpenAI request failed (\(message.prefix(200))).")
        }

        guard let outputText = try JSONDecoder().decode(ResponsesEnvelope.self, from: data).outputText,
              let jsonData = outputText.data(using: .utf8)
        else {
            throw InsightsError.generationFailed("Couldn't read the analysis.")
        }

        let narration = try JSONDecoder().decode(InsightsNarration.self, from: jsonData)
        guard !narration.sections.isEmpty else {
            throw InsightsError.generationFailed("Couldn't read the analysis.")
        }
        return narration.sections
    }

    // Immutable literal, never mutated after init — safe to exempt from
    // Sendable checking, same as every other static-literal-dict case here.
    nonisolated(unsafe) private static let responseFormat: [String: Any] = [
        "type": "json_schema",
        "name": "insights_narration",
        "strict": true,
        "schema": [
            "type": "object",
            "properties": [
                "sections": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "title": ["type": "string"],
                            "body": ["type": "string"]
                        ],
                        "required": ["title", "body"],
                        "additionalProperties": false
                    ]
                ]
            ],
            "required": ["sections"],
            "additionalProperties": false
        ]
    ]

    private static let instructions = """
        You are a calm, precise analyst summarizing a restaurant server's tip data for them in \
        plain conversational sentences - not a cheerleader, not a hype coach. Flat, neutral, \
        matter-of-fact delivery, the way a bank statement summary reads, just in plain English \
        instead of financial jargon. \

        Absolute rule, no exceptions: never use an exclamation point. Never say "great job," \
        "nice work," "solid," "awesome," or express excitement or praise of any kind. State \
        each fact plainly and move on. If you catch yourself about to end a sentence with "!", \
        end it with "." instead. \

        You'll be given tip facts already computed - dates, dollar amounts, and counts. Never \
        invent a number that wasn't given to you, and never do any math of your own; just \
        narrate the facts you're handed. \

        You'll always get an OVERALL fact and a CASH VS CREDIT fact - always turn each into \
        its own section. TOP EARNING DAYS, LUNCH VS DINNER, and DOUBLES VS SOLO facts are only \
        included when there's real data for them - turn each into its own section only when \
        present, in the order given. Ignore the pay frequency line entirely when deciding what \
        sections to write - it's background context for your own understanding, never a topic \
        of its own. After all given facts are covered, add exactly one final section that's a \
        concrete, actionable suggestion based on them - practical, not motivational. \

        Each title is 2 to 4 words (e.g. "Overall Snapshot", "Top Earning Days", "Cash vs \
        Credit", "Lunch vs Dinner", "Doubles vs Solo", "What To Try Next"). Each body is 2 to \
        4 short sentences, no markdown formatting, no bullet characters, no disclaimers about \
        being an AI. \

        Never say "entries," "data points," "dataset," or "logged" - if you need to name the \
        unit, say "shifts" or "days," but usually you don't need to name it at all: just talk \
        about the money. Say "you made $488 from credit tips versus $288 from cash" instead of \
        "credit tips totaled $488 across five entries." \

        You are usually asked to AMEND a previous analysis, not write a new one. When a \
        previous analysis is given: keep every section and every sentence that is still \
        accurate, word for word - do not rephrase something that hasn't changed just to sound \
        fresh. Only touch a section whose underlying numbers actually moved, and change only \
        what needs to change to make it accurate again. Only add or remove a section if a fact \
        newly appeared or newly dropped out. The longer someone's history gets, the less any of \
        this should move - a stable pattern should read as the same paragraph week after week, \
        not a rewrite. If no previous analysis is given, write one fresh, following every rule \
        above.
        """

    private static func promptDescription(for facts: InsightsFacts, scheduleFrequency: PayFrequency, previousSections: [InsightSection]?) -> String {
        var lines = [
            "BACKGROUND CONTEXT, NOT A SECTION - pay frequency: \(scheduleFrequency.displayName).",
            "OVERALL: \(Money.string(fromCents: facts.totalCents)) across \(facts.shiftCount) shifts, averaging \(Money.string(fromCents: facts.averagePerShiftCents)) per shift.",
        ]
        if !facts.topDays.isEmpty {
            let days = facts.topDays.map { "\(Money.string(fromCents: $0.cents)) on \($0.date.formatted(.dateTime.month(.wide).day()))" }
            lines.append("TOP EARNING DAYS: " + days.joined(separator: ", ") + ".")
        }
        lines.append("CASH VS CREDIT: \(Money.string(fromCents: facts.cashCents)) cash, \(Money.string(fromCents: facts.creditCents)) credit.")
        if let lunchDinner = facts.lunchDinner {
            lines.append("LUNCH VS DINNER: lunch \(Money.string(fromCents: lunchDinner.lunchCents)) across \(lunchDinner.lunchShiftCount) shifts, dinner \(Money.string(fromCents: lunchDinner.dinnerCents)) across \(lunchDinner.dinnerShiftCount) shifts.")
        }
        if let doublesSolo = facts.doublesSolo {
            lines.append("DOUBLES VS SOLO: doubles averaged \(Money.string(fromCents: doublesSolo.doubleAverageCents)) across \(doublesSolo.doubleCount) shifts, solo averaged \(Money.string(fromCents: doublesSolo.soloAverageCents)) across \(doublesSolo.soloCount) shifts.")
        }

        var promptSections = ["NEW FACTS TO REFLECT:", lines.joined(separator: "\n")]
        if let previousSections, !previousSections.isEmpty {
            let previous = previousSections.map { "\($0.title): \($0.body)" }.joined(separator: "\n")
            promptSections = ["PREVIOUS ANALYSIS (amend this, do not rewrite from scratch):", previous, ""] + promptSections
        }
        return promptSections.joined(separator: "\n")
    }
}
