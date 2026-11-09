import { assert, assertEquals, assertFalse } from "@std/assert";
import {
  createHandler,
  type Dependencies,
  historyStart,
  MAX_PAGES_PER_LINK,
} from "./index.ts";
import {
  normalizeStatement,
  parseCents,
  parseHours,
  type TruvStatement,
} from "./normalize.ts";
import { mapStatus, TruvClient, TruvError } from "./truv.ts";

// MARK: - A fake Supabase Auth + Truv, behind one stubbed fetch.
//
// It models the refusals the real services make, not just their happy
// answers: Auth 401s an unknown token, Truv 401s wrong keys, 404s a user or
// link that does not exist, filters users by external_user_id, and 403s a
// call the account is not allowed to make (`forbidden`).

const CLIENT_ID = "truv-client-id-SECRET-1234";
const ACCESS_SECRET = "truv-access-secret-SECRET-5678";
const ANON_KEY = "anon-key-SECRET-9999";
const NOW = new Date("2026-11-08T12:00:00Z");

const ALICE = "11111111-1111-4111-8111-111111111111";
const BOB = "22222222-2222-4222-8222-222222222222";
const ALICE_JWT = "aaa.alice.sig";
const BOB_JWT = "bbb.bob.sig";

interface FakeLink {
  id: string;
  owner: string; // truv user id
  status: string;
  provider: { id: string; name: string };
  updated_at: string;
  statements: TruvStatement[];
  company_mapping?: { name: string } | null;
  employments?: { is_active: boolean | null; company: { name: string } }[];
}

interface Call {
  method: string;
  url: string;
  headers: Headers;
  body: unknown;
}

class Fake {
  tokens = new Map<string, string>([[ALICE_JWT, ALICE], [BOB_JWT, BOB]]);
  users: { id: string; external_user_id: string }[] = [];
  links: FakeLink[] = [];
  publicTokens = new Map<string, string>(); // public token -> link id
  refreshes: string[] = [];
  calls: Call[] = [];
  env: Record<string, string> = {
    SUPABASE_URL: "https://project.supabase.co",
    SUPABASE_ANON_KEY: ANON_KEY,
    TRUV_CLIENT_ID: CLIENT_ID,
    TRUV_ACCESS_SECRET: ACCESS_SECRET,
    TRUV_ENV: "sandbox",
  };
  pageSize = 100;
  /// "METHOD /path/" prefixes Truv answers 403 for: keys valid, call not
  /// allowed for this account.
  forbidden: string[] = [];
  /// Truv masks a link's access token unless the link list is filtered by
  /// `user_id`. True models an account where it is masked even then.
  alwaysMaskAccessTokens = false;

  deps(): Dependencies {
    return {
      fetch: (input, init) => this.fetch(input, init),
      env: (name) => this.env[name],
      now: () => NOW,
    };
  }

  addUser(uid: string): string {
    const id = `truv-user-${this.users.length + 1}`;
    this.users.push({ id, external_user_id: uid });
    return id;
  }

  addLink(
    owner: string,
    id: string,
    statements: TruvStatement[] = [],
    extra: Partial<FakeLink> = {},
  ): FakeLink {
    const link: FakeLink = {
      id,
      owner,
      status: "done",
      provider: { id: "toast", name: "Toast" },
      updated_at: "2026-11-01T00:00:00Z",
      statements,
      ...extra,
    };
    this.links.push(link);
    return link;
  }

  private respond(status: number, body?: unknown): Response {
    return new Response(body === undefined ? null : JSON.stringify(body), {
      status,
    });
  }

  fetch(input: string | URL | Request, init?: RequestInit): Promise<Response> {
    const url = new URL(
      typeof input === "string"
        ? input
        : input instanceof URL
        ? input.href
        : input.url,
    );
    const headers = new Headers(init?.headers);
    const method = init?.method ?? "GET";
    const body = typeof init?.body === "string"
      ? JSON.parse(init.body)
      : undefined;
    this.calls.push({ method, url: url.href, headers, body });
    return Promise.resolve(this.handle(method, url, headers, body));
  }

