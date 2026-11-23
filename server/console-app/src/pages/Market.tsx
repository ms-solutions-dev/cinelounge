/** Marktplatz — the mockup's `pageMarkt()` and `installSheet()`. */
import { useState } from "react";
import { useTranslation } from "react-i18next";
import { call, get, post } from "../api";
import { LoadFail, Loading, useLoad } from "../data";
import { errorText } from "../i18n";
import { Slot } from "../extension";
import type { MarketEntry } from "../extension/types";
import type { Exit, Role } from "../model";
import { Sheet, useEnter } from "../Shell";
import { useApp } from "../state";
import { Hero, HoldButton, Icon, Marks, type Strip, Switch, useWhen } from "../ui";

type Entry = {
  id: string; name: any; description?: any; version: string; source: string; source_name?: string; kind?: string; adult?: boolean; nights?: Strip;
  trust: "signed" | "unsigned" | "bad"; signed_by?: string | null; installed: boolean; installed_version: string; same_version: boolean;
};

function pick(v: any, lang: string): string {
  if (!v) return "";
  if (typeof v === "string") return v;
  return v[lang] || v.en || v.de || Object.values(v)[0] || "";
}

export function Market() {
  const { t, i18n } = useTranslation();
  const { ui, setUi, toast, setLayer } = useApp();
  const when = useWhen();
  const { data, error, reload } = useLoad(async () => {
    const [m, s, r, x] = await Promise.all([get("/household/market"), get("/household/market/sources"), get("/household/roles"), get("/network/exits")]);
    return { entries: m.portals as Entry[], complaints: m.complaints as Record<string, string[]>, sources: s.sources as any[], anchors: s.anchors as any[], roles: r.roles as Role[], exits: x.exits as Exit[] };
  }, []);
  const [busy, setBusy] = useState<string | null>(null);
  useEnter(!!data);
  if (error) return (<><Hero id="markt" /><LoadFail error={error} retry={reload} /></>);
  if (!data) return (<><Hero id="markt" /><Loading /></>);
  const tab = ui.mt || "offer";
  const lang = i18n.language;
  const failing = data.sources.filter((s) => s.last_error).length;
  const lastRead = Math.max(0, ...data.sources.map((s) => s.last_fetch || 0));

  const reread = async (url?: string) => {
    setBusy(url ?? "all");
    // Reading the listing again makes the server fetch every source.
    await reload();
    setBusy(null);
    toast(url ? t("ui.market.read_one") : t("ui.market.read_all"));
  };

  return (
    <>
      <Hero id="markt" />
      <div className="tabs" role="tablist">
        {([["offer", t("ui.market.t_offer"), data.entries.length], ["src", t("ui.market.t_sources"), data.sources.length], ["trust", t("ui.market.t_trust"), data.anchors.length]] as const).map(([k, n, c]) => (
          <button key={k} className="tab" role="tab" aria-selected={tab === k} onClick={() => setUi({ mt: k })}>{n} <b>{c}</b></button>
        ))}
      </div>
      {tab === "offer" && (
        <>
          <div className="toolbar">
            <p className="hint">
              {data.sources.length ? t("ui.market.read_from", { when: lastRead ? when(lastRead) : "—", n: data.sources.length }) + (failing ? " · " + t("ui.market.n_failing", { count: failing }) : "") : t("ui.market.no_sources")}
            </p>
            <button className="btn" onClick={() => reread()} disabled={busy !== null}><Icon k="refresh" /> {t("ui.market.reread_all")}</button>
          </div>
          {data.entries.length ? (
            <div className="tiles">
              {data.entries.map((m) => {
                const upd = m.installed && !m.same_version;
                return (
                  <article key={m.source + m.id} className="tile w-markt">
                    <div className="th">
                      <span className="pav" style={{ background: "#555" }}>{pick(m.name, lang).slice(0, 2) || m.id.slice(0, 2)}</span>
                      <div style={{ minWidth: 0 }}>
                        <b>{pick(m.name, lang) || m.id}</b>
                        <small>{(m.source_name || m.source) + " · " + m.version}</small>
                      </div>
                    </div>
                    <p>{pick(m.description, lang)}</p>
                    <div className="row">
                      <TrustBadge trust={m.trust} />
                      {m.adult && <span className="chip bad">18+</span>}
                      <Slot name="market.tile" entry={m as unknown as MarketEntry} exits={data.exits} />
                      {m.installed && <span className="chip">{t("ui.market.installed_v", { v: m.installed_version || "?" })}</span>}
                    </div>
                    <div className="foot">
                      {m.nights ? <Marks s={m.nights} cls="s7" /> : <span />}
                      {m.trust === "bad" ? (
                        <button className="btn sm" disabled>{t("ui.market.locked")}</button>
                      ) : m.installed && !upd ? (
                        <button className="btn sm" disabled>{t("ui.market.up_to_date")}</button>
                      ) : (
                        <button className="btn sm pri" onClick={() => setLayer(<Install m={m} roles={data.roles} exits={data.exits} done={reload} />)}>
                          {upd ? t("ui.market.switch_to", { v: m.version }) : t("ui.market.install")}
                        </button>
                      )}
                    </div>
                  </article>
                );
              })}
            </div>
          ) : (
            <div className="empty"><Icon k="markt" /><b>{t("ui.market.empty")}</b><span>{t("ui.market.empty_hint")}</span></div>
          )}
          {Object.entries(data.complaints).filter(([, v]) => v.length).map(([src, v]) => (
            <div key={src} className="flag">{t("ui.market.complaints", { source: src, list: v.slice(0, 3).join(" · ") })}</div>
          ))}
          <p className="legend" dangerouslySetInnerHTML={{ __html: t("ui.market.legend") }} />
        </>
      )}
      {tab === "src" && <Sources sources={data.sources} reload={reload} busy={busy} reread={reread} />}
      {tab === "trust" && <Anchors anchors={data.anchors} reload={reload} />}
    </>
  );
}

