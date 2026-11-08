// Truv pay statement -> the typed, integer-cents shape the app imports.
//
// This module only READS what the stub says. It does not estimate, infer or
// reconcile anything: the one sum it makes is the tax lines into
// `taxes_cents`, which is what "taxes withheld" on a stub is.

export interface TruvEarning {
  name?: string | null;
  category?: string | null;
  amount?: string | number | null;
  rate?: string | number | null;
  units?: string | number | null;
}

export interface TruvDeduction {
  name?: string | null;
  category?: string | null;
  amount?: string | number | null;
}

export interface TruvStatement {
  id: string;
  pay_date?: string | null;
  period_start?: string | null;
  period_end?: string | null;
  gross_pay?: string | number | null;
  net_pay?: string | number | null;
  hours?: string | number | null;
  regular?: string | number | null;
  overtime?: string | number | null;
  earnings?: TruvEarning[] | null;
  deductions?: TruvDeduction[] | null;
}

export interface Deduction {
  name: string;
  category: string;
  cents: number;
}

export interface Paystub {
  source_id: string;
  link_id: string;
  provider_name: string | null;
  employer_name: string | null;
  pay_date: string;
  period_start: string | null;
  period_end: string | null;
  gross_cents: number | null;
  net_cents: number | null;
  /// Decimal string exactly as the stub printed it ("80.00"), or null.
  hours: string | null;
  regular_cents: number | null;
  overtime_cents: number | null;
  /// Tips paid on this check (see `classifyEarning`). 0 when the stub has
  /// earnings lines and none of them is a tip; null when it has no lines.
  tips_cents: number | null;
  gratuity_cents: number | null;
  /// Cash tips the person declared and already has. On the stub for tax
  /// only; never part of `tips_cents`.
  declared_tips_cents: number | null;
  /// federal + state + local + socialsec + medicare. Null when the stub has
  /// no tax lines at all (not the same as zero tax).
  taxes_cents: number | null;
  deductions: Deduction[];
}

export const TAX_CATEGORIES = new Set([
  "federal",
  "state",
  "local",
  "socialsec",
  "medicare",
]);

const DECIMAL = /^(-?)(\d+)(?:\.(\d+))?$/;
const ISO_DAY = /^\d{4}-\d{2}-\d{2}$/;

/// "1629.98" -> 162998. Money arrives as a decimal STRING and is converted
/// digit by digit, never through a float, so 0.1 + 0.2 problems cannot reach
/// a paycheck. More than two decimals round half away from zero. Null, empty
/// or unreadable -> null (unknown), never 0.
export function parseCents(value: unknown): number | null {
  if (value === null || value === undefined) return null;
  let text: string;
  if (typeof value === "number") {
    if (!Number.isFinite(value)) return null;
    text = value.toFixed(4);
  } else if (typeof value === "string") {
    text = value.trim().replaceAll(",", "");
  } else {
    return null;
  }
  const match = text.match(DECIMAL);
  if (!match) return null;
  const [, sign, whole, fraction = ""] = match;
  const padded = (fraction + "000").slice(0, 3);
  let cents = Number(whole) * 100 + Number(padded.slice(0, 2));
  if (Number(padded[2]) >= 5) cents += 1;
  if (!Number.isSafeInteger(cents)) return null;
  return sign === "-" && cents !== 0 ? -cents : cents;
}

/// "80" / "80.5" / 80.25 -> a plain decimal string; anything else -> null.
export function parseHours(value: unknown): string | null {
  if (value === null || value === undefined) return null;
  const text = typeof value === "number"
    ? (Number.isFinite(value) ? String(value) : "")
    : typeof value === "string"
    ? value.trim()
    : "";
  return DECIMAL.test(text) && !text.startsWith("-") ? text : null;
}

export function isoDay(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const day = value.slice(0, 10);
  if (!ISO_DAY.test(day)) return null;
  const parsed = new Date(`${day}T00:00:00Z`);
  return !Number.isNaN(parsed.getTime()) && parsed.toISOString().startsWith(day)
    ? day
    : null;
}

export type EarningKind = "tips" | "declared_tips" | "gratuity" | "other";

