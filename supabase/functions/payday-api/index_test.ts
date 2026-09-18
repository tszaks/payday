import { assertEquals, assertThrows } from "@std/assert";
import { handleRequest, testing } from "./index.ts";

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
