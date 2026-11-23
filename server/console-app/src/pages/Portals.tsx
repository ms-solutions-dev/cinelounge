/** Portale — the mockup's `pagePortale()` and `portalDetail()`. */
import { useState } from "react";
import { useTranslation } from "react-i18next";
import { del, post, put } from "../api";
import { LoadFail, Loading, useLoad } from "../data";
import { errorText } from "../i18n";
import { Slot } from "../extension";
import { type Access, type All, failedLast, loadAll, type Person, type Portal, type Role, routeLabel, seers, strip } from "../model";
import { Sheet, useEnter } from "../Shell";
import { useApp } from "../state";
import { Avatar, Hero, HoldButton, Icon, Marks, stripOk, stripTotal, Switch } from "../ui";

export function Portals() {
  const { ui } = useApp();
  const { data, error, reload } = useLoad(() => loadAll(), []);
  useEnter(!!data);
  const p = data?.portals.find((x) => x.id === ui.pid);
  if (error) return (<><Hero id="portale" /><LoadFail error={error} retry={reload} /></>);
  if (!data) return (<><Hero id="portale" /><Loading /></>);
  if (ui.pid && p) return <Detail p={p} d={data} reload={reload} />;
  return <List d={data} reload={reload} />;
}

function useLabels(d: All) {
  const { t } = useTranslation();
  const route = (c: string) => routeLabel(t, c);
  const exitOf = (p: Portal) => d.exits.find((e) => e.id === p.exit_net);
  const noExit = (p: Portal) => p.exit_net !== "direct" && !exitOf(p);
  const fault = (p: Portal) => p.state !== "ready";
  // A missing value is a task, not a defect: amber and named, not red.
  const setup = (p: Portal) => p.state === "needs_setting";
  const setupLine = (p: Portal) => t("ui.portals.needs_setting_line", { keys: (p.missing_settings ?? []).join(", ") || "?" });
  const stateChip = (p: Portal) => {
    if (setup(p)) return <span className="chip warn">{t("ui.portals.needs_setting")}</span>;
    if (fault(p)) return <span className="chip bad">{t("ui.portals.fault")}</span>;
    if (failedLast(d.nights, p.id)) return <span className="chip warn">{t("ui.portals.failed_today")}</span>;
    if (!p.on) return <span className="chip">{t("ui.portals.off")}</span>;
    return <span className="chip ok">{t("ui.portals.ready")}</span>;
  };
  const exitChip = (p: Portal) => {
    if (p.exit_net === "direct") return <span className="chip">{t("ui.portals.direct_short")}</span>;
    const e = exitOf(p);
    if (!e) return <span className="chip bad">{t("ui.portals.exit_missing", { exit: route(p.exit_net) })}</span>;
    const ok = e.state === "running";
    return <span className={"chip " + (ok ? "" : "bad")}>{e.id.toUpperCase()}{ok ? "" : " · " + t("ui.portals.off")}</span>;
  };
  const kind = (p: Portal) => t(`ui.portal_kind.${p.kind}`, { defaultValue: p.kind });
  const origin = (p: Portal) => ((p as any).origin?.version ? t("ui.portals.from_market") + " · " + (p as any).origin.version : t("ui.portals.by_hand"));
  return { route, exitOf, noExit, fault, setup, setupLine, stateChip, exitChip, kind, origin };
}

