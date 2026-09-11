import "@supabase/functions-js/edge-runtime.d.ts";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";

const API_VERSION = "1.0.0";
const MCP_PROTOCOL_VERSION = "2025-06-18";
const MAX_BODY_BYTES = 256_000;
const IDEMPOTENCY_STALE_MS = 30_000;
const ALL_SCOPES = ["read", "write", "delete", "admin"] as const;
type Scope = typeof ALL_SCOPES[number];

type JsonObject = Record<string, unknown>;

interface AgentKey {
  id: string;
  user_id: string;
  name: string;
  scopes: Scope[];
  rate_limit_per_minute: number;
  expires_at: string | null;
  created_by_key_id: string | null;
}

interface RequestContext {
  admin: SupabaseClient;
  key: AgentKey;
  requestID: string;
  startedAt: number;
  idempotencyKey?: string;
  idempotencyMarker?: string;
}

interface ApiResult {
  status: number;
  body: JsonObject;
  operation: string;
  headers?: Record<string, string>;
  errorCode?: string;
}

class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
  }
}

const jsonHeaders = {
  "content-type": "application/json; charset=utf-8",
  "cache-control": "no-store",
  "x-content-type-options": "nosniff",
  "referrer-policy": "no-referrer",
};

function jsonResponse(
  body: unknown,
  status = 200,
  headers: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...jsonHeaders, ...headers },
  });
}

function noContent(status = 204): Response {
  return new Response(null, { status, headers: jsonHeaders });
}

