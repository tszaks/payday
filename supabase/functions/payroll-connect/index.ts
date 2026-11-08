// payroll-connect: the server half of "Connect payroll".
//
// The app holds a Supabase session and nothing else. This function holds the
// Truv keys, turns the session into a Truv user, and hands back only what the
// app needs: a short-lived bridge token, link summaries, and pay stubs already
// normalized to integer cents (normalize.ts).
//
// No table. Truv keeps the mapping: every Truv user is created with
// `external_user_id` = the Supabase auth uid, and every route looks the caller
// up by that uid. A link id the caller sends is honoured only when it is in
// the caller's own Truv user's link list, so one account can never read,
// refresh or delete another's link.
//
// Secrets: TRUV_CLIENT_ID, TRUV_ACCESS_SECRET, TRUV_ENV ("sandbox" |
// "production"). They are read from the environment per request, never
// logged, and never put in a response. TRUV_ENV is only reported back so the
// app can label test data; the keys alone decide which Truv data comes back.

import "@supabase/functions-js/edge-runtime.d.ts";
import { type FetchLike, TruvClient, TruvError } from "./truv.ts";
import {
  normalizeStatement,
  type Paystub,
  type TruvStatement,
} from "./normalize.ts";

type JsonObject = Record<string, unknown>;

export type Environment = "sandbox" | "production";

/// How far back pay stubs are read. Two years covers a tax year plus the
/// one before it, and bounds the number of Truv pages one call can cost.
export const HISTORY_MONTHS = 24;
/// Truv's statement page size, and a hard stop on pages per link so a
/// misbehaving `next` cannot loop the function until it times out.
export const PAGE_SIZE = 100;
export const MAX_PAGES_PER_LINK = 10;
/// One data refresh per link per this many hours. Truv bills refreshes, and
/// payroll changes once per pay period, so more often buys nothing.
export const REFRESH_INTERVAL_HOURS = 20;
const AUTH_TIMEOUT_MS = 10_000;
const MAX_BODY_BYTES = 16_000;

export interface Dependencies {
  fetch: FetchLike;
  env: (name: string) => string | undefined;
  now: () => Date;
}

class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly extra: JsonObject = {},
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

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: jsonHeaders });
}

// MARK: - Truv shapes (only the fields read here)

interface TruvProvider {
  id?: string | null;
  name?: string | null;
}

interface TruvLink {
  id: string;
  status?: string | null;
  provider?: TruvProvider | null;
  company_mapping?: {
    name?: string | null;
    company?: { name?: string | null } | null;
  } | null;
  updated_at?: string | null;
}

interface TruvUser {
  id: string;
  external_user_id?: string | null;
  links?: TruvLink[] | null;
}

interface Paged<T> {
  count?: number;
  next?: string | null;
  results?: T[] | null;
}

// MARK: - Configuration and auth

interface Config {
  environment: Environment;
  truv: TruvClient;
}

