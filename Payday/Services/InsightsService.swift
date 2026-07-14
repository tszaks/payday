import Foundation
import FoundationModels

/// One labeled block in the Insights screen, e.g. "Top Earning Days" + body.
/// @Generable so Foundation Models can produce this shape directly via
/// guided generation — no hand-parsed JSON, no schema drift risk.
@Generable
struct InsightSection: Codable, Identifiable, Equatable, Sendable {
    let title: String
    let body: String
    var id: String { title }
}

@Generable
private struct InsightsNarration: Equatable, Sendable {
    let sections: [InsightSection]
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
/// itself, never sees raw entries. Runs entirely on-device via Apple's
/// Foundation Models framework: no network call, no API key, nothing
/// leaves the phone. Unsupported hardware is handled by the caller
/// (InsightsView shows InsightsFactsCopy's deterministic sections instead
/// of calling this at all — the facts "must stand alone anyway").
enum InsightsService {
    static var availability: SystemLanguageModel.Availability {
        SystemLanguageModel.default.availability
    }

    static func narrate(facts: InsightsFacts, scheduleFrequency: PayFrequency) async throws -> [InsightSection] {
        let session = LanguageModelSession {
            """
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
            "credit tips totaled $488 across five entries."
            """
        }

        let prompt = promptDescription(for: facts, scheduleFrequency: scheduleFrequency)
        do {
            let response = try await session.respond(to: prompt, generating: InsightsNarration.self)
            guard !response.content.sections.isEmpty else {
                throw InsightsError.generationFailed("Couldn't read the analysis.")
            }
            return response.content.sections
        } catch let error as InsightsError {
            throw error
        } catch {
            throw InsightsError.generationFailed(error.localizedDescription)
        }
    }

    private static func promptDescription(for facts: InsightsFacts, scheduleFrequency: PayFrequency) -> String {
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
        return lines.joined(separator: "\n")
    }
}