function List({ d, reload }: { d: All; reload: () => void }) {
  const { t } = useTranslation();
  const { ui, setUi, can } = useApp();
  const L = useLabels(d);
  const f: string = ui.pf || "all";
  const filters: Record<string, [string, (p: Portal) => boolean]> = {
    all: [t("ui.portals.f_all"), () => true],
    on: [t("ui.portals.f_on"), (p) => p.on],
    off: [t("ui.portals.f_off"), (p) => !p.on],
    fault: [t("ui.portals.f_fault"), (p) => L.fault(p) || L.noExit(p) || failedLast(d.nights, p.id)],
  };
  const q = String(ui.q || "").toLowerCase();
  const list = d.portals.filter(filters[f][1]).filter((p) => !q || p.name.toLowerCase().includes(q));
  // Grouped by state when nothing is filtered (redesign 09.11.2026, variant A):
  // what needs a look first, with its reason; switched-off portals folded.
  const needs = (p: Portal) => L.fault(p) || (L.noExit(p) && p.on) || failedLast(d.nights, p.id);
  const why = (p: Portal) => {
    if (L.setup(p)) return L.setupLine(p);
    if (L.fault(p)) return p.reason || t("ui.portals.fault");
    if (L.noExit(p)) return t("ui.portals.needs_exit", { exit: L.route(p.exit_net) });
    const l = d.nights.last[p.id];
    return l ? t("ui.portals.fail_line", { step: l.step, reason: l.reason }) : "";
  };
  const grouped = f === "all" && !q;
  const groups: [string, string, Portal[]][] = grouped
    ? [
        ["need", "bad", list.filter(needs)],
        ["running", "ok", list.filter((p) => p.on && !needs(p))],
        ["off", "", list.filter((p) => !p.on && !needs(p))],
      ]
    : [["", "", list]];
  const flip = useFlip(d, reload);
  return (
    <>
      <Hero id="portale" />
      <div className="toolbar">
        <div className="filters" role="group" aria-label={t("ui.common.filter")}>
          {Object.entries(filters).map(([k, [n, fn]]) => (
            <button key={k} className="fchip" aria-pressed={f === k} onClick={() => setUi({ pf: k })}>
              {n} <b>{d.portals.filter(fn).length}</b>
            </button>
          ))}
        </div>
        <label className="find">
          <Icon k="search" />
          <input placeholder={t("ui.portals.find")} aria-label={t("ui.portals.find")} value={ui.q || ""} onChange={(e) => setUi({ q: e.target.value })} />
        </label>
      </div>
      <div className="phead" aria-hidden="true">
        <span>{t("ui.portals.h_portal")}</span>
        <span>{t("ui.portals.h_state")}</span>
        <span>{t("ui.portals.h_exit")}</span>
        <span className="rd">{t("ui.portals.h_visible")}</span>
        <span>{t("ui.portals.h_nights")}</span>
        <span>{t("ui.portals.h_on")}</span>
      </div>
      {groups.map(([gid, tone, items]) => (gid && !items.length) ? null : (
      <div key={gid || "all"} className="pgroup">
      {gid && (
        <div className="ph pgh">
          <h3>{t(`ui.portals.g_${gid}`)}</h3>
          {gid === "off" ? (
            <button className="btn ghost sm" onClick={() => setUi({ showOff: !ui.showOff })}>{ui.showOff ? t("ui.portals.fold") : t("ui.portals.unfold", { count: items.length })}</button>
          ) : (
            <span className={"chip " + tone}>{items.length}</span>
          )}
        </div>
      )}
      {(gid !== "off" || ui.showOff) && (
      <div className="plist">
        {items.length ? (
          items.map((p) => {
            const ps = seers(p, d.people);
            return (
              <div key={p.id} className={"prow" + (p.on ? "" : " off")}>
                <button className="pn" onClick={() => setUi({ pid: p.id })}>
                  <span className="pav" style={{ background: colorOf(p.id) }}>{p.name.slice(0, 2)}</span>
                  <span>
                    <b>
                      {p.name}
                      {p.adult && <> <span className="chip bad" style={{ padding: "0 6px" }}>18+</span></>}
                    </b>
                    {gid === "need" ? <small style={{ color: "var(--bad)" }}>{why(p)}</small> : <small>{L.kind(p)} · {L.origin(p)}</small>}
                    <Slot name="portal.row" portal={p} />
                  </span>
                </button>
                <span className="pmeta">
                  <span className="st">{L.stateChip(p)}</span>
                  <span className="nx">{L.exitChip(p)}</span>
                  <span className="rdots rd">
                    {ps.length ? ps.map((x) => (
                      <span key={x.id} style={{ ["--rc" as any]: x.color }}><i />{x.name}</span>
                    )) : <Nobody p={p} d={d} reload={reload} />}
                  </span>
                  <span className="mk"><Marks s={strip(d.nights, p.id, 7)} cls="s7" /></span>
                </span>
                <Switch className="w-portale" on={p.on} label={t("ui.portals.to_devices_of", { portal: p.name })} disabled={!can("switch_portals") || (L.fault(p) && !p.on) || (L.noExit(p) && !p.on)} onChange={(on) => flip(p, on)} />
              </div>
            );
          })
        ) : (
          <div className="empty">{t("ui.portals.none_match")}</div>
        )}
      </div>
      )}
      </div>
      ))}
      <p className="hint">{t("ui.portals.on_hint")}</p>
    </>
  );
}

