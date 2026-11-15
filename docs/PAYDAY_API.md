# Payday API

Payday exposes the same Supabase source of truth through a versioned REST API
and a remote MCP endpoint. Phone authentication remains Sign in with Apple;
agents use separate `pd_live_*` credentials that are hashed at rest, scoped,
rate-limited, revocable, and audited.

## Endpoints

- Base URL: `https://bkkxunqqfkogxibyyjmc.supabase.co/functions/v1/payday-api`
- OpenAPI: `/v1/openapi.json`
- Health: `/v1/health`
- MCP Streamable HTTP: `/mcp`

> **Contract change, 2026-09-18.** A shift is now **read** from the derived
> `public.shifts` table rather than assembled from tip rows at request time.
> Two things changed for callers, both deliberate:
>
> - **`tip_entries` is gone from a shift response**, replaced by
>   `legacy_entry_ids` and `source`. A shift is no longer built from rows, so
>   embedding them would mean re-deriving the figure the database already
>   computed. If you were reading that array to reconcile an id you obtained
>   earlier, `GET /v1/shifts/{id}` now accepts any of those ids directly.
> - **`GET /v1/shifts/{id}` resolves more ids than before, not fewer.** It
>   previously filtered on `shift_id` alone, so a shift whose legacy rows
>   carried no `shift_id` — which the listing reported under the *row's* id —
>   returned 404. You could list a shift and then fail to fetch it. Both that
>   id and the shift's own now resolve.
>
> Why: the API was computing net earnings in TypeScript, the app computed them
> in Swift, and the database computed them in SQL — three implementations that
> disagreed about a shift's date, its detail precedence and its receipt owner.
> There is now one, in SQL, and this layer reads it.
>
> **Wages are reported in `data.earnings` of the summary.** A wage is a
> property of a workweek under a rate policy, not of a row, so the server does
> not value one. The iPhone publishes a snapshot of per-day figures its engine
> already valued, and `GET /v1/summary` (`get_summary`) adds up the days in
> the requested range: `earned_income_cents` is the wage-inclusive figure the
> app shows, beside `regular_wages_cents`, `overtime_wages_cents`, the tip
> components, `minutes_worked`, `shift_count` and `days_in_range`. Days after
> the snapshot's `as_of` are left out, as the app leaves them out.
> `available: false` with `reason: "no_snapshot"` means no device has
> published yet; `stale: true` means the data changed after the snapshot was
> made and stays true until a device publishes again. `data.shifts` is the
> older tips-only total: it includes no wage and is not comparable with
> `data.earnings` or with the app.

REST resources include summaries, grouped shifts, raw tip entries, paychecks,
settings, incremental changes, agent keys, and the audit log. The MCP endpoint
publishes matching tools.

## Authentication and permissions

Send a key as `Authorization: Bearer pd_live_…`. Available scopes are:

- `read`: summaries, shifts, tips, paychecks, settings, and changes
- `write`: create shifts; create/update/restore tips and paychecks; update
  settings
- `delete`: soft-delete tips and paychecks
- `admin`: create/revoke keys and read the audit log

Never use a Supabase secret/service-role key in an agent. A Payday key can only
access the one Payday user it belongs to. Newly created keys are displayed once;
only their SHA-256 hashes are stored.

Financial and settings mutations require an idempotency key; updates/deletes
also require the current record `version`. Auto-generated record IDs are stable
for a given idempotency key, preventing duplicate creates after an ambiguous
network failure. Version checks prevent one writer from silently overwriting
another. Deletions are tombstones, so the iPhone receives them through normal
sync and they can be restored. Direct authenticated table deletes are disabled.
Recovery markers are scoped to the authenticating key and exact request body.

`GET /v1/changes` is cursor-paginated across tips, paychecks, and settings. Keep
calling it with the returned `next_cursor` while `has_more` is true; this avoids
losing rows when many records share the same update timestamp.

## REST examples

Keep the token in a secret manager or the macOS Keychain rather than shell
history.

```sh
curl "$PAYDAY_API_URL/v1/summary?start_date=2026-08-01" \
  -H "Authorization: Bearer $PAYDAY_API_TOKEN"

curl "$PAYDAY_API_URL/v1/shifts" \
  -H "Authorization: Bearer $PAYDAY_API_TOKEN"

curl "$PAYDAY_API_URL/v1/shifts" \
  -X POST \
  -H "Authorization: Bearer $PAYDAY_API_TOKEN" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: agent-shift-unique-id" \
  --data '{"work_date":"2026-08-31","cash_tip_cents":2000,"credit_tip_cents":10000}'
```

Money is always integer cents. Dates are `YYYY-MM-DD`; instants are ISO-8601.

## MCP clients

Remote MCP clients can connect directly to:

```text
https://bkkxunqqfkogxibyyjmc.supabase.co/functions/v1/payday-api/mcp
```

and send the Payday token as a Bearer token. Tyler's Codex configuration uses
`scripts/payday-mcp-stdio`, which retrieves its admin credential from macOS
Keychain so no plaintext token is stored in Codex configuration or process
arguments. The bridge negotiates the MCP protocol version, supports JSON and
SSE responses, and bounds remote calls with a timeout.

To create a narrower key for another agent, use `POST /v1/keys` from a secure
provisioning process and write the one-time token directly to that agent's
secret manager. Key creation is intentionally not exposed as an MCP tool so a
new token cannot be copied into an agent transcript. A child key cannot exceed
its creator's scopes, rate limit, or expiry; delegated admins must create
expiring children. Revoking a key with `revoke_api_key` or
`DELETE /v1/keys/{id}` also revokes all descendant keys. An API key cannot
revoke itself; use another active admin key so an interrupted revocation stays
recoverable.
