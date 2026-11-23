/**
 * The household as the pages need it, put together from the server's routes.
 * Every rule that decides what somebody *sees* stays on the server; what is
 * computed here is only for display (who sees a portal, counts, the strip).
 */
import { get } from "./api";
import type { Strip } from "./ui";

/** A portal as `/household/portals` lists it — the core's fields only. A
 *  manifest field an extension publishes (`FieldSpec.public_json`) stands in
 *  the answer too; that extension's console part reads it under its own key. */
export type Portal = {
  id: string;
  name: string;
  description: string;
  kind: string;
  capabilities: string[];
  net_override: string | null;
  exit_net: string;
  adult: boolean;
  /** `needs_setting`: not ready only because a required setting is empty —
   *  a task for the operator, not a fault. */
  state: "ready" | "broken" | "needs_setting" | string;
  reason: string | null;
  /** The empty required settings; filled exactly when `state` is `needs_setting`. */
  missing_settings?: string[];
  on: boolean;
  roles: string[];
  source: string;
  settings: PortalSetting[];
  /** The server's decision per person and per role (AP90) — never rebuilt here. */
  who: Record<string, Access>;
  role_who: Record<string, Access>;
};
/** Why somebody does or does not see a portal, in the order the server checks. */
export type Reason = "ok" | "adult" | "off" | "no_role" | "broken";
export type Access = { allowed: boolean; reason: Reason; detail: string | null };
export type PortalSetting = { key: string; label?: any; kind?: string; value?: string; secret?: boolean; options?: string[]; set?: boolean };
export type Role = { id: string; name: string; color: string; rights: string[]; portals: string[]; members: number; child_lock: boolean };
export type Person = { id: string; name: string; role: string; role_id: string; console: boolean; color: string; adult: boolean; has_pin: boolean; has_mark: boolean };
export type Device = { id: string; name: string; kind: string; person: string | null; shared: boolean; last_seen: number; from: string; paired: number; via_mark: boolean };
/** A route as `GET /network/exits` lists it (the field names are the API's).
 *  `source` is where a proxy comes from; providers of extensions may add more. */
export type Exit = {
  id: string;
  host: string;
  state: "running" | "stopped" | "unreachable";
  why?: string;
  public_ip: string | null;
  ms: number | null;
  portals: string[];
  source?: "environment" | "console" | string;
} & Record<string, any>;
export type Nights = { nights: number; history: Record<string, Strip>; last: Record<string, { night: string; ok: boolean | null; step: string; reason: string; ms: number }>; failures: Record<string, { night: string; step: string; reason: string }[]> };

/** A route's name for people: `ui.route.<name>` when a text gives one, else the
 *  name in capitals; `direct` is the house's own connection. */
export function routeLabel(t: (k: string, o?: any) => string, name: string): string {
  return name === "direct" ? t("ui.network.direct") : t(`ui.route.${name}`, { defaultValue: name.toUpperCase() });
}

/** Why an exit is down, in words — the server says `URLError`, `http 401`, … */
export function exitWhy(t: (k: string, o?: any) => string, why: string | undefined, state: string): string {
  const w = (why || "").trim();
  const http = w.match(/^http (\d{3})$/i);
  if (http) return t("ui.network.why_http", { code: http[1] });
  if (/timeout/i.test(w)) return t("ui.network.why_timeout");
  if (w && /error|refused|unreach|gaierror|oserror/i.test(w)) return t("ui.network.why_noanswer");
  if (w) return w;
  return t(`ui.network.state_${state}`);
}

export const APP_RIGHTS = ["watch", "track_progress", "view_adult", "own_devices", "invite"] as const;
export const ROLE_COLORS = ["#6aa8ff", "#6fcf8e", "#c08cf5", "#f08cb4", "#f2a65a", "#5fd0c7"];

/** Whether a member of this role sees the portal — the server's answer (AP90). */
export const roleSees = (r: Role, p: Portal) => !!p.role_who?.[r.id]?.allowed;

/** The people who see the portal, as the server decided. */
export const seers = (p: Portal, people: Person[]) => people.filter((x) => p.who?.[x.id]?.allowed);

/** The rules allow it for somebody — only a fault is in the way. */
export const permittedFor = (p: Portal, people: Person[]) =>
  people.filter((x) => ["ok", "broken"].includes(p.who?.[x.id]?.reason ?? ""));

export function strip(n: Nights | null, id: string, len = 14): Strip {
  const s = n?.history[id] ?? [];
  const full: Strip = Array.from({ length: Math.max(0, len - s.length) }, () => null);
  return [...full, ...s].slice(-len) as Strip;
}

/** Today's night key as the server writes it (UTC date of the run). */
export const todayKey = () => new Date().toISOString().slice(0, 10);

/** The last nightly run of this portal failed — however long ago that was
 *  (a portal failing for 14 nights showed "bereit" when only "today" counted). */
export const failedLast = (n: Nights | null, id: string) => {
  const l = n?.last[id];
  return !!l && l.ok === false;
};

type ExitList = { exits: Exit[]; without_exit: { id: string; net: string }[] };
const NO_EXITS: ExitList = { exits: [], without_exit: [] };

/** Everything a page may need. `exits: false` skips the exit states — the
 *  household page does not show them and should not wait for them. */
export async function loadAll(opts: { exits?: boolean } = {}) {
  const [portals, roles, members, devices, nights, exits] = await Promise.all([
    get<{ portals: Portal[] }>("/household/portals"),
    get<{ roles: Role[]; rights: string[] }>("/household/roles"),
    get<{ people: Person[] }>("/household/members"),
    get<{ devices: Device[] }>("/household/devices"),
    get<Nights>("/household/nights"),
    opts.exits === false ? Promise.resolve(NO_EXITS) : get<ExitList>("/network/exits"),
  ]);
  return {
    portals: portals.portals,
    roles: roles.roles,
    people: members.people,
    devices: devices.devices,
    nights,
    exits: exits.exits,
    withoutExit: exits.without_exit,
  };
}
export type All = Awaited<ReturnType<typeof loadAll>>;

/** A person that is really a television, created before joining existed. */
export const isLegacyPerson = (p: Person, devices: Device[]) => {
  const own = devices.filter((d) => d.person === p.id);
  return /\btv\b/i.test(p.name) && !p.console && own.length > 0 && own.every((d) => d.kind === "tv");
};
