# PaydayCore fixtures

One JSON file per fixture ID (`W1.json`, `W2.json`, ... see `docs/METRICS.md`
for the table of IDs and their independently specified expected values).
Loaded by `Tests/PaydayCoreTests/Support/FixtureLoader.swift` via
`Bundle.module`, and by the Deno golden test in
`supabase/functions/payday-api`, so the shape is a contract:

```json
{
  "id": "W1",
  "description": "...",
  "kind": "ledger | migration | query | export | paycheck | presentation",
  "policies": {
    "rate": [ { "effectiveFrom": "YYYY-MM-DD", "hourlyRateCents": 283, "provenance": "confirmed | assumedFromLegacySetting" } ],
    "calendar": [ { "effectiveFrom": "YYYY-MM-DD", "workweekStartWeekday": 2, "overtimeThresholdMinutes": 2400, "overtimeMultiplierHundredths": 150, "payrollTimeZone": "America/New_York" } ]
  },
  "schedule": { "frequency": "weekly | biweekly | twiceMonthly | monthly", "anchorPeriodEnd": "YYYY-MM-DD", "firstWeekday": 2 } | null,
  "shifts": [ { "id": "uuid", "workDay": "YYYY-MM-DD", "period": "lunch | dinner" | null, "minutesWorked": 255 | null, "voluntaryCashCents": 0, "voluntaryCreditCents": 0, "gratuityFeesCents": 0, "tipOutCents": 0 | null } ],
  "legacyEntries": [ { "id": "uuid", "shiftID": "uuid" | null, "date": "YYYY-MM-DD" | "YYYY-MM-DDTHH:MM:SS-04:00", "amountCents": 0, "kind": "cash | credit", "tipOutCents": 0 | null, "hoursWorked": 4.25 | null, "receiptMetricsJSON": "..." | null } ],
  "paychecks": [ { "id": "uuid", "periodStart": "YYYY-MM-DD", "periodEnd": "YYYY-MM-DD", "paidTipsCents": 0, "grossPayCents": 0, ... } ],
  "asOf": "YYYY-MM-DD" | null,
  "deviceTimeZone": "Pacific/Honolulu",
  "expected": { "...": 0, "wrongAnswers": { "label": 0 } },
  "notes": "..."
}
```

A legacy entry's `date` is the stored `TipEntry.date`, a `Date`, so it may be
a full ISO-8601 timestamp with offset (N1, N3: the migration reduces it to a
civil day in the payroll zone) or a bare civil day (N2). `Fixture.LegacyEntry
.civilDay(in:)` accepts both.

`KnownIssues.json` in this directory is the list of fixture IDs whose tests
are wrapped in `withKnownIssue` (see `Support/KnownIssues.swift` and
`docs/CI.md`). It must be `[]` for a release.

This README exists so the directory is present (and the `.copy("Fixtures")`
resource resolves) even before the first fixture lands.
