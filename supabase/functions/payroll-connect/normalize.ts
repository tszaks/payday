// Truv pay statement -> the typed, integer-cents shape the app imports.
//
// This module only READS what the stub says: decimal strings become integer
// cents, dates become ISO days. It classifies and sums nothing. Which lines
// are tips, gratuity or taxes is an earnings rule, and earnings rules live in
// PaydayCore (`PayStubFigures`), so the app gets every line as printed.

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

/// One earnings or deduction line, as printed. `category` is Truv's, lower
/// case ("federal", "retirement", ...), or "other" when Truv gave none.
export interface Line {
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
  /// Every earnings line with a readable amount, sign kept (an adjustment
  /// can be negative). Empty when the stub lists none.
  earnings: Line[];
  /// Every deduction line with a readable amount, as a positive amount
  /// withheld.
  deductions: Line[];
}

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

function lineName(name: string | null | undefined, fallback: string): string {
  return (name ?? "").trim() || fallback;
}

function lineCategory(category: string | null | undefined): string {
  return (category ?? "other").trim().toLowerCase() || "other";
}

export function normalizeEarnings(
  earnings: TruvEarning[] | null | undefined,
): Line[] {
  const result: Line[] = [];
  for (const line of Array.isArray(earnings) ? earnings : []) {
    const cents = parseCents(line.amount);
    if (cents === null) continue;
    result.push({
      name: lineName(line.name, "Earnings"),
      category: lineCategory(line.category),
      cents,
    });
  }
  return result;
}

export function normalizeDeductions(
  deductions: TruvDeduction[] | null | undefined,
): Line[] {
  const result: Line[] = [];
  for (const line of Array.isArray(deductions) ? deductions : []) {
    const cents = parseCents(line.amount);
    if (cents === null) continue;
    result.push({
      name: lineName(line.name, "Deduction"),
      category: lineCategory(line.category),
      // A withholding is a positive amount taken out. Some payroll systems
      // print it negative; the sign carries no extra meaning here.
      cents: Math.abs(cents),
    });
  }
  return result;
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
    earnings: normalizeEarnings(statement.earnings),
    deductions: normalizeDeductions(statement.deductions),
  };
}