function isRecord(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function requireObject(value: unknown, label = "body"): JsonObject {
  if (!isRecord(value)) {
    throw new ApiError(
      400,
      "invalid_request",
      `${label} must be a JSON object.`,
    );
  }
  return value;
}

function requiredString(
  value: unknown,
  field: string,
  maxLength = 10_000,
): string {
  if (
    typeof value !== "string" || value.length === 0 || value.length > maxLength
  ) {
    throw new ApiError(
      400,
      "invalid_field",
      `${field} must be a non-empty string no longer than ${maxLength} characters.`,
    );
  }
  return value;
}

function optionalString(
  value: unknown,
  field: string,
  maxLength = 10_000,
): string | null | undefined {
  if (value === undefined) return undefined;
  if (value === null) return null;
  if (typeof value !== "string" || value.length > maxLength) {
    throw new ApiError(
      400,
      "invalid_field",
      `${field} must be null or a string no longer than ${maxLength} characters.`,
    );
  }
  return value;
}

function integer(value: unknown, field: string, minimum = 0): number {
  if (!Number.isSafeInteger(value) || (value as number) < minimum) {
    throw new ApiError(
      400,
      "invalid_field",
      `${field} must be an integer greater than or equal to ${minimum}.`,
    );
  }
  return value as number;
}

function optionalInteger(
  value: unknown,
  field: string,
  minimum = 0,
): number | null | undefined {
  if (value === undefined) return undefined;
  if (value === null) return null;
  return integer(value, field, minimum);
}

function optionalNumber(
  value: unknown,
  field: string,
  minimum = 0,
): number | null | undefined {
  if (value === undefined) return undefined;
  if (value === null) return null;
  if (typeof value !== "number" || !Number.isFinite(value) || value < minimum) {
    throw new ApiError(
      400,
      "invalid_field",
      `${field} must be null or a finite number greater than or equal to ${minimum}.`,
    );
  }
  return value;
}

function optionalBoolean(value: unknown, field: string): boolean | undefined {
  if (value === undefined) return undefined;
  if (typeof value !== "boolean") {
    throw new ApiError(400, "invalid_field", `${field} must be a boolean.`);
  }
  return value;
}

function uuid(value: unknown, field: string): string {
  const result = requiredString(value, field, 36).toLowerCase();
  if (
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
      .test(result)
  ) {
    throw new ApiError(400, "invalid_field", `${field} must be a UUID.`);
  }
  return result;
}

function optionalUUID(
  value: unknown,
  field: string,
): string | null | undefined {
  if (value === undefined) return undefined;
  if (value === null) return null;
  return uuid(value, field);
}

function dateOnly(value: unknown, field: string): string {
  const result = requiredString(value, field, 10);
  const parsed = new Date(`${result}T00:00:00Z`);
  if (
    !/^\d{4}-\d{2}-\d{2}$/.test(result) ||
    Number.isNaN(parsed.getTime()) ||
    parsed.toISOString().slice(0, 10) !== result
  ) {
    throw new ApiError(400, "invalid_field", `${field} must use YYYY-MM-DD.`);
  }
  return result;
}

function optionalDate(
  value: unknown,
  field: string,
): string | null | undefined {
  if (value === undefined) return undefined;
  if (value === null) return null;
  return dateOnly(value, field);
}

function timestamp(value: unknown, field: string): string {
  const result = requiredString(value, field, 64);
  if (
    !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/
      .test(
        result,
      )
  ) {
    throw new ApiError(
      400,
      "invalid_field",
      `${field} must be an ISO-8601 timestamp with a timezone.`,
    );
  }
  const parsed = new Date(result);
  if (Number.isNaN(parsed.getTime())) {
    throw new ApiError(
      400,
      "invalid_field",
      `${field} must be an ISO-8601 timestamp.`,
    );
  }
  return parsed.toISOString();
}

function receiptMetrics(
  value: unknown,
  field: string,
): JsonObject | null | undefined {
  const metrics = optionalObject(value, field);
  if (!metrics) return metrics;
  requireOnlyFields(metrics, [
    "earningsSchemaVersion",
    "guestCount",
    "creditCheckCount",
    "tableCount",
    "tableCountSource",
    "netSalesCents",
    "taxCents",
    "printedTipPercentHundredths",
    "averageSpendPerGuestCents",
    "cashSalesCents",
    "gratuityFeesCents",
    "totalAmountCents",
    "categorySales",
    "tipSharing",
  ]);
  const nonnegativeIntegers = [
    "earningsSchemaVersion",
    "guestCount",
    "creditCheckCount",
    "tableCount",
    "netSalesCents",
    "taxCents",
    "printedTipPercentHundredths",
    "averageSpendPerGuestCents",
    "cashSalesCents",
    "gratuityFeesCents",
    "totalAmountCents",
  ];
  for (const key of nonnegativeIntegers) {
    if (metrics[key] !== undefined && metrics[key] !== null) {
      integer(metrics[key], `${field}.${key}`);
    }
  }
  if (
    metrics.earningsSchemaVersion !== undefined &&
    metrics.earningsSchemaVersion !== null &&
    Number(metrics.earningsSchemaVersion) < 1
  ) {
    throw new ApiError(
      400,
      "invalid_field",
      `${field}.earningsSchemaVersion must be at least 1.`,
    );
  }
  if (
    metrics.tableCountSource !== undefined &&
    metrics.tableCountSource !== null
  ) {
    enumValue(
      metrics.tableCountSource,
      `${field}.tableCountSource`,
      [
        "printed",
        "inferredFromChecks",
        "confirmed",
      ] as const,
    );
  }
  if (metrics.categorySales !== undefined && metrics.categorySales !== null) {
    if (!Array.isArray(metrics.categorySales)) {
      throw new ApiError(
        400,
        "invalid_field",
        `${field}.categorySales must be an array.`,
      );
    }
    for (const [index, value] of metrics.categorySales.entries()) {
      const row = requireObject(value, `${field}.categorySales[${index}]`);
      requireOnlyFields(row, ["name", "quantity", "netSalesCents"]);
      requiredString(row.name, `${field}.categorySales[${index}].name`, 200);
      if (row.quantity !== undefined && row.quantity !== null) {
        integer(row.quantity, `${field}.categorySales[${index}].quantity`);
      }
      if (row.netSalesCents !== undefined && row.netSalesCents !== null) {
        integer(
          row.netSalesCents,
          `${field}.categorySales[${index}].netSalesCents`,
        );
      }
    }
  }
  if (metrics.tipSharing !== undefined && metrics.tipSharing !== null) {
    if (!Array.isArray(metrics.tipSharing)) {
      throw new ApiError(
        400,
        "invalid_field",
        `${field}.tipSharing must be an array.`,
      );
    }
    for (const [index, value] of metrics.tipSharing.entries()) {
      const row = requireObject(value, `${field}.tipSharing[${index}]`);
      requireOnlyFields(row, ["role", "amountCents"]);
      requiredString(row.role, `${field}.tipSharing[${index}].role`, 200);
      integer(row.amountCents, `${field}.tipSharing[${index}].amountCents`);
    }
  }
  return metrics;
}

function moveLedger(value: unknown, field: string): JsonObject {
  if (!isRecord(value)) {
    throw new ApiError(400, "invalid_field", `${field} must be a JSON object.`);
  }
  if (JSON.stringify(value).length > 100_000) {
    throw new ApiError(413, "field_too_large", `${field} is too large.`);
  }
  for (const [key, instant] of Object.entries(value)) {
    if (!key || key.length > 200) {
      throw new ApiError(
        400,
        "invalid_field",
        `${field} keys must contain 1 to 200 characters.`,
      );
    }
    timestamp(instant, `${field}.${key}`);
  }
  return value;
}

function optionalTimestamp(
  value: unknown,
  field: string,
): string | null | undefined {
  if (value === undefined) return undefined;
  if (value === null) return null;
  return timestamp(value, field);
}

function enumValue<T extends string>(
  value: unknown,
  field: string,
  allowed: readonly T[],
): T {
  const result = requiredString(value, field, 64) as T;
  if (!allowed.includes(result)) {
    throw new ApiError(
      400,
      "invalid_field",
      `${field} must be one of: ${allowed.join(", ")}.`,
    );
  }
  return result;
}

function optionalEnum<T extends string>(
  value: unknown,
  field: string,
  allowed: readonly T[],
): T | null | undefined {
  if (value === undefined) return undefined;
  if (value === null) return null;
  return enumValue(value, field, allowed);
}

function optionalObject(
  value: unknown,
  field: string,
): JsonObject | null | undefined {
  if (value === undefined) return undefined;
  if (value === null) return null;
  if (!isRecord(value)) {
    throw new ApiError(
      400,
      "invalid_field",
      `${field} must be null or a JSON object.`,
    );
  }
  if (JSON.stringify(value).length > 100_000) {
    throw new ApiError(413, "field_too_large", `${field} is too large.`);
  }
  return value;
}

async function readJSON(req: Request): Promise<unknown> {
  const declaredLength = Number(req.headers.get("content-length") ?? "0");
  if (declaredLength > MAX_BODY_BYTES) {
    throw new ApiError(413, "body_too_large", "Request body is too large.");
  }
  const text = await req.text();
  if (new TextEncoder().encode(text).byteLength > MAX_BODY_BYTES) {
    throw new ApiError(413, "body_too_large", "Request body is too large.");
  }
  if (!text) return {};
  try {
    return JSON.parse(text);
  } catch {
    throw new ApiError(
      400,
      "invalid_json",
      "Request body must contain valid JSON.",
    );
  }
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  return Array.from(new Uint8Array(digest)).map((byte) =>
    byte.toString(16).padStart(2, "0")
  ).join("");
}

async function deterministicUUID(
  ctx: RequestContext,
  label: string,
): Promise<string> {
  if (!ctx.idempotencyKey) return crypto.randomUUID();
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(`${ctx.key.id}:${ctx.idempotencyKey}:${label}`),
  );
  const bytes = new Uint8Array(digest).slice(0, 16);
  bytes[6] = (bytes[6] & 0x0f) | 0x50;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = Array.from(bytes).map((byte) =>
    byte.toString(16).padStart(2, "0")
  ).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${
    hex.slice(16, 20)
  }-${hex.slice(20)}`;
}

function base64URL(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(
    /=+$/,
    "",
  );
}

function newAgentToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return `pd_live_${base64URL(bytes)}`;
}

function requireScope(ctx: RequestContext, scope: Scope): void {
  if (!ctx.key.scopes.includes(scope)) {
    throw new ApiError(
      403,
      "insufficient_scope",
      `This credential requires the ${scope} scope.`,
    );
  }
}

function checkOrigin(req: Request): void {
  const origin = req.headers.get("origin");
  if (!origin) return;
  const allowed = (Deno.env.get("PAYDAY_API_ALLOWED_ORIGINS") ?? "")
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
  if (!allowed.includes(origin)) {
    throw new ApiError(
      403,
      "origin_not_allowed",
      "This request origin is not allowed.",
    );
  }
}

function adminClient(): SupabaseClient {
  const url = Deno.env.get("SUPABASE_URL");
  const secret = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !secret) {
    throw new ApiError(
      503,
      "configuration_error",
      "The API is not configured.",
    );
  }
  return createClient(url, secret, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

async function authenticate(
  req: Request,
  requestID: string,
  startedAt: number,
): Promise<RequestContext> {
  const authorization = req.headers.get("authorization") ?? "";
  const match = authorization.match(/^Bearer (pd_live_[A-Za-z0-9_-]{40,80})$/);
  if (!match) {
    throw new ApiError(
      401,
      "invalid_token",
      "A Payday agent Bearer token is required.",
    );
  }
  const admin = adminClient();
  const tokenHash = await sha256Hex(match[1]);
  const { data, error } = await admin
    .from("payday_agent_api_keys")
    .select(
      "id,user_id,name,scopes,rate_limit_per_minute,expires_at,created_by_key_id",
    )
    .eq("token_hash", tokenHash)
    .is("revoked_at", null)
    .or(`expires_at.is.null,expires_at.gt.${new Date().toISOString()}`)
    .maybeSingle();
  if (error) {
    throw new ApiError(
      503,
      "authorization_unavailable",
      "Credential verification is temporarily unavailable.",
    );
  }
  if (!data) {
    throw new ApiError(
      401,
      "invalid_token",
      "The Payday agent token is invalid, expired, or revoked.",
    );
  }

  const key = data as AgentKey;
  if (key.created_by_key_id) {
    const { data: family, error: familyError } = await admin.from(
      "payday_agent_api_keys",
    ).select("id,created_by_key_id,revoked_at,expires_at").eq(
      "user_id",
      key.user_id,
    );
    if (familyError) {
      throw new ApiError(
        503,
        "authorization_unavailable",
        "Credential ancestry verification is temporarily unavailable.",
      );
    }
    const byID = new Map((family ?? []).map((item) => [item.id, item]));
    const visited = new Set<string>([key.id]);
    let parentID: string | null = key.created_by_key_id;
    const now = new Date().toISOString();
    while (parentID) {
      if (visited.has(parentID)) {
        throw new ApiError(401, "invalid_token", "Invalid credential chain.");
      }
      visited.add(parentID);
      const parent = byID.get(parentID);
      if (
        !parent || parent.revoked_at ||
        (parent.expires_at && parent.expires_at <= now)
      ) {
        throw new ApiError(
          401,
          "invalid_token",
          "The Payday agent token is invalid, expired, or revoked.",
        );
      }
      parentID = parent.created_by_key_id;
    }
  }
  const { data: rateData, error: rateError } = await admin.rpc(
    "consume_payday_agent_rate_limit",
    { p_key_id: key.id },
  );
  if (rateError) {
    throw new ApiError(
      503,
      "rate_limit_unavailable",
      "Rate-limit verification is temporarily unavailable.",
    );
  }
  const rate = Array.isArray(rateData) ? rateData[0] : rateData;
  if (!rate?.allowed) {
    throw new ApiError(
      429,
      "rate_limited",
      `Rate limit exceeded. Retry in ${
        rate?.retry_after_seconds ?? 60
      } seconds.`,
    );
  }
  await admin.from("payday_agent_api_keys").update({
    last_used_at: new Date().toISOString(),
  }).eq("id", key.id);
  return { admin, key, requestID, startedAt };
}

function publicPath(url: URL): string {
  const marker = "/payday-api";
  const index = url.pathname.indexOf(marker);
  const result = index >= 0
    ? url.pathname.slice(index + marker.length)
    : url.pathname;
  return result || "/";
}

function stripOwner<T extends JsonObject>(
  row: T,
): Omit<T, "user_id" | "agent_idempotency_key"> {
  const {
    user_id: _userID,
    agent_idempotency_key: _idempotencyKey,
    ...safe
  } = row;
  return safe;
}

function requireOnlyFields(body: JsonObject, fields: readonly string[]): void {
  const unknown = Object.keys(body).filter((key) => !fields.includes(key));
  if (unknown.length) {
    throw new ApiError(
      400,
      "unknown_field",
      `Unknown field${unknown.length === 1 ? "" : "s"}: ${unknown.join(", ")}.`,
    );
  }
}

function tipPayload(bodyValue: unknown, partial: boolean): JsonObject {
  const body = requireObject(bodyValue);
  requireOnlyFields(body, [
    "id",
    "expected_version",
    "shift_id",
    "work_date",
    "amount_cents",
    "kind",
    "note",
    "recorded_at",
    "is_double",
    "hours_worked",
    "tip_out_cents",
    "sales_cents",
    "shift_period",
    "clock_in",
    "clock_out",
    "server_count",
    "receipt_metrics",
  ]);
  const result: JsonObject = {};
  if (!partial || "work_date" in body) {
    result.work_date = dateOnly(body.work_date, "work_date");
  }
  if (!partial || "amount_cents" in body) {
    result.amount_cents = integer(body.amount_cents, "amount_cents");
  }
  if (!partial || "kind" in body) {
    result.kind = enumValue(body.kind, "kind", ["cash", "credit"] as const);
  }
  if ("shift_id" in body) {
    result.shift_id = optionalUUID(body.shift_id, "shift_id");
  }
  if ("note" in body) result.note = optionalString(body.note, "note");
  if ("recorded_at" in body) {
    result.recorded_at = optionalTimestamp(body.recorded_at, "recorded_at");
  }
  if ("is_double" in body) {
    result.is_double = optionalBoolean(body.is_double, "is_double");
  }
  if ("hours_worked" in body) {
    result.hours_worked = optionalNumber(body.hours_worked, "hours_worked");
  }
  if ("tip_out_cents" in body) {
    result.tip_out_cents = optionalInteger(body.tip_out_cents, "tip_out_cents");
  }
  if ("sales_cents" in body) {
    result.sales_cents = optionalInteger(body.sales_cents, "sales_cents");
  }
  if ("shift_period" in body) {
    result.shift_period = optionalEnum(
      body.shift_period,
      "shift_period",
      ["lunch", "dinner"] as const,
    );
  }
  if ("clock_in" in body) {
    result.clock_in = optionalTimestamp(body.clock_in, "clock_in");
  }
  if ("clock_out" in body) {
    result.clock_out = optionalTimestamp(body.clock_out, "clock_out");
  }
  if ("server_count" in body) {
    result.server_count = optionalInteger(body.server_count, "server_count");
  }
  if ("receipt_metrics" in body) {
    result.receipt_metrics = receiptMetrics(
      body.receipt_metrics,
      "receipt_metrics",
    );
  }
  if (partial && Object.keys(result).length === 0) {
    throw new ApiError(
      400,
      "empty_update",
      "At least one writable field is required.",
    );
  }
  return result;
}

function paycheckPayload(bodyValue: unknown, partial: boolean): JsonObject {
  const body = requireObject(bodyValue);
  requireOnlyFields(body, [
    "id",
    "expected_version",
    "period_start",
    "period_end",
    "paid_tips_cents",
    "note",
    "hourly_rate_cents",
    "owed_tips_cents",
    "gross_pay_cents",
    "net_pay_cents",
    "regular_wages_cents",
    "overtime_wages_cents",
    "gratuity_cents",
    "taxes_cents",
  ]);
  const result: JsonObject = {};
  if (!partial || "period_start" in body) {
    result.period_start = dateOnly(body.period_start, "period_start");
  }
  if (!partial || "period_end" in body) {
    result.period_end = dateOnly(body.period_end, "period_end");
  }
  if (!partial || "paid_tips_cents" in body) {
    result.paid_tips_cents = integer(body.paid_tips_cents, "paid_tips_cents");
  }
  if ("note" in body) result.note = optionalString(body.note, "note");
  for (
    const field of [
      "hourly_rate_cents",
      "owed_tips_cents",
      "gross_pay_cents",
      "net_pay_cents",
      "regular_wages_cents",
      "overtime_wages_cents",
      "gratuity_cents",
      "taxes_cents",
    ] as const
  ) {
    if (field in body) result[field] = optionalInteger(body[field], field);
  }
  if (
    result.period_start && result.period_end &&
    result.period_end < result.period_start
  ) {
    throw new ApiError(
      400,
      "invalid_period",
      "period_end must be on or after period_start.",
    );
  }
  if (partial && Object.keys(result).length === 0) {
    throw new ApiError(
      400,
      "empty_update",
      "At least one writable field is required.",
    );
  }
  return result;
}

function settingsPayload(bodyValue: unknown): JsonObject {
  const body = requireObject(bodyValue);
  requireOnlyFields(body, [
    "expected_version",
    "first_name",
    "base_hourly_wage_cents",
    "pay_frequency",
    "anchor_period_end",
    "pay_delay_days",
    "first_weekday",
    "smart_nudge_enabled",
    "payday_reminder_enabled",
    "move_ledger",
  ]);
  const result: JsonObject = {};
  if ("first_name" in body) {
    result.first_name = optionalString(body.first_name, "first_name", 200);
  }
  if ("base_hourly_wage_cents" in body) {
    result.base_hourly_wage_cents = optionalInteger(
      body.base_hourly_wage_cents,
      "base_hourly_wage_cents",
    );
  }
  if ("pay_frequency" in body) {
    result.pay_frequency = optionalEnum(
      body.pay_frequency,
      "pay_frequency",
      ["weekly", "biweekly", "twiceMonthly", "monthly"] as const,
    );
  }
  if ("anchor_period_end" in body) {
    result.anchor_period_end = optionalDate(
      body.anchor_period_end,
      "anchor_period_end",
    );
  }
  if ("pay_delay_days" in body) {
    result.pay_delay_days = optionalInteger(
      body.pay_delay_days,
      "pay_delay_days",
    );
  }
  if ("first_weekday" in body) {
    const weekday = optionalInteger(body.first_weekday, "first_weekday", 1);
    if (typeof weekday === "number" && weekday > 7) {
      throw new ApiError(
        400,
        "invalid_field",
        "first_weekday must be between 1 and 7.",
      );
    }
    result.first_weekday = weekday;
  }
  if ("smart_nudge_enabled" in body) {
    result.smart_nudge_enabled = optionalBoolean(
      body.smart_nudge_enabled,
      "smart_nudge_enabled",
    );
  }
  if ("payday_reminder_enabled" in body) {
    result.payday_reminder_enabled = optionalBoolean(
      body.payday_reminder_enabled,
      "payday_reminder_enabled",
    );
  }
  if ("move_ledger" in body) {
    result.move_ledger = moveLedger(body.move_ledger, "move_ledger");
  }
  if (Object.keys(result).length === 0) {
    throw new ApiError(
      400,
      "empty_update",
      "At least one writable field is required.",
    );
  }
  if (("pay_frequency" in result) !== ("anchor_period_end" in result)) {
    throw new ApiError(
      400,
      "incomplete_schedule",
      "pay_frequency and anchor_period_end must be updated together.",
    );
  }
  return result;
}

function expectedVersion(body: JsonObject): number {
  return integer(body.expected_version, "expected_version", 1);
}

function listArguments(
  url: URL,
): { limit: number; cursor?: string; includeDeleted: boolean } {
  const limitValue = url.searchParams.get("limit");
  const limit = limitValue === null
    ? 100
    : Math.min(200, integer(Number(limitValue), "limit", 1));
  const cursor = url.searchParams.get("cursor") ?? undefined;
  return {
    limit,
    cursor,
    includeDeleted: url.searchParams.get("include_deleted") === "true",
  };
}

async function listRows(
  ctx: RequestContext,
  table: "tip_entries" | "paycheck_records",
  args: JsonObject,
): Promise<JsonObject> {
  requireScope(ctx, "read");
  const limit = Math.min(
    200,
    args.limit === undefined ? 100 : integer(args.limit, "limit", 1),
  );
  const cursor = args.cursor === undefined
    ? undefined
    : uuid(args.cursor, "cursor");
  const includeDeleted = args.include_deleted === true;
  let query = ctx.admin.from(table).select("*").eq("user_id", ctx.key.user_id)
    .order("id", { ascending: true }).limit(limit + 1);
  if (!includeDeleted) query = query.is("deleted_at", null);
  if (cursor) query = query.gt("id", cursor);
  const startField = table === "tip_entries" ? "work_date" : "period_end";
  if (args.start_date !== undefined) {
    query = query.gte(startField, dateOnly(args.start_date, "start_date"));
  }
  if (args.end_date !== undefined) {
    query = query.lte(startField, dateOnly(args.end_date, "end_date"));
  }
  const { data, error } = await query;
  if (error) {
    throw new ApiError(500, "database_error", "Unable to list records.");
  }
  const rows = (data ?? []) as JsonObject[];
  const hasMore = rows.length > limit;
  const page = rows.slice(0, limit).map(stripOwner);
  return { data: page, next_cursor: hasMore ? page.at(-1)?.id ?? null : null };
}

async function getRow(
  ctx: RequestContext,
  table: "tip_entries" | "paycheck_records",
  idValue: unknown,
): Promise<JsonObject> {
  requireScope(ctx, "read");
  const id = uuid(idValue, "id");
  const { data, error } = await ctx.admin.from(table).select("*").eq(
    "user_id",
    ctx.key.user_id,
  ).eq("id", id).maybeSingle();
  if (error) {
    throw new ApiError(500, "database_error", "Unable to retrieve the record.");
  }
  if (!data) throw new ApiError(404, "not_found", "Record not found.");
  return { data: stripOwner(data as JsonObject) };
}

async function markedReplayRow(
  ctx: RequestContext,
  table: "tip_entries" | "paycheck_records",
  id: string,
): Promise<JsonObject | null> {
  if (!ctx.idempotencyMarker) return null;
  const { data, error } = await ctx.admin.from(table).select("*")
    .eq("user_id", ctx.key.user_id)
    .eq("id", id)
    .eq("agent_idempotency_key", ctx.idempotencyMarker)
    .maybeSingle();
  if (error) {
    throw new ApiError(
      503,
      "replay_unavailable",
      "Unable to recover the completed request.",
    );
  }
  return data ? stripOwner(data as JsonObject) : null;
}

async function createRow(
  ctx: RequestContext,
  table: "tip_entries" | "paycheck_records",
  input: unknown,
): Promise<JsonObject> {
  requireScope(ctx, "write");
  const body = requireObject(input);
  const now = new Date().toISOString();
  const payload = table === "tip_entries"
    ? tipPayload(body, false)
    : paycheckPayload(body, false);
  const autoID = body.id === undefined;
  payload.id = autoID
    ? await deterministicUUID(ctx, `${table}:${JSON.stringify(body)}`)
    : uuid(body.id, "id");
  payload.user_id = ctx.key.user_id;
  payload.client_updated_at = now;
  payload.deleted_at = null;
  payload.agent_idempotency_key = ctx.idempotencyMarker;
  if (table === "tip_entries") {
    payload.shift_id = payload.shift_id ?? await deterministicUUID(
      ctx,
      `tip_entries:shift:${JSON.stringify(body)}`,
    );
    payload.recorded_at = payload.recorded_at ?? now;
    payload.is_double = payload.is_double ?? false;
  }
  const { data, error } = await ctx.admin.from(table).insert(payload).select(
    "*",
  ).single();
  if (error?.code === "23505") {
    const replay = await markedReplayRow(ctx, table, String(payload.id));
    if (replay) return { data: replay };
  }
  if (error?.code === "23505") {
    throw new ApiError(
      409,
      "already_exists",
      "A record with this id already exists.",
    );
  }
  if (error) {
    throw new ApiError(
      400,
      "database_constraint",
      "The record did not satisfy Payday's data rules.",
    );
  }
  return { data: stripOwner(data as JsonObject) };
}

async function createShift(
  ctx: RequestContext,
  input: unknown,
): Promise<JsonObject> {
  requireScope(ctx, "write");
  const body = requireObject(input);
  const cash = body.cash_tip_cents === undefined
    ? 0
    : integer(body.cash_tip_cents, "cash_tip_cents");
  const credit = body.credit_tip_cents === undefined
    ? 0
    : integer(body.credit_tip_cents, "credit_tip_cents");
  if (cash <= 0 && credit <= 0) {
    throw new ApiError(
      400,
      "empty_shift",
      "A shift requires a positive cash_tip_cents or credit_tip_cents value.",
    );
  }
  const {
    cash_tip_cents: _cashTipCents,
    credit_tip_cents: _creditTipCents,
    shift_id: _shiftID,
    ...shiftFields
  } = body;
  const base = tipPayload(
    { ...shiftFields, amount_cents: 0, kind: "cash" },
    false,
  );
  delete base.amount_cents;
  delete base.kind;
  const now = new Date().toISOString();
  const autoShiftID = body.shift_id === undefined;
  const shiftID = autoShiftID
    ? await deterministicUUID(ctx, `shift:${JSON.stringify(body)}`)
    : uuid(body.shift_id, "shift_id");
  const common = {
    user_id: ctx.key.user_id,
    shift_id: shiftID,
    work_date: base.work_date,
    note: base.note,
    recorded_at: base.recorded_at ?? now,
    is_double: base.is_double ?? false,
    client_updated_at: now,
    deleted_at: null,
    agent_idempotency_key: ctx.idempotencyMarker,
  };
  const details = {
    hours_worked: base.hours_worked,
    tip_out_cents: base.tip_out_cents,
    sales_cents: base.sales_cents,
    shift_period: base.shift_period,
    clock_in: base.clock_in,
    clock_out: base.clock_out,
    server_count: base.server_count,
    receipt_metrics: base.receipt_metrics,
  };
  const rows: JsonObject[] = [];
  if (cash > 0) {
    rows.push({
      ...common,
      id: await deterministicUUID(ctx, `shift:${shiftID}:cash`),
      amount_cents: cash,
      kind: "cash",
    });
  }
  if (credit > 0) {
    rows.push({
      ...common,
      id: await deterministicUUID(ctx, `shift:${shiftID}:credit`),
      amount_cents: credit,
      kind: "credit",
    });
  }
  Object.assign(rows.find((row) => row.kind === "credit") ?? rows[0], details);
  const { data, error } = await ctx.admin.from("tip_entries").insert(rows)
    .select("*");
  if (error?.code === "23505") {
    const { data: existing, error: fetchError } = await ctx.admin.from(
      "tip_entries",
    ).select("*").eq("user_id", ctx.key.user_id).eq("shift_id", shiftID)
      .eq("agent_idempotency_key", ctx.idempotencyMarker ?? "")
      .is("deleted_at", null);
    if (!fetchError && existing?.length === rows.length) {
      return {
        data: {
          shift_id: shiftID,
          tip_entries: (existing as JsonObject[]).map(stripOwner),
        },
      };
    }
  }
  if (error) {
    throw new ApiError(
      400,
      "database_constraint",
      "The shift did not satisfy Payday's data rules.",
    );
  }
  return {
    data: {
      shift_id: shiftID,
      tip_entries: (data as JsonObject[]).map(stripOwner),
    },
  };
}

async function updateRow(
  ctx: RequestContext,
  table: "tip_entries" | "paycheck_records",
  idValue: unknown,
  input: unknown,
): Promise<JsonObject> {
  requireScope(ctx, "write");
  const body = requireObject(input);
  const id = uuid(idValue, "id");
  const version = expectedVersion(body);
  const payload = table === "tip_entries"
    ? tipPayload(body, true)
    : paycheckPayload(body, true);
  payload.client_updated_at = new Date().toISOString();
  payload.agent_idempotency_key = ctx.idempotencyMarker;
  const { data, error } = await ctx.admin.from(table).update(payload).eq(
    "user_id",
    ctx.key.user_id,
  ).eq("id", id).eq("version", version).is("deleted_at", null).select("*")
    .maybeSingle();
  if (error) {
    throw new ApiError(
      400,
      "database_constraint",
      "The update did not satisfy Payday's data rules.",
    );
  }
  if (!data) {
    const replay = await markedReplayRow(ctx, table, id);
    if (replay) return { data: replay };
    throw new ApiError(
      409,
      "version_conflict",
      "The record changed, was deleted, or does not exist. Fetch it again before retrying.",
    );
  }
  return { data: stripOwner(data as JsonObject) };
}

async function changeDeletion(
  ctx: RequestContext,
  table: "tip_entries" | "paycheck_records",
  idValue: unknown,
  versionValue: unknown,
  restore: boolean,
): Promise<JsonObject> {
  requireScope(ctx, restore ? "write" : "delete");
  const id = uuid(idValue, "id");
  const version = integer(versionValue, "expected_version", 1);
  const now = new Date().toISOString();
  let query = ctx.admin.from(table).update({
    deleted_at: restore ? null : now,
    client_updated_at: now,
    agent_idempotency_key: ctx.idempotencyMarker,
  })
    .eq("user_id", ctx.key.user_id).eq("id", id).eq("version", version);
  query = restore
    ? query.not("deleted_at", "is", null)
    : query.is("deleted_at", null);
  const { data, error } = await query.select("*").maybeSingle();
  if (error) {
    throw new ApiError(
      400,
      "database_constraint",
      "Unable to change the record's deletion state.",
    );
  }
  if (!data) {
    const replay = await markedReplayRow(ctx, table, id);
    if (
      replay &&
      (restore
        ? replay.deleted_at === null
        : typeof replay.deleted_at === "string")
    ) return { data: replay };
    throw new ApiError(
      409,
      "version_conflict",
      "The record changed, has the requested deletion state, or does not exist.",
    );
  }
  return { data: stripOwner(data as JsonObject) };
}

async function getSettings(ctx: RequestContext): Promise<JsonObject> {
  requireScope(ctx, "read");
  const { data, error } = await ctx.admin.from("user_settings").select("*").eq(
    "user_id",
    ctx.key.user_id,
  ).maybeSingle();
  if (error) {
    throw new ApiError(500, "database_error", "Unable to retrieve settings.");
  }
  if (!data) {
    throw new ApiError(404, "not_found", "Settings have not been created yet.");
  }
  return { data: stripOwner(data as JsonObject) };
}

async function updateSettings(
  ctx: RequestContext,
  input: unknown,
): Promise<JsonObject> {
  requireScope(ctx, "write");
  const body = requireObject(input);
  const version = expectedVersion(body);
  const payload = settingsPayload(body);
  payload.client_updated_at = new Date().toISOString();
  payload.agent_idempotency_key = ctx.idempotencyMarker;
  const { data, error } = await ctx.admin.from("user_settings").update(payload)
    .eq("user_id", ctx.key.user_id).eq("version", version).select("*")
    .maybeSingle();
  if (error) {
    throw new ApiError(
      400,
      "database_constraint",
      "The settings update did not satisfy Payday's data rules.",
    );
  }
  if (!data) {
    if (ctx.idempotencyMarker) {
      const { data: replay, error: replayError } = await ctx.admin
        .from("user_settings").select("*")
        .eq("user_id", ctx.key.user_id)
        .eq("agent_idempotency_key", ctx.idempotencyMarker)
        .maybeSingle();
      if (replayError) {
        throw new ApiError(
          503,
          "replay_unavailable",
          "Unable to recover the completed request.",
        );
      }
      if (replay) return { data: stripOwner(replay as JsonObject) };
    }
    throw new ApiError(
      409,
      "version_conflict",
      "Settings changed or do not exist. Fetch them again before retrying.",
    );
  }
  return { data: stripOwner(data as JsonObject) };
}

function money(row: JsonObject, field: string): number {
  const value = row[field];
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

function tipFacts(
  row: JsonObject,
): { voluntary: number; gratuity: number; gross: number; net: number } {
  const amount = money(row, "amount_cents");
  const metrics = isRecord(row.receipt_metrics) ? row.receipt_metrics : {};
  const gratuity = money(metrics, "gratuityFeesCents");
  const version = money(metrics, "earningsSchemaVersion") || 1;
  const voluntary = version >= 2 ? amount : Math.max(0, amount - gratuity);
  const gross = voluntary + gratuity;
  return {
    voluntary,
    gratuity,
    gross,
    net: gross - money(row, "tip_out_cents"),
  };
}

function groupShifts(rows: JsonObject[]): JsonObject[] {
  const groups = new Map<string, JsonObject[]>();
  for (const row of rows) {
    const key = typeof row.shift_id === "string"
      ? row.shift_id
      : row.id as string;
    groups.set(key, [...(groups.get(key) ?? []), row]);
  }
  return Array.from(groups, ([shiftID, groupedEntries]) => {
    const entries = [...groupedEntries].sort((left, right) =>
      String(left.id).localeCompare(String(right.id))
    );
    const credit = entries.find((row) => row.kind === "credit");
    const cash = entries.find((row) => row.kind === "cash");
    const canonical = credit ?? cash ?? entries[0];
    const workDate = entries.reduce(
      (latest, row) =>
        typeof row.work_date === "string" && row.work_date > latest
          ? row.work_date
          : latest,
      "",
    );
    const metricsOwner = credit?.receipt_metrics
      ? credit
      : cash?.receipt_metrics
      ? cash
      : undefined;
    const detail = (field: string): unknown =>
      credit?.[field] ?? cash?.[field] ?? canonical[field] ?? null;
    const facts = entries.map((row) =>
      tipFacts({
        ...row,
        receipt_metrics: row.id === metricsOwner?.id
          ? metricsOwner?.receipt_metrics
          : null,
      })
    );
    return {
      id: shiftID,
      work_date: workDate || canonical.work_date,
      shift_period: detail("shift_period"),
      recorded_at: detail("recorded_at"),
      cash_tip_cents: entries.reduce(
        (sum, row, index) =>
          sum + (row.kind === "cash" ? facts[index].voluntary : 0),
        0,
      ),
      credit_tip_cents: entries.reduce(
        (sum, row, index) =>
          sum + (row.kind === "credit" ? facts[index].voluntary : 0),
        0,
      ),
      gratuity_cents: facts.reduce((sum, item) => sum + item.gratuity, 0),
      gross_tip_earnings_cents: facts.reduce(
        (sum, item) => sum + item.gross,
        0,
      ),
      tip_out_cents: Number(detail("tip_out_cents") ?? 0),
      net_tip_earnings_cents: facts.reduce((sum, item) => sum + item.gross, 0) -
        Number(detail("tip_out_cents") ?? 0),
      sales_cents: detail("sales_cents"),
      hours_worked: detail("hours_worked"),
      clock_in: detail("clock_in"),
      clock_out: detail("clock_out"),
      server_count: detail("server_count"),
      receipt_metrics: detail("receipt_metrics"),
      note: detail("note"),
      tip_entries: entries.map(stripOwner),
    };
  }).sort((a, b) =>
    String(b.work_date).localeCompare(String(a.work_date)) ||
    String(b.recorded_at ?? "").localeCompare(String(a.recorded_at ?? "")) ||
    String(b.id).localeCompare(String(a.id))
  );
}

async function summary(
  ctx: RequestContext,
  args: JsonObject,
): Promise<JsonObject> {
  requireScope(ctx, "read");
  const start = args.start_date === undefined
    ? undefined
    : dateOnly(args.start_date, "start_date");
  const end = args.end_date === undefined
    ? undefined
    : dateOnly(args.end_date, "end_date");
  const { data, error } = await ctx.admin.rpc("payday_agent_summary", {
    p_user_id: ctx.key.user_id,
    p_start_date: start ?? null,
    p_end_date: end ?? null,
  });
  if (
    error || !isRecord(data) || !isRecord(data.shifts) ||
    !isRecord(data.paychecks)
  ) {
    throw new ApiError(
      500,
      "database_error",
      "Unable to calculate the summary.",
    );
  }
  return {
    data: {
      range: { start_date: start ?? null, end_date: end ?? null },
      shifts: data.shifts,
      paychecks: data.paychecks,
    },
  };
}

async function listShifts(
  ctx: RequestContext,
  args: JsonObject,
): Promise<JsonObject> {
  requireScope(ctx, "read");
  const start = args.start_date === undefined
    ? undefined
    : dateOnly(args.start_date, "start_date");
  const end = args.end_date === undefined
    ? undefined
    : dateOnly(args.end_date, "end_date");
  const limit = Math.min(
    200,
    args.limit === undefined ? 100 : integer(args.limit, "limit", 1),
  );
  const cursor = shiftCursor(args.cursor);
  const { data, error } = await ctx.admin.rpc(
    "payday_agent_recent_tip_entries",
    {
      p_user_id: ctx.key.user_id,
      p_start_date: start ?? null,
      p_end_date: end ?? null,
      p_shift_limit: limit + 1,
      p_before_work_date: cursor?.work_date ?? null,
      p_before_recorded_at: cursor?.recorded_at ?? null,
      p_before_shift_id: cursor?.shift_id ?? null,
    },
  );
  if (error) {
    throw new ApiError(
      500,
      "database_error",
      "Unable to list shifts.",
    );
  }
  const shifts = groupShifts((data ?? []) as JsonObject[]);
  const hasMore = shifts.length > limit;
  const page = shifts.slice(0, limit);
  const last = page.at(-1);
  return {
    data: page,
    has_more: hasMore,
    next_cursor: hasMore && last
      ? encodeShiftCursor({
        work_date: String(last.work_date),
        recorded_at: typeof last.recorded_at === "string"
          ? last.recorded_at
          : null,
        shift_id: String(last.id),
      })
      : null,
  };
}

interface ShiftCursor {
  work_date: string;
  recorded_at: string | null;
  shift_id: string;
}

function shiftCursor(value: unknown): ShiftCursor | undefined {
  if (value === undefined || value === null || value === "") return undefined;
  const encoded = requiredString(value, "cursor", 500);
  try {
    const padded = encoded.replaceAll("-", "+").replaceAll("_", "/") +
      "=".repeat((4 - encoded.length % 4) % 4);
    const decoded = JSON.parse(atob(padded));
    if (!isRecord(decoded)) throw new Error("invalid cursor");
    return {
      work_date: dateOnly(decoded.work_date, "cursor.work_date"),
      recorded_at: decoded.recorded_at === null
        ? null
        : timestamp(decoded.recorded_at, "cursor.recorded_at"),
      shift_id: uuid(decoded.shift_id, "cursor.shift_id"),
    };
  } catch (error) {
    if (error instanceof ApiError) throw error;
    throw new ApiError(400, "invalid_cursor", "cursor is invalid.");
  }
}

function encodeShiftCursor(cursor: ShiftCursor): string {
  return base64URL(new TextEncoder().encode(JSON.stringify(cursor)));
}

async function getShift(
  ctx: RequestContext,
  idValue: unknown,
): Promise<JsonObject> {
  requireScope(ctx, "read");
  const id = uuid(idValue, "shift_id");
  const { data, error } = await ctx.admin.from("tip_entries").select("*").eq(
    "user_id",
    ctx.key.user_id,
  ).eq("shift_id", id).is("deleted_at", null);
  if (error) {
    throw new ApiError(500, "database_error", "Unable to retrieve the shift.");
  }
  if (!data?.length) throw new ApiError(404, "not_found", "Shift not found.");
  return { data: groupShifts(data as JsonObject[])[0] };
}

async function listKeys(ctx: RequestContext): Promise<JsonObject> {
  requireScope(ctx, "admin");
  const { data, error } = await ctx.admin.from("payday_agent_api_keys")
    .select(
      "id,name,token_prefix,scopes,rate_limit_per_minute,created_at,last_used_at,expires_at,revoked_at",
    )
    .eq("user_id", ctx.key.user_id).order("created_at", { ascending: false });
  if (error) {
    throw new ApiError(500, "database_error", "Unable to list API keys.");
  }
  return { data: data ?? [] };
}

function requestedScopes(value: unknown): Scope[] {
  if (!Array.isArray(value) || value.length === 0) {
    throw new ApiError(
      400,
      "invalid_field",
      "scopes must be a non-empty array.",
    );
  }
  const scopes = [
    ...new Set(value.map((item) => enumValue(item, "scopes", ALL_SCOPES))),
  ];
  return scopes;
}

async function createKey(
  ctx: RequestContext,
  input: unknown,
): Promise<JsonObject> {
  requireScope(ctx, "admin");
  const body = requireObject(input);
  requireOnlyFields(body, [
    "name",
    "scopes",
    "rate_limit_per_minute",
    "expires_at",
  ]);
  const { count: activeKeyCount, error: countError } = await ctx.admin.from(
    "payday_agent_api_keys",
  ).select("id", { count: "exact", head: true }).eq(
    "user_id",
    ctx.key.user_id,
  ).is("revoked_at", null);
  if (countError) {
    throw new ApiError(500, "database_error", "Unable to count API keys.");
  }
  if ((activeKeyCount ?? 0) >= 25) {
    throw new ApiError(
      409,
      "active_key_limit",
      "Revoke an existing key before creating another one.",
    );
  }
  const name = requiredString(body.name, "name", 100);
  const scopes = requestedScopes(body.scopes);
  if (scopes.some((scope) => !ctx.key.scopes.includes(scope))) {
    throw new ApiError(
      403,
      "scope_escalation",
      "A child key cannot receive scopes its creator does not have.",
    );
  }
  const rateLimit = body.rate_limit_per_minute === undefined
    ? 60
    : integer(body.rate_limit_per_minute, "rate_limit_per_minute", 1);
  if (rateLimit > Math.min(600, ctx.key.rate_limit_per_minute)) {
    throw new ApiError(
      400,
      "invalid_field",
      "rate_limit_per_minute cannot exceed the creator key's limit.",
    );
  }
  const expiresAt = body.expires_at === undefined
    ? null
    : optionalTimestamp(body.expires_at, "expires_at");
  if (expiresAt && expiresAt <= new Date().toISOString()) {
    throw new ApiError(
      400,
      "invalid_field",
      "expires_at must be in the future.",
    );
  }
  if (ctx.key.expires_at && (!expiresAt || expiresAt > ctx.key.expires_at)) {
    throw new ApiError(
      400,
      "invalid_field",
      "A child key cannot outlive its creator key.",
    );
  }
  if (ctx.key.created_by_key_id && !expiresAt) {
    throw new ApiError(
      400,
      "invalid_field",
      "Keys created by a delegated admin must have an expiration.",
    );
  }
  const token = newAgentToken();
  const payload = {
    user_id: ctx.key.user_id,
    name,
    token_prefix: token.slice(0, 20),
    token_hash: await sha256Hex(token),
    scopes,
    rate_limit_per_minute: rateLimit,
    expires_at: expiresAt,
    created_by_key_id: ctx.key.id,
  };
  const { data, error } = await ctx.admin.from("payday_agent_api_keys").insert(
    payload,
  )
    .select(
      "id,name,token_prefix,scopes,rate_limit_per_minute,created_at,expires_at",
    ).single();
  if (error?.code === "23505") {
    throw new ApiError(
      409,
      "name_in_use",
      "An active key already uses this name.",
    );
  }
  if (error) {
    throw new ApiError(
      400,
      "database_constraint",
      "Unable to create the API key.",
    );
  }
  return {
    data: {
      ...data,
      token,
      token_notice:
        "Save this token now. Payday stores only its hash and cannot display it again.",
    },
  };
}

async function revokeKey(
  ctx: RequestContext,
  idValue: unknown,
): Promise<JsonObject> {
  requireScope(ctx, "admin");
  const id = uuid(idValue, "key_id");
  if (id === ctx.key.id) {
    throw new ApiError(
      409,
      "cannot_revoke_current_key",
      "Use another active admin key to revoke this key.",
    );
  }
  const { data, error } = await ctx.admin.rpc("revoke_payday_agent_key_tree", {
    p_user_id: ctx.key.user_id,
    p_key_id: id,
    p_idempotency_key: ctx.idempotencyMarker,
  });
  if (error) {
    throw new ApiError(500, "database_error", "Unable to revoke the API key.");
  }
  const revoked = (data ?? []) as Array<{
    id: string;
    name: string;
    revoked_at: string;
  }>;
  const target = revoked.find((key) => key.id === id);
  if (!target) {
    throw new ApiError(404, "not_found", "Active API key not found.");
  }
  return {
    data: {
      id: target.id,
      name: target.name,
      revoked_at: target.revoked_at,
      revoked_key_count: revoked.length,
    },
  };
}

async function listAudit(
  ctx: RequestContext,
  args: JsonObject,
): Promise<JsonObject> {
  requireScope(ctx, "admin");
  const limit = Math.min(
    200,
    args.limit === undefined ? 100 : integer(args.limit, "limit", 1),
  );
  const cursor = auditCursor(args.cursor);
  let query = ctx.admin.from("payday_agent_audit_log")
    .select(
      "request_id,key_id,requested_at,method,path,operation,status_code,duration_ms,idempotency_key,error_code,metadata",
    )
    .eq("user_id", ctx.key.user_id)
    .order("requested_at", { ascending: false })
    .order("request_id", { ascending: false })
    .limit(limit + 1);
  if (cursor) {
    query = query.or(
      `requested_at.lt.${cursor.requested_at},and(requested_at.eq.${cursor.requested_at},request_id.lt.${cursor.request_id})`,
    );
  }
  const { data, error } = await query;
  if (error) {
    throw new ApiError(500, "database_error", "Unable to list audit events.");
  }
  const rows = (data ?? []) as JsonObject[];
  const hasMore = rows.length > limit;
  const page = rows.slice(0, limit);
  const last = page.at(-1);
  return {
    data: page,
    has_more: hasMore,
    next_cursor: hasMore && last
      ? encodeAuditCursor({
        requested_at: String(last.requested_at),
        request_id: String(last.request_id),
      })
      : null,
  };
}

interface AuditCursor {
  requested_at: string;
  request_id: string;
}

function auditCursor(value: unknown): AuditCursor | undefined {
  if (value === undefined || value === null || value === "") return undefined;
  const encoded = requiredString(value, "cursor", 500);
  try {
    const padded = encoded.replaceAll("-", "+").replaceAll("_", "/") +
      "=".repeat((4 - encoded.length % 4) % 4);
    const decoded = JSON.parse(atob(padded));
    if (!isRecord(decoded)) throw new Error("invalid cursor");
    return {
      requested_at: timestamp(decoded.requested_at, "cursor.requested_at"),
      request_id: uuid(decoded.request_id, "cursor.request_id"),
    };
  } catch (error) {
    if (error instanceof ApiError) throw error;
    throw new ApiError(400, "invalid_cursor", "cursor is invalid.");
  }
}

function encodeAuditCursor(cursor: AuditCursor): string {
  return base64URL(new TextEncoder().encode(JSON.stringify(cursor)));
}

const CHANGE_TABLES = [
  "tip_entries",
  "paycheck_records",
  "user_settings",
] as const;
type ChangeTable = typeof CHANGE_TABLES[number];

interface ChangeCursor {
  updated_at: string;
  table: ChangeTable;
  id: string;
}

function changeCursor(value: unknown): ChangeCursor | undefined {
  if (value === undefined || value === null || value === "") return undefined;
  const encoded = requiredString(value, "cursor", 500);
  try {
    const padded = encoded.replaceAll("-", "+").replaceAll("_", "/") +
      "=".repeat((4 - encoded.length % 4) % 4);
    const decoded = JSON.parse(atob(padded));
    if (
      !isRecord(decoded) ||
      !CHANGE_TABLES.includes(decoded.table as ChangeTable)
    ) throw new Error("invalid cursor");
    return {
      updated_at: timestamp(decoded.updated_at, "cursor.updated_at"),
      table: decoded.table as ChangeTable,
      id: uuid(decoded.id, "cursor.id"),
    };
  } catch (error) {
    if (error instanceof ApiError) throw error;
    throw new ApiError(400, "invalid_cursor", "cursor is invalid.");
  }
}

function encodeChangeCursor(cursor: ChangeCursor): string {
  return base64URL(new TextEncoder().encode(JSON.stringify(cursor)));
}

async function changePage(
  ctx: RequestContext,
  table: ChangeTable,
  since: string,
  cursor: ChangeCursor | undefined,
  limit: number,
): Promise<JsonObject[]> {
  const idField = table === "user_settings" ? "user_id" : "id";
  let query = ctx.admin.from(table).select("*").eq("user_id", ctx.key.user_id)
    .order("updated_at", { ascending: true }).order(idField, {
      ascending: true,
    }).limit(limit + 1);
  if (!cursor) {
    query = query.gt("updated_at", since);
  } else {
    const tableRank = CHANGE_TABLES.indexOf(table);
    const cursorRank = CHANGE_TABLES.indexOf(cursor.table);
    if (tableRank < cursorRank) {
      query = query.gt("updated_at", cursor.updated_at);
    } else if (tableRank > cursorRank) {
      query = query.gte("updated_at", cursor.updated_at);
    } else {
      query = query.or(
        `updated_at.gt.${cursor.updated_at},and(updated_at.eq.${cursor.updated_at},${idField}.gt.${cursor.id})`,
      );
    }
  }
  const { data, error } = await query;
  if (error) {
    throw new ApiError(500, "database_error", "Unable to retrieve changes.");
  }
  return (data ?? []) as JsonObject[];
}

async function changes(
  ctx: RequestContext,
  args: JsonObject,
): Promise<JsonObject> {
  requireScope(ctx, "read");
  const since = timestamp(args.since, "since");
  const cursor = changeCursor(args.cursor);
  const limit = Math.min(
    500,
    args.limit === undefined ? 200 : integer(args.limit, "limit", 1),
  );
  const pages = await Promise.all(
    CHANGE_TABLES.map((table) => changePage(ctx, table, since, cursor, limit)),
  );
  const merged = pages.flatMap((rows, tableIndex) =>
    rows.map((row) => ({
      row,
      table: CHANGE_TABLES[tableIndex],
      id: String(
        row[CHANGE_TABLES[tableIndex] === "user_settings" ? "user_id" : "id"],
      ),
    }))
  ).sort((left, right) =>
    String(left.row.updated_at).localeCompare(String(right.row.updated_at)) ||
    CHANGE_TABLES.indexOf(left.table) - CHANGE_TABLES.indexOf(right.table) ||
    left.id.localeCompare(right.id)
  );
  const page = merged.slice(0, limit);
  const hasMore = merged.length > limit ||
    pages.some((rows) => rows.length > limit);
  const last = page.at(-1);
  return {
    data: {
      tip_entries: page.filter((item) => item.table === "tip_entries").map(
        (item) => stripOwner(item.row),
      ),
      paychecks: page.filter((item) => item.table === "paycheck_records").map(
        (item) => stripOwner(item.row),
      ),
      settings: page.filter((item) => item.table === "user_settings").map(
        (item) => stripOwner(item.row),
      ),
      has_more: hasMore,
      next_cursor: hasMore && last
        ? encodeChangeCursor({
          updated_at: String(last.row.updated_at),
          table: last.table,
          id: last.id,
        })
        : null,
    },
  };
}

async function reserveIdempotency(
  ctx: RequestContext,
  key: string,
  fingerprint: string,
): Promise<ApiResult | null> {
  if (key.length < 8 || key.length > 200) {
    throw new ApiError(
      400,
      "invalid_idempotency_key",
      "Idempotency keys must contain 8 to 200 characters.",
    );
  }
  ctx.idempotencyKey = key;
  const requestHash = await sha256Hex(fingerprint);
  // Durable row recovery is scoped to the authenticated key and exact
  // request body. Reusing a raw idempotency key after its receipt expires can
  // never be mistaken for an older, different mutation.
  ctx.idempotencyMarker = await sha256Hex(
    `${ctx.key.id}:${key}:${requestHash}`,
  );
  const reservation = {
    key_id: ctx.key.id,
    idempotency_key: key,
    user_id: ctx.key.user_id,
    request_hash: requestHash,
  };
  const { error } = await ctx.admin.from("payday_agent_idempotency").insert(
    reservation,
  );
  if (!error) return null;
  if (error.code !== "23505") {
    throw new ApiError(
      503,
      "idempotency_unavailable",
      "Unable to reserve the idempotency key.",
    );
  }
  const { data, error: fetchError } = await ctx.admin.from(
    "payday_agent_idempotency",
  ).select("request_hash,state,status_code,response_body,created_at,expires_at")
    .eq("key_id", ctx.key.id).eq("idempotency_key", key).single();
  if (fetchError || !data) {
    throw new ApiError(
      503,
      "idempotency_unavailable",
      "Unable to verify the idempotency key.",
    );
  }
  if (data.request_hash !== requestHash) {
    throw new ApiError(
      409,
      "idempotency_conflict",
      "This idempotency key was already used for a different request.",
    );
  }
  if (data.expires_at <= new Date().toISOString()) {
    await ctx.admin.from("payday_agent_idempotency").delete().eq(
      "key_id",
      ctx.key.id,
    ).eq("idempotency_key", key);
    return reserveIdempotency(ctx, key, fingerprint);
  }
  if (data.state !== "completed") {
    const createdAt = Date.parse(data.created_at);
    if (
      Number.isFinite(createdAt) &&
      Date.now() - createdAt >= IDEMPOTENCY_STALE_MS
    ) {
      const { error: releaseError } = await ctx.admin
        .from("payday_agent_idempotency")
        .delete()
        .eq("key_id", ctx.key.id)
        .eq("idempotency_key", key)
        .eq("state", "in_progress")
        .eq("created_at", data.created_at);
      if (releaseError) {
        throw new ApiError(
          503,
          "idempotency_unavailable",
          "Unable to recover the interrupted request.",
        );
      }
      return reserveIdempotency(ctx, key, fingerprint);
    }
    throw new ApiError(
      409,
      "request_in_progress",
      "A request with this idempotency key is still in progress.",
    );
  }
  return {
    status: data.status_code,
    body: data.response_body,
    operation: "idempotent_replay",
    headers: { "idempotent-replayed": "true" },
  };
}

async function completeIdempotency(
  ctx: RequestContext,
  result: ApiResult,
): Promise<void> {
  if (!ctx.idempotencyKey) return;
  const { error } = await ctx.admin.from("payday_agent_idempotency").update({
    state: "completed",
    status_code: result.status,
    response_body: result.body,
    completed_at: new Date().toISOString(),
  }).eq("key_id", ctx.key.id).eq("idempotency_key", ctx.idempotencyKey);
  if (error) {
    throw new ApiError(
      503,
      "idempotency_completion_failed",
      "The mutation completed, but its retry receipt could not be saved. Retry with the same idempotency key.",
    );
  }
}

async function abandonIdempotency(ctx: RequestContext): Promise<void> {
  if (!ctx.idempotencyKey) return;
  await ctx.admin.from("payday_agent_idempotency").delete().eq(
    "key_id",
    ctx.key.id,
  ).eq("idempotency_key", ctx.idempotencyKey).eq("state", "in_progress");
}

async function idempotent(
  ctx: RequestContext,
  key: string | undefined,
  fingerprint: string,
  operation: () => Promise<ApiResult>,
): Promise<ApiResult> {
  if (!key) {
    throw new ApiError(
      400,
      "idempotency_required",
      "Write requests require an Idempotency-Key header or idempotency_key tool argument.",
    );
  }
  const replay = await reserveIdempotency(ctx, key, fingerprint);
  if (replay) return replay;
  try {
    const result = await operation();
    await completeIdempotency(ctx, result);
    return result;
  } catch (error) {
    if (
      error instanceof ApiError &&
      (error.status < 500 || error.code === "idempotency_completion_failed")
    ) {
      await abandonIdempotency(ctx);
    }
    throw error;
  }
}

async function executeNamed(
  ctx: RequestContext,
  name: string,
  argsValue: unknown,
): Promise<ApiResult> {
  const args = requireObject(argsValue, "arguments");
  const idempotencyKey = typeof args.idempotency_key === "string"
    ? args.idempotency_key
    : undefined;
  const input = { ...args };
  delete input.idempotency_key;
  const mutation = (operation: () => Promise<JsonObject>, status = 200) =>
    idempotent(
      ctx,
      idempotencyKey,
      JSON.stringify({ name, input }),
      async () => ({ status, body: await operation(), operation: name }),
    );
  switch (name) {
    case "get_summary":
      return { status: 200, body: await summary(ctx, input), operation: name };
    case "list_shifts":
      return {
        status: 200,
        body: await listShifts(ctx, input),
        operation: name,
      };
    case "get_shift":
      return {
        status: 200,
        body: await getShift(ctx, input.shift_id),
        operation: name,
      };
    case "list_tip_entries":
      return {
        status: 200,
        body: await listRows(ctx, "tip_entries", input),
        operation: name,
      };
    case "get_tip_entry":
      return {
        status: 200,
        body: await getRow(ctx, "tip_entries", input.id),
        operation: name,
      };
    case "create_shift":
      return mutation(() => createShift(ctx, input), 201);
    case "create_tip_entry":
      return mutation(() => createRow(ctx, "tip_entries", input), 201);
    case "update_tip_entry":
      return mutation(() => updateRow(ctx, "tip_entries", input.id, input));
    case "delete_tip_entry":
      return mutation(() =>
        changeDeletion(
          ctx,
          "tip_entries",
          input.id,
          input.expected_version,
          false,
        )
      );
    case "restore_tip_entry":
      return mutation(() =>
        changeDeletion(
          ctx,
          "tip_entries",
          input.id,
          input.expected_version,
          true,
        )
      );
    case "list_paychecks":
      return {
        status: 200,
        body: await listRows(ctx, "paycheck_records", input),
        operation: name,
      };
    case "get_paycheck":
      return {
        status: 200,
        body: await getRow(ctx, "paycheck_records", input.id),
        operation: name,
      };
    case "create_paycheck":
      return mutation(() => createRow(ctx, "paycheck_records", input), 201);
    case "update_paycheck":
      return mutation(() =>
        updateRow(ctx, "paycheck_records", input.id, input)
      );
    case "delete_paycheck":
      return mutation(() =>
        changeDeletion(
          ctx,
          "paycheck_records",
          input.id,
          input.expected_version,
          false,
        )
      );
    case "restore_paycheck":
      return mutation(() =>
        changeDeletion(
          ctx,
          "paycheck_records",
          input.id,
          input.expected_version,
          true,
        )
      );
    case "get_settings":
      return { status: 200, body: await getSettings(ctx), operation: name };
    case "update_settings":
      return mutation(() => updateSettings(ctx, input));
    case "get_changes":
      return { status: 200, body: await changes(ctx, input), operation: name };
    case "list_api_keys":
      return { status: 200, body: await listKeys(ctx), operation: name };
    // Key secrets are intentionally never persisted in the idempotency cache.
    // Active key names are unique, so an accidental retry fails closed.
    case "create_api_key":
      return {
        status: 201,
        body: await createKey(ctx, input),
        operation: name,
      };
    case "revoke_api_key":
      return mutation(() => revokeKey(ctx, input.key_id));
    case "list_audit_log":
      return {
        status: 200,
        body: await listAudit(ctx, input),
        operation: name,
      };
    default:
      throw new ApiError(404, "unknown_tool", `Unknown Payday tool: ${name}`);
  }
}

const dateRangeProperties = {
  start_date: {
    type: "string",
    format: "date",
    description: "Optional inclusive YYYY-MM-DD lower bound.",
  },
  end_date: {
    type: "string",
    format: "date",
    description: "Optional inclusive YYYY-MM-DD upper bound.",
  },
};
const listProperties = {
  ...dateRangeProperties,
  limit: { type: "integer", minimum: 1, maximum: 200, default: 100 },
  cursor: {
    type: "string",
    format: "uuid",
    description: "The next_cursor from the previous page.",
  },
  include_deleted: { type: "boolean", default: false },
};
const idempotencyProperty = {
  type: "string",
  minLength: 8,
  maxLength: 200,
  description: "A unique retry-safe identifier for this write.",
};
const versionProperty = {
  type: "integer",
  minimum: 1,
  description: "The latest version returned by a read.",
};
const nullableNonnegativeInteger = {
  type: ["integer", "null"],
  minimum: 0,
};
const tipWritableProperties = {
  shift_id: { type: ["string", "null"], format: "uuid" },
  work_date: { type: "string", format: "date" },
  amount_cents: { type: "integer", minimum: 0 },
  kind: { enum: ["cash", "credit"] },
  note: { type: ["string", "null"] },
  recorded_at: { type: ["string", "null"], format: "date-time" },
  is_double: { type: "boolean" },
  hours_worked: { type: ["number", "null"], minimum: 0 },
  tip_out_cents: nullableNonnegativeInteger,
  sales_cents: nullableNonnegativeInteger,
  shift_period: { enum: ["lunch", "dinner", null] },
  clock_in: { type: ["string", "null"], format: "date-time" },
  clock_out: { type: ["string", "null"], format: "date-time" },
  server_count: nullableNonnegativeInteger,
  receipt_metrics: { type: ["object", "null"] },
};
const paycheckWritableProperties = {
  period_start: { type: "string", format: "date" },
  period_end: { type: "string", format: "date" },
  paid_tips_cents: { type: "integer", minimum: 0 },
  note: { type: ["string", "null"] },
  hourly_rate_cents: nullableNonnegativeInteger,
  owed_tips_cents: nullableNonnegativeInteger,
  gross_pay_cents: nullableNonnegativeInteger,
  net_pay_cents: nullableNonnegativeInteger,
  regular_wages_cents: nullableNonnegativeInteger,
  overtime_wages_cents: nullableNonnegativeInteger,
  gratuity_cents: nullableNonnegativeInteger,
  taxes_cents: nullableNonnegativeInteger,
};
const settingsWritableProperties = {
  first_name: { type: ["string", "null"] },
  base_hourly_wage_cents: nullableNonnegativeInteger,
  pay_frequency: {
    enum: ["weekly", "biweekly", "twiceMonthly", "monthly", null],
  },
  anchor_period_end: { type: ["string", "null"], format: "date" },
  pay_delay_days: nullableNonnegativeInteger,
  first_weekday: { type: ["integer", "null"], minimum: 1, maximum: 7 },
  smart_nudge_enabled: { type: "boolean" },
  payday_reminder_enabled: { type: "boolean" },
  move_ledger: { type: "object", additionalProperties: { type: "string" } },
};

const tools = [
  {
    name: "get_summary",
    description:
      "Return Payday earnings and paycheck totals for an optional date range.",
    inputSchema: {
      type: "object",
      properties: dateRangeProperties,
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true },
  },
  {
    name: "list_shifts",
    description:
      "List semantic shifts grouped from their cash and credit tip rows.",
    inputSchema: {
      type: "object",
      properties: {
        ...dateRangeProperties,
        limit: { type: "integer", minimum: 1, maximum: 200 },
        cursor: {
          type: "string",
          description: "Opaque next_cursor returned by the previous page.",
        },
      },
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true },
  },
  {
    name: "get_shift",
    description: "Get one shift and all of its underlying tip entries.",
    inputSchema: {
      type: "object",
      properties: { shift_id: { type: "string", format: "uuid" } },
      required: ["shift_id"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true },
  },
  {
    name: "list_tip_entries",
    description: "List raw tip-entry records with cursor pagination.",
    inputSchema: {
      type: "object",
      properties: listProperties,
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true },
  },
  {
    name: "get_tip_entry",
    description: "Get one raw tip-entry record.",
    inputSchema: {
      type: "object",
      properties: { id: { type: "string", format: "uuid" } },
      required: ["id"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true },
  },
  {
    name: "create_shift",
    description:
      "Create a complete shift with cash and/or credit tips. Shift-level facts are stored on the credit row when present.",
    inputSchema: {
      type: "object",
      properties: {
        idempotency_key: idempotencyProperty,
        shift_id: { type: "string", format: "uuid" },
        work_date: { type: "string", format: "date" },
        cash_tip_cents: { type: "integer", minimum: 0 },
        credit_tip_cents: { type: "integer", minimum: 0 },
        note: { type: ["string", "null"] },
        recorded_at: { type: ["string", "null"], format: "date-time" },
        hours_worked: { type: ["number", "null"], minimum: 0 },
        tip_out_cents: { type: ["integer", "null"], minimum: 0 },
        sales_cents: { type: ["integer", "null"], minimum: 0 },
        shift_period: { enum: ["lunch", "dinner", null] },
        clock_in: { type: ["string", "null"], format: "date-time" },
        clock_out: { type: ["string", "null"], format: "date-time" },
        server_count: { type: ["integer", "null"], minimum: 0 },
        receipt_metrics: { type: ["object", "null"] },
      },
      required: ["idempotency_key", "work_date"],
      additionalProperties: false,
    },
    annotations: { destructiveHint: false },
  },
  {
    name: "create_tip_entry",
    description: "Create one raw cash or credit tip entry.",
    inputSchema: {
      type: "object",
      properties: {
        idempotency_key: idempotencyProperty,
        id: { type: "string", format: "uuid" },
        ...tipWritableProperties,
      },
      required: ["idempotency_key", "work_date", "amount_cents", "kind"],
      additionalProperties: false,
    },
    annotations: { destructiveHint: false },
  },
  {
    name: "update_tip_entry",
    description:
      "Optimistically update a tip entry. Fetch first and pass its current version.",
    inputSchema: {
      type: "object",
      properties: {
        idempotency_key: idempotencyProperty,
        id: { type: "string", format: "uuid" },
        expected_version: versionProperty,
        ...tipWritableProperties,
      },
      required: ["idempotency_key", "id", "expected_version"],
      additionalProperties: false,
    },
    annotations: { destructiveHint: false },
  },
  {
    name: "delete_tip_entry",
    description:
      "Soft-delete a tip entry so the deletion safely syncs to devices.",
    inputSchema: {
      type: "object",
      properties: {
        idempotency_key: idempotencyProperty,
        id: { type: "string", format: "uuid" },
        expected_version: versionProperty,
      },
      required: ["idempotency_key", "id", "expected_version"],
      additionalProperties: false,
    },
    annotations: { destructiveHint: true },
  },
  {
    name: "restore_tip_entry",
    description: "Restore a previously soft-deleted tip entry.",
    inputSchema: {
      type: "object",
      properties: {
        idempotency_key: idempotencyProperty,
        id: { type: "string", format: "uuid" },
        expected_version: versionProperty,
      },
      required: ["idempotency_key", "id", "expected_version"],
      additionalProperties: false,
    },
  },
  {
    name: "list_paychecks",
    description: "List paycheck records with cursor pagination.",
    inputSchema: {
      type: "object",
      properties: listProperties,
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true },
  },
  {
    name: "get_paycheck",
    description: "Get one paycheck record.",
    inputSchema: {
      type: "object",
      properties: { id: { type: "string", format: "uuid" } },
      required: ["id"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true },
  },
  {
    name: "create_paycheck",
    description: "Create a paycheck record using exact integer cents.",
    inputSchema: {
      type: "object",
      properties: {
        idempotency_key: idempotencyProperty,
        id: { type: "string", format: "uuid" },
        ...paycheckWritableProperties,
      },
      required: [
        "idempotency_key",
        "period_start",
        "period_end",
        "paid_tips_cents",
      ],
      additionalProperties: false,
    },
    annotations: { destructiveHint: false },
  },
  {
    name: "update_paycheck",
    description:
      "Optimistically update a paycheck. Fetch first and pass its current version.",
    inputSchema: {
      type: "object",
      properties: {
        idempotency_key: idempotencyProperty,
        id: { type: "string", format: "uuid" },
        expected_version: versionProperty,
        ...paycheckWritableProperties,
      },
      required: ["idempotency_key", "id", "expected_version"],
      additionalProperties: false,
    },
    annotations: { destructiveHint: false },
  },
  {
    name: "delete_paycheck",
    description: "Soft-delete a paycheck record.",
    inputSchema: {
      type: "object",
      properties: {
        idempotency_key: idempotencyProperty,
        id: { type: "string", format: "uuid" },
        expected_version: versionProperty,
      },
      required: ["idempotency_key", "id", "expected_version"],
      additionalProperties: false,
    },
    annotations: { destructiveHint: true },
  },
  {
    name: "restore_paycheck",
    description: "Restore a previously soft-deleted paycheck record.",
    inputSchema: {
      type: "object",
      properties: {
        idempotency_key: idempotencyProperty,
        id: { type: "string", format: "uuid" },
        expected_version: versionProperty,
      },
      required: ["idempotency_key", "id", "expected_version"],
      additionalProperties: false,
    },
  },
  {
    name: "get_settings",
    description: "Read Payday settings and their current version.",
    inputSchema: { type: "object", additionalProperties: false },
    annotations: { readOnlyHint: true },
  },
  {
    name: "update_settings",
    description: "Optimistically update Payday settings.",
    inputSchema: {
      type: "object",
      properties: {
        idempotency_key: idempotencyProperty,
        expected_version: versionProperty,
        ...settingsWritableProperties,
      },
      required: ["idempotency_key", "expected_version"],
      additionalProperties: false,
    },
    annotations: { destructiveHint: false },
  },
  {
    name: "get_changes",
    description:
      "Get records changed after an ISO-8601 timestamp, including tombstones.",
    inputSchema: {
      type: "object",
      properties: {
        since: { type: "string", format: "date-time" },
        cursor: {
          type: "string",
          description: "Opaque next_cursor returned by the previous page.",
        },
        limit: { type: "integer", minimum: 1, maximum: 500, default: 200 },
      },
      required: ["since"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true },
  },
  {
    name: "list_api_keys",
    description:
      "List agent-key metadata without revealing token hashes or secrets.",
    inputSchema: { type: "object", additionalProperties: false },
    annotations: { readOnlyHint: true },
  },
  {
    name: "revoke_api_key",
    description: "Immediately revoke an agent key.",
    inputSchema: {
      type: "object",
      properties: {
        idempotency_key: idempotencyProperty,
        key_id: { type: "string", format: "uuid" },
      },
      required: ["idempotency_key", "key_id"],
      additionalProperties: false,
    },
    annotations: { destructiveHint: true },
  },
  {
    name: "list_audit_log",
    description: "List recent REST and MCP audit events.",
    inputSchema: {
      type: "object",
      properties: {
        limit: { type: "integer", minimum: 1, maximum: 200 },
        cursor: {
          type: "string",
          description: "Opaque next_cursor returned by the previous page.",
        },
      },
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true },
  },
];

function mcpResult(body: JsonObject): JsonObject {
  return {
    content: [{ type: "text", text: JSON.stringify(body) }],
    structuredContent: body,
    isError: false,
  };
}

function mcpProtocolError(
  id: unknown,
  code: number,
  message: string,
  operation: string,
): ApiResult {
  return {
    status: 200,
    operation,
    errorCode: String(code),
    body: { jsonrpc: "2.0", id: id ?? null, error: { code, message } },
  };
}

async function handleMCP(
  ctx: RequestContext,
  payloadValue: unknown,
): Promise<ApiResult | null> {
  let payload: JsonObject;
  try {
    payload = requireObject(payloadValue, "JSON-RPC message");
  } catch {
    return mcpProtocolError(null, -32600, "Invalid Request", "mcp.invalid");
  }
  if (payload.jsonrpc !== "2.0" || typeof payload.method !== "string") {
    return mcpProtocolError(
      payload.id,
      -32600,
      "Invalid Request",
      "mcp.invalid",
    );
  }
  const hasID = Object.prototype.hasOwnProperty.call(payload, "id");
  if (!hasID) return null;
  const id = payload.id;
  if (
    id === null ||
    (typeof id !== "string" && typeof id !== "number")
  ) {
    return mcpProtocolError(
      null,
      -32600,
      "Invalid Request",
      "mcp.invalid",
    );
  }
  if (payload.method === "initialize") {
    try {
      const params = requireObject(payload.params, "params");
      requiredString(params.protocolVersion, "params.protocolVersion", 32);
      requireObject(params.capabilities, "params.capabilities");
      const clientInfo = requireObject(params.clientInfo, "params.clientInfo");
      requiredString(clientInfo.name, "params.clientInfo.name", 200);
      requiredString(clientInfo.version, "params.clientInfo.version", 100);
    } catch {
      return mcpProtocolError(
        id,
        -32602,
        "Invalid initialize parameters",
        "mcp.initialize.invalid",
      );
    }
    return {
      status: 200,
      operation: "mcp.initialize",
      body: {
        jsonrpc: "2.0",
        id,
        result: {
          protocolVersion: MCP_PROTOCOL_VERSION,
          capabilities: { tools: { listChanged: false } },
          serverInfo: { name: "payday", title: "Payday", version: API_VERSION },
          instructions:
            "Read and write the authenticated user's Payday shifts, tips, paychecks, and settings. Fetch current versions before updates or deletes.",
        },
      },
    };
  }
  if (payload.method === "ping") {
    return {
      status: 200,
      operation: "mcp.ping",
      body: { jsonrpc: "2.0", id, result: {} },
    };
  }
  if (payload.method === "tools/list") {
    return {
      status: 200,
      operation: "mcp.tools.list",
      body: { jsonrpc: "2.0", id, result: { tools } },
    };
  }
  if (payload.method === "tools/call") {
    let params: JsonObject;
    let name: string;
    try {
      params = requireObject(payload.params, "params");
      name = requiredString(params.name, "params.name", 128);
      if (
        params.arguments !== undefined && !isRecord(params.arguments)
      ) throw new Error("invalid arguments");
    } catch {
      return mcpProtocolError(
        id,
        -32602,
        "Invalid tools/call parameters",
        "mcp.tools.call.invalid",
      );
    }
    if (!tools.some((tool) => tool.name === name)) {
      return mcpProtocolError(
        id,
        -32602,
        `Unknown tool: ${name}`,
        "mcp.tools.call.invalid",
      );
    }
    try {
      const result = await executeNamed(ctx, name, params.arguments ?? {});
      return {
        status: 200,
        operation: `mcp.${name}`,
        body: { jsonrpc: "2.0", id, result: mcpResult(result.body) },
        headers: result.headers,
      };
    } catch (error) {
      const apiError = error instanceof ApiError
        ? error
        : new ApiError(500, "internal_error", "Unexpected server error.");
      return {
        status: 200,
        operation: `mcp.${name}`,
        errorCode: apiError.code,
        body: {
          jsonrpc: "2.0",
          id,
          result: {
            content: [{
              type: "text",
              text: `${apiError.code}: ${apiError.message}`,
            }],
            structuredContent: {
              error: { code: apiError.code, message: apiError.message },
            },
            isError: true,
          },
        },
      };
    }
  }
  return mcpProtocolError(id, -32601, "Method not found", "mcp.unknown");
}

function openAPISpec(origin: string): JsonObject {
  const security = [{ paydayAgentToken: [] }];
  const idParameter = {
    name: "id",
    in: "path",
    required: true,
    schema: { type: "string", format: "uuid" },
  };
  const shiftIDParameter = { ...idParameter, name: "shift_id" };
  const idempotencyParameter = {
    name: "Idempotency-Key",
    in: "header",
    required: true,
    schema: { type: "string", minLength: 8, maxLength: 200 },
  };
  const expectedVersionParameter = {
    name: "expected_version",
    in: "query",
    required: true,
    schema: { type: "integer", minimum: 1 },
  };
  const jsonBody = (properties: JsonObject, required: string[] = []) => ({
    required: true,
    content: {
      "application/json": {
        schema: {
          type: "object",
          properties,
          ...(required.length ? { required } : {}),
          additionalProperties: false,
        },
      },
    },
  });
  const mutationResponses = {
    "200": { description: "Completed" },
    "400": { description: "Invalid request or missing idempotency key" },
    "409": { description: "Version or idempotency conflict" },
  };
  return {
    openapi: "3.1.0",
    info: {
      title: "Payday API",
      version: API_VERSION,
      description:
        "Secure, user-scoped API for Payday shifts, tip entries, paychecks, settings, agent credentials, and audit events.",
    },
    servers: [{ url: `${origin}/functions/v1/payday-api` }],
    components: {
      securitySchemes: {
        paydayAgentToken: {
          type: "http",
          scheme: "bearer",
          bearerFormat: "pd_live_…",
        },
      },
    },
    paths: {
      "/v1/health": {
        get: {
          security: [],
          summary: "Health check",
          responses: { "200": { description: "Healthy" } },
        },
      },
      "/v1/openapi.json": {
        get: {
          security: [],
          summary: "OpenAPI description",
          responses: { "200": { description: "OpenAPI 3.1 document" } },
        },
      },
      "/v1/summary": {
        get: {
          security,
          summary: "Get earnings summary",
          parameters: [{
            name: "start_date",
            in: "query",
            schema: { type: "string", format: "date" },
          }, {
            name: "end_date",
            in: "query",
            schema: { type: "string", format: "date" },
          }],
          responses: { "200": { description: "Summary" } },
        },
      },
      "/v1/shifts": {
        get: {
          security,
          summary: "List semantic shifts",
          parameters: [{
            name: "cursor",
            in: "query",
            schema: { type: "string" },
            description: "Opaque next_cursor returned by the previous page.",
          }],
          responses: { "200": { description: "Shifts" } },
        },
        post: {
          security,
          summary: "Create a shift",
          parameters: [idempotencyParameter],
          requestBody: jsonBody({
            shift_id: { type: "string", format: "uuid" },
            work_date: { type: "string", format: "date" },
            cash_tip_cents: { type: "integer", minimum: 0 },
            credit_tip_cents: { type: "integer", minimum: 0 },
            note: { type: ["string", "null"] },
            recorded_at: {
              type: ["string", "null"],
              format: "date-time",
            },
            hours_worked: { type: ["number", "null"], minimum: 0 },
            tip_out_cents: nullableNonnegativeInteger,
            sales_cents: nullableNonnegativeInteger,
            shift_period: { enum: ["lunch", "dinner", null] },
            clock_in: { type: ["string", "null"], format: "date-time" },
            clock_out: { type: ["string", "null"], format: "date-time" },
            server_count: nullableNonnegativeInteger,
            receipt_metrics: { type: ["object", "null"] },
          }, ["work_date"]),
          responses: { "201": { description: "Created" } },
        },
      },
      "/v1/shifts/{shift_id}": {
        get: {
          security,
          summary: "Get one semantic shift",
          parameters: [shiftIDParameter],
          responses: { "200": { description: "Shift" } },
        },
      },
      "/v1/tip-entries": {
        get: {
          security,
          summary: "List tip entries",
          responses: { "200": { description: "Tip entries" } },
        },
        post: {
          security,
          summary: "Create a tip entry",
          parameters: [idempotencyParameter],
          requestBody: jsonBody({
            id: { type: "string", format: "uuid" },
            ...tipWritableProperties,
          }, ["work_date", "amount_cents", "kind"]),
          responses: { "201": { description: "Created" } },
        },
      },
      "/v1/tip-entries/{id}": {
        get: {
          security,
          summary: "Get a tip entry",
          parameters: [idParameter],
          responses: { "200": { description: "Tip entry" } },
        },
        patch: {
          security,
          summary: "Update a tip entry",
          parameters: [idParameter, idempotencyParameter],
          requestBody: jsonBody({
            expected_version: versionProperty,
            ...tipWritableProperties,
          }, ["expected_version"]),
          responses: mutationResponses,
        },
        delete: {
          security,
          summary: "Soft-delete a tip entry",
          parameters: [
            idParameter,
            idempotencyParameter,
            expectedVersionParameter,
          ],
          responses: mutationResponses,
        },
      },
      "/v1/tip-entries/{id}/restore": {
        post: {
          security,
          summary: "Restore a tip entry tombstone",
          parameters: [idParameter, idempotencyParameter],
          requestBody: jsonBody({ expected_version: versionProperty }, [
            "expected_version",
          ]),
          responses: mutationResponses,
        },
      },
      "/v1/paychecks": {
        get: {
          security,
          summary: "List paychecks",
          responses: { "200": { description: "Paychecks" } },
        },
        post: {
          security,
          summary: "Create a paycheck",
          parameters: [idempotencyParameter],
          requestBody: jsonBody({
            id: { type: "string", format: "uuid" },
            ...paycheckWritableProperties,
          }, ["period_start", "period_end", "paid_tips_cents"]),
          responses: { "201": { description: "Created" } },
        },
      },
      "/v1/paychecks/{id}": {
        get: {
          security,
          summary: "Get a paycheck",
          parameters: [idParameter],
          responses: { "200": { description: "Paycheck" } },
        },
        patch: {
          security,
          summary: "Update a paycheck",
          parameters: [idParameter, idempotencyParameter],
          requestBody: jsonBody({
            expected_version: versionProperty,
            ...paycheckWritableProperties,
          }, ["expected_version"]),
          responses: mutationResponses,
        },
        delete: {
          security,
          summary: "Soft-delete a paycheck",
          parameters: [
            idParameter,
            idempotencyParameter,
            expectedVersionParameter,
          ],
          responses: mutationResponses,
        },
      },
      "/v1/paychecks/{id}/restore": {
        post: {
          security,
          summary: "Restore a paycheck tombstone",
          parameters: [idParameter, idempotencyParameter],
          requestBody: jsonBody({ expected_version: versionProperty }, [
            "expected_version",
          ]),
          responses: mutationResponses,
        },
      },
      "/v1/settings": {
        get: {
          security,
          summary: "Get settings",
          responses: { "200": { description: "Settings" } },
        },
        patch: {
          security,
          summary: "Update settings",
          parameters: [idempotencyParameter],
          requestBody: jsonBody({
            expected_version: versionProperty,
            ...settingsWritableProperties,
          }, ["expected_version"]),
          responses: mutationResponses,
        },
      },
      "/v1/changes": {
        get: {
          security,
          summary: "Get changes since a timestamp",
          parameters: [{
            name: "since",
            in: "query",
            required: true,
            schema: { type: "string", format: "date-time" },
          }, {
            name: "cursor",
            in: "query",
            schema: { type: "string" },
          }, {
            name: "limit",
            in: "query",
            schema: { type: "integer", minimum: 1, maximum: 500 },
          }],
          responses: { "200": { description: "Changes" } },
        },
      },
      "/v1/keys": {
        get: {
          security,
          summary: "List agent keys",
          responses: { "200": { description: "Keys" } },
        },
        post: {
          security,
          summary: "Create an agent key",
          requestBody: jsonBody({
            name: { type: "string", minLength: 1, maxLength: 100 },
            scopes: {
              type: "array",
              minItems: 1,
              uniqueItems: true,
              items: { enum: ALL_SCOPES },
            },
            rate_limit_per_minute: {
              type: "integer",
              minimum: 1,
              maximum: 600,
            },
            expires_at: { type: ["string", "null"], format: "date-time" },
          }, ["name", "scopes"]),
          responses: { "201": { description: "Created; token returned once" } },
        },
      },
      "/v1/keys/{id}": {
        delete: {
          security,
          summary: "Revoke a key and all descendant keys",
          parameters: [idParameter, idempotencyParameter],
          responses: mutationResponses,
        },
      },
      "/v1/audit": {
        get: {
          security,
          summary: "List audit events",
          parameters: [{
            name: "cursor",
            in: "query",
            schema: { type: "string" },
            description: "Opaque next_cursor returned by the previous page.",
          }],
          responses: { "200": { description: "Audit events" } },
        },
      },
      "/mcp": {
        post: {
          security,
          summary: "MCP Streamable HTTP endpoint",
          responses: {
            "200": { description: "JSON-RPC response" },
            "202": { description: "Notification accepted" },
          },
        },
        delete: {
          security,
          summary: "Terminate a stateless MCP session",
          responses: { "204": { description: "Accepted" } },
        },
      },
    },
  };
}

export const testing = {
  auditCursor,
  dateOnly,
  encodeAuditCursor,
  encodeShiftCursor,
  groupShifts,
  moveLedger,
  publicPath,
  receiptMetrics,
  shiftCursor,
  timestamp,
  tipFacts,
};

function handleREST(
  req: Request,
  url: URL,
  path: string,
  ctx: RequestContext,
  body: unknown,
): Promise<ApiResult> {
  const method = req.method.toUpperCase();
  const parts = path.split("/").filter(Boolean);
  const idempotencyKey = req.headers.get("idempotency-key") ?? undefined;
  const argsFromURL = (): JsonObject => {
    const args = listArguments(url);
    return {
      ...args,
      start_date: url.searchParams.get("start_date") ?? undefined,
      end_date: url.searchParams.get("end_date") ?? undefined,
    };
  };
  const mutation = (name: string, args: JsonObject) =>
    executeNamed(ctx, name, { ...args, idempotency_key: idempotencyKey });

  if (method === "GET" && path === "/v1/summary") {
    return executeNamed(ctx, "get_summary", {
      start_date: url.searchParams.get("start_date") ?? undefined,
      end_date: url.searchParams.get("end_date") ?? undefined,
    });
  }
  if (method === "GET" && path === "/v1/shifts") {
    return executeNamed(ctx, "list_shifts", argsFromURL());
  }
  if (method === "POST" && path === "/v1/shifts") {
    return mutation("create_shift", requireObject(body));
  }
  if (
    method === "GET" && parts.length === 3 && parts[0] === "v1" &&
    parts[1] === "shifts" && parts[2]
  ) return executeNamed(ctx, "get_shift", { shift_id: parts[2] });
  if (method === "GET" && path === "/v1/tip-entries") {
    return executeNamed(ctx, "list_tip_entries", argsFromURL());
  }
  if (method === "POST" && path === "/v1/tip-entries") {
    return mutation("create_tip_entry", requireObject(body));
  }
  if (parts[0] === "v1" && parts[1] === "tip-entries" && parts[2]) {
    if (method === "GET" && parts.length === 3) {
      return executeNamed(ctx, "get_tip_entry", { id: parts[2] });
    }
    if (method === "PATCH" && parts.length === 3) {
      return mutation("update_tip_entry", {
        ...requireObject(body),
        id: parts[2],
      });
    }
    if (method === "DELETE" && parts.length === 3) {
      return mutation("delete_tip_entry", {
        id: parts[2],
        expected_version: Number(url.searchParams.get("expected_version")),
      });
    }
    if (
      method === "POST" && parts.length === 4 && parts[3] === "restore"
    ) {
      return mutation("restore_tip_entry", {
        id: parts[2],
        expected_version: requireObject(body).expected_version,
      });
    }
  }
  if (method === "GET" && path === "/v1/paychecks") {
    return executeNamed(ctx, "list_paychecks", argsFromURL());
  }
  if (method === "POST" && path === "/v1/paychecks") {
    return mutation("create_paycheck", requireObject(body));
  }
  if (parts[0] === "v1" && parts[1] === "paychecks" && parts[2]) {
    if (method === "GET" && parts.length === 3) {
      return executeNamed(ctx, "get_paycheck", { id: parts[2] });
    }
    if (method === "PATCH" && parts.length === 3) {
      return mutation("update_paycheck", {
        ...requireObject(body),
        id: parts[2],
      });
    }
    if (method === "DELETE" && parts.length === 3) {
      return mutation("delete_paycheck", {
        id: parts[2],
        expected_version: Number(url.searchParams.get("expected_version")),
      });
    }
    if (
      method === "POST" && parts.length === 4 && parts[3] === "restore"
    ) {
      return mutation("restore_paycheck", {
        id: parts[2],
        expected_version: requireObject(body).expected_version,
      });
    }
  }
  if (method === "GET" && path === "/v1/settings") {
    return executeNamed(ctx, "get_settings", {});
  }
  if (method === "PATCH" && path === "/v1/settings") {
    return mutation("update_settings", requireObject(body));
  }
  if (method === "GET" && path === "/v1/changes") {
    return executeNamed(ctx, "get_changes", {
      since: url.searchParams.get("since"),
      cursor: url.searchParams.get("cursor") ?? undefined,
      limit: url.searchParams.get("limit")
        ? Number(url.searchParams.get("limit"))
        : undefined,
    });
  }
  if (method === "GET" && path === "/v1/keys") {
    return executeNamed(ctx, "list_api_keys", {});
  }
  if (method === "POST" && path === "/v1/keys") {
    return executeNamed(ctx, "create_api_key", requireObject(body));
  }
  if (
    method === "DELETE" && parts.length === 3 && parts[0] === "v1" &&
    parts[1] === "keys" && parts[2]
  ) return mutation("revoke_api_key", { key_id: parts[2] });
  if (method === "GET" && path === "/v1/audit") {
    return executeNamed(ctx, "list_audit_log", {
      cursor: url.searchParams.get("cursor") ?? undefined,
      limit: url.searchParams.get("limit")
        ? Number(url.searchParams.get("limit"))
        : undefined,
    });
  }
  throw new ApiError(404, "not_found", "API route not found.");
}

async function audit(
  ctx: RequestContext,
  req: Request,
  path: string,
  operation: string,
  statusCode: number,
  errorCode?: string,
): Promise<void> {
  const duration = Math.max(0, Math.round(performance.now() - ctx.startedAt));
  const { error } = await ctx.admin.from("payday_agent_audit_log").insert({
    request_id: ctx.requestID,
    key_id: ctx.key.id,
    user_id: ctx.key.user_id,
    method: req.method,
    path,
    operation,
    status_code: statusCode,
    duration_ms: duration,
    idempotency_key: ctx.idempotencyKey ?? null,
    error_code: errorCode ?? null,
    metadata: {
      interface: path === "/mcp" ? "mcp" : "rest",
      api_version: API_VERSION,
    },
  });
  if (error) console.error("Payday audit insertion failed.");
}

async function auditRejectedRequest(
  req: Request,
  path: string,
  requestID: string,
  startedAt: number,
  error: ApiError,
): Promise<void> {
  const event = {
    request_id: requestID,
    method: req.method,
    path,
    status_code: error.status,
    duration_ms: Math.max(0, Math.round(performance.now() - startedAt)),
    error_code: error.code,
    metadata: {
      interface: path === "/mcp" ? "mcp" : "rest",
      api_version: API_VERSION,
      authorization_present: req.headers.has("authorization"),
      origin_present: req.headers.has("origin"),
    },
  };
  console.warn("Payday unauthenticated request rejected.", event);
  try {
    const { error: auditError } = await adminClient()
      .from("payday_agent_rejected_requests")
      .insert(event);
    if (auditError) {
      console.error("Payday rejected-request audit insertion failed.");
    }
  } catch {
    // Platform logs remain available when the database or configuration is
    // itself the failed dependency.
    console.error("Payday rejected-request audit was unavailable.");
  }
}

export async function handleRequest(req: Request): Promise<Response> {
  const requestID = crypto.randomUUID();
  const startedAt = performance.now();
  let ctx: RequestContext | undefined;
  const url = new URL(req.url);
  const path = publicPath(url);
  try {
    checkOrigin(req);
    if (req.method === "OPTIONS") return noContent();
    if (req.method === "GET" && path === "/v1/health") {
      return jsonResponse({ data: { status: "ok", version: API_VERSION } });
    }
    if (req.method === "GET" && path === "/v1/openapi.json") {
      return jsonResponse(openAPISpec(url.origin));
    }
    if (req.method === "GET" && path === "/mcp") {
      return new Response(null, {
        status: 405,
        headers: { allow: "POST, DELETE", ...jsonHeaders },
      });
    }
    ctx = await authenticate(req, requestID, startedAt);
    if (req.method === "DELETE" && path === "/mcp") {
      await audit(ctx, req, path, "mcp.session.delete", 204);
      return noContent();
    }
    const body = req.method === "GET" || req.method === "DELETE"
      ? {}
      : await readJSON(req);
    if (
      path === "/mcp" && isRecord(body) && body.method !== "initialize" &&
      req.headers.get("mcp-protocol-version") !== MCP_PROTOCOL_VERSION
    ) {
      throw new ApiError(
        400,
        "unsupported_protocol_version",
        `MCP-Protocol-Version must be ${MCP_PROTOCOL_VERSION}.`,
      );
    }
    const result = path === "/mcp"
      ? await handleMCP(ctx, body)
      : await handleREST(req, url, path, ctx, body);
    if (!result) {
      await audit(ctx, req, path, "mcp.notification", 202);
      return noContent(202);
    }
    await audit(
      ctx,
      req,
      path,
      result.operation,
      result.status,
      result.errorCode,
    );
    return jsonResponse(result.body, result.status, {
      "x-request-id": requestID,
      ...(path === "/mcp"
        ? { "mcp-protocol-version": MCP_PROTOCOL_VERSION }
        : {}),
      ...(result.headers ?? {}),
    });
  } catch (error) {
    const apiError = error instanceof ApiError
      ? error
      : new ApiError(500, "internal_error", "Unexpected server error.");
    if (path === "/mcp" && apiError.code === "invalid_json") {
      const result = mcpProtocolError(
        null,
        -32700,
        "Parse error",
        "mcp.parse_error",
      );
      if (ctx) {
        await audit(
          ctx,
          req,
          path,
          result.operation,
          result.status,
          result.errorCode,
        );
      }
      return jsonResponse(result.body, result.status, {
        "x-request-id": requestID,
        "mcp-protocol-version": MCP_PROTOCOL_VERSION,
      });
    }
    if (ctx) {
      await audit(
        ctx,
        req,
        path,
        "request_failed",
        apiError.status,
        apiError.code,
      );
    } else {
      await auditRejectedRequest(req, path, requestID, startedAt, apiError);
    }
    return jsonResponse(
      {
        error: {
          code: apiError.code,
          message: apiError.message,
          request_id: requestID,
        },
      },
      apiError.status,
      { "x-request-id": requestID },
    );
  }
}

if (import.meta.main) Deno.serve(handleRequest);