/** A steady colour per portal for its avatar (the mockup had one per manifest). */
function colorOf(id: string): string {
  const c = ["#5f7fbf", "#8a5cd6", "#1f5fb4", "#e8662c", "#c43f2f", "#2e9c8a", "#3a7bd5", "#f08a24", "#6b4a5a", "#1c9b5c", "#7d8a90"];
  let h = 0;
  for (const ch of id) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
  return c[h % c.length];
}

function Detail({ p, d, reload }: { p: Portal; d: All; reload: () => void }) {
  const { t } = useTranslation();
  const { setUi, toast, go, can } = useApp();
  const L = useLabels(d);
  const e = L.exitOf(p);
  const s = strip(d.nights, p.id);
  const fails = d.nights.failures?.[p.id] ?? [];
  const [checking, setChecking] = useState(false);
  const blockedOn = (L.fault(p) || L.noExit(p)) && !p.on;

  const flipAny = useFlip(d, reload);
  const flip = (on: boolean) => flipAny(p, on);
  const setNet = async (net: string) => {
    try {
      await post(`/household/portals/${p.id}/net`, { net });
      toast(t("ui.portals.net_set", { portal: p.name, exit: L.route(net) }));
      reload();
    } catch (err) {
      toast(errorText(err));
    }
  };
  const checkNow = async () => {
    setChecking(true);
    try {
      const r = await post("/household/nights/run", { portal: p.id });
      toast((r.carried || []).includes(p.id) ? t("ui.portals.check_ok", { portal: p.name }) : (r.skipped || []).includes(p.id) ? t("ui.portals.check_skipped", { portal: p.name }) : t("ui.portals.check_failed", { portal: p.name }));
      reload();
    } catch (err) {
      toast(errorText(err));
    } finally {
      setChecking(false);
    }
  };
  const remove = async () => {
    try {
      await del(`/household/portals/${p.id}`);
      toast(t("ui.portals.removed", { portal: p.name }));
      setUi({ pid: null });
      reload();
    } catch (err) {
      toast(errorText(err));
    }
  };
  const nets = Array.from(new Set(["direct", ...d.exits.map((x) => x.id), p.exit_net]));
  // Back to the version before the last marketplace install (the old console had it).
  const rollback = async () => {
    try {
      const r = await post("/household/market/rollback", { portal: p.id });
      toast(t("ui.portals.rolled_back", { portal: p.name, v: r.version || "?" }));
      reload();
    } catch (err) {
      toast(errorText(err));
    }
  };
  const origin = (p as any).origin as { version?: string; sha256?: string; installed?: number } | undefined;

  return (
    <>
      <Hero id="portale" title={p.name} />
      <div className="row">
        <button className="btn ghost" onClick={() => setUi({ pid: null })}><Icon k="back" /> {t("ui.portals.all")}</button>
      </div>
      <AccessChain p={p} d={d} reload={reload} flip={flip} blockedOn={blockedOn} />
      <div className="pd-grid">
        <div className="col">
          <section className="panel w-portale" id="p-operation">
            <div className="ph"><h3>{t("ui.portals.operation")}</h3>{L.stateChip(p)}</div>
            {L.setup(p) ? <div className="flag">{L.setupLine(p)}</div> : L.fault(p) && p.reason && <div className="flag bad">{p.reason}</div>}
            <div className="grid2">
              <div className="field">
                <label htmlFor="p-net">{t("ui.portals.h_exit")}</label>
                <select className="sel" id="p-net" value={p.exit_net} onChange={(ev) => setNet(ev.target.value)} disabled={!can("change_settings")}>
                  {nets.map((n) => (
                    <option key={n} value={n}>
                      {L.route(n)}
                      {n !== "direct" && !d.exits.find((x) => x.id === n) ? " " + t("ui.portals.missing") : ""}
                    </option>
                  ))}
                </select>
              </div>
              <div className="field">
                <span className="lbl">{t("ui.portals.can")}</span>
                <div className="row">{p.capabilities.map((c) => <span key={c} className="chip">{t(`ui.cap.${c}`, { defaultValue: c })}</span>)}</div>
              </div>
            </div>
            {e && e.state !== "running" && <div className="flag bad">{t("ui.portals.exit_down", { exit: L.route(e.id) })}</div>}
          </section>
          <Slot name="portal.detail" portal={p} reload={reload} />
          <section className="panel w-werk">
            <div className="ph"><h3>{t("ui.portals.nights")}</h3><span className="eyebrow">{t("ui.portals.carried_of", { ok: stripOk(s), total: stripTotal(s) })}</span></div>
            <Marks s={s} />
            {fails.length ? (
              <div className="fails">
                {fails.map((x, i) => (
                  <div key={i} className="fail"><time>{x.night.split("-").reverse().slice(0, 2).join(".") + "."}</time><span>{t("ui.portals.fail_line", { step: x.step, reason: x.reason })}</span></div>
                ))}
              </div>
            ) : stripTotal(s) ? <p className="hint">{t("ui.portals.no_fails")}</p> : <p className="hint">{t("ui.portals.never_checked")}</p>}
            <div className="row">
              <button className="btn" onClick={checkNow} disabled={checking || !can("change_settings")}><Icon k="play" /> {checking ? t("ui.portals.checking") : t("ui.portals.check_now")}</button>
              <button className="btn ghost" onClick={() => go("werk", { wp: p.id })}>{t("ui.portals.open_workshop")}</button>
            </div>
          </section>
        </div>
        <div className="col">
          {p.settings.length > 0 && <Settings p={p} reload={reload} />}
          <section className="panel w-markt">
            <div className="ph"><h3>{t("ui.portals.origin")}</h3>{origin?.version ? <span className="trust sig"><Icon k="shield" /> {t("ui.portals.from_market")}</span> : <span className="trust uns">{t("ui.portals.by_hand")}</span>}</div>
            <dl className="dl">
              <dt>{t("ui.portals.folder")}</dt><dd>{p.source || p.id}</dd>
              <dt>{t("ui.portals.version")}</dt><dd>{origin?.version || "—"}</dd>
              <dt>{t("ui.portals.checksum")}</dt><dd style={{ fontFamily: "var(--fm)", fontSize: 14 }}>{origin?.sha256 ? "sha256:" + origin.sha256.slice(0, 10) + "…" : "—"}</dd>
            </dl>
            <div className="row">
              <button className="btn ghost" onClick={() => go("markt")}>{t("ui.portals.in_market")}</button>
              {origin?.version && can("install_portals") && <button className="btn ghost" onClick={rollback}>{t("ui.portals.rollback")}</button>}
              {can("install_portals") && <HoldButton label={t("ui.portals.hold_remove")} onDone={remove} />}
            </div>
            <p className="hint">{t("ui.portals.remove_hint")}</p>
          </section>
        </div>
      </div>
    </>
  );
}