// The rules, in the order they are tried. Payroll systems name these lines
// freely ("CC Tips", "Tips - Credit Card", "Charged Tips", "Auto Gratuity",
// "Service Charge"), so the match is on the words that carry the meaning:
//
// 1. Not a tip at all, even though the word is there:
//    "tip credit" / "tip makeup" / "tip adjustment" are the employer's
//    minimum-wage accounting (FLSA 3(m)), wages rather than tips.
// 2. Gratuity: "gratuity", "gratuities", "grat", "service charge". A
//    mandatory charge the employer distributes is wages-like and Payday keeps
//    it apart from tips (`PaycheckRecord.gratuityCents`).
// 3. Declared tips: a tip line that says "cash", "declared" or "reported".
//    Cash already in the person's pocket, on the stub so it can be taxed
//    (usually offset by a memo deduction). Not paid by this check.
// 4. Tips: any other line with "tip" or "tips" as a word ("Credit Card Tips",
//    "Tips Paid", "Tip Share").
const NOT_TIPS = /\btips?\s*(credit|make\s*-?\s*up|adj(ustment)?)\b/i;
const GRATUITY =
  /\b(gratuit(y|ies)|grat|service\s*charges?|auto\s*-?\s*grat)\b/i;
const DECLARED = /\b(cash|declared|reported)\b/i;
const TIPS = /\btips?\b/i;

export function classifyEarning(name: string | null | undefined): EarningKind {
  const text = (name ?? "").trim();
  if (!text) return "other";
  if (NOT_TIPS.test(text)) return "other";
  if (GRATUITY.test(text)) return "gratuity";
  if (TIPS.test(text)) return DECLARED.test(text) ? "declared_tips" : "tips";
  return "other";
}

function sumKind(earnings: TruvEarning[], kind: EarningKind): number | null {
  let total: number | null = null;
  for (const earning of earnings) {
    if (classifyEarning(earning.name) !== kind) continue;
    const cents = parseCents(earning.amount);
    if (cents === null) continue;
    total = (total ?? 0) + cents;
  }
  return total;
}

export function normalizeDeductions(
  deductions: TruvDeduction[] | null | undefined,
): Deduction[] {
  const result: Deduction[] = [];
  for (const line of deductions ?? []) {
    const cents = parseCents(line.amount);
    if (cents === null) continue;
    result.push({
      name: (line.name ?? "").trim() || "Deduction",
      category: (line.category ?? "other").trim().toLowerCase() || "other",
      // A withholding is a positive amount taken out. Some payroll systems
      // print it negative; the sign carries no extra meaning here.
      cents: Math.abs(cents),
    });
  }
  return result;
}

export function sumTaxes(deductions: Deduction[]): number | null {
  const taxes = deductions.filter((line) => TAX_CATEGORIES.has(line.category));
  if (taxes.length === 0) return null;
  return taxes.reduce((total, line) => total + line.cents, 0);
}

/// One Truv statement as the app imports it, or null when it has no
/// readable pay date (there is then nothing to place it by).
export function normalizeStatement(
  statement: TruvStatement,
  context: {
    linkId: string;
    providerName: string | null;
    employerName: string | null;
  },
): Paystub | null {
  const payDate = isoDay(statement.pay_date);
  if (!payDate || typeof statement.id !== "string" || !statement.id) {
    return null;
  }
  const earnings = Array.isArray(statement.earnings) ? statement.earnings : [];
  const hasEarnings = earnings.length > 0;
  const deductions = normalizeDeductions(statement.deductions);
  return {
    source_id: statement.id,
    link_id: context.linkId,
    provider_name: context.providerName,
    employer_name: context.employerName,
    pay_date: payDate,
    period_start: isoDay(statement.period_start),
    period_end: isoDay(statement.period_end),
    gross_cents: parseCents(statement.gross_pay),
    net_cents: parseCents(statement.net_pay),
    hours: parseHours(statement.hours),
    regular_cents: parseCents(statement.regular),
    overtime_cents: parseCents(statement.overtime),
    tips_cents: hasEarnings ? (sumKind(earnings, "tips") ?? 0) : null,
    gratuity_cents: hasEarnings ? sumKind(earnings, "gratuity") : null,
    declared_tips_cents: hasEarnings
      ? sumKind(earnings, "declared_tips")
      : null,
    taxes_cents: sumTaxes(deductions),
    deductions,
  };
}
