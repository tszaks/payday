# Connect payroll (Truv)

"Connect payroll" lets a person sign in to their payroll account (Toast, or
any provider Truv supports) and imports their pay stubs as paychecks.

- Edge function: `supabase/functions/payroll-connect/` (one POST endpoint,
  `{ "action": ... }`). No table and no migration: Truv keeps the link list,
  keyed by `external_user_id` = the Supabase auth uid.
- App: `Payday/PayrollConnect/`. Settings > Connect payroll.
- Imported paychecks are ordinary `PaycheckRecord`s and sync like typed ones.
  The map of pay stub to paycheck, hours and deduction lines stays on the
  phone (`PayrollImportLedger`), and is erased with the account.

## Secrets

Set these as Supabase function secrets. Never put them in the repo.

| Name | Value |
| --- | --- |
| `TRUV_CLIENT_ID` | Truv client id |
| `TRUV_ACCESS_SECRET` | Truv access secret (sandbox or production key) |
| `TRUV_ENV` | `sandbox` or `production` |

```sh
supabase secrets set TRUV_CLIENT_ID=... TRUV_ACCESS_SECRET=... TRUV_ENV=sandbox
supabase functions deploy payroll-connect
```

`TRUV_ENV` only labels the data in the app ("Test mode: sample payroll
data"). The key decides which Truv data comes back. Keep the two in step.

## Test in sandbox

1. Set the sandbox key and `TRUV_ENV=sandbox`, then deploy the function.
2. In the app: Settings > Connect payroll > Connect payroll.
3. In Truv Bridge, search **Truv Payroll Provider**. Sign in with
   `goodlogin` / `goodpassword` (prefilled in sandbox).
4. The screen shows a preview (52 bi-weekly stubs, employer "Acme", on
   2026-11-08). Tap **Import**.
5. Check Periods: one paycheck per stub period. A period that already had a
   typed paycheck keeps it, with only its empty fields filled.

## Production

Production needs a paid Truv plan. The switch is two Supabase secrets,
nothing else:

```sh
supabase secrets set TRUV_ACCESS_SECRET=<production secret> TRUV_ENV=production
```

`TRUV_CLIENT_ID` stays the same unless Truv gives a different one for
production. No app change, no new build: the app has no Truv key and no
environment setting. The Bridge token the server makes decides which Truv
environment the sign-in screen talks to, and the server tells the app which
one it is (the "Test mode" line goes away).

Before the switch, testers should tap **Remove imported paychecks** for
any sample paychecks they imported. Sandbox Truv users and links do not
exist under the production key, so after the switch the app shows "Connect
payroll" again.

If the secrets are missing or Truv refuses the key, the server answers 503
(`not_configured` or `truv_not_configured`). The app then says "Payroll
connection isn't available right now" and shows no Connect button.

### Cost (Truv dashboard, 2026-11-08)

Self-serve under Billing > Choose plan (use case "Consumer Lending"; no
sales call needed):

| Plan | Monthly commitment | Per successful payroll connection |
| --- | --- | --- |
| Launch | $300 | $30 |
| Growth | $500 | $25 |
| Professional | $1,000 | $20 |
| Professional Plus | $1,500 | $15 |

The monthly fee becomes prepaid credits that expire after each 30-day cycle;
using them up starts the next cycle (and charge) early. Only successful
verifications are billed. Refreshes of a report are free for 90 days. Cancel
by emailing support@truv.com at least 30 days before renewal.

To go live: Truv dashboard > Billing > choose a plan > company details >
payment, then Development > API keys > production secret, then the
`supabase secrets set` line above on the Payday project.

## Rules the code keeps

- An import never makes a second paycheck for a period the person already
  has, and never overwrites a figure they entered (`PayrollImporter`).
- The first import, after every new connection, waits for a preview and an
  Import tap. After that, the app imports on open (at most every 6 hours)
  and on pull-to-refresh in Periods.
- "Check for new paystubs" starts a Truv data refresh. The server allows one
  per link every 20 hours, counted from the link's `updated_at` (when Truv
  last read the account), so a link connected a moment ago is already fresh.
  On top of that, each function isolate reserves the 20 hours in memory
  before it calls Truv, so two taps at once start one paid refresh.
  **Known limit:** there is deliberately no table, so the reservation is per
  isolate. A request that reaches another isolate, or comes after a cold
  start, sees only `updated_at`, and can start a second refresh before Truv
  moves `updated_at`.
- Disconnect deletes the Truv link. Truv answered 403 to a single-link
  delete for our sandbox account (2026-11-08) while it allows deleting the
  Truv user, so when the link is the person's only one the server deletes
  their Truv user instead (same result: no link, no data at Truv). With more
  links it reports the refusal. Errors carry `truv_status` for this reason.
- Account deletion calls `forget` first: it deletes the person's Truv user,
  all links and the data Truv read. Best effort, with a 5 second timeout:
  Truv being down never blocks an account deletion. **Known limit:** if
  `forget` fails at that moment, the Truv user stays at Truv, and no Payday
  account can reach it any more. Delete it from the Truv dashboard (search
  by external user id = the deleted Supabase user id).
- A link that exists but is not `done` keeps the connection on. The server
  lists every link and reads only `done` ones. A link still running (`new`,
  `login`, `mfa`, `parse`, `full_parse`) shows "Still connecting". Any
  other state (`login_error`, `mfa_error`, `account_locked`, ...) shows
  "Sign in again" and a **Reconnect** button.
- Reconnect opens Bridge in Truv's update mode on the SAME link, so no second
  link is made. That needs the link's access token. Nothing stores it: Truv
  returns it in full only in `GET /links/?user_id=<truv user>`, so the
  server reads it there (after the ownership check), passes it to Truv in
  the bridge token request, and never returns it. If Truv returns it masked,
  the app says to disconnect and connect again (`reconnect_unavailable`).
- Disconnect is offered for every link in any state, and "Remove imported
  paychecks" for as long as the import record lists paychecks it made, even
  after the last link is gone.
- "Remove imported paychecks" deletes only paychecks the import made that
  nobody changed since. It turns automatic imports off and saves that
  BEFORE it deletes anything, so a removal that fails part way can't be
  undone by the next automatic import.
- When two stubs could match one paycheck the person typed (two weekly
  stubs inside one biweekly period), the paycheck goes to the stub whose net,
  then gross, it already holds. Date order decides only when the amounts
  say nothing.
- **Known limit:** when the payroll pays more often than the pay schedule
  set in Payday (weekly stubs, biweekly schedule), each stub is still its
  own paycheck, but Periods shows one paycheck per schedule period. The
  preview warns about this so the person can fix their schedule.
- The server only reads stubs (cents, dates, every line as printed). Which
  lines are tips, gratuity or taxes is decided in PaydayCore,
  `PayStubFigures`: "tips" words count as tips paid on the check, except
  cash / declared / reported tips (already in the person's pocket) and tip
  credit or make-up lines (wages). Gratuity and service charge lines go to
  gratuity. Taxes are the federal, state, local, Social Security and
  Medicare lines.
- The employer name comes from Bridge's employer choice, or else from the
  link's employment record. It picks a Payday job only on an exact name
  match; otherwise the paycheck goes to the primary job.
- An imported paycheck's id is derived from the account and the stub, so two
  phones importing the same stub upload one row. The pay stub map stays on
  each phone, so a paycheck deleted on one phone can come back from another
  phone's import.