function Settings({ p, reload }: { p: Portal; reload: () => void }) {
  const { t } = useTranslation();
  const { toast } = useApp();
  const [edit, setEdit] = useState<string | null>(null);
  const save = async (key: string, value: string) => {
    try {
      await put(`/household/portals/${p.id}/settings`, { settings: { [key]: value } });
      toast(t("ui.common.saved"));
      setEdit(null);
      reload();
    } catch (e) {
      toast(errorText(e));
    }
  };
  return (
    <section className="panel w-portale" id="p-settings">
      <div className="ph"><h3>{t("ui.portals.own_settings")}</h3><span className="eyebrow">{t("ui.portals.from_manifest")}</span></div>
      {p.settings.map((s: any) =>
        s.secret && edit !== s.key ? (
          <div key={s.key} className="secret">
            <div>
              <b>{s.label}</b>
              <small>{s.value ? t("ui.portals.secret_set") : t("ui.portals.secret_unset")}</small>
            </div>
            <button className="btn sm" onClick={() => setEdit(s.key)}>{t("ui.common.change")}</button>
          </div>
        ) : (
          <SettingField key={s.key} s={s} onSave={(v) => save(s.key, v)} />
        ),
      )}
    </section>
  );
}

function SettingField({ s, onSave }: { s: any; onSave: (v: string) => void }) {
  const { t } = useTranslation();
  const [v, setV] = useState(s.secret ? "" : s.value || "");
  return (
    <div className="field">
      <label htmlFor={"ps-" + s.key}>{s.label}{s.required ? " *" : ""}</label>
      <div className="row">
        <input className="inp" id={"ps-" + s.key} type={s.secret ? "password" : "text"} value={v} autoComplete="off" onChange={(e) => setV(e.target.value)} style={{ flex: 1, minWidth: "min(100%,220px)" }} />
        <button className="btn" onClick={() => onSave(v)}>{t("ui.common.save")}</button>
      </div>
      {s.secret && <p className="hint">{t("ui.portals.secret_hint")}</p>}
    </div>
  );
}