  private handle(
    method: string,
    url: URL,
    headers: Headers,
    body: Record<string, string>,
  ): Response {
    if (url.host === "project.supabase.co") {
      if (
        url.pathname !== "/auth/v1/user" || headers.get("apikey") !== ANON_KEY
      ) return this.respond(401);
      const token = (headers.get("authorization") ?? "").replace("Bearer ", "");
      const uid = this.tokens.get(token);
      return uid
        ? this.respond(200, { id: uid })
        : this.respond(401, { msg: "invalid JWT" });
    }
    assertEquals(
      url.origin + url.pathname.slice(0, 3),
      "https://prod.truv.com/v1",
    );
    if (
      headers.get("X-Access-Client-Id") !== CLIENT_ID ||
      headers.get("X-Access-Secret") !== ACCESS_SECRET
    ) {
      return this.respond(401, { detail: "bad keys" });
    }
    const path = url.pathname.replace(/^\/v1/, "");
    if (this.forbidden.some((rule) => `${method} ${path}`.startsWith(rule))) {
      return this.respond(403, { detail: "not allowed" });
    }
    let m: RegExpMatchArray | null;
    if (method === "GET" && path === "/users/") {
      const ext = url.searchParams.get("external_user_id");
      const results = this.users.filter((u) => u.external_user_id === ext).map((
        u,
      ) => ({
        ...u,
        links: url.searchParams.get("list_links") === "true"
          ? this.links.filter((l) => l.owner === u.id).map((
            { statements: _s, owner: _o, employments: _e, ...rest },
          ) => rest)
          : undefined,
      }));
      return this.respond(200, { count: results.length, next: null, results });
    }
    if (method === "POST" && path === "/users/") {
      return this.respond(201, {
        id: this.addUser(body.external_user_id),
        external_user_id: body.external_user_id,
      });
    }
    if (method === "POST" && (m = path.match(/^\/users\/([^/]+)\/tokens\/$/))) {
      if (!this.users.some((u) => u.id === m![1])) return this.respond(404);
      return this.respond(200, {
        bridge_token: `bridge-for-${m[1]}`,
        user_id: m[1],
      });
    }
    if (method === "POST" && path === "/link-access-tokens/") {
      const linkId = this.publicTokens.get(body.public_token);
      if (!linkId) return this.respond(400, { detail: "invalid token" });
      return this.respond(200, {
        link_id: linkId,
        access_token: "ACCESS-TOKEN-NEVER-RETURN",
        data_source: "payroll",
      });
    }
    if (
      method === "GET" && (m = path.match(/^\/links\/([^/]+)\/statements\/$/))
    ) {
      const link = this.links.find((l) => l.id === m![1]);
      if (!link) return this.respond(404);
      const from = url.searchParams.get("pay_date_from") ?? "0000-00-00";
      const rows = link.statements.filter((s) => (s.pay_date ?? "") >= from);
      const size = Math.min(
        Number(url.searchParams.get("page_size")),
        this.pageSize,
      );
      const page = Number(url.searchParams.get("page"));
      const slice = rows.slice((page - 1) * size, page * size);
      const next = page * size < rows.length
        ? `${url.origin}${url.pathname}?page=${page + 1}`
        : null;
      return this.respond(200, { count: rows.length, next, results: slice });
    }
    if (
      method === "GET" && (m = path.match(/^\/links\/([^/]+)\/employments\/$/))
    ) {
      const link = this.links.find((l) => l.id === m![1]);
      if (!link) return this.respond(404);
      return this.respond(200, link.employments ?? []);
    }
    if (method === "GET" && path === "/links/") {
      // Every link of every user unless filtered; the full access token only
      // when filtered by user_id.
      const userId = url.searchParams.get("user_id");
      const full = userId !== null && !this.alwaysMaskAccessTokens;
      const results = this.links
        .filter((l) => userId === null || l.owner === userId)
        .map((l) => ({
          id: l.id,
          status: l.status,
          access_token: full ? `access-${l.id}` : `****${l.id.slice(-4)}`,
        }));
      return this.respond(200, { count: results.length, next: null, results });
    }
    if (method === "DELETE" && (m = path.match(/^\/users\/([^/]+)\/$/))) {
      const id = m[1];
      if (!this.users.some((u) => u.id === id)) return this.respond(404);
      this.users = this.users.filter((u) => u.id !== id);
      this.links = this.links.filter((l) => l.owner !== id);
      return this.respond(204);
    }
    if (method === "POST" && path === "/refresh/tasks/") {
      // Truv's contract: { access_token, product_type } (both required).
      if (
        typeof body.access_token !== "string" ||
        typeof body.product_type !== "string" || body.link_id !== undefined
      ) {
        return this.respond(400);
      }
      const refreshed = this.links.find((l) =>
        `access-${l.id}` === body.access_token
      );
      if (!refreshed) return this.respond(404);
      this.refreshes.push(refreshed.id);
      return this.respond(201, { task_id: "task-1" });
    }
    if (method === "DELETE" && (m = path.match(/^\/links\/([^/]+)\/$/))) {
      const before = this.links.length;
      this.links = this.links.filter((l) => l.id !== m![1]);
      return this.respond(before === this.links.length ? 404 : 204);
    }
    return this.respond(404);
  }
}

