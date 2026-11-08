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
4. The screen shows a preview (about 55 bi-weekly stubs). Tap **Import**.
5. Check Periods: one paycheck per stub period. A period that already had a
   typed paycheck keeps it, with only its empty fields filled.

## Production

Production needs a paid Truv plan. Put the production key into the same two
secrets and set `TRUV_ENV=production`. No app change and no new build.

## Rules the code keeps

- An import never makes a second paycheck for a period the person already
  has, and never overwrites a figure they entered (`PayrollImporter`).
- The first import, after every new connection, waits for a preview and an
  Import tap. After that, the app imports on open (at most every 6 hours)
  and on pull-to-refresh in Periods.
- "Check for new paystubs" starts a Truv data refresh. The server allows one
  per link every 20 hours.
- "Remove imported paychecks" deletes only paychecks the import made that
  nobody changed since.
- Tip lines: "tips" words count as tips paid on the check, except cash /
  declared / reported tips (already in the person's pocket) and tip credit or
  make-up lines (wages). Gratuity and service charge lines go to gratuity.
  The rules are in `normalize.ts`.
