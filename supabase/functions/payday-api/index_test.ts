import {
  assertEquals,
  assertNotEquals,
  assertRejects,
  assertThrows,
} from "@std/assert";
import {
  engineEarnings,
  earnedIncomeCents,
  handleRequest,
  sumSnapshotDays,
  testing,
} from "./index.ts";

type JsonRecord = Record<string, unknown>;

Deno.test("health is public and versioned", async () => {
  const response = await handleRequest(
    new Request("https://example.test/functions/v1/payday-api/v1/health"),
  );
  assertEquals(response.status, 200);
  assertEquals(await response.json(), {
    data: { status: "ok", version: "1.0.0" },
  });
});

Deno.test("OpenAPI advertises REST and MCP without authentication", async () => {
  const response = await handleRequest(
    new Request("https://example.test/functions/v1/payday-api/v1/openapi.json"),
  );
  const body = await response.json();
  assertEquals(response.status, 200);
  assertEquals(body.openapi, "3.1.0");
  assertEquals(body.paths["/mcp"].post.summary, "MCP Streamable HTTP endpoint");
  assertEquals(body.paths["/v1/shifts"].get.parameters[0].name, "cursor");
  assertEquals(body.paths["/v1/audit"].get.parameters[0].name, "cursor");
});

Deno.test("semantic shift cursors round-trip all ordering fields", () => {
  const cursor = {
    work_date: "2026-09-04",
    recorded_at: "2026-09-04T22:15:00.000Z",
    shift_id: "33333333-3333-4333-8333-333333333333",
  };
  assertEquals(testing.shiftCursor(testing.encodeShiftCursor(cursor)), cursor);
});

Deno.test("audit cursors round-trip their stable tie breaker", () => {
  const cursor = {
    requested_at: "2026-09-04T22:15:00.000Z",
    request_id: "11111111-1111-4111-8111-111111111111",
  };
  assertEquals(testing.auditCursor(testing.encodeAuditCursor(cursor)), cursor);
});

// Postgres stores microseconds and PostgREST returns them, so a cursor holds
// the row's exact string. The `.000Z` values above cannot tell an exact
// cursor from one rounded to milliseconds; these can.
const MICROS = "2026-09-04T22:15:00.123456+00:00";

Deno.test("cursors keep a microsecond timestamp exactly as it was encoded", () => {
  const shift = {
    work_date: "2026-09-04",
    recorded_at: MICROS,
    shift_id: "33333333-3333-4333-8333-333333333333",
  };
  assertEquals(testing.shiftCursor(testing.encodeShiftCursor(shift)), shift);
  const audit = {
    requested_at: MICROS,
    request_id: "11111111-1111-4111-8111-111111111111",
  };
  assertEquals(testing.auditCursor(testing.encodeAuditCursor(audit)), audit);
  const change = {
    updated_at: MICROS,
    table: "tip_entries" as const,
    id: "22222222-2222-4222-8222-222222222222",
  };
  assertEquals(testing.changeCursor(testing.encodeChangeCursor(change)), change);
  // Kept exact, but still validated.
  assertThrows(
    () =>
      testing.changeCursor(
        testing.encodeChangeCursor({ ...change, updated_at: "01/02/2026" }),
      ),
    Error,
    "must be an ISO-8601 timestamp with a timezone",
  );
});

/// A stand-in for the PostgREST builder that applies the filters the list
/// and change readers send, over rows held in memory. `updated_at` compares
/// as an instant at microsecond precision, as Postgres compares it, so a
/// cursor rounded to milliseconds lands before its own row here too.
function micros(value: unknown): number {
  const m = String(value).match(
    /^(.+T\d{2}:\d{2}:\d{2})(?:\.(\d+))?(Z|[+-]\d{2}:\d{2})$/,
  );
  if (!m) throw new Error(`stub cannot compare ${value}`);
  return Date.parse(m[1] + m[3]) * 1000 +
    Number((m[2] ?? "").padEnd(6, "0").slice(0, 6));
}

