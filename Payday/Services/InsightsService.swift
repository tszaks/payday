import Foundation
import OSLog

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
    /// Transient — no network, a timeout, or a 5xx from narration. Retrying
    /// the same input later can plausibly succeed.
    case generationFailed(String)
    /// Deterministic — narration was reached and refused the request (4xx), or
    /// it answered and the answer couldn't be parsed. Retrying byte-identical
    /// input produces a byte-identical failure, so this must never earn the
    /// retry that bypasses the refresh interval. The parse case is the
    /// expensive one: the OpenAI call already succeeded and was already
    /// billed by the time it failed here.
    case requestRejected(String)

    var errorDescription: String? {
        switch self {
        case .notEnoughData: "Log a few more shifts before analyzing patterns."
        case .generationFailed(let message): message
        case .requestRejected(let message): message
        }
    }

    /// Whether retrying the SAME input soon could plausibly succeed.
    var isRetryable: Bool {
        switch self {
        case .generationFailed: true
        case .notEnoughData, .requestRejected: false
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
    private static let logger = Logger(
        subsystem: "com.szakacsmedia.payday",
        category: "InsightsNarration"
    )

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
        let requestID = UUID().uuidString
        request.setValue(requestID, forHTTPHeaderField: "X-Request-ID")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "input": promptDescription(for: facts, scheduleFrequency: scheduleFrequency, previousSections: previousSections, topMove: topMove, latestFollowUp: latestFollowUp)
        ])

        let startedAt = Date()
        let requestBytes = request.httpBody?.count ?? 0
        logger.notice(
            "Narration request started. requestID=\(requestID, privacy: .public) bytes=\(requestBytes)"
        )

        let result: (Data, URLResponse)
        do {
            result = try await URLSession.shared.data(for: request)
        } catch {
            let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
            let errorType = String(describing: type(of: error))
            logger.error(
                "Narration request failed. requestID=\(requestID, privacy: .public) elapsedMs=\(elapsedMilliseconds) type=\(errorType, privacy: .public)"
            )
            throw InsightsError.generationFailed("Couldn't reach narration right now.")
        }
        let (data, response) = result
        let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error(
                "Narration response was not HTTP. requestID=\(requestID, privacy: .public) elapsedMs=\(elapsedMilliseconds) bytes=\(data.count)"
            )
            throw InsightsError.generationFailed("Couldn't reach narration right now.")
        }
        logger.notice(
            "Narration response received. requestID=\(requestID, privacy: .public) status=\(httpResponse.statusCode) elapsedMs=\(elapsedMilliseconds) bytes=\(data.count)"
        )
        guard (200..<300).contains(httpResponse.statusCode) else {
            // A 4xx means narration WAS reached and turned the request down —
            // our bug (an oversized prompt is the one that actually happened),
            // not a connectivity problem. Collapsing both into "couldn't reach"
            // pointed a ten-day outage at the network, the key, and the OpenAI
            // balance, none of which were involved.
            if (400..<500).contains(httpResponse.statusCode) {
                throw InsightsError.requestRejected("Narration turned down this request (\(httpResponse.statusCode)).")
            }
            throw InsightsError.generationFailed("Couldn't reach narration right now.")
        }

        // Reaching here means OpenAI answered and the call was BILLED. A parse
        // failure is therefore the one failure that must not retry on its own:
        // identical input yields an identical unparseable answer, and every
        // attempt costs money.
        guard let outputText = try JSONDecoder().decode(ResponsesEnvelope.self, from: data).outputText,
              let jsonData = outputText.data(using: .utf8)
        else {
            throw InsightsError.requestRejected("Couldn't read the analysis.")
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
        if let cashWeekday = facts.cashWeekday {
            let weekdayName = Calendar.current.weekdaySymbols[cashWeekday.weekday - 1]
            let countPhrase = cashWeekday.nightCount == 1 ? "1 \(weekdayName)" : "\(cashWeekday.nightCount) \(weekdayName)s"
            lines.append("CASH WEEKDAY: \(weekdayName)s run \(Int(cashWeekday.sharePercent.rounded()))% cash against \(Int(cashWeekday.restSharePercent.rounded()))% the rest of the week, across \(countPhrase).")
        }
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
        if let receipt = facts.receiptPerformance {
            var receiptParts: [String] = []
            if let spend = receipt.averageSpendPerGuestCents, let grossTips = receipt.grossTipsPerGuestCents, let netTips = receipt.netTipsPerGuestCents {
                receiptParts.append("across \(receipt.guestShiftCount) shifts and \(receipt.totalGuests) guests: pre-tax spend \(Money.string(fromCents: spend)) per guest, gross tips \(Money.string(fromCents: grossTips)) per guest, net tips \(Money.string(fromCents: netTips)) per guest")
            }
            if let spend = receipt.averageSpendPerTableCents, let tips = receipt.netTipsPerTableCents {
                receiptParts.append("across \(receipt.tableShiftCount) shifts and \(receipt.totalTables) tables: pre-tax spend \(Money.string(fromCents: spend)) per table and net tips \(Money.string(fromCents: tips)) per table; \(receipt.estimatedTableShiftCount) of those shifts use check count as an estimated table count, so split checks can overstate tables")
            }
            if let averageCheck = receipt.averageCheckCents {
                receiptParts.append("average check \(Money.string(fromCents: averageCheck)) on no-cash-sales shifts")
            }
            if let guestsPerHour = receipt.guestsPerHour {
                receiptParts.append("\(String(format: "%.1f", guestsPerHour)) guests per hour")
            }
            if let tipOutPercent = receipt.tipOutPercentOfGrossTips {
                receiptParts.append("tip-out is \(String(format: "%.1f", tipOutPercent))% of gross tips")
            }
            if !receipt.topCategories.isEmpty {
                receiptParts.append("sales mix: " + receipt.topCategories.map { "\($0.name) \(String(format: "%.0f", $0.sharePercent))%" }.joined(separator: ", "))
            }
            if !receiptParts.isEmpty {
                lines.append("GUESTS, TABLES, AND SALES MIX: " + receiptParts.joined(separator: "; ") + ".")
            }
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

        lines.append("THE OBVIOUSNESS LAW, absolute: never state anything that would be true for every server everywhere - if a sentence doesn't depend on THIS person's numbers, it is not an insight and must not be written. Banned by this law: how tipping works (cash goes home nightly, credit arrives on the paycheck), what any term means, that weekends or dinners are generally busier, that more hours mean more pay. The cash-versus-credit mix in general is banned under this law too - the ONLY cash fact you may ever mention is the CASH WEEKDAY line above, when present, and only in that specific framing. The test for every sentence you write: could it only be said about this person's data? If not, delete it.")

        lines.append("THE NEUTRALITY LAW, absolute: this page reports what the data shows. It never tells the reader what to do, what is better, or what they would have earned had they chosen differently. Write in the indicative mood, never the imperative and never the conditional. Specifically banned: advice, suggestions, encouragement, any sentence containing 'you should', 'try', 'consider', 'worth it', or 'if you', and any counterfactual or projection of what a different choice would have paid. Neutral does NOT mean vague - name the exact number and the exact shift. 'Saturdays run double Mondays' is correct; 'Saturday beats Monday, so pick up Saturdays' is not. The reader decides what to do with a fact; your job ends at stating it.")

        if let topMove {
            lines.append("TOP OBSERVATION (already shown to the reader as its own card, above everything you write - never repeat it as an item): \(topMove.title) - \(topMove.body)")
        }

        if let latestFollowUp {
            lines.append("WHAT CHANGED (a shift in one pattern since it was first shown, already displayed to the reader as its own card, above everything you write, including TOP OBSERVATION - never repeat it as an item): \(latestFollowUp.title) - \(latestFollowUp.body)")
        }

        lines.append("THE READER ALREADY SEES ALL OF THE ABOVE AS NUMBERS AND RANKED OBSERVATIONS ON SCREEN: hourly rate, tip percent, spend per guest, tips per table, lunch vs dinner per shift, doubles vs solo per shift, cash weekday (when one qualifies), start times, and up to three quantified observations, each already hedged when its sample is thin. Your only remaining job is DATA QUALITY CONTEXT. Return 0 to 2 items in the sections array, and only when one of these applies: (a) a SHIFT NOTE above directly explains an anomaly or unusual number, or (b) a specific caveat materially changes how the reader should interpret a figure (estimated, incomplete, noisy, or otherwise limited) and the grid's own hedge does not already disclose it. Do NOT synthesize a recommendation, rank a shift, repeat an observation, restate a metric, or add a generic observation. Each title must be 4 words or fewer; each body must be 1-2 sentences, never more. If nothing clears that bar, return an empty sections array.")

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