// ── Access (AP90): the chain the server checks, and "why?" ──────────────────

/** Switching a portal: on without anybody seeing it asks which roles get it. */
function useFlip(d: All, reload: () => void) {
  const { t } = useTranslation();
  const { toast, setLayer } = useApp();
  return async (p: Portal, on: boolean) => {
    try {
      const r = await post(`/household/portals/${p.id}/switch`, { on });
      toast(on ? t("ui.portals.now_on", { portal: p.name }) : t("ui.portals.now_off", { portal: p.name }));
      reload();
      if (on && r.who_sees === 0) setLayer(<AskRoles p={p} roles={d.roles} reload={reload} />);
    } catch (e) {
      toast(errorText(e));
    }
  };
}

/** The roles a portal can go to: a role without "ab 18" cannot take an 18+ portal. */
const takes = (r: Role, p: Portal) => !p.adult || r.rights.includes("view_adult");

/** On, but nobody sees it — the server said `who_sees: 0`. Asked once. */
function AskRoles({ p, roles, reload }: { p: Portal; roles: Role[]; reload: () => void }) {
  const { t } = useTranslation();
  const { setLayer, toast, can } = useApp();
  const open = roles.filter((r) => takes(r, p));
  const [pick, setPick] = useState<Record<string, boolean>>(() => Object.fromEntries(open.map((r) => [r.id, true])));
  const chosen = open.filter((r) => pick[r.id]).map((r) => r.id);
  const grant = async () => {
    try {
      const r = await post(`/household/portals/${p.id}/switch`, { on: true, roles: chosen });
      toast(t("ui.access.granted_n", { portal: p.name, count: r.who_sees }));
      setLayer(null);
      reload();
    } catch (e) {
      toast(errorText(e));
    }
  };
  return (
    <Sheet>
      <span className="eyebrow">{t("ui.access.ask_eyebrow")}</span>
      <h3>{t("ui.access.ask_title", { portal: p.name })}</h3>
      <p className="hint">{t("ui.access.ask_hint")}</p>
      {roles.map((r) => (
        <div key={r.id} className="toggle-row" style={{ ["--a" as any]: r.color }}>
          <div>
            <b>{r.name}</b>
            <small>{takes(r, p) ? t("ui.household.people_n", { count: r.members }) : t("ui.portals.role_no_adult")}</small>
          </div>
          <Switch on={takes(r, p) && !!pick[r.id]} label={r.name} disabled={!takes(r, p)} onChange={(v) => setPick({ ...pick, [r.id]: v })} />
        </div>
      ))}
      <div className="req-act">
        <button className="btn pri w-portale" onClick={grant} disabled={!chosen.length || !can("change_access")}>{t("ui.access.on_and_grant")}</button>
        <button className="btn ghost" onClick={() => setLayer(null)}>{t("ui.access.only_on")}</button>
      </div>
    </Sheet>
  );
}

/** "nobody" in the list: with a fault the fault, otherwise a button "why?". */
function Nobody({ p, d, reload }: { p: Portal; d: All; reload: () => void }) {
  const { t } = useTranslation();
  const { setLayer } = useApp();
  if (p.on && p.state !== "ready" && Object.values(p.who ?? {}).some((x) => x.reason === "broken"))
    return <span>{t("ui.portals.nobody")} · {p.state === "needs_setting"
      ? <span style={{ color: "var(--warn)" }}>{t("ui.portals.needs_setting")}</span>
      : <span style={{ color: "var(--bad)" }}>{t("ui.portals.fault")}</span>}</span>;
  return (
    <span>
      {t("ui.portals.nobody")} · <button className="linkbtn" onClick={() => setLayer(<WhySheet p={p} d={d} reload={reload} />)}>{t("ui.access.why")}</button>
    </span>
  );
}