function rowsCtx(tables: Record<string, Record<string, unknown>[]>) {
  const compare = (column: string, a: unknown, b: unknown) => {
    if (column === "updated_at") return micros(a) - micros(b);
    return String(a) < String(b) ? -1 : String(a) > String(b) ? 1 : 0;
  };
  const from = (name: string) => {
    let rows = [...(tables[name] ?? [])];
    const orders: string[] = [];
    let limit = Infinity;
    const keep = (column: string, test: (c: number) => boolean, v: unknown) =>
      (rows = rows.filter((row) => test(compare(column, row[column], v))));
    const builder = {
      select: () => builder,
      eq: (c: string, v: unknown) => (keep(c, (x) => x === 0, v), builder),
      gt: (c: string, v: unknown) => (keep(c, (x) => x > 0, v), builder),
      gte: (c: string, v: unknown) => (keep(c, (x) => x >= 0, v), builder),
      lte: (c: string, v: unknown) => (keep(c, (x) => x <= 0, v), builder),
      is: (c: string, v: null) => (
        rows = rows.filter((row) => (row[c] ?? null) === v), builder
      ),
      or: (expression: string) => {
        const m = expression.match(
          /^updated_at\.gt\.([^,]+),and\(updated_at\.eq\.([^,]+),(\w+)\.gt\.([^)]+)\)$/,
        );
        if (!m) throw new Error(`stub cannot parse ${expression}`);
        rows = rows.filter((row) =>
          compare("updated_at", row.updated_at, m[1]) > 0 ||
          (compare("updated_at", row.updated_at, m[2]) === 0 &&
            compare(m[3], row[m[3]], m[4]) > 0)
        );
        return builder;
      },
      order: (c: string) => (orders.push(c), builder),
      limit: (n: number) => (limit = n, builder),
      then: (
        resolve: (value: { data: unknown; error: null }) => unknown,
      ) => {
        const sorted = [...rows].sort((a, b) => {
          for (const c of orders) {
            const order = compare(c, a[c], b[c]);
            if (order !== 0) return order;
          }
          return 0;
        });
        return Promise.resolve({ data: sorted.slice(0, limit), error: null })
          .then(resolve);
      },
    };
    return builder;
  };
  return {
    key: { user_id: "u1", scopes: ["read"] },
    admin: { from },
    // deno-lint-ignore no-explicit-any
  } as any;
}

const changeID = (n: number) =>
  `${String(n).repeat(8)}-0000-4000-8000-000000000000`;

Deno.test("change pages move past rows that share one microsecond timestamp", async () => {
  // One device sync writes a whole batch in one statement, so every row in
  // it carries the same `now()`. More rows than one page share it here.
  const ids = [1, 2, 3, 4, 5].map(changeID);
  const ctx = rowsCtx({
    tip_entries: ids.map((id) => ({ id, user_id: "u1", updated_at: MICROS })),
  });
  const pages: string[][] = [];
  let cursor: string | undefined;
  do {
    const out = await testing.changes(ctx, {
      since: "2026-09-01T00:00:00Z",
      limit: 2,
      cursor,
    });
    const data = out.data as {
      tip_entries: { id: string }[];
      next_cursor: string | null;
    };
    pages.push(data.tip_entries.map((row) => row.id));
    cursor = data.next_cursor ?? undefined;
  } while (cursor !== undefined && pages.length < 10);
  assertNotEquals(pages[1], pages[0]);
  assertEquals(pages.flat(), ids);
});