function TrustBadge({ trust, by }: { trust: Entry["trust"]; by?: string | null }) {
  const { t } = useTranslation();
  if (trust === "signed") return <span className="trust sig"><Icon k="shield" /> {by ? t("ui.market.signed_by", { by }) : t("ui.market.signed")}</span>;
  if (trust === "unsigned") return <span className="trust uns">{t("ui.market.unsigned")}</span>;
  return <span className="trust bad">{t("ui.market.bad")}</span>;
}

function Install({ m, roles, exits, done }: { m: Entry; roles: Role[]; exits: Exit[]; done: () => void }) {
  const { t, i18n } = useTranslation();
  const { setLayer, toast } = useApp();
  const [ack, setAck] = useState(false);
  // An extension may hold "on right away" back (slot `market.install`), e.g.
  // while a route the portal needs is missing; the core holds nothing.
  const [held, setHeld] = useState<string | null>(null);
  const exitOk = held === null;
  const [onNow, setOnNow] = useState(true);
  // An installed portal keeps the roles it has; a new one goes to every role that may take it.
  const [who, setWho] = useState<Record<string, boolean>>(() =>
    Object.fromEntries(roles.map((r) => [r.id, m.installed ? r.portals.includes(m.id) : !m.adult || r.rights.includes("view_adult")])),
  );
  const [steps, setSteps] = useState<{ ok: boolean | null; text: string }[]>([]);
  const [busy, setBusy] = useState(false);
  const name = pick(m.name, i18n.language) || m.id;

  const run = async () => {
    if (m.trust === "unsigned" && !ack) {
      setSteps([{ ok: false, text: t("ui.market.need_ack") }]);
      return;
    }
    setBusy(true);
    const log: { ok: boolean | null; text: string }[] = [{ ok: null, text: t("ui.market.step_fetch") }];
    setSteps([...log]);
    try {
      // Roles and switch go along in the same call (AP90): the server checks
      // the roles before it fetches and writes both in one transaction, so a
      // failure leaves nothing half done.
      const chosen = roles.filter((r) => !!who[r.id] && (!m.adult || r.rights.includes("view_adult"))).map((r) => r.id);
      const res = await post("/household/market/install", {
        portal: m.id,
        source: m.source,
        allow_unsigned: m.trust === "unsigned" && ack,
        roles: chosen,
        ...(onNow && exitOk ? { on: true } : {}),
      });
      log[0] = { ok: true, text: t("ui.market.step_fetched", { v: m.version }) };
      log.push({ ok: true, text: t("ui.market.step_roles") });
      if (onNow && exitOk) log.push({ ok: true, text: t("ui.market.step_on") });
      if (res.on && res.who_sees === 0) log.push({ ok: null, text: t("ui.access.nobody_after_install") });
      setSteps([...log]);
      toast(t("ui.market.installed_toast", { portal: name }));
      done();
      if (log.every((x) => x.ok !== false)) setTimeout(() => setLayer(null), 900);
    } catch (e) {
      log[0] = { ok: false, text: errorText(e) };
      setSteps([...log]);
    } finally {
      setBusy(false);
    }
  };

  return (
    <Sheet>
      <span className="eyebrow">{m.installed ? t("ui.market.change_version") : t("ui.market.install")}</span>
      <h3>{name}</h3>
      <div className="row">
        <TrustBadge trust={m.trust} by={m.signed_by} />
        <span className="chip">{(m.source_name || m.source) + " · " + m.version}</span>
      </div>
      {m.trust === "unsigned" && (
        <label className="check">
          <input type="checkbox" checked={ack} onChange={(e) => setAck(e.target.checked)} /> <span>{t("ui.market.unsigned_ack")}</span>
        </label>
      )}
      <Slot name="market.install" entry={m as unknown as MarketEntry} exits={exits} hold={setHeld} />
      <div className="toggle-row w-markt">
        <div>
          <b>{t("ui.market.on_now")}</b>
          <small>{t("ui.market.on_now_hint")}</small>
        </div>
        <Switch on={onNow && exitOk} label={t("ui.market.on_now")} disabled={!exitOk} onChange={setOnNow} />
      </div>
      <div className="field">
        <span className="lbl">{t("ui.market.which_roles")}</span>
        {roles.map((r) => {
          const blk = !!m.adult && !r.rights.includes("view_adult");
          return (
            <div key={r.id} className="toggle-row" style={{ ["--a" as any]: r.color }}>
              <div>
                <b>{r.name}</b>
                <small>{blk ? t("ui.portals.role_no_adult") : t("ui.household.people_n", { count: r.members })}</small>
              </div>
              <Switch on={!!who[r.id] && !blk} label={r.name} disabled={blk} onChange={(v) => setWho({ ...who, [r.id]: v })} />
            </div>
          );
        })}
      </div>
      <div className="steps">
        {steps.map((s, i) => (
          <div key={i} className={s.ok === false ? "bad" : s.ok ? "ok" : ""}>{s.ok === null ? "… " : s.ok ? "✓ " : "✗ "}{s.text}</div>
        ))}
      </div>
      <div className="req-act">
        <button className="btn pri w-markt" onClick={run} disabled={busy}>{m.installed ? t("ui.market.switch_to", { v: m.version }) : t("ui.market.install")}</button>
        <button className="btn ghost" onClick={() => setLayer(null)}>{t("ui.common.cancel")}</button>
      </div>
    </Sheet>
  );
}