function post(body: unknown, jwt: string | null = ALICE_JWT): Request {
  const headers: Record<string, string> = {
    "content-type": "application/json",
  };
  if (jwt) headers.authorization = `Bearer ${jwt}`;
  return new Request("https://example.test/functions/v1/payroll-connect", {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
}

async function call(fake: Fake, body: unknown, jwt: string | null = ALICE_JWT) {
  const response = await createHandler(fake.deps())(post(body, jwt));
  const text = await response.text();
  return { status: response.status, text, json: JSON.parse(text) };
}

function stmt(
  id: string,
  payDate: string,
  extra: Partial<TruvStatement> = {},
): TruvStatement {
  return {
    id,
    pay_date: payDate,
    period_start: "2026-10-12",
    period_end: "2026-10-25",
    gross_pay: "1629.98",
    net_pay: "1201.50",
    hours: "80.00",
    regular: "1500.00",
    overtime: "129.98",
    earnings: [{ name: "Regular", amount: "1500.00" }, {
      name: "Overtime",
      amount: "129.98",
    }],
    deductions: [
      { name: "Federal Income Tax", category: "federal", amount: "150.00" },
      { name: "Social Security", category: "socialsec", amount: "101.06" },
      { name: "Medicare", category: "medicare", amount: "23.63" },
      { name: "CA State", category: "state", amount: "40.00" },
      { name: "SF City", category: "local", amount: "5.00" },
      { name: "401k", category: "retirement", amount: "108.79" },
    ],
    ...extra,
  };
}

// MARK: - Auth

Deno.test("auth: missing, malformed and unknown tokens are 401 before Truv is touched", async () => {
  for (const jwt of [null, "not-a-jwt", "zzz.unknown.sig"]) {
    const fake = new Fake();
    const result = await call(fake, { action: "status" }, jwt);
    assertEquals(result.status, 401, `token ${jwt}`);
    assertEquals(result.json.error.code, "unauthorized");
    assertFalse(
      fake.calls.some((c) => c.url.includes("truv.com")),
      "Truv must not be called",
    );
  }
});

Deno.test("auth: GET is refused", async () => {
  const fake = new Fake();
  const response = await createHandler(fake.deps())(
    new Request("https://example.test/", { method: "GET" }),
  );
  assertEquals(response.status, 405);
});

Deno.test("auth: the token is checked with Supabase Auth using the project key", async () => {
  const fake = new Fake();
  await call(fake, { action: "status" });
  const auth = fake.calls[0];
  assertEquals(auth.url, "https://project.supabase.co/auth/v1/user");
  assertEquals(auth.headers.get("authorization"), `Bearer ${ALICE_JWT}`);
  assertEquals(auth.headers.get("apikey"), ANON_KEY);
});

Deno.test("config: missing Truv secrets or a bad TRUV_ENV is 503, not a crash", async () => {
  for (const missing of ["TRUV_CLIENT_ID", "TRUV_ACCESS_SECRET", "TRUV_ENV"]) {
    const fake = new Fake();
    delete fake.env[missing];
    const result = await call(fake, { action: "status" });
    assertEquals(result.status, 503, missing);
    assertEquals(result.json.error.code, "not_configured");
  }
  const fake = new Fake();
  fake.env.TRUV_ENV = "staging";
  assertEquals((await call(fake, { action: "status" })).status, 503);
});

// MARK: - Environment reporting

Deno.test("environment: sandbox and production are reported as configured", async () => {
  for (const env of ["sandbox", "production"]) {
    const fake = new Fake();
    fake.env.TRUV_ENV = env;
    const result = await call(fake, { action: "status" });
    assertEquals(result.status, 200);
    assertEquals(result.json.data.environment, env);
    assertEquals(result.json.data.links, []);
  }
});

// MARK: - link_token / exchange

Deno.test("link_token: creates the Truv user once, keyed by the auth uid, and reuses it", async () => {
  const fake = new Fake();
  const first = await call(fake, { action: "link_token" });
  assertEquals(first.status, 200);
  assertEquals(first.json.data.bridge_token, "bridge-for-truv-user-1");
  assertEquals(fake.users, [{ id: "truv-user-1", external_user_id: ALICE }]);
  const create = fake.calls.find((c) =>
    c.method === "POST" && c.url.endsWith("/users/")
  );
  assertEquals(create?.body, { external_user_id: ALICE });
  const token = fake.calls.find((c) => c.url.includes("/tokens/"));
  assertEquals(token?.body, { product_type: "income", tracking_info: ALICE });

  const second = await call(fake, { action: "link_token" });
  assertEquals(second.json.data.bridge_token, "bridge-for-truv-user-1");
  assertEquals(fake.users.length, 1, "no second Truv user");
});

Deno.test("link_token reconnect: opens Bridge on the caller's own link with its full access token, never returned", async () => {
  const fake = new Fake();
  const owner = fake.addUser(ALICE);
  fake.addLink(owner, "link-a", [], { status: "login_error" });
  const result = await call(fake, { action: "link_token", link_id: "link-a" });
  assertEquals(result.status, 200);
  assertEquals(result.json.data.bridge_token, `bridge-for-${owner}`);
  const list = fake.calls.find((c) => c.url.includes("/v1/links/?"));
  assertEquals(new URL(list!.url).searchParams.get("user_id"), owner);
  const token = fake.calls.find((c) => c.url.includes("/tokens/"));
  assertEquals(token?.body, {
    product_type: "income",
    tracking_info: ALICE,
    access_token: "access-link-a",
  });
  assertFalse(result.text.includes("access-link-a"));
  assertEquals(fake.links.length, 1, "no second link");
});

Deno.test("link_token reconnect: someone else's link, or a bad id, gets no Bridge token", async () => {
  const fake = new Fake();
  fake.addUser(ALICE);
  const bob = fake.addUser(BOB);
  fake.addLink(bob, "link-b", [], { status: "login_error" });
  const other = await call(fake, { action: "link_token", link_id: "link-b" });
  assertEquals(other.status, 404);
  assertEquals(other.json.error.code, "link_not_found");
  const bad = await call(fake, { action: "link_token", link_id: "../x" });
  assertEquals(bad.status, 400);
  assertFalse(fake.calls.some((c) => c.url.includes("/tokens/")));
  assertFalse(fake.calls.some((c) => c.url.includes("/v1/links/?")));
});

Deno.test("link_token reconnect: a masked access token is refused, not sent to Truv as one", async () => {
  const fake = new Fake();
  const owner = fake.addUser(ALICE);
  fake.addLink(owner, "link-a", [], { status: "mfa_error" });
  fake.alwaysMaskAccessTokens = true;
  const result = await call(fake, { action: "link_token", link_id: "link-a" });
  assertEquals(result.status, 409);
  assertEquals(result.json.error.code, "reconnect_unavailable");
  assertFalse(fake.calls.some((c) => c.url.includes("/tokens/")));
});

Deno.test("exchange: confirms the caller's own link and never returns the access token", async () => {
  const fake = new Fake();
  const owner = fake.addUser(ALICE);
  fake.addLink(owner, "link-a");
  fake.publicTokens.set("public-a", "link-a");
  const result = await call(fake, {
    action: "exchange",
    public_token: "public-a",
  });
  assertEquals(result.status, 200);
  assertEquals(result.json.data.link.link_id, "link-a");
  assertEquals(result.json.data.link.provider_name, "Toast");
  assertFalse(result.text.includes("ACCESS-TOKEN-NEVER-RETURN"));
});

Deno.test("exchange: a public token for someone else's link is refused", async () => {
  const fake = new Fake();
  fake.addUser(ALICE);
  const bob = fake.addUser(BOB);
  fake.addLink(bob, "link-b");
  fake.publicTokens.set("public-b", "link-b");
  const result = await call(fake, {
    action: "exchange",
    public_token: "public-b",
  });
  assertEquals(result.status, 404);
  assertEquals(result.json.error.code, "link_not_found");
  assertFalse(result.text.includes("ACCESS-TOKEN-NEVER-RETURN"));
});

Deno.test("exchange: a missing or bad public token is a 400 / mapped Truv error", async () => {
  const fake = new Fake();
  fake.addUser(ALICE);
  assertEquals((await call(fake, { action: "exchange" })).status, 400);
  const bad = await call(fake, { action: "exchange", public_token: "nope" });
  assertEquals(bad.status, 502);
  assertEquals(bad.json.error.code, "truv_rejected");
});

// MARK: - User isolation

Deno.test("isolation: refresh and disconnect refuse a link that is not the caller's", async () => {
  const fake = new Fake();
  fake.addUser(ALICE);
  const bob = fake.addUser(BOB);
  fake.addLink(bob, "link-b", [], { updated_at: "2026-01-01T00:00:00Z" });

  const refresh = await call(fake, { action: "refresh", link_id: "link-b" });
  assertEquals(refresh.status, 404);
  const disconnect = await call(fake, {
    action: "disconnect",
    link_id: "link-b",
  });
  assertEquals(disconnect.status, 404);
  assertEquals(fake.refreshes, []);
  assertEquals(fake.links.length, 1, "Bob's link survives");

  // And Bob can, which shows the refusal above is about ownership.
  assertEquals(
    (await call(fake, { action: "disconnect", link_id: "link-b" }, BOB_JWT))
      .status,
    200,
  );
  assertEquals(fake.links.length, 0);
});

Deno.test("isolation: paystubs only reads the caller's links", async () => {
  const fake = new Fake();
  const alice = fake.addUser(ALICE);
  const bob = fake.addUser(BOB);
  fake.addLink(alice, "link-a", [stmt("a1", "2026-10-31")]);
  fake.addLink(bob, "link-b", [stmt("b1", "2026-10-31")]);
  const result = await call(fake, { action: "paystubs" });
  assertEquals(
    result.json.data.paystubs.map((s: { source_id: string }) => s.source_id),
    ["a1"],
  );
  assertFalse(fake.calls.some((c) => c.url.includes("/links/link-b/")));
});

Deno.test("isolation: a Truv user whose external id differs is ignored even if Truv returns it", async () => {
  const response = new Response(
    JSON.stringify({
      results: [{ id: "u-x", external_user_id: BOB, links: [] }],
    }),
  );
  const client = new TruvClient({
    clientId: CLIENT_ID,
    accessSecret: ACCESS_SECRET,
  }, () => Promise.resolve(response));
  const { testing } = await import("./index.ts");
  assertEquals(await testing.findTruvUser(client, ALICE), null);
});

// MARK: - Paystubs

Deno.test("paystubs: normalized, cents, ISO dates, sorted newest first, only done links", async () => {
  const fake = new Fake();
  const alice = fake.addUser(ALICE);
  fake.addLink(alice, "link-a", [
    stmt("s1", "2026-10-17"),
    stmt("s2", "2026-10-31"),
  ]);
  fake.addLink(alice, "link-pending", [stmt("p1", "2026-10-31")], {
    status: "pending",
  });
  const result = await call(fake, { action: "paystubs" });
  assertEquals(result.status, 200);
  const stubs = result.json.data.paystubs;
  assertEquals(stubs.map((s: { source_id: string }) => s.source_id), [
    "s2",
    "s1",
  ]);
  assertEquals(stubs[0], {
    source_id: "s2",
    link_id: "link-a",
    provider_name: "Toast",
    employer_name: null,
    pay_date: "2026-10-31",
    period_start: "2026-10-12",
    period_end: "2026-10-25",
    gross_cents: 162998,
    net_cents: 120150,
    hours: "80.00",
    regular_cents: 150000,
    overtime_cents: 12998,
    earnings: [
      { name: "Regular", category: "other", cents: 150000 },
      { name: "Overtime", category: "other", cents: 12998 },
    ],
    deductions: [
      { name: "Federal Income Tax", category: "federal", cents: 15000 },
      { name: "Social Security", category: "socialsec", cents: 10106 },
      { name: "Medicare", category: "medicare", cents: 2363 },
      { name: "CA State", category: "state", cents: 4000 },
      { name: "SF City", category: "local", cents: 500 },
      { name: "401k", category: "retirement", cents: 10879 },
    ],
  });
  assertFalse(
    fake.calls.some((c) => c.url.includes("link-pending")),
    "pending links are not read",
  );
});

Deno.test("paystubs: follows pagination across pages and stops at the history cap", async () => {
  const fake = new Fake();
  fake.pageSize = 2; // the fake ignores the requested 100 to force pages
  const alice = fake.addUser(ALICE);
  const rows = Array.from(
    { length: 5 },
    (_, i) => stmt(`s${i}`, `2026-0${i + 1}-15`),
  );
  rows.push(stmt("too-old", "2024-10-01"));
  fake.addLink(alice, "link-a", rows);
  const result = await call(fake, { action: "paystubs" });
  assertEquals(result.json.data.paystubs.length, 5);
  const pages = fake.calls.filter((c) => c.url.includes("/statements/"));
  assertEquals(pages.length, 3);
  for (const page of pages) {
    assertEquals(
      new URL(page.url).searchParams.get("pay_date_from"),
      historyStart(NOW),
    );
  }
  assertEquals(historyStart(NOW), "2024-11-08");
});

Deno.test("paystubs: a runaway `next` stops at the page limit", async () => {
  const fake = new Fake();
  fake.pageSize = 1;
  const alice = fake.addUser(ALICE);
  fake.addLink(
    alice,
    "link-a",
    Array.from({ length: 50 }, (_, i) => stmt(`s${i}`, "2026-10-01")),
  );
  const result = await call(fake, { action: "paystubs" });
  assertEquals(result.json.data.paystubs.length, MAX_PAGES_PER_LINK);
});

Deno.test("paystubs: `since` narrows the window but can never widen past the cap", async () => {
  const fake = new Fake();
  const alice = fake.addUser(ALICE);
  fake.addLink(alice, "link-a", [stmt("s1", "2026-10-01")]);
  await call(fake, { action: "paystubs", since: "2026-09-01" });
  await call(fake, { action: "paystubs", since: "2001-01-01" });
  const froms = fake.calls.filter((c) => c.url.includes("/statements/"))
    .map((c) => new URL(c.url).searchParams.get("pay_date_from"));
  assertEquals(froms, ["2026-09-01", "2024-11-08"]);
});

Deno.test("paystubs: a user who never connected gets an empty list, not an error", async () => {
  const fake = new Fake();
  const result = await call(fake, { action: "paystubs" });
  assertEquals(result.status, 200);
  assertEquals(result.json.data.paystubs, []);
});

// MARK: - Refresh throttle

Deno.test("refresh: starts a Truv refresh for an owned link, then throttles for 20 hours", async () => {
  const fake = new Fake();
  const alice = fake.addUser(ALICE);
  const link = fake.addLink(alice, "link-a", [], {
    updated_at: "2026-11-07T00:00:00Z",
  });
  const ok = await call(fake, { action: "refresh", link_id: "link-a" });
  assertEquals(ok.status, 200);
  assertEquals(fake.refreshes, ["link-a"]);

  link.updated_at = "2026-11-08T02:00:00Z"; // a refresh moves the link's clock
  const throttled = await call(fake, { action: "refresh", link_id: "link-a" });
  assertEquals(throttled.status, 429);
  assertEquals(throttled.json.error.code, "refresh_throttled");
  assertEquals(
    throttled.json.error.refresh_available_at,
    "2026-11-08T22:00:00.000Z",
  );
  assertEquals(fake.refreshes, ["link-a"], "no second Truv refresh");
});

Deno.test("refresh: a malformed link id is a 400", async () => {
  const fake = new Fake();
  fake.addUser(ALICE);
  assertEquals(
    (await call(fake, { action: "refresh", link_id: "../users" })).status,
    400,
  );
  assertEquals((await call(fake, { action: "refresh" })).status, 400);
});

// MARK: - Secrets

Deno.test("secrets: never appear in any response, success or failure", async () => {
  const fake = new Fake();
  const alice = fake.addUser(ALICE);
  fake.addLink(alice, "link-a", [stmt("s1", "2026-10-31")]);
  fake.publicTokens.set("public-a", "link-a");
  const bodies = [
    { action: "status" },
    { action: "link_token" },
    { action: "exchange", public_token: "public-a" },
    { action: "paystubs" },
    { action: "refresh", link_id: "link-a" },
    { action: "nope" },
    { action: "disconnect", link_id: "link-a" },
  ];
  const texts: string[] = [];
  for (const body of bodies) texts.push((await call(fake, body)).text);
  fake.env.TRUV_ACCESS_SECRET = "wrong-SECRET"; // Truv now 401s
  const broken = await call(fake, { action: "status" });
  assertEquals(
    broken.status,
    503,
    "bad Truv keys are a server problem, not the caller's",
  );
  texts.push(broken.text);
  for (const text of texts) {
    for (
      const secret of [
        CLIENT_ID,
        ACCESS_SECRET,
        ANON_KEY,
        "wrong-SECRET",
        "ACCESS-TOKEN-NEVER-RETURN",
      ]
    ) {
      assertFalse(text.includes(secret), `${secret} leaked in ${text}`);
    }
  }
});

Deno.test("truv client: sends both key headers and maps statuses", async () => {
  let seen: Headers | undefined;
  const client = new TruvClient(
    { clientId: "id", accessSecret: "secret" },
    (_url, init) => {
      seen = new Headers(init?.headers);
      return Promise.resolve(new Response(JSON.stringify({ ok: true })));
    },
  );
  assertEquals(await client.request("GET", "/x/"), { ok: true });
  assertEquals(seen?.get("X-Access-Client-Id"), "id");
  assertEquals(seen?.get("X-Access-Secret"), "secret");
  assertEquals(mapStatus(401).status, 503);
  assertEquals(mapStatus(401).code, "truv_not_configured");
  assertEquals(mapStatus(403).status, 502);
  assertEquals(mapStatus(403).code, "truv_forbidden");
  assertEquals(mapStatus(404).status, 404);
  assertEquals(mapStatus(429).status, 429);
  assertEquals(mapStatus(500).status, 502);
});

Deno.test("truv client: a timeout is a 504 and a network failure a 502", async () => {
  const slow = new TruvClient(
    { clientId: "id", accessSecret: "s" },
    (_url, init) =>
      new Promise((_resolve, reject) => {
        init?.signal?.addEventListener(
          "abort",
          () => reject(init.signal!.reason),
        );
      }),
    5,
  );
  try {
    await slow.request("GET", "/x/");
    throw new Error("expected a timeout");
  } catch (error) {
    assert(error instanceof TruvError);
    assertEquals(error.status, 504);
  }
  const down = new TruvClient(
    { clientId: "id", accessSecret: "s" },
    () => Promise.reject(new TypeError("dns")),
  );
  try {
    await down.request("GET", "/x/");
    throw new Error("expected a failure");
  } catch (error) {
    assert(error instanceof TruvError);
    assertEquals(error.code, "truv_unreachable");
  }
});

// MARK: - Normalization units

Deno.test("cents: decimal strings convert exactly; null, empty and junk are null", () => {
  assertEquals(parseCents("1629.98"), 162998);
  assertEquals(parseCents("0.10"), 10);
  assertEquals(parseCents("0.1"), 10);
  assertEquals(parseCents("12"), 1200);
  assertEquals(parseCents("1,234.56"), 123456);
  assertEquals(parseCents("-45.50"), -4550);
  assertEquals(parseCents("10.005"), 1001);
  assertEquals(parseCents("10.004"), 1000);
  assertEquals(parseCents(19.99), 1999);
  assertEquals(parseCents("0.00"), 0);
  assertEquals(parseCents(null), null);
  assertEquals(parseCents(undefined), null);
  assertEquals(parseCents(""), null);
  assertEquals(parseCents("  "), null);
  assertEquals(parseCents("abc"), null);
  assertEquals(parseCents("$12.00"), null);
  assertEquals(parseCents(Number.NaN), null);
});

Deno.test("hours: decimal strings only", () => {
  assertEquals(parseHours("80.00"), "80.00");
  assertEquals(parseHours(72.5), "72.5");
  assertEquals(parseHours(""), null);
  assertEquals(parseHours("-3"), null);
  assertEquals(parseHours(null), null);
});

Deno.test("lines: every earnings line comes back as printed, sign kept, nothing classified", () => {
  const stub = normalizeStatement(
    stmt("t", "2026-10-31", {
      earnings: [
        { name: "Regular", category: "Regular", amount: "300.00" },
        { name: "Credit Card Tips", amount: "412.35" },
        { name: "Tip Credit", amount: "-120.00" },
        { name: "  ", amount: "1.00" },
        { name: "Unreadable", amount: "n/a" },
      ],
      deductions: [
        { name: "Federal", category: "Federal", amount: "-15.00" },
        { name: null, category: null, amount: "2.50" },
      ],
    }),
    { linkId: "l", providerName: "Toast", employerName: null },
  )!;
  assertEquals(stub.earnings, [
    { name: "Regular", category: "regular", cents: 30000 },
    { name: "Credit Card Tips", category: "other", cents: 41235 },
    { name: "Tip Credit", category: "other", cents: -12000 },
    { name: "Earnings", category: "other", cents: 100 },
  ]);
  assertEquals(stub.deductions, [
    { name: "Federal", category: "federal", cents: 1500 },
    { name: "Deduction", category: "other", cents: 250 },
  ]);
  // The app's earnings engine decides tips and taxes; none of that is here.
  for (const key of ["tips_cents", "gratuity_cents", "taxes_cents"]) {
    assertFalse(key in stub, key);
  }
});

Deno.test("statement: no pay date -> skipped; no earnings lines -> an empty list", () => {
  const ctx = { linkId: "l", providerName: null, employerName: null };
  assertEquals(normalizeStatement(stmt("x", ""), ctx), null);
  assertEquals(normalizeStatement(stmt("x", "2026-02-30"), ctx), null);
  const bare = normalizeStatement(
    stmt("y", "2026-10-31", {
      earnings: [],
      period_start: null,
      period_end: "bad",
    }),
    ctx,
  )!;
  assertEquals(bare.earnings, []);
  assertEquals(bare.period_start, null);
  assertEquals(bare.period_end, null);
});

// MARK: - Employer name

Deno.test("employer: read from the link's employment when Bridge mapped none", async () => {
  const fake = new Fake();
  const alice = fake.addUser(ALICE);
  fake.addLink(alice, "link-toast", [stmt("s1", "2026-10-31")], {
    employments: [
      { is_active: false, company: { name: "Old Diner" } },
      { is_active: true, company: { name: " Blue Door Bistro " } },
    ],
  });
  fake.addLink(alice, "link-mapped", [stmt("s2", "2026-10-30")], {
    company_mapping: { name: "Mapped Employer" },
    employments: [{ is_active: true, company: { name: "Ignored" } }],
  });
  const result = await call(fake, { action: "paystubs" });
  assertEquals(result.status, 200);
  const byId = Object.fromEntries(
    result.json.data.paystubs.map((
      s: { source_id: string; employer_name: string | null },
    ) => [s.source_id, s.employer_name]),
  );
  assertEquals(byId, { s1: "Blue Door Bistro", s2: "Mapped Employer" });
  assertEquals(
    result.json.data.links.map((l: { employer_name: string }) =>
      l.employer_name
    ),
    ["Blue Door Bistro", "Mapped Employer"],
  );
  assertFalse(
    fake.calls.some((c) => c.url.includes("link-mapped/employments")),
    "a mapped employer needs no extra call",
  );
});

Deno.test("employer: a refused employment lookup still imports the stubs, unnamed", async () => {
  const fake = new Fake();
  const alice = fake.addUser(ALICE);
  fake.addLink(alice, "link-a", [stmt("s1", "2026-10-31")]);
  fake.forbidden = ["GET /links/link-a/employments/"];
  const result = await call(fake, { action: "paystubs" });
  assertEquals(result.status, 200);
  assertEquals(result.json.data.paystubs.length, 1);
  assertEquals(result.json.data.paystubs[0].employer_name, null);
});

// MARK: - Account deletion

Deno.test("forget: deletes the caller's Truv user and links, and nobody else's", async () => {
  const fake = new Fake();
  const alice = fake.addUser(ALICE);
  const bob = fake.addUser(BOB);
  fake.addLink(alice, "link-a1");
  fake.addLink(alice, "link-a2");
  fake.addLink(bob, "link-b");
  const result = await call(fake, { action: "forget" });
  assertEquals(result.status, 200);
  assertEquals(result.json.data.deleted, true);
  assertEquals(fake.users.map((u) => u.id), [bob]);
  assertEquals(fake.links.map((l) => l.id), ["link-b"]);
  assert(
    fake.calls.some((c) =>
      c.method === "DELETE" && c.url.endsWith(`/users/${alice}/`)
    ),
  );
  // Again, with nothing left: still done, nothing else touched.
  const again = await call(fake, { action: "forget" });
  assertEquals(again.status, 200);
  assertEquals(fake.links.map((l) => l.id), ["link-b"]);
});

Deno.test("forget: a refusal from Truv is an error with Truv's status, not a success", async () => {
  const fake = new Fake();
  const alice = fake.addUser(ALICE);
  fake.addLink(alice, "link-a1");
  fake.forbidden = [`DELETE /users/${alice}/`];
  const result = await call(fake, { action: "forget" });
  assertEquals(result.status, 502);
  assertEquals(result.json.error.code, "truv_forbidden");
  assertEquals(result.json.error.truv_status, 403);
  assertEquals(fake.links.length, 1);
});

Deno.test("disconnect: when Truv refuses a link delete, the only link goes by deleting the Truv user", async () => {
  const fake = new Fake();
  const alice = fake.addUser(ALICE);
  const bob = fake.addUser(BOB);
  fake.addLink(alice, "link-a1");
  fake.addLink(bob, "link-b");
  fake.forbidden = ["DELETE /links/"];
  const result = await call(fake, {
    action: "disconnect",
    link_id: "link-a1",
  });
  assertEquals(result.status, 200);
  assertEquals(result.json.data.disconnected, true);
  assertEquals(fake.users.map((u) => u.id), [bob]);
  assertEquals(fake.links.map((l) => l.id), ["link-b"]);
});

Deno.test("disconnect: a refused link delete with other links left is an error, and deletes nothing", async () => {
  const fake = new Fake();
  const alice = fake.addUser(ALICE);
  fake.addLink(alice, "link-a1");
  fake.addLink(alice, "link-a2");
  fake.forbidden = ["DELETE /links/"];
  const result = await call(fake, {
    action: "disconnect",
    link_id: "link-a1",
  });
  assertEquals(result.status, 502);
  assertEquals(result.json.error.code, "truv_forbidden");
  assertEquals(result.json.error.truv_status, 403);
  assertEquals(fake.links.map((l) => l.id), ["link-a1", "link-a2"]);
  assertEquals(fake.users.map((u) => u.id), [alice]);
});

Deno.test("disconnect: a link delete Truv allows removes only that link", async () => {
  const fake = new Fake();
  const alice = fake.addUser(ALICE);
  fake.addLink(alice, "link-a1");
  const result = await call(fake, {
    action: "disconnect",
    link_id: "link-a1",
  });
  assertEquals(result.status, 200);
  assertEquals(fake.links.length, 0);
  assertEquals(fake.users.map((u) => u.id), [alice], "the user stays");
});

// MARK: - Refresh cooldown and links that are not ready

Deno.test("refresh: two taps at once start one paid refresh, not two", async () => {
  const fake = new Fake();
  const alice = fake.addUser(ALICE);
  // Eligible by updated_at (well over 20 hours ago).
  fake.addLink(alice, "link-a1", [], { updated_at: "2026-11-01T00:00:00Z" });
  const handler = createHandler(fake.deps());
  const body = { action: "refresh", link_id: "link-a1" };
  const [first, second] = await Promise.all([
    handler(post(body)),
    handler(post(body)),
  ]);
  const statuses = [first.status, second.status].sort();
  assertEquals(statuses, [200, 429]);
  assertEquals(fake.refreshes, ["link-a1"]);
  await first.body?.cancel();
  await second.body?.cancel();
  // Later, still inside the reservation: refused without asking Truv.
  const third = await handler(post(body));
  assertEquals(third.status, 429);
  assertEquals(
    (await third.json()).error.refresh_available_at,
    "2026-11-09T08:00:00.000Z",
  );
  assertEquals(fake.refreshes.length, 1);
});

Deno.test("refresh: a refresh Truv refused does not hold the cooldown", async () => {
  const fake = new Fake();
  const alice = fake.addUser(ALICE);
  fake.addLink(alice, "link-a1", [], { updated_at: "2026-11-01T00:00:00Z" });
  const handler = createHandler(fake.deps());
  const body = { action: "refresh", link_id: "link-a1" };
  fake.forbidden = ["POST /refresh/tasks/"];
  const refused = await handler(post(body));
  assertEquals(refused.status, 502);
  await refused.body?.cancel();
  fake.forbidden = [];
  const retried = await handler(post(body));
  assertEquals(retried.status, 200);
  await retried.body?.cancel();
  assertEquals(fake.refreshes, ["link-a1"]);
});

Deno.test("paystubs: links that are not ready are listed, not read", async () => {
  const fake = new Fake();
  const alice = fake.addUser(ALICE);
  fake.addLink(alice, "link-done", [stmt("s1", "2026-10-31")]);
  fake.addLink(alice, "link-sync", [stmt("s2", "2026-10-31")], {
    status: "pending",
  });
  const result = await call(fake, { action: "paystubs" });
  assertEquals(result.status, 200);
  assertEquals(
    result.json.data.links.map((l: { link_id: string; status: string }) => [
      l.link_id,
      l.status,
    ]),
    [["link-done", "done"], ["link-sync", "pending"]],
  );
  assertEquals(
    result.json.data.paystubs.map((p: { source_id: string }) => p.source_id),
    ["s1"],
  );
  assertFalse(fake.calls.some((c) => c.url.includes("link-sync/")));
});