Deno.test("changes merge a whole second before a fraction of that second", async () => {
  // Postgres prints a whole second with no fraction, so the two strings
  // differ at the character after the seconds: `+` against `.`. Ordered by
  // code point that is the instant order; a locale collation reverses it.
  const tip = { id: changeID(1), user_id: "u1", updated_at: "2026-09-04T22:15:00.5+00:00" };
  const paycheck = { id: changeID(2), user_id: "u1", updated_at: "2026-09-04T22:15:00+00:00" };
  const ctx = rowsCtx({ tip_entries: [tip], paycheck_records: [paycheck] });
  const first = (await testing.changes(ctx, {
    since: "2026-09-01T00:00:00Z",
    limit: 1,
  })).data as JsonRecord;
  assertEquals((first.paychecks as JsonRecord[]).map((row) => row.id), [paycheck.id]);
  assertEquals(first.tip_entries, []);
  const second = (await testing.changes(ctx, {
    since: "2026-09-01T00:00:00Z",
    limit: 1,
    cursor: first.next_cursor,
  })).data as JsonRecord;
  assertEquals((second.tip_entries as JsonRecord[]).map((row) => row.id), [tip.id]);
  assertEquals(second.paychecks, []);
});

Deno.test("REST lists return tombstones only when include_deleted=true", async () => {
  // Listing tombstones is how a REST caller finds what to restore.
  const live = { id: changeID(1), user_id: "u1", deleted_at: null };
  const gone = { id: changeID(2), user_id: "u1", deleted_at: "2026-09-04T22:15:00+00:00" };
  const ctx = rowsCtx({ tip_entries: [live, gone], paycheck_records: [live, gone] });
  for (const path of ["/v1/tip-entries", "/v1/paychecks"]) {
    const ids = async (query: string) => {
      const url = new URL(`https://example.test/functions/v1/payday-api${path}${query}`);
      const result = await testing.handleREST(new Request(url), url, path, ctx, undefined);
      return (result.body.data as JsonRecord[]).map((row) => row.id);
    };
    assertEquals(await ids(""), [live.id], path);
    assertEquals(await ids("?include_deleted=true"), [live.id, gone.id], path);
  }
});

Deno.test("protected endpoints reject missing Payday tokens", async () => {
  const response = await handleRequest(
    new Request("https://example.test/functions/v1/payday-api/v1/summary"),
  );
  const body = await response.json();
  assertEquals(response.status, 401);
  assertEquals(body.error.code, "invalid_token");
});

Deno.test("date validation rejects normalized impossible dates", () => {
  assertThrows(
    () => testing.dateOnly("2026-02-30", "work_date"),
    Error,
    "work_date must use YYYY-MM-DD",
  );
});

Deno.test("timestamp validation rejects ambiguous local dates", () => {
  assertThrows(
    () => testing.timestamp("01/02/2026", "recorded_at"),
    Error,
    "must be an ISO-8601 timestamp with a timezone",
  );
});

Deno.test("receipt metrics reject nonnumeric financial fields", () => {
  assertThrows(
    () =>
      testing.receiptMetrics(
        { earningsSchemaVersion: 2, gratuityFeesCents: "bad" },
        "receipt_metrics",
      ),
    Error,
    "receipt_metrics.gratuityFeesCents must be an integer",
  );
});

Deno.test("receipt metrics reject malformed nested rows", () => {
  assertThrows(
    () =>
      testing.receiptMetrics(
        { categorySales: "not-an-array" },
        "receipt_metrics",
      ),
    Error,
    "receipt_metrics.categorySales must be an array",
  );
});

Deno.test("move ledger requires timestamp string values", () => {
  assertThrows(
    () => testing.moveLedger({ weekdaySwap: 123 }, "move_ledger"),
    Error,
    "move_ledger.weekdaySwap must be a non-empty string",
  );
});

// These five tests used to exercise `groupShifts` and `tipFacts`, the API's
// own grouping and net implementation. That implementation is deleted: the
// deriver already answered, and a third copy of the net rule was the problem
// rather than the coverage.
//
// The claims that are still THIS layer's job are kept below, now against
// `shiftResponse`. Two are deliberately gone, and both were pinning
// behaviour that was wrong:
//
//   "shift summaries use the database cursor's max work date" asserted that a
//   shift is dated by its LATEST row. iOS dates it by the earliest, so that
//   test pinned the divergence rather than catching it. Where a shift's day
//   comes from is now the deriver's, and shift_deriver_test.sql owns it.
//
//   "shift details fall back field by field from credit to cash" asserted the
//   pre-S3 `credit ?? cash` rule that correction D6 replaced with a detail
//   rank. Also the deriver's, also tested in SQL.