function config(deps: Dependencies): Config {
  const clientId = deps.env("TRUV_CLIENT_ID");
  const accessSecret = deps.env("TRUV_ACCESS_SECRET");
  const environment = deps.env("TRUV_ENV");
  if (
    !clientId || !accessSecret ||
    (environment !== "sandbox" && environment !== "production")
  ) {
    throw new ApiError(
      503,
      "not_configured",
      "Payroll connection is not set up.",
    );
  }
  return {
    environment,
    truv: new TruvClient({ clientId, accessSecret }, deps.fetch),
  };
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/// The caller's Supabase user id, from their access token, or a 401.
///
/// Asked of Supabase Auth itself (`GET /auth/v1/user`) rather than decoded
/// locally: that works with both the legacy shared-secret JWTs and the newer
/// asymmetric signing keys, and it refuses a token whose session was signed
/// out or whose user was deleted, which a signature check alone would accept.
async function authenticate(req: Request, deps: Dependencies): Promise<string> {
  const header = req.headers.get("authorization") ?? "";
  const match = header.match(
    /^Bearer ([A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)$/,
  );
  if (!match) {
    throw new ApiError(401, "unauthorized", "Sign in to connect payroll.");
  }
  const supabaseURL = deps.env("SUPABASE_URL");
  const apiKey = deps.env("SUPABASE_ANON_KEY") ??
    deps.env("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseURL || !apiKey) {
    throw new ApiError(
      503,
      "not_configured",
      "Payroll connection is not set up.",
    );
  }
  let response: Response;
  try {
    response = await deps.fetch(
      `${supabaseURL.replace(/\/$/, "")}/auth/v1/user`,
      {
        headers: { authorization: `Bearer ${match[1]}`, apikey: apiKey },
        signal: AbortSignal.timeout(AUTH_TIMEOUT_MS),
      },
    );
  } catch {
    throw new ApiError(
      503,
      "auth_unavailable",
      "Payday could not check your sign-in. Try again.",
    );
  }
  if (response.status === 401 || response.status === 403) {
    await response.body?.cancel();
    throw new ApiError(401, "unauthorized", "Sign in to connect payroll.");
  }
  if (!response.ok) {
    await response.body?.cancel();
    throw new ApiError(
      503,
      "auth_unavailable",
      "Payday could not check your sign-in. Try again.",
    );
  }
  const user = await response.json().catch(() => null) as
    | { id?: unknown }
    | null;
  if (!user || typeof user.id !== "string" || !UUID.test(user.id)) {
    throw new ApiError(401, "unauthorized", "Sign in to connect payroll.");
  }
  return user.id.toLowerCase();
}

// MARK: - Truv user and links

/// The caller's Truv user, with links, or null when they never connected.
/// A result is accepted only when it names this uid (or names none, in which
/// case the server-side filter is what matched it).
async function findTruvUser(
  truv: TruvClient,
  uid: string,
): Promise<TruvUser | null> {
  const page = await truv.request<Paged<TruvUser>>(
    "GET",
    `/users/?external_user_id=${encodeURIComponent(uid)}&list_links=true`,
  );
  const results = Array.isArray(page?.results) ? page.results : [];
  return results.find((user) =>
    typeof user?.id === "string" &&
    (user.external_user_id === undefined || user.external_user_id === null ||
      user.external_user_id === uid)
  ) ?? null;
}

async function findOrCreateTruvUser(
  truv: TruvClient,
  uid: string,
): Promise<TruvUser> {
  const existing = await findTruvUser(truv, uid);
  if (existing) return existing;
  // No name or email is sent: Truv needs none to run Bridge, and Payday does
  // not hand a third party more about a person than the job requires.
  const created = await truv.request<TruvUser>("POST", "/users/", {
    external_user_id: uid,
  });
  if (!created || typeof created.id !== "string") {
    throw new TruvError(
      502,
      "truv_bad_response",
      "Payroll sent an answer Payday could not read.",
    );
  }
  return created;
}

function linksOf(user: TruvUser | null): TruvLink[] {
  return (user?.links ?? []).filter((link): link is TruvLink =>
    typeof link?.id === "string"
  );
}

/// The caller's link with this id, or 404. The ownership check every
/// link-scoped route goes through.
async function ownedLink(
  truv: TruvClient,
  uid: string,
  linkId: unknown,
): Promise<TruvLink> {
  if (typeof linkId !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(linkId)) {
    throw new ApiError(
      400,
      "invalid_link",
      "That payroll connection is not valid.",
    );
  }
  const link = linksOf(await findTruvUser(truv, uid)).find((candidate) =>
    candidate.id === linkId
  );
  // 404, not 403: a link that is not yours is indistinguishable from one
  // that does not exist, so the answer says nothing about other accounts.
  if (!link) {
    throw new ApiError(
      404,
      "link_not_found",
      "That payroll connection was not found.",
    );
  }
  return link;
}

function employerName(link: TruvLink): string | null {
  const name = link.company_mapping?.name ??
    link.company_mapping?.company?.name ?? null;
  return typeof name === "string" && name.trim() ? name.trim() : null;
}

function refreshAvailableAt(link: TruvLink, now: Date): string | null {
  const updated = link.updated_at ? Date.parse(link.updated_at) : Number.NaN;
  if (Number.isNaN(updated)) return null;
  const next = updated + REFRESH_INTERVAL_HOURS * 3_600_000;
  return next > now.getTime() ? new Date(next).toISOString() : null;
}

function linkSummary(link: TruvLink, now: Date): JsonObject {
  return {
    link_id: link.id,
    status: link.status ?? null,
    provider_id: link.provider?.id ?? null,
    provider_name: link.provider?.name ?? null,
    employer_name: employerName(link),
    updated_at: link.updated_at ?? null,
    refresh_available_at: refreshAvailableAt(link, now),
  };
}

// MARK: - Statements

export function historyStart(now: Date, months = HISTORY_MONTHS): string {
  const start = new Date(
    Date.UTC(
      now.getUTCFullYear(),
      now.getUTCMonth() - months,
      now.getUTCDate(),
    ),
  );
  return start.toISOString().slice(0, 10);
}

async function statements(
  truv: TruvClient,
  linkId: string,
  from: string,
): Promise<TruvStatement[]> {
  const all: TruvStatement[] = [];
  for (let page = 1; page <= MAX_PAGES_PER_LINK; page++) {
    const result = await truv.request<Paged<TruvStatement>>(
      "GET",
      `/links/${
        encodeURIComponent(linkId)
      }/statements/?page_size=${PAGE_SIZE}&page=${page}&pay_date_from=${from}`,
    );
    const rows = Array.isArray(result?.results) ? result.results : [];
    all.push(...rows);
    if (!result?.next || rows.length === 0) break;
  }
  return all;
}

// MARK: - Routes

async function route(
  action: string,
  body: JsonObject,
  uid: string,
  cfg: Config,
  deps: Dependencies,
): Promise<JsonObject> {
  const { truv, environment } = cfg;
  const now = deps.now();
  switch (action) {
    case "status": {
      const user = await findTruvUser(truv, uid);
      return {
        environment,
        links: linksOf(user).map((link) => linkSummary(link, now)),
      };
    }
    case "link_token": {
      const user = await findOrCreateTruvUser(truv, uid);
      const token = await truv.request<{ bridge_token?: unknown }>(
        "POST",
        `/users/${encodeURIComponent(user.id)}/tokens/`,
        { product_type: "income", tracking_info: uid },
      );
      if (typeof token?.bridge_token !== "string" || !token.bridge_token) {
        throw new TruvError(
          502,
          "truv_bad_response",
          "Payroll sent an answer Payday could not read.",
        );
      }
      return { environment, bridge_token: token.bridge_token };
    }
    case "exchange": {
      const publicToken = body.public_token;
      if (
        typeof publicToken !== "string" || !publicToken ||
        publicToken.length > 512
      ) {
        throw new ApiError(
          400,
          "invalid_public_token",
          "The payroll sign-in did not finish.",
        );
      }
      const exchanged = await truv.request<{ link_id?: unknown }>(
        "POST",
        "/link-access-tokens/",
        { public_token: publicToken },
      );
      // The access token in that answer is dropped here on purpose. Links
      // are listable per user with our keys, so storing it buys nothing and
      // returning it would put a payroll credential on the phone.
      const link = await ownedLink(truv, uid, exchanged?.link_id);
      return { environment, link: linkSummary(link, now) };
    }
    case "paystubs": {
      const user = await findTruvUser(truv, uid);
      const cap = historyStart(now);
      const since =
        typeof body.since === "string" && /^\d{4}-\d{2}-\d{2}$/.test(body.since)
          ? body.since
          : null;
      const from = since && since > cap ? since : cap;
      const paystubs: Paystub[] = [];
      const links = linksOf(user).filter((link) => link.status === "done");
      for (const link of links) {
        const context = {
          linkId: link.id,
          providerName: link.provider?.name ?? null,
          employerName: employerName(link),
        };
        for (const statement of await statements(truv, link.id, from)) {
          const stub = normalizeStatement(statement, context);
          if (stub) paystubs.push(stub);
        }
      }
      paystubs.sort((a, b) =>
        b.pay_date.localeCompare(a.pay_date) ||
        a.source_id.localeCompare(b.source_id)
      );
      return {
        environment,
        links: links.map((link) => linkSummary(link, now)),
        paystubs,
      };
    }
    case "refresh": {
      const link = await ownedLink(truv, uid, body.link_id);
      const availableAt = refreshAvailableAt(link, now);
      if (availableAt) {
        throw new ApiError(
          429,
          "refresh_throttled",
          "Payday checked this payroll recently.",
          {
            refresh_available_at: availableAt,
          },
        );
      }
      await truv.request("POST", "/refresh/tasks/", { link_id: link.id });
      return { environment, started: true };
    }
    case "disconnect": {
      const link = await ownedLink(truv, uid, body.link_id);
      await truv.request("DELETE", `/links/${encodeURIComponent(link.id)}/`);
      return { environment, disconnected: true };
    }
    default:
      throw new ApiError(400, "unknown_action", "Unknown action.");
  }
}

async function readBody(req: Request): Promise<JsonObject> {
  const text = await req.text();
  if (text.length > MAX_BODY_BYTES) {
    throw new ApiError(413, "body_too_large", "Request is too large.");
  }
  if (!text.trim()) return {};
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new ApiError(400, "invalid_json", "Request body must be JSON.");
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new ApiError(
      400,
      "invalid_json",
      "Request body must be a JSON object.",
    );
  }
  return parsed as JsonObject;
}

export function createHandler(
  deps: Dependencies,
): (req: Request) => Promise<Response> {
  return async (req: Request) => {
    let action = "unknown";
    try {
      if (req.method !== "POST") {
        throw new ApiError(405, "method_not_allowed", "Use POST.");
      }
      // Auth before anything else, including reading the body or checking
      // configuration, so an anonymous caller learns nothing.
      const uid = await authenticate(req, deps);
      const body = await readBody(req);
      action = typeof body.action === "string" ? body.action : "unknown";
      const cfg = config(deps);
      return json({ data: await route(action, body, uid, cfg, deps) });
    } catch (error) {
      if (error instanceof ApiError) {
        return json({
          error: { code: error.code, message: error.message, ...error.extra },
        }, error.status);
      }
      if (error instanceof TruvError) {
        // Codes only. Never the request, the response, or the keys.
        console.error(
          `payroll-connect ${action} ${error.code} truv_status=${
            error.truvStatus ?? "-"
          }`,
        );
        return json(
          { error: { code: error.code, message: error.message } },
          error.status,
        );
      }
      console.error(`payroll-connect ${action} internal_error`);
      return json({
        error: { code: "internal_error", message: "Something went wrong." },
      }, 500);
    }
  };
}

export const testing = { authenticate, findTruvUser };

if (import.meta.main) {
  Deno.serve(
    createHandler({
      fetch,
      env: (name) => Deno.env.get(name),
      now: () => new Date(),
    }),
  );
}
