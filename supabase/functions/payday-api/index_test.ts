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

Deno.test("shift summaries preserve v2 gratuity and canonical tip-out", () => {
  const rows = [
    {
      id: "11111111-1111-4111-8111-111111111111",
      user_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      shift_id: "33333333-3333-4333-8333-333333333333",
      work_date: "2026-08-31",
      kind: "cash",
      amount_cents: 1000,
      version: 1,
    },
    {
      id: "22222222-2222-4222-8222-222222222222",
      user_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      shift_id: "33333333-3333-4333-8333-333333333333",
      work_date: "2026-08-31",
      kind: "credit",
      amount_cents: 2000,
      tip_out_cents: 300,
      receipt_metrics: {
        earningsSchemaVersion: 2,
        gratuityFeesCents: 500,
      },
      version: 1,
    },
  ];
  const shift = testing.groupShifts(rows)[0];
  assertEquals(shift.cash_tip_cents, 1000);
  assertEquals(shift.credit_tip_cents, 2000);
  assertEquals(shift.gratuity_cents, 500);
  assertEquals(shift.gross_tip_earnings_cents, 3500);
  assertEquals(shift.net_tip_earnings_cents, 3200);
  assertEquals(
    (shift.tip_entries as Record<string, unknown>[])[0].user_id,
    undefined,
  );
});

Deno.test("legacy combined tips do not double-count gratuity", () => {
  assertEquals(
    testing.tipFacts({
      amount_cents: 2500,
      receipt_metrics: { gratuityFeesCents: 500 },
    }),
    { voluntary: 2000, gratuity: 500, gross: 2500, net: 2500 },
  );
});

Deno.test("shift summaries use exactly one receipt-metrics owner", () => {
  const metrics = { earningsSchemaVersion: 2, gratuityFeesCents: 500 };
  const shift = testing.groupShifts([{
    id: "11111111-1111-4111-8111-111111111111",
    shift_id: "33333333-3333-4333-8333-333333333333",
    work_date: "2026-08-31",
    kind: "cash",
    amount_cents: 1000,
    receipt_metrics: metrics,
  }, {
    id: "22222222-2222-4222-8222-222222222222",
    shift_id: "33333333-3333-4333-8333-333333333333",
    work_date: "2026-08-31",
    kind: "credit",
    amount_cents: 2000,
    receipt_metrics: metrics,
  }])[0];
  assertEquals(shift.gratuity_cents, 500);
  assertEquals(shift.gross_tip_earnings_cents, 3500);
});

Deno.test("shift summaries use the database cursor's max work date", () => {
  const shift = testing.groupShifts([{
    id: "22222222-2222-4222-8222-222222222222",
    shift_id: "33333333-3333-4333-8333-333333333333",
    work_date: "2026-08-31",
    kind: "credit",
    amount_cents: 2000,
  }, {
    id: "11111111-1111-4111-8111-111111111111",
    shift_id: "33333333-3333-4333-8333-333333333333",
    work_date: "2026-09-01",
    kind: "cash",
    amount_cents: 1000,
  }])[0];

  assertEquals(shift.id, "33333333-3333-4333-8333-333333333333");
  assertEquals(shift.work_date, "2026-09-01");
  assertEquals(
    (shift.tip_entries as Record<string, unknown>[]).map((row) => row.id),
    [
      "11111111-1111-4111-8111-111111111111",
      "22222222-2222-4222-8222-222222222222",
    ],
  );
});

Deno.test("shift details fall back field by field from credit to cash", () => {
  const shift = testing.groupShifts([{
    id: "11111111-1111-4111-8111-111111111111",
    shift_id: "33333333-3333-4333-8333-333333333333",
    work_date: "2026-08-31",
    kind: "cash",
    amount_cents: 1000,
    hours_worked: 6.5,
  }, {
    id: "22222222-2222-4222-8222-222222222222",
    shift_id: "33333333-3333-4333-8333-333333333333",
    work_date: "2026-08-31",
    kind: "credit",
    amount_cents: 2000,
    hours_worked: null,
  }])[0];
  assertEquals(shift.hours_worked, 6.5);
});