Deno.test("a shift response reads the derived money and never recomputes it", () => {
  const shift = testing.shiftResponse({
    id: "33333333-3333-4333-8333-333333333333",
    work_date: "2026-08-31",
    cash_tips_cents: 1000,
    credit_tips_cents: 2000,
    gratuity_fees_cents: 500,
    tip_out_cents: 300,
    // The generated column: cash + credit + gratuity - tip_out.
    non_wage_earnings_cents: 3200,
    receipt_metrics: { earningsSchemaVersion: 2, gratuityFeesCents: 500 },
    legacy_entry_ids: [],
    source: "device",
  });
  assertEquals(shift.cash_tip_cents, 1000);
  assertEquals(shift.credit_tip_cents, 2000);
  assertEquals(shift.gratuity_cents, 500);
  assertEquals(shift.net_tip_earnings_cents, 3200);
  // The one arithmetic left in this layer: the net plus the tip-out back.
  // "Before tip-out" is a presentation of the stored figure, not a second
  // derivation of it.
  assertEquals(shift.gross_tip_earnings_cents, 3500);
});

Deno.test("the gross is derived from the stored net, not from the components", () => {
  // Deliberately inconsistent input: the components would give 3500 but the
  // stored net says 9000. The response must follow the STORED figure, because
  // that is the deriver's answer and this layer does not get a vote. If this
  // ever reports 3500 again, someone has reintroduced the component sum.
  const shift = testing.shiftResponse({
    id: "33333333-3333-4333-8333-333333333333",
    work_date: "2026-08-31",
    cash_tips_cents: 1000,
    credit_tips_cents: 2000,
    gratuity_fees_cents: 500,
    tip_out_cents: 300,
    non_wage_earnings_cents: 9000,
    legacy_entry_ids: [],
  });
  assertEquals(shift.net_tip_earnings_cents, 9000);
  assertEquals(shift.gross_tip_earnings_cents, 9300);
});

Deno.test("a shift response never leaks the owning account or the idempotency key", () => {
  const shift = testing.shiftResponse({
    id: "33333333-3333-4333-8333-333333333333",
    user_id: "11111111-1111-4111-8111-111111111111",
    agent_idempotency_key: "secret-key",
    work_date: "2026-08-31",
    cash_tips_cents: 1000,
    credit_tips_cents: 0,
    gratuity_fees_cents: 0,
    tip_out_cents: 0,
    non_wage_earnings_cents: 1000,
    legacy_entry_ids: [],
  });
  // The response is built from a named field list rather than by spreading the
  // row and deleting keys, so a column added to public.shifts cannot leak by
  // default. That is why this asserts absence rather than trusting a filter.
  assertEquals(shift.user_id, undefined);
  assertEquals(shift.agent_idempotency_key, undefined);
});

Deno.test("provenance replaces the embedded rows, and is always an array", () => {
  const withProvenance = testing.shiftResponse({
    id: "33333333-3333-4333-8333-333333333333",
    work_date: "2026-08-31",
    cash_tips_cents: 0,
    credit_tips_cents: 0,
    gratuity_fees_cents: 0,
    tip_out_cents: 0,
    non_wage_earnings_cents: 0,
    legacy_entry_ids: [
      "11111111-1111-4111-8111-111111111111",
      "22222222-2222-4222-8222-222222222222",
    ],
    source: "migration",
  });
  assertEquals((withProvenance.legacy_entry_ids as string[]).length, 2);
  assertEquals(withProvenance.source, "migration");
  // `tip_entries` is gone on purpose: a shift is no longer assembled from rows
  // at read time, so embedding them would re-derive the thing this slice
  // removes. Provenance is what a caller needed them for, and
  // payday_agent_shift_by_id accepts any of these ids directly.
  assertEquals(withProvenance.tip_entries, undefined);

  // A natively authored shift has none, and must still report an array rather
  // than null, so a caller can iterate without a guard.
  const native = testing.shiftResponse({
    id: "44444444-4444-4444-8444-444444444444",
    work_date: "2026-08-31",
    cash_tips_cents: 0,
    credit_tips_cents: 0,
    gratuity_fees_cents: 0,
    tip_out_cents: 0,
    non_wage_earnings_cents: 0,
  });
  assertEquals(native.legacy_entry_ids, []);
});

