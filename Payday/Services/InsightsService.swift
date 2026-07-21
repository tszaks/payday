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
/// itself, never sees raw entries. Calls a small serverless proxy
/// (payday-website's app/api/insights-narrate) that holds the OpenAI key
/// server-side and owns the model/instructions/schema; the app never sees
/// or ships a provider key, same pattern Vero uses. This is deliberately
/// the smaller half of the page now: InsightsView's THE NUMBERS grid reads
/// InsightsFacts directly and needs no narration at all, so when this call
/// fails (not deployed yet, no network, rate limited) or simply has
/// nothing worth flagging, InsightsView renders no WORTH KNOWING section —
/// the grid "must stand alone anyway."
enum InsightsService {
    /// Set once the payday-website Vercel deployment's production domain
    /// is confirmed — the proxy route already exists
    /// (app/api/insights-narrate/route.ts) but hasn't been deployed with a
    /// rotated key yet. Empty until then: isConfigured stays false and
    /// Insights shows its deterministic facts sections, exactly like a
    /// build with no key ever did.
    private static let proxyHost = "payday-website-eta.vercel.app"
    private static let endpoint: URL? = {
        guard !proxyHost.isEmpty else { return nil }
        return URL(string: "https://\(proxyHost)/api/insights-narrate")
    }()

    static var isConfigured: Bool {
        endpoint != nil
    }

    /// `previousSections` is the last narration shown, if any — passed back
    /// in so each refresh amends it rather than rewriting from scratch.
    /// Wording should settle down and change less over time as patterns
    /// stabilize, not reshuffle on every call.
    static func narrate(facts: InsightsFacts, scheduleFrequency: PayFrequency, previousSections: [InsightSection]?, topMove: Move? = nil, latestFollowUp: FollowUp? = nil) async throws -> [InsightSection] {
        guard let endpoint else {
            throw InsightsError.generationFailed("Narration isn't set up yet.")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "input": promptDescription(for: facts, scheduleFrequency: scheduleFrequency, previousSections: previousSections, topMove: topMove, latestFollowUp: latestFollowUp)
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw InsightsError.generationFailed("Couldn't reach narration right now.")
        }

        guard let outputText = try JSONDecoder().decode(ResponsesEnvelope.self, from: data).outputText,
              let jsonData = outputText.data(using: .utf8)
        else {
            throw InsightsError.generationFailed("Couldn't read the analysis.")
        }

        // Empty is a legitimate answer now, not a failure — the prompt
        // below explicitly permits returning nothing when there's no
        // anomaly, caveat, or synthesis worth surfacing, and InsightsView
        // renders no WORTH KNOWING section in that case.
        let narration = try JSONDecoder().decode(InsightsNarration.self, from: jsonData)
        return narration.sections
    }

