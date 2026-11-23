/** Netz — the mockup's `pageNetz()`: the routes (direct and HTTP proxies), their
 *  state, portals without a route, and proxies saved in the console. */
import { useState } from "react";
import { useTranslation } from "react-i18next";
import { del, get, post, put } from "../api";
import { LoadFail, Loading, useLoad } from "../data";
import { Slot } from "../extension";
import type { NetworkAnswer } from "../extension/types";
import { errorText } from "../i18n";
import { type Exit, exitWhy, type Portal, routeLabel } from "../model";
import { useEnter } from "../Shell";
import { useApp } from "../state";
import { Hero, Icon } from "../ui";

/** Latency measured in this browser session — the server keeps no history. */
const HIST_KEY = "cl.console.exit_ms";
function remember(exits: Exit[]): Record<string, number[]> {
  let h: Record<string, number[]> = {};
  try {
    h = JSON.parse(sessionStorage.getItem(HIST_KEY) || "{}");
  } catch {
    /* none */
  }
  for (const e of exits) h[e.id] = [...(h[e.id] || []), e.state === "running" && e.ms != null ? e.ms : 0].slice(-12);
  try {
    sessionStorage.setItem(HIST_KEY, JSON.stringify(h));
  } catch {
    /* none */
  }
  return h;
}

function Spark({ h, ok }: { h: number[]; ok: boolean }) {
  if (h.length < 2) return null;
  const w = 200, ht = 34, max = Math.max(...h, 1);
  const pts = h.map((v, i) => `${((i / (h.length - 1)) * w).toFixed(1)},${(ht - 2 - (v / max) * (ht - 6)).toFixed(1)}`).join(" ");
  return (
    <svg className="spark" viewBox={`0 0 ${w} ${ht}`} preserveAspectRatio="none" aria-hidden="true">
      <polyline points={pts} fill="none" stroke={ok ? "var(--a)" : "var(--bad)"} strokeWidth="2" vectorEffect="non-scaling-stroke" />
    </svg>
  );
}