Deno.test("absent optional fields report null rather than being omitted", () => {
  const shift = testing.shiftResponse({
    id: "33333333-3333-4333-8333-333333333333",
    work_date: "2026-08-31",
    cash_tips_cents: 0,
    credit_tips_cents: 0,
    gratuity_fees_cents: 0,
    tip_out_cents: 0,
    non_wage_earnings_cents: 0,
  });
  // Explicit nulls, not missing keys: a consumer reading `shift.hours_worked`
  // should get null rather than undefined, so "not recorded" and "field no
  // longer exists" stay distinguishable.
  for (const field of ["shift_period", "recorded_at", "sales_cents",
                       "hours_worked", "clock_in", "clock_out",
                       "server_count", "receipt_metrics", "note"]) {
    assertEquals(shift[field], null, `${field} must be null, not omitted`);
  }
});

// --- the engine's figure, read from the uploaded snapshot -------------------
//
// The server sums precomputed per-day integers. It applies NO POLICY: no
// overtime allocation, no rounding, no deciding which day a shift belongs
// to. Every one of those happened once, on device. Summing integers cannot
// make two surfaces disagree; allocating overtime can, and has.

const day = (
  d: string,
  o: Partial<{
    cash: number; credit: number; gratuity: number; tipOut: number;
    regular: number; overtime: number; minutes: number; shifts: number;
  }> = {},
) => ({
  day: d,
  minutes: o.minutes ?? 0,
  totalShifts: o.shifts ?? 1,
  knownComponents: {
    voluntaryCashCents: o.cash ?? 0,
    voluntaryCreditCents: o.credit ?? 0,
    gratuityFeesCents: o.gratuity ?? 0,
    tipOutCents: o.tipOut ?? 0,
    regularWagesCents: o.regular ?? 0,
    overtimeWagesCents: o.overtime ?? 0,
  },
});

Deno.test("a range sums only the days inside it, inclusive of both ends", () => {
  const days = [
    day("2026-09-01", { cash: 1000 }),
    day("2026-09-02", { cash: 2000 }),
    day("2026-09-03", { cash: 4000 }),
  ];
  // Both endpoints included: the boundary day is the one people check.
  assertEquals(sumSnapshotDays(days, "2026-09-01", "2026-09-02", null).cash, 3000);
  assertEquals(sumSnapshotDays(days, "2026-09-02", "2026-09-03", null).cash, 6000);
  assertEquals(sumSnapshotDays(days, "2026-09-02", "2026-09-02", null).cash, 2000);
  // A null bound means unbounded on that side, not "today".
  assertEquals(sumSnapshotDays(days, null, null, null).cash, 7000);
  assertEquals(sumSnapshotDays(days, null, "2026-09-01", null).cash, 1000);
});

Deno.test("wages are included, which is the whole difference from the legacy figure", () => {
  const t = sumSnapshotDays(
    [day("2026-09-01", { cash: 500, credit: 800, gratuity: 100, tipOut: 200, regular: 1320, overtime: 396 })],
    null,
    null,
    null,
  );
  // payday_agent_summary would report 1200 here: tips minus tip-out, no
  // wages at all. The engine reports the wage-inclusive figure.
  assertEquals(t.cash + t.credit + t.gratuity - t.tipOut, 1200);
  assertEquals(
    t.cash + t.credit + t.gratuity - t.tipOut + t.regular + t.overtime,
    2916,
  );
});

