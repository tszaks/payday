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
    static func narrate(facts: InsightsFacts, scheduleFrequency: PayFrequency, previousSections: [InsightSection]?, topMove: Move? = nil) async throws -> [InsightSection] {
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
            "input": promptDescription(for: facts, scheduleFrequency: scheduleFrequency, previousSections: previousSections, topMove: topMove),
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
        narrate the facts you're handed. Every dollar figure you're given is already net of any \
        tip-outs; never call a number "gross" or re-derive what it would be before a tip-out. \

        You'll always get an OVERALL fact and a CASH VS CREDIT fact - always turn each into \
        its own section. TOP EARNING DAYS, LUNCH VS DINNER, DOUBLES VS SOLO, RATE, TIP PERCENT, \
        and TIP-OUTS facts are only included when there's real data for them - turn each into \
        its own section only when present, in the order given, EXCEPT TIP-OUTS: fold that into \
        the OVERALL section as a short trailing clause rather than a section of its own, since \
        it's explaining a number already stated there. RATE is a $/hr fact and TIP PERCENT is a \
        percent-of-sales fact, each only ever computed over shifts that actually had hours or \
        sales logged - never estimate either for a shift that wasn't given one. TIP PERCENT is \
        measured against gross tips, not the net figures everywhere else - don't flag this \
        distinction to the reader, just use the percent you're given as-is. Ignore the pay \
        frequency line entirely when deciding what sections to write - it's background context \
        for your own understanding, never a topic of its own. After all given facts are \
        covered, add exactly one final section that's a concrete, actionable suggestion based \
        on them - practical, not motivational. \

        Each title is 2 to 4 words (e.g. "Overall Snapshot", "Top Earning Days", "Cash vs \
        Credit", "Lunch vs Dinner", "Doubles vs Solo", "Your Hourly Rate", "Tip Percent", "What \
        To Try Next"). Each body is 2 to 4 short sentences, no markdown formatting, no bullet \
        characters, no disclaimers about being an AI. \

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

    private static func promptDescription(for facts: InsightsFacts, scheduleFrequency: PayFrequency, previousSections: [InsightSection]?, topMove: Move?) -> String {
        var lines = [
            "BACKGROUND CONTEXT, NOT A SECTION - pay frequency: \(scheduleFrequency.displayName).",
            "OVERALL: \(Money.string(fromCents: facts.totalCents)) across \(facts.shiftCount) shifts, averaging \(Money.string(fromCents: facts.averagePerShiftCents)) per shift.",
        ]
        if !facts.topDays.isEmpty {
            let days = facts.topDays.map { "\(Money.string(fromCents: $0.cents)) on \($0.date.formatted(.dateTime.month(.wide).day()))" }
            lines.append("TOP EARNING DAYS: " + days.joined(separator: ", ") + ".")
        }
        lines.append("CASH VS CREDIT: \(Money.string(fromCents: facts.cashCents)) cash, \(Money.string(fromCents: facts.creditCents)) credit (this split is gross, before any tip-out).")
        if facts.totalTipOutCents > 0 {
            lines.append("TIP-OUTS: \(Money.string(fromCents: facts.totalTipOutCents)) total tipped out - already subtracted from OVERALL above.")
        }
        if let lunchDinner = facts.lunchDinner {
            lines.append("LUNCH VS DINNER: lunch \(Money.string(fromCents: lunchDinner.lunchCents)) across \(lunchDinner.lunchShiftCount) shifts, dinner \(Money.string(fromCents: lunchDinner.dinnerCents)) across \(lunchDinner.dinnerShiftCount) shifts.")
        }
        if let doublesSolo = facts.doublesSolo {
            lines.append("DOUBLES VS SOLO: doubles averaged \(Money.string(fromCents: doublesSolo.doubleAverageCents)) across \(doublesSolo.doubleCount) shifts, solo averaged \(Money.string(fromCents: doublesSolo.soloAverageCents)) across \(doublesSolo.soloCount) shifts.")
        }
        if let rate = facts.rate {
            var rateLine = "RATE: averaging \(Money.wholeDollarString(fromCents: Int((rate.overallDollarsPerHour * 100).rounded())))/hr across \(rate.nightsWithHours) shifts with hours logged."
            if let bestWeekday = rate.bestWeekday, let bestRate = rate.bestWeekdayDollarsPerHour, let count = rate.bestWeekdayNightCount {
                let weekdayName = Calendar.current.weekdaySymbols[bestWeekday - 1]
                rateLine += " Best-paying weekday: \(weekdayName) at \(Money.wholeDollarString(fromCents: Int((bestRate * 100).rounded())))/hr across \(count == 1 ? "1 night" : "\(count) nights")."
            }
            lines.append(rateLine)
        }
        if let sales = facts.sales {
            var salesLine = "TIP PERCENT: averaging \(String(format: "%.1f", sales.overallTipPercent))% of sales across \(sales.nightsWithSales) shifts with sales logged."
            if let bestWeekday = sales.bestWeekday, let bestPercent = sales.bestWeekdayTipPercent, let count = sales.bestWeekdayNightCount {
                let weekdayName = Calendar.current.weekdaySymbols[bestWeekday - 1]
                salesLine += " Best weekday: \(weekdayName) at \(String(format: "%.1f", bestPercent))% across \(count == 1 ? "1 night" : "\(count) nights")."
            }
            lines.append(salesLine)
        }

        if let topMove {
            lines.append("TOP MOVE (already shown to the reader as its own card, above everything you write - do not repeat it as a section; only weave it into the final suggestion section if it genuinely strengthens it): \(topMove.title) - \(topMove.body)")
        }

        var promptSections = ["NEW FACTS TO REFLECT:", lines.joined(separator: "\n")]
        if let previousSections, !previousSections.isEmpty {
            let previous = previousSections.map { "\($0.title): \($0.body)" }.joined(separator: "\n")
            promptSections = ["PREVIOUS ANALYSIS (amend this, do not rewrite from scratch):", previous, ""] + promptSections
        }
        return promptSections.joined(separator: "\n")
    }
}
