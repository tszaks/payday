// The one door to Truv. Every request this function makes to Truv goes
// through `TruvClient.request`, so the timeout, the auth headers and the
// error mapping live in one place and the tests stub one `fetch`.

export const TRUV_API_BASE = "https://prod.truv.com/v1";
const DEFAULT_TIMEOUT_MS = 15_000;

export type FetchLike = (
  input: string | URL | Request,
  init?: RequestInit,
) => Promise<Response>;

/// A Truv failure, already mapped to what the app should be told. The Truv
/// response body is never copied into `message`: it can echo request fields,
/// and nothing from Truv reaches the app unless a route picks it out.
export class TruvError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly truvStatus?: number,
  ) {
    super(message);
  }
}

export interface TruvCredentials {
  clientId: string;
  accessSecret: string;
}

export class TruvClient {
  constructor(
    private readonly credentials: TruvCredentials,
    private readonly fetchImpl: FetchLike = fetch,
    private readonly timeoutMs = DEFAULT_TIMEOUT_MS,
    private readonly base = TRUV_API_BASE,
  ) {}

  async request<T>(
    method: "GET" | "POST" | "DELETE",
    path: string,
    body?: unknown,
  ): Promise<T> {
    let response: Response;
    try {
      response = await this.fetchImpl(`${this.base}${path}`, {
        method,
        headers: {
          "X-Access-Client-Id": this.credentials.clientId,
          "X-Access-Secret": this.credentials.accessSecret,
          "Content-Type": "application/json",
          "Accept": "application/json",
        },
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(this.timeoutMs),
      });
    } catch (error) {
      if (error instanceof DOMException && error.name === "TimeoutError") {
        throw new TruvError(
          504,
          "truv_timeout",
          "Payroll took too long to answer.",
        );
      }
      throw new TruvError(
        502,
        "truv_unreachable",
        "Payroll could not be reached.",
      );
    }

    if (response.status === 204) {
      await response.body?.cancel();
      return undefined as T;
    }
    if (!response.ok) {
      await response.body?.cancel();
      throw mapStatus(response.status);
    }
    try {
      return await response.json() as T;
    } catch {
      throw new TruvError(
        502,
        "truv_bad_response",
        "Payroll sent an answer Payday could not read.",
      );
    }
  }
}

/// Truv's status, translated. A 401/403 from Truv means OUR keys are wrong
/// or revoked, which is a server problem, never the caller's: it maps to 503
/// so the app does not sign the person out over it.
export function mapStatus(status: number): TruvError {
  if (status === 401 || status === 403) {
    return new TruvError(
      503,
      "truv_not_configured",
      "Payroll connection is not set up.",
      status,
    );
  }
  if (status === 404) {
    return new TruvError(
      404,
      "truv_not_found",
      "That payroll connection no longer exists.",
      status,
    );
  }
  if (status === 429) {
    return new TruvError(
      429,
      "truv_rate_limited",
      "Payroll is busy. Try again soon.",
      status,
    );
  }
  if (status >= 400 && status < 500) {
    return new TruvError(
      502,
      "truv_rejected",
      "Payroll refused the request.",
      status,
    );
  }
  return new TruvError(
    502,
    "truv_unavailable",
    "Payroll is not answering right now.",
    status,
  );
}