function Sources({ sources, reload, busy, reread }: { sources: any[]; reload: () => void; busy: string | null; reread: (url?: string) => void }) {
  const { t } = useTranslation();
  const { toast } = useApp();
  const when = useWhen();
  const [adding, setAdding] = useState(false);
  const [url, setUrl] = useState("");
  const add = async () => {
    try {
      await post("/household/market/sources", { url: url.trim() });
      setAdding(false);
      setUrl("");
      toast(t("ui.market.source_added"));
      reload();
    } catch (e) {
      toast(errorText(e));
    }
  };
  const remove = async (u: string) => {
    try {
      await call("/household/market/sources", { method: "DELETE", body: { url: u } });
      toast(t("ui.market.source_removed"));
      reload();
    } catch (e) {
      toast(errorText(e));
    }
  };
  return (
    <section className="panel w-markt">
      <div className="ph"><h3>{t("ui.market.t_sources")}</h3><button className="btn" onClick={() => setAdding(!adding)}><Icon k="plus" /> {t("ui.market.add_source")}</button></div>
      {adding && (
        <div className="composer">
          <div className="field"><label htmlFor="src-url">{t("ui.market.source_url")}</label><input className="inp" id="src-url" placeholder="https://…/index.json" value={url} onChange={(e) => setUrl(e.target.value)} autoFocus /></div>
          <div className="req-act"><button className="btn pri" onClick={add}>{t("ui.market.add")}</button><button className="btn ghost" onClick={() => setAdding(false)}>{t("ui.common.cancel")}</button></div>
        </div>
      )}
      <div className="list">
        {sources.length ? sources.map((s) => (
          <div key={s.url} className="src">
            <span className={"dot " + (s.last_error ? "bad" : "ok")} />
            <div style={{ minWidth: 0 }}>
              <b>{s.name || new URL(s.url).host}</b>
              <small>{s.url}</small>
              <small style={{ color: s.last_error ? "var(--bad)" : "var(--faint)" }}>{s.last_error ? t("ui.market.source_error", { why: s.last_error }) : s.last_fetch ? t("ui.market.source_read", { when: when(s.last_fetch) }) : t("ui.market.source_unread")}</small>
            </div>
            <div className="row">
              <button className="btn sm" onClick={() => reread(s.url)} disabled={busy !== null}>{t("ui.market.reread")}</button>
              <button className="linkbtn danger" onClick={() => remove(s.url)}>{t("ui.market.remove")}</button>
            </div>
          </div>
        )) : <div className="empty">{t("ui.market.no_sources")}</div>}
      </div>
    </section>
  );
}