Deno.test("a malformed day is skipped rather than counted as zero", () => {
  // Counting it as zero would quietly lower a total; skipping it leaves
  // days_in_range as the tell that something was dropped.
  const t = sumSnapshotDays(
    [day("2026-09-01", { cash: 1000 }), { day: 5 }, "nonsense", null],
    null,
    null,
    null,
  );
  assertEquals(t.cash, 1000);
  assertEquals(t.inRange, 1);
});

Deno.test("a non-array payload sums to nothing rather than throwing", () => {
  assertEquals(sumSnapshotDays(undefined, null, null, null).inRange, 0);
  assertEquals(sumSnapshotDays({ days: [] }, null, null, null).cash, 0);
});

Deno.test("earned income includes wages, asserted against a literal", () => {
  // A LITERAL, not a re-derivation. The previous version of this check
  // recomputed the sum in the test, so dropping `+ regular + overtime`
  // from the response passed all nineteen tests.
  assertEquals(
    earnedIncomeCents({
      cash: 500, credit: 800, gratuity: 100, tipOut: 200,
      regular: 1320, overtime: 396,
    }),
    2916,
  );
  // And tips-only is 1200, which is what the legacy figure reports. The
  // gap between them is the bug this whole engine exists to close.
  assertEquals(
    earnedIncomeCents({
      cash: 500, credit: 800, gratuity: 100, tipOut: 200,
      regular: 0, overtime: 0,
    }),
    1200,
  );
});

/// The serving half of the snapshot path, which had no test at all.
///
/// `SnapshotUploaderTests` covers the device publishing with nine cases.
/// Nothing covered the API reading it back, so "the engine's answer is
/// served" rested on the code looking right.
///
/// Expected totals are LITERALS on purpose. The mirror-test trap in this
/// very file already cost a real defect once: a test that recomputed the
/// sum passed all 19 cases while `+ regular + overtime` was missing from
/// the implementation. A test that redoes the arithmetic cannot detect the
/// arithmetic being wrong.
function stubCtx(snapshot: unknown, revision: unknown) {
  const table = (name: string) => ({
    select: () => ({
      eq: () => ({
        maybeSingle: () =>
          Promise.resolve({
            data: name === "earnings_snapshots" ? snapshot : revision,
          }),
      }),
    }),
  });
  return {
    key: { user_id: "u1" },
    admin: { from: (name: string) => table(name) },
    // deno-lint-ignore no-explicit-any
  } as any;
}

const DAY = {
  day: "2026-09-10",
  minutes: 300,
  totalShifts: 1,
  knownComponents: {
    voluntaryCashCents: 1000,
    voluntaryCreditCents: 2000,
    gratuityFeesCents: 300,
    tipOutCents: 150,
    regularWagesCents: 1415,
    overtimeWagesCents: 0,
  },
};

Deno.test("engine earnings are absent until a device publishes", async () => {
  const out = await engineEarnings(stubCtx(null, null), null, null);
  assertEquals(out.available, false);
  assertEquals(out.reason, "no_snapshot");
});

Deno.test("the API serves the device's WAGE-INCLUSIVE figure", async () => {
  const snap = {
    dataset_revision: 7,
    engine_version: 1,
    as_of: "2026-09-19",
    payload: { days: [DAY] },
  };
  const out = await engineEarnings(stubCtx(snap, { revision: 7 }), null, null);
  assertEquals(out.available, true);
  assertEquals(out.stale, false);
  // 1000 + 2000 + 300 - 150 + 1415 + 0. Written out, not computed: dropping
  // the wage terms is exactly the defect this file shipped once before, and
  // 3150 (the non-wage answer) must not pass.
  assertEquals(out.earned_income_cents, 4565);
  assertEquals(out.regular_wages_cents, 1415);
  assertEquals(out.minutes_worked, 300);
});