/** One person's reason in words — the server's `reason`, never re-derived. */
function useReasonText() {
  const { t } = useTranslation();
  return (p: Portal, a: Access | undefined, role: Role | undefined) => {
    const rn = role?.name ?? "?";
    switch (a?.reason) {
      case "ok": return t("ui.access.r_ok");
      case "adult": return role?.child_lock ? t("ui.access.r_adult_locked", { role: rn }) : t("ui.access.r_adult", { role: rn });
      case "off": return t("ui.access.r_off");
      case "no_role": return t("ui.access.r_no_role", { role: rn, portal: p.name });
      case "broken": return p.state === "needs_setting"
        ? t("ui.access.r_needs_setting", { keys: (p.missing_settings ?? []).join(", ") || "?" })
        : t("ui.access.r_broken", { why: a.detail || t("ui.portals.fault") });
      default: return t("ui.access.r_unknown");
    }
  };
}

/** The button that changes a person's reason — or none, where it is meant so. */
function Fix({ p, x, a, role, reload, flip }: { p: Portal; x: Person; a: Access | undefined; role: Role | undefined; reload: () => void; flip?: (on: boolean) => void }) {
  const { t } = useTranslation();
  const { toast, go, setUi, setLayer, can } = useApp();
  const grant = async () => {
    if (!role) return;
    try {
      await post(`/household/roles/${role.id}/portals`, { portal: p.id, on: true });
      toast(t("ui.household.portal_visible", { portal: p.name, role: role.name }));
      setLayer(null);
      reload();
    } catch (e) {
      toast(errorText(e));
    }
  };
  if (!a || a.reason === "ok") return null;
  if (a.reason === "adult" && role?.child_lock) return <span className="hint">{t("ui.access.meant_so")}</span>;
  if (a.reason === "adult" || !role) return <button className="btn ghost sm" onClick={() => { setLayer(null); go("haushalt", { tab: "rol", role: x.role_id }); }}>{t("ui.access.to_role")}</button>;
  if (a.reason === "no_role") return <button className="btn sm" onClick={grant} disabled={!can("change_access")}>{t("ui.access.grant_for", { role: role.name })}</button>;
  if (a.reason === "off") return flip ? <button className="btn sm" onClick={() => { setLayer(null); flip(true); }} disabled={!can("switch_portals")}>{t("ui.access.switch_on")}</button> : null;
  return <button className="btn ghost sm" onClick={() => { setLayer(null); setUi({ pid: p.id }); }}>{t("ui.access.to_portal")}</button>;
}

/** One row per person: who it is, the reason, and the way to change it. */
function PersonRows({ p, d, reload, flip }: { p: Portal; d: All; reload: () => void; flip?: (on: boolean) => void }) {
  const why = useReasonText();
  return (
    <div className="list why-rows">
      {d.people.map((x) => {
        const a = p.who?.[x.id];
        const role = d.roles.find((r) => r.id === x.role_id);
        return (
          <div key={x.id} className={"why-row " + (a?.allowed ? "ok" : "")}>
            <Avatar name={x.name} color={x.color} />
            <div>
              <b>{x.name} · {role?.name ?? "?"}</b>
              <small>{why(p, a, role)}</small>
            </div>
            <Fix p={p} x={x} a={a} role={role} reload={reload} flip={flip} />
          </div>
        );
      })}
    </div>
  );
}

function WhySheet({ p, d, reload }: { p: Portal; d: All; reload: () => void }) {
  const { t } = useTranslation();
  const flip = useFlip(d, reload);
  return (
    <Sheet>
      <span className="eyebrow">{t("ui.access.why")}</span>
      <h3>{t("ui.access.why_title", { portal: p.name })}</h3>
      <PersonRows p={p} d={d} reload={reload} flip={(on) => flip(p, on)} />
      <p className="hint">{t("ui.access.why_hint")}</p>
    </Sheet>
  );
}

/** The chain at the top of the portal page, in the order the server checks.
 *  The first red step is the reason; its button fixes it. */