function Anchors({ anchors, reload }: { anchors: any[]; reload: () => void }) {
  const { t } = useTranslation();
  const { toast } = useApp();
  const [adding, setAdding] = useState(false);
  const [key, setKey] = useState("");
  const [name, setName] = useState("");
  const add = async () => {
    try {
      await post("/household/market/anchors", { public_key: key.trim(), name: name.trim() });
      setAdding(false);
      setKey("");
      setName("");
      toast(t("ui.market.anchor_added"));
      reload();
    } catch (e) {
      toast(errorText(e));
    }
  };
  const remove = async (fp: string) => {
    try {
      await call(`/household/market/anchors/${encodeURIComponent(fp)}`, { method: "DELETE" });
      toast(t("ui.market.anchor_removed"));
      reload();
    } catch (e) {
      toast(errorText(e));
    }
  };
  const fpShow = (fp: string) => (fp.length > 16 ? fp.slice(0, 4).toUpperCase() + " " + fp.slice(4, 8).toUpperCase() + " … " + fp.slice(-4).toUpperCase() : fp);
  return (
    <section className="panel w-markt">
      <div className="ph"><h3>{t("ui.market.anchors")}</h3><button className="btn" onClick={() => setAdding(!adding)}><Icon k="plus" /> {t("ui.market.add_anchor")}</button></div>
      <p className="hint">{t("ui.market.anchors_hint")}</p>
      {adding && (
        <div className="composer">
          <div className="grid2">
            <div className="field"><label htmlFor="a-name">{t("ui.household.name")}</label><input className="inp" id="a-name" value={name} onChange={(e) => setName(e.target.value)} autoFocus /></div>
            <div className="field"><label htmlFor="a-key">{t("ui.market.public_key")}</label><input className="inp" id="a-key" value={key} onChange={(e) => setKey(e.target.value)} style={{ fontFamily: "var(--fm)" }} /></div>
          </div>
          <div className="req-act"><button className="btn pri" onClick={add}>{t("ui.market.add")}</button><button className="btn ghost" onClick={() => setAdding(false)}>{t("ui.common.cancel")}</button></div>
        </div>
      )}
      <div className="list">
        {anchors.length ? anchors.map((a) => (
          <div key={a.fingerprint} className="src">
            <span className="ico w-markt"><Icon k="shield" /></span>
            <div style={{ minWidth: 0 }}><b>{a.name || t("ui.market.anchor_unnamed")}</b><small>{fpShow(a.fingerprint)}</small></div>
            <HoldButton small label={t("ui.market.hold_withdraw")} onDone={() => remove(a.fingerprint)} />
          </div>
        )) : <div className="empty">{t("ui.market.no_anchors")}</div>}
      </div>
    </section>
  );
}