Deno.test("stale flips when the dataset moved under the snapshot", async () => {
  const snap = {
    dataset_revision: 7,
    engine_version: 1,
    as_of: "2026-09-19",
    payload: { days: [DAY] },
  };
  const out = await engineEarnings(stubCtx(snap, { revision: 8 }), null, null);
  assertEquals(out.available, true);
  assertEquals(out.stale, true);
});

Deno.test("a day outside the range contributes nothing", async () => {
  const snap = {
    dataset_revision: 1,
    engine_version: 1,
    as_of: "2026-09-19",
    payload: { days: [DAY] },
  };
  const out = await engineEarnings(
    stubCtx(snap, { revision: 1 }), "2026-09-11", "2026-09-12");
  assertEquals(out.days_in_range, 0);
  assertEquals(out.earned_income_cents, 0);
});

// Fixture S2 (PaydayCore/Tests/PaydayCoreTests/Fixtures/S2.json): W2's week,
// valued per day, plus a shift on Oct 9, a week after the document's asOf.
const S2_DAYS = [
  day("2026-09-28", { regular: 2901, minutes: 615 }),
  day("2026-09-29", { regular: 2759, minutes: 585 }),
  day("2026-09-30", { regular: 2972, minutes: 630 }),
  day("2026-10-01", { regular: 2688, overtime: 849, minutes: 690 }),
  day("2026-10-02", { overtime: 2547, minutes: 360 }),
  day("2026-10-09", {
    cash: 5000, credit: 8000, tipOut: 1000, regular: 2264, minutes: 480,
  }),
];

Deno.test("days after the document's asOf are left out, as the engine leaves them out", async () => {
  const snap = {
    dataset_revision: 1,
    engine_version: 1,
    as_of: "2026-10-02",
    payload: { asOf: "2026-10-02", days: S2_DAYS },
  };
  const earned = async (start: string | null, end: string | null) =>
    (await engineEarnings(stubCtx(snap, { revision: 1 }), start, end))
      .earned_income_cents;
  // S2 lists 28980 (the Oct 9 shift added in) as the wrong answer.
  assertEquals(await earned(null, null), 14716);
  assertEquals(await earned("2026-09-28", "2026-10-09"), 14716);
  assertEquals(await earned("2026-10-01", "2026-10-31"), 6084);
  assertEquals(await earned("2026-10-09", "2026-10-09"), 0);
  // An explicit end before the cutoff still wins.
  assertEquals(await earned("2026-09-01", "2026-09-30"), 8632);
  const all = await engineEarnings(stubCtx(snap, { revision: 1 }), null, null);
  assertEquals(all.days_in_range, 5);
  assertEquals(all.minutes_worked, 2880);
  // A document with no asOf has no cutoff, so nothing is clamped.
  const open = { ...snap, payload: { days: S2_DAYS } };
  assertEquals(
    (await engineEarnings(stubCtx(open, { revision: 1 }), null, null))
      .earned_income_cents,
    28980,
  );
});

function failingCtx(failing: string) {
  const table = (name: string) => ({
    select: () => ({
      eq: () => ({
        maybeSingle: () =>
          Promise.resolve(
            name === failing
              ? { data: null, error: { message: "connection reset" } }
              : {
                data: name === "earnings_snapshots"
                  ? { dataset_revision: 1, engine_version: 1, as_of: "2026-09-19", payload: { days: [DAY] } }
                  : { revision: 1 },
                error: null,
              },
          ),
      }),
    }),
  });
  return {
    key: { user_id: "u1" },
    admin: { from: (name: string) => table(name) },
    // deno-lint-ignore no-explicit-any
  } as any;
}

Deno.test("a failed earnings read is a database error, not a missing snapshot", async () => {
  // "no_snapshot" says no device ever published, which a dropped connection
  // does not show. The caller gets an error it can retry instead.
  for (const failing of ["earnings_snapshots", "dataset_revisions"]) {
    const error = await assertRejects(
      () => engineEarnings(failingCtx(failing), null, null),
      Error,
      "Unable to read the earnings snapshot.",
    ) as Error & { status?: number; code?: string };
    assertEquals(error.status, 500, failing);
    assertEquals(error.code, "database_error", failing);
  }
});