function AccessChain({ p, d, reload, flip, blockedOn }: { p: Portal; d: All; reload: () => void; flip: (on: boolean) => void; blockedOn: boolean }) {
  const { t } = useTranslation();
  const { toast, can, go } = useApp();
  const L = useLabels(d);
  const ps = seers(p, d.people);
  const origin = (p as any).origin as { version?: string } | undefined;
  const required = p.settings.filter((s: any) => s.required && !s.value);
  const ready = !L.fault(p);
  const listing = d.roles.filter((r) => p.roles.includes(r.id));
  const roleSwitch = async (r: Role, on: boolean) => {
    try {
      await post(`/household/roles/${r.id}/portals`, { portal: p.id, on });
      toast(t(on ? "ui.household.portal_visible" : "ui.household.portal_hidden", { portal: p.name, role: r.name }));
      reload();
    } catch (err) {
      toast(errorText(err));
    }
  };
  const jump = (id: string) => document.getElementById(id)?.scrollIntoView({ behavior: "smooth", block: "start" });
  const step = (ok: boolean | null, title: string, body: React.ReactNode, act?: React.ReactNode) => (
    <div className={"chain-step " + (ok === null ? "" : ok ? "ok" : "bad")}>
      <span className="chain-dot" aria-hidden="true" />
      <div className="chain-body">
        <b>{title}</b>
        <div>{body}</div>
      </div>
      {act && <div className="chain-act">{act}</div>}
    </div>
  );
  return (
    <section className="panel w-portale chain" aria-label={t("ui.access.title")}>
      <div className="ph">
        <h3>{t("ui.access.title")}</h3>
        <span className={"chip " + (ps.length ? "ok" : "bad")}>{ps.length ? t("ui.access.seen_by_n", { count: ps.length }) : t("ui.access.seen_by_none")}</span>
      </div>
      {step(true, t("ui.access.s_installed"), <small>{origin?.version ? t("ui.portals.from_market") + " · " + origin.version : t("ui.portals.by_hand")}</small>)}
      {step(
        ready,
        t("ui.access.s_ready"),
        <small>
          {ready
            ? [p.exit_net === "direct" ? t("ui.portals.direct_short") : t("ui.access.exit_is", { exit: L.route(p.exit_net) }), required.length ? "" : t("ui.access.no_required")].filter(Boolean).join(" · ")
            : L.setup(p) ? L.setupLine(p) : p.reason || t("ui.portals.fault")}
        </small>,
        !ready && (L.noExit(p) ? <button className="btn ghost sm" onClick={() => jump("p-operation")}>{t("ui.access.to_exit")}</button> : required.length ? <button className="btn ghost sm" onClick={() => jump("p-settings")}>{t("ui.access.to_settings")}</button> : <button className="btn ghost sm" onClick={() => go("werk", { wp: p.id })}>{t("ui.portals.open_workshop")}</button>),
      )}
      {step(
        p.on,
        t("ui.portals.to_devices"),
        <small>{blockedOn ? t("ui.portals.blocked_fault") : p.on ? t("ui.access.on_house") : t("ui.access.off_house")}</small>,
        <Switch on={p.on} label={t("ui.portals.to_devices")} disabled={!can("switch_portals") || blockedOn} onChange={flip} />,
      )}
      {step(
        listing.some((r) => takes(r, p)),
        t("ui.access.s_roles"),
        <div className="chain-roles">
          {d.roles.map((r) => {
            const blk = !takes(r, p);
            return (
              <label key={r.id} className="chain-role" style={{ ["--a" as any]: r.color }}>
                <Switch on={r.portals.includes(p.id) && !blk} label={r.name} disabled={blk || !can("change_access")} onChange={(on) => roleSwitch(r, on)} />
                <span>
                  <b>{r.name}</b>
                  <small>{blk ? (r.child_lock ? t("ui.access.role_locked") : t("ui.portals.role_no_adult")) : r.portals.includes(p.id) ? t("ui.access.role_lists") : t("ui.access.role_not")}</small>
                </span>
              </label>
            );
          })}
        </div>,
      )}
      {step(
        ps.length > 0,
        t("ui.access.s_people"),
        <PersonRows p={p} d={d} reload={reload} flip={flip} />,
      )}
      <p className="hint">{t("ui.access.chain_hint")}</p>
    </section>
  );
}