export function Network() {
  const { t } = useTranslation();
  const { go, toast } = useApp();
  const { data, error, reload } = useLoad(async () => {
    const [x, p] = await Promise.all([get<NetworkAnswer>("/network/exits"), get("/household/portals")]);
    return { answer: x, exits: x.exits, without: x.without_exit, portals: p.portals as Portal[], hist: remember(x.exits) };
  }, []);
  const [probing, setProbing] = useState<string | null>(null);
  useEnter(!!data);
  if (error) return (<><Hero id="netz" /><LoadFail error={error} retry={reload} /></>);
  if (!data) return (<><Hero id="netz" /><Loading /></>);
  const label = (c: string) => routeLabel(t, c);

  const probe = async (id: string) => {
    setProbing(id);
    try {
      const r = await post(`/network/exits/${id}/probe`);
      const bad = (r.checked || []).filter((c: any) => !c.ok);
      toast(bad.length ? t("ui.network.probe_bad", { exit: label(id), n: bad.length }) : t("ui.network.probe_ok", { exit: label(id), n: (r.checked || []).length }));
    } catch (e) {
      toast(errorText(e));
    }
    setProbing(null);
    reload();
  };
  const probeAll = async () => {
    for (const e of data.exits) await probe(e.id);
    if (!data.exits.length) toast(t("ui.network.no_exits"));
  };
  const remove = async (id: string) => {
    try {
      await del(`/network/exits/${id}`);
      toast(t("ui.network.proxy_removed", { exit: label(id) }));
      reload();
    } catch (e) {
      toast(errorText(e));
    }
  };
  const rows: Exit[] = [
    { id: "direct", host: "", state: "running", ms: null, public_ip: null, portals: data.portals.filter((p) => p.exit_net === "direct").map((p) => p.id), why: "" },
    ...data.exits,
  ];
  const nameOf = (id: string) => data.portals.find((p) => p.id === id)?.name ?? id;

  return (
    <>
      <Hero id="netz" />
      <div className="toolbar">
        <p className="hint">{t("ui.network.hint")}</p>
        <button className="btn" onClick={probeAll} disabled={probing !== null || !data.exits.length}><Icon k="refresh" /> {t("ui.network.check_all")}</button>
      </div>
      <div className="exits">
        {rows.map((e) => {
          const ok = e.state === "running";
          const ps = e.portals.filter((id) => data.portals.find((p) => p.id === id)?.on);
          return (
            <article key={e.id} className={"xc w-netz" + (ok ? "" : " down")}>
              <div className="xh">
                <span className="fl">{e.id === "direct" ? "··" : e.id.toUpperCase()}</span>
                <div>
                  <b>{label(e.id)}</b>
                  <small>{e.id === "direct" ? t("ui.network.direct_sub") : (e.host + " · " + (ok ? (e.public_ip ? "IP " + e.public_ip : t("ui.network.running")) : exitWhy(t, e.why, e.state)))}</small>
                </div>
              </div>
              <div className="row" style={{ justifyContent: "space-between", alignItems: "flex-end" }}>
                <span className={"lat" + (ok ? " at" : "")} style={ok ? undefined : { color: "var(--bad)" }}>
                  {ok ? (e.ms != null ? <>{e.ms}<small> ms</small></> : null) : t("ui.network.off")}
                </span>
                <span className={"chip " + (ok ? "ok" : "bad")}>{ok ? t("ui.network.running") : t("ui.network.unreachable")}</span>
              </div>
              {e.id !== "direct" && <Spark h={data.hist[e.id] || []} ok={ok} />}
              <div className="row">
                {ps.length ? ps.map((id) => <button key={id} className="chip" onClick={() => go("portale", { pid: id })}>{nameOf(id)}</button>) : <span className="hint">{t("ui.network.no_portal")}</span>}
              </div>
              <Slot name="network.route" route={e} answer={data.answer} reload={reload} />
              {e.id !== "direct" && (
                <div className="row">
                  <button className="btn sm" onClick={() => probe(e.id)} disabled={probing !== null}>{probing === e.id ? t("ui.network.checking") : t("ui.network.check")}</button>
                  {e.source === "console" && <button className="btn ghost sm" onClick={() => remove(e.id)}>{t("ui.network.delete")}</button>}
                </div>
              )}
            </article>
          );
        })}
      </div>
      {data.without.length > 0 && (
        <section className="panel w-netz">
          <div className="ph"><h3>{t("ui.network.without")}</h3><span className="chip warn">{data.without.length}</span></div>
          {data.without.map((w) => (
            <div key={w.id} className="toggle-row">
              <div><b>{nameOf(w.id)}</b><small>{t("ui.network.needs", { exit: label(w.net) })}</small></div>
              <button className="btn sm" onClick={() => go("portale", { pid: w.id })}>{t("ui.network.portal")}</button>
            </div>
          ))}
        </section>
      )}
      <Slot name="network" answer={data.answer} reload={reload} />
      <AddProxy reload={reload} />
    </>
  );
}

/** A proxy saved in the console; the ones from `CL_PROXIES` are fixed. */
function AddProxy({ reload }: { reload: () => void }) {
  const { t } = useTranslation();
  const { toast, can } = useApp();
  const [name, setName] = useState("");
  const [address, setAddress] = useState("");
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const save = async () => {
    setBusy(true);
    setMsg(null);
    try {
      await put("/network/exits", { name: name.trim(), address: address.trim() });
      toast(t("ui.network.proxy_saved", { exit: routeLabel(t, name.trim().toLowerCase()) }));
      setName("");
      setAddress("");
      reload();
    } catch (e) {
      setMsg(errorText(e));
    } finally {
      setBusy(false);
    }
  };
  return (
    <section className="panel w-netz" id="proxy">
      <div className="ph"><h3>{t("ui.network.proxy_add")}</h3><span className="eyebrow">{t("ui.network.proxy_kind")}</span></div>
      <div className="grid2">
        <div className="field">
          <label htmlFor="px-name">{t("ui.network.proxy_name")}</label>
          <input className="inp" id="px-name" value={name} placeholder="buero" autoComplete="off" onChange={(e) => setName(e.target.value)} />
        </div>
        <div className="field">
          <label htmlFor="px-addr">{t("ui.network.proxy_address")}</label>
          <input className="inp" id="px-addr" value={address} placeholder="http://10.0.0.2:3128" autoComplete="off" onChange={(e) => setAddress(e.target.value)} />
        </div>
      </div>
      {msg && <div className="flag bad">{msg}</div>}
      <div className="row">
        <button className="btn pri" onClick={save} disabled={busy || !name.trim() || !address.trim() || !can("change_settings")}>{t("ui.network.proxy_save")}</button>
        <span className="hint">{t("ui.network.proxy_hint")}</span>
      </div>
    </section>
  );
}