    private static func promptDescription(for facts: InsightsFacts, scheduleFrequency: PayFrequency, previousSections: [InsightSection]?, topMove: Move?, latestFollowUp: FollowUp?) -> String {
        var lines = [
            "BACKGROUND CONTEXT, NOT A SECTION - pay frequency: \(scheduleFrequency.displayName).",
            "OVERALL: \(Money.string(fromCents: facts.totalCents)) across \(facts.shiftCount) shifts, averaging \(Money.string(fromCents: facts.averagePerShiftCents)) per shift.",
        ]
        if !facts.topDays.isEmpty {
            let days = facts.topDays.map { "\(Money.string(fromCents: $0.cents)) on \($0.date.formatted(.dateTime.month(.wide).day()))" }
            lines.append("TOP EARNING DAYS: " + days.joined(separator: ", ") + ".")
        }
        lines.append("CASH VS CREDIT: \(Money.string(fromCents: facts.cashCents)) cash, \(Money.string(fromCents: facts.creditCents)) credit (this split is gross, before any tip-out). Credit exceeding cash is normal in a card-heavy restaurant and is NOT a finding - never present 'credit was the larger share' as an insight. If this section is worth writing at all, say what the split means: cash went home the day it was earned; credit arrives on the paycheck.")
        if facts.totalTipOutCents > 0 {
            lines.append("TIP-OUTS: \(Money.string(fromCents: facts.totalTipOutCents)) total tipped out - already subtracted from OVERALL above.")
        }
        if let lunchDinner = facts.lunchDinner {
            let lunchAvg = lunchDinner.lunchShiftCount > 0 ? lunchDinner.lunchCents / lunchDinner.lunchShiftCount : 0
            let dinnerAvg = lunchDinner.dinnerShiftCount > 0 ? lunchDinner.dinnerCents / lunchDinner.dinnerShiftCount : 0
            lines.append("LUNCH VS DINNER: lunch \(Money.string(fromCents: lunchDinner.lunchCents)) across \(lunchDinner.lunchShiftCount) shifts (\(Money.string(fromCents: lunchAvg)) per shift), dinner \(Money.string(fromCents: lunchDinner.dinnerCents)) across \(lunchDinner.dinnerShiftCount) shifts (\(Money.string(fromCents: dinnerAvg)) per shift). Compare PER-SHIFT averages, never the raw totals - the shift counts differ.")
        }
        if let doublesSolo = facts.doublesSolo {
            lines.append("DOUBLE DAYS VS SINGLE-SHIFT DAYS: a day with two shifts brought in \(Money.string(fromCents: doublesSolo.doubleAverageCents)) on average (\(Money.string(fromCents: doublesSolo.doublePerShiftCents)) per shift) across \(doublesSolo.doubleCount) such days; single-shift days averaged \(Money.string(fromCents: doublesSolo.soloAverageCents)) across \(doublesSolo.soloCount) days. A double day out-earning a single shift is arithmetic (two shifts were worked), NOT a finding - only the per-shift comparison can support any claim about doubles.")
        }
        if let rate = facts.rate {
            var rateLine = "RATE: averaging \(Money.wholeDollarString(fromCents: Int((rate.overallDollarsPerHour * 100).rounded())))/hr across \(rate.nightsWithHours) shifts with hours logged."
            if let bestWeekday = rate.bestWeekday, let bestRate = rate.bestWeekdayDollarsPerHour, let count = rate.bestWeekdayNightCount {
                let weekdayName = Calendar.current.weekdaySymbols[bestWeekday - 1]
                rateLine += " Best-paying weekday: \(weekdayName) at \(Money.wholeDollarString(fromCents: Int((bestRate * 100).rounded())))/hr across \(count == 1 ? "1 shift" : "\(count) shifts")."
            }
            lines.append(rateLine)
        }
        if let sales = facts.sales {
            var salesLine = "TIP PERCENT: averaging \(String(format: "%.1f", sales.overallTipPercent))% of sales across \(sales.nightsWithSales) shifts with sales logged."
            if let bestWeekday = sales.bestWeekday, let bestPercent = sales.bestWeekdayTipPercent, let count = sales.bestWeekdayNightCount {
                let weekdayName = Calendar.current.weekdaySymbols[bestWeekday - 1]
                salesLine += " Best weekday: \(weekdayName) at \(String(format: "%.1f", bestPercent))% across \(count == 1 ? "1 shift" : "\(count) shifts")."
            }
            lines.append(salesLine)
        }
        if let startTime = facts.startTime {
            let bestHour = hourLabel(startTime.bestStartHour)
            let worstHour = hourLabel(startTime.worstStartHour)
            let bestRate = Money.wholeDollarString(fromCents: Int((startTime.bestDollarsPerHour * 100).rounded()))
            let worstRate = Money.wholeDollarString(fromCents: Int((startTime.worstDollarsPerHour * 100).rounded()))
            lines.append("START TIMES: shifts starting around \(bestHour) average \(bestRate)/hr across \(startTime.bestShiftCount == 1 ? "1 shift" : "\(startTime.bestShiftCount) shifts"); around \(worstHour) average \(worstRate)/hr across \(startTime.worstShiftCount == 1 ? "1 shift" : "\(startTime.worstShiftCount) shifts").")
        }

        if !facts.notes.isEmpty {
            let noteLines = facts.notes.map { "\($0.date.formatted(.dateTime.month(.abbreviated).day())): \"\($0.text)\"" }
            lines.append("SHIFT NOTES (the worker's own words, context only - never arithmetic): " + noteLines.joined(separator: " | ") + " - When a note explains an unusual number (a POS outage, tips carried between shifts, a comped shift), prefer the note's explanation over reading meaning into that number, and say so plainly. Quote or paraphrase only what is actually written; never invent notes.")
        }

        lines.append("SAMPLE SIZE RULES: a pattern claim (weekday, lunch vs dinner, doubles, start times) backed by fewer than 3 shifts is an anecdote - if you mention it at all, hedge it explicitly by naming the count, and NEVER base a claim on it otherwise.")

        lines.append("VOCABULARY: never use 'night' as a generic stand-in for a shift or a day - a shift can be lunch, dinner, or unspecified, and it may be logged and read back at any hour. Say lunch, dinner, shift, or day, matching what the data actually reflects.")

        if let topMove {
            lines.append("TOP MOVE (already shown to the reader as its own card, above everything you write - never repeat it as an item): \(topMove.title) - \(topMove.body)")
        }

        if let latestFollowUp {
            lines.append("SINCE THEN (a follow-up on a past Move, already shown to the reader as its own card, above everything you write, including TOP MOVE - never repeat it as an item): \(latestFollowUp.title) - \(latestFollowUp.body)")
        }

        lines.append("THE READER ALREADY SEES ALL OF THE ABOVE AS NUMBERS ON SCREEN, in a stat grid directly below TOP MOVE/SINCE THEN: hourly rate, tip percent, lunch vs dinner per shift, doubles vs solo per shift, cash share, and start times, each already hedged there when the sample is thin. Your job is NOT to restate any of those figures and NOT to write one item per fact / narrate section-by-section - the grid already does that job better than prose can. Return 1 to 3 items in the sections array, and only when something is actually worth flagging beyond the numbers themselves: (a) an explanation for an anomaly or unusual number - especially one grounded in a SHIFT NOTE above - (b) a caveat about how to read the data (e.g. why a figure is thin or noisy) that the grid's own hedge doesn't already cover, or (c) one synthesis connecting two or more of the facts above into a takeaway the grid doesn't spell out on its own. Each item's title must be 4 words or fewer; each item's body must be 1-2 sentences, never more. If nothing above actually clears that bar, return an empty sections array rather than padding it with a restated number or a generic remark.")

        var promptSections = ["NEW FACTS TO REFLECT:", lines.joined(separator: "\n")]
        if let previousSections, !previousSections.isEmpty {
            let previous = previousSections.map { "\($0.title): \($0.body)" }.joined(separator: "\n")
            promptSections = ["PREVIOUS ANALYSIS (amend this, do not rewrite from scratch):", previous, ""] + promptSections
        }
        return promptSections.joined(separator: "\n")
    }

    /// Same locale-respecting rendering as StatsEngine's own hourLabel — an
    /// actual Date at that hour, formatted by Date.FormatStyle rather than
    /// hand-rolled am/pm math.
    private static func hourLabel(_ hour: Int) -> String {
        let calendar = Calendar.current
        let anchored = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: .now) ?? .now
        return anchored.formatted(.dateTime.hour())
    }
}
