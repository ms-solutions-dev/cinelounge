/**
 * Talking to the CineLounge server.
 *
 * The server answers errors as `{error: {code, values}}`; the code becomes a
 * sentence only in the interface (`errorText` in i18n.ts). The device token
 * travels as `X-CL-Device`; a 401 on a signed-in request means the access is
 * gone, and the app shows the sign-in again.
 */

const TOKEN_KEY = "cl.console.token";

export class ServerError extends Error {
  constructor(
    public code: string,
    public values: Record<string, unknown> = {},
    public status = 0,
  ) {
    super(code);
  }
}

let onAccessLost: () => void = () => {};
export const setAccessLost = (fn: () => void) => {
  onAccessLost = fn;
};

export function token(): string | null {
  try {
    return localStorage.getItem(TOKEN_KEY);
  } catch {
    return null;
  }
}

export function setToken(value: string | null): void {
  try {
    if (value) localStorage.setItem(TOKEN_KEY, value);
    else localStorage.removeItem(TOKEN_KEY);
  } catch {
    /* private window: the token lives only as long as the page */
  }
}

type Options = { method?: string; body?: unknown; query?: Record<string, unknown>; open?: boolean; signal?: AbortSignal };

export async function call<T = any>(path: string, opts: Options = {}): Promise<T> {
  const { method = "GET", body, query, open = false, signal } = opts;
  let url = path;
  if (query) {
    const q = new URLSearchParams();
    for (const [k, v] of Object.entries(query)) if (v !== undefined && v !== null && v !== "") q.set(k, String(v));
    const s = q.toString();
    if (s) url += (url.includes("?") ? "&" : "?") + s;
  }
  const headers: Record<string, string> = {};
  if (body !== undefined) headers["Content-Type"] = "application/json";
  const t = open ? null : token();
  if (t) headers["X-CL-Device"] = t;

  let res: Response;
  const send = () => fetch(url, { method, headers, body: body === undefined ? undefined : JSON.stringify(body), signal });
  try {
    try {
      res = await send();
    } catch (e) {
      // One lost request (Wi-Fi hiccup, a reset connection) should not turn a
      // page into an error. Reading again is harmless; writing again is not,
      // so only GET retries — once, after a short pause.
      if ((e as Error)?.name === "AbortError" || method !== "GET") throw e;
      await new Promise((r) => setTimeout(r, 350));
      res = await send();
    }
  } catch (e) {
    if ((e as Error)?.name === "AbortError") throw new ServerError("net.aborted");
    throw new ServerError("net.unreachable");
  }
  if (res.status === 204) return {} as T;
  const raw = await res.text();
  let data: any = {};
  if (raw) {
    try {
      data = JSON.parse(raw);
    } catch {
      data = { error: { code: "server.broken", values: { status: res.status } } };
    }
  }
  if (!res.ok) {
    const e = data.error || {};
    const code = e.code || (res.status === 422 ? "input.invalid" : "server.broken");
    // Only `auth.required` means the access is gone. A wrong confirmation PIN
    // (`auth.bad_credentials`, also 401) must not sign anybody out — found by
    // the click-through test on 09.11.2026.
    if (res.status === 401 && code === "auth.required" && !open && t) {
      setToken(null);
      onAccessLost();
    }
    throw new ServerError(code, e.values || {}, res.status);
  }
  return data as T;
}

export const get = <T = any>(path: string, query?: Record<string, unknown>) => call<T>(path, { query });
export const post = <T = any>(path: string, body: unknown = {}, open = false) =>
  call<T>(path, { method: "POST", body, open });
export const put = <T = any>(path: string, body: unknown = {}) => call<T>(path, { method: "PUT", body });
export const patch = <T = any>(path: string, body: unknown = {}) => call<T>(path, { method: "PATCH", body });
export const del = <T = any>(path: string) => call<T>(path, { method: "DELETE" });