Deno.test("a received tip share is reported and already inside the stored net", () => {
  // A bartender with no card tips: $180 share in, $40 tipped out.
  const shift = testing.shiftResponse({
    id: "44444444-4444-4444-8444-444444444444",
    work_date: "2026-09-05",
    cash_tips_cents: 0,
    credit_tips_cents: 0,
    gratuity_fees_cents: 0,
    tip_out_cents: 4000,
    tip_share_in_cents: 18000,
    // The generated column: cash + credit + gratuity + tip_share_in - tip_out.
    non_wage_earnings_cents: 14000,
    legacy_entry_ids: [],
    source: "device",
  });
  assertEquals(shift.tip_share_in_cents, 18000);
  assertEquals(shift.net_tip_earnings_cents, 14000);
  assertEquals(shift.gross_tip_earnings_cents, 18000);
});

Deno.test("a shift with no tip share reports null, not zero", () => {
  const shift = testing.shiftResponse({
    id: "55555555-5555-4555-8555-555555555555",
    work_date: "2026-09-05",
    non_wage_earnings_cents: 0,
  });
  assertEquals(shift.tip_share_in_cents, null);
});

Deno.test("a shift row carries its role, and null without one", () => {
  const base = {
    id: "66666666-6666-4666-8666-666666666666",
    work_date: "2026-09-05",
    non_wage_earnings_cents: 10000,
  };
  assertEquals(testing.shiftResponse({ ...base, role_name: "Bar" }).role_name, "Bar");
  assertEquals(testing.shiftResponse(base).role_name, null);
  // A role is not money.
  assertEquals(testing.shiftResponse({ ...base, role_name: "Bar" }).net_tip_earnings_cents, 10000);
});

Deno.test("a shift row carries its job, and null for the primary job", () => {
  const base = {
    id: "77777777-7777-4777-8777-777777777777",
    work_date: "2026-09-05",
    non_wage_earnings_cents: 10000,
  };
  assertEquals(testing.shiftResponse({ ...base, job_name: "Cafe" }).job_name, "Cafe");
  assertEquals(testing.shiftResponse(base).job_name, null);
  // A job is not money.
  assertEquals(testing.shiftResponse({ ...base, job_name: "Cafe" }).net_tip_earnings_cents, 10000);
});

Deno.test("an agent cannot write a paycheck's job: it is read-only", () => {
  assertThrows(() =>
    testing.paycheckPayload({
      period_start: "2026-09-01",
      period_end: "2026-09-14",
      paid_tips_cents: 0,
      job_name: "Cafe",
    }, false)
  );
});

Deno.test("snapshot sums carry a received tip share into earned income", () => {
  const days = [{
    day: "2026-09-05",
    minutes: 0,
    totalShifts: 1,
    knownComponents: {
      voluntaryCashCents: 0, voluntaryCreditCents: 0, gratuityFeesCents: 0,
      tipOutCents: 4000, tipShareInCents: 18000,
      regularWagesCents: 1000, overtimeWagesCents: 0,
    },
  }];
  const t = sumSnapshotDays(days, null, null, null);
  assertEquals(t.tipShareIn, 18000);
  assertEquals(earnedIncomeCents(t), 15000);
  // A document written before the component existed sums it as zero.
  assertEquals(sumSnapshotDays([day("2026-09-01", { cash: 100 })], null, null, null).tipShareIn, 0);
});

Deno.test("settings accept card_tips_paid_at_close as a boolean only", () => {
  assertEquals(
    testing.settingsPayload({ card_tips_paid_at_close: true }),
    { card_tips_paid_at_close: true },
  );
  assertThrows(() => testing.settingsPayload({ card_tips_paid_at_close: "yes" }));
});
