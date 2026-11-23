/** Werkstatt — the mockup's `pageWerk()`: call a portal by hand and read what comes back. */
import { useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { call, post, ServerError } from "../api";
import { LoadFail, Loading, useLoad } from "../data";
import { errorText, esc } from "../i18n";
import { useEnter } from "../Shell";
import { useApp } from "../state";
import { Hero, Icon } from "../ui";

type Fn = "menu" | "list" | "search" | "walk";
type Line = [cls: "" | "d" | "c" | "e" | "w", text: string];

function pick(v: any, lang: string): string {
  if (!v || typeof v === "string") return v || "";
  return v[lang] || v.en || v.de || Object.values(v)[0] || "";
}

export function Workshop() {
  const { t, i18n } = useTranslation();
  const { ui, setUi, toast, can } = useApp();
  const { data, error, reload } = useLoad(() => call("/household/workshop"), []);
  const [lines, setLines] = useState<Line[]>([]);
  const [running, setRunning] = useState(false);
  const [busyAll, setBusyAll] = useState<string | null>(null);
  const abort = useRef<AbortController | null>(null);
  const term = useRef<HTMLPreElement>(null);
  const [q, setQ] = useState("");
  useEnter(!!data);
  useEffect(() => () => abort.current?.abort(), []);
  useEffect(() => {
    if (term.current) term.current.scrollTop = term.current.scrollHeight;
  }, [lines]);
  const fn: Fn = ui.fn || "menu";
  useEffect(() => setQ(""), [fn]);

  if (error) return (<><Hero id="werk" /><LoadFail error={error} retry={reload} /></>);
  if (!data) return (<><Hero id="werk" /><Loading /></>);
  const lang = i18n.language;
  const portals: any[] = data.portals;
  const wp: string = ui.wp && portals.some((p) => p.id === ui.wp) ? ui.wp : portals[0]?.id;
  const cur = portals.find((p) => p.id === wp);
  const lim = data.limits;
  const limits = t("ui.workshop.limits", { mb: lim.memory_mb, s: lim.deadline_s });

  const out = (cls: Line[0], text: string) => setLines((l) => [...l, [cls, text]]);
  const run = async () => {
    if (!cur) return;
    abort.current = new AbortController();
    const signal = abort.current.signal;
    const get = (path: string, query?: Record<string, unknown>) => call(path, { query, signal });
    setLines([]);
    setRunning(true);
    // On a phone the output sits below the form — bring it into view.
    term.current?.closest(".term")?.scrollIntoView({ behavior: "smooth", block: "start" });
    const t0 = performance.now();
    const ms = () => Math.round(performance.now() - t0) + " ms";
    const name = pick(cur.name, lang) || cur.id;
    try {
      if (fn === "menu") {
        out("d", `→ ${name} · menu()`);
        const d = await get(`/p/${encodeURIComponent(wp)}/menu`);
        out("", (d.entries || []).map((e: any) => e.name).join(" · ") || t("ui.workshop.nothing"));
        out("d", t("ui.workshop.n_entries", { n: (d.entries || []).length }) + " · " + ms());
      } else if (fn === "list") {
        const m = await get(`/p/${encodeURIComponent(wp)}/menu`);
        const entries: any[] = m.entries || [];
        const e = q.trim() ? entries.find((x) => (x.id + " " + x.name).toLowerCase().includes(q.trim().toLowerCase())) : entries[0];
        if (!e) {
          out("e", t("ui.workshop.no_entry", { q }));
        } else {
          out("d", `→ ${name} · list("${e.name}")`);
          const d = await get(`/p/${encodeURIComponent(wp)}/list`, { entry: e.id });
          (d.items || []).slice(0, 12).forEach((x: any, i: number) => out("", `${String(i + 1).padStart(2)}  ${x.title}${x.year ? " (" + x.year + ")" : ""}${x.has_children ? " ›" : ""}`));
          out("d", t("ui.workshop.n_items", { n: (d.items || []).length }) + " · " + ms());
        }
      } else if (fn === "search") {
        out("d", `→ ${name} · search("${q}")`);
        const d = await get("/search", { q, portal: wp });
        const hits: any[] = d.hits?.[wp] || [];
        if (d.failed?.[wp]) out("e", t("ui.workshop.failed", { why: errorText(new ServerError(d.failed[wp])) }));
        hits.slice(0, 12).forEach((x: any, i: number) => out("", `${String(i + 1).padStart(2)}  ${x.title}${x.year ? " (" + x.year + ")" : ""}`));
        out("d", t("ui.workshop.n_hits", { n: hits.length }) + " · " + ms());
      } else {
        await walk(wp, name, get, out, t);
      }
    } catch (e: any) {
      out(e?.code === "net.aborted" ? "w" : "e", e?.code === "net.aborted" ? t("ui.workshop.aborted") : errorText(e));
    } finally {
      setRunning(false);
    }
  };

  const nightAll = async () => {
    setBusyAll("night");
    try {
      const r = await post("/household/nights/run");
      toast(t("ui.workshop.night_done", { carried: (r.carried || []).length, failed: (r.failed || []).length }));
    } catch (e) {
      toast(errorText(e));
    }
    setBusyAll(null);
  };
  const reread = async () => {
    setBusyAll("reload");
    try {
      await post("/household/workshop/reload");
      toast(t("ui.workshop.reloaded"));
      reload();
    } catch (e) {
      toast(errorText(e));
    }
    setBusyAll(null);
  };

  return (
    <>
      <Hero id="werk" />
      <div className="wk">
        <section className="panel w-werk">
          <div className="ph"><h3>{t("ui.workshop.run")}</h3><span className="eyebrow">{limits}</span></div>
          <div className="field">
            <label htmlFor="w-p">{t("ui.workshop.portal")}</label>
            <select className="sel" id="w-p" value={wp} onChange={(e) => setUi({ wp: e.target.value })}>
              {portals.map((p) => <option key={p.id} value={p.id}>{(pick(p.name, lang) || p.id) + (p.ready ? "" : " " + t("ui.workshop.faulty"))}</option>)}
            </select>
          </div>
          {cur && !cur.ready && cur.reason && <div className="flag bad">{cur.reason}</div>}
          <div className="field">
            <span className="lbl">{t("ui.workshop.what")}</span>
            <div className="segc">
              {(["menu", "list", "search", "walk"] as Fn[]).map((k) => (
                <button key={k} aria-pressed={fn === k} onClick={() => setUi({ fn: k })}>{t(`ui.workshop.fn_${k}`)}</button>
              ))}
            </div>
          </div>
          <div className="field">
            <label htmlFor="w-q">{fn === "search" ? t("ui.workshop.term") : fn === "list" ? t("ui.workshop.entry") : t("ui.workshop.input")}</label>
            <input className="inp" id="w-q" value={q} onChange={(e) => setQ(e.target.value)} placeholder={fn === "menu" || fn === "walk" ? t("ui.workshop.not_needed") : fn === "list" ? t("ui.workshop.first_entry") : ""} disabled={fn === "menu"} onKeyDown={(e) => e.key === "Enter" && !running && run()} />
          </div>
          <div className="row">
            <button className="btn pri" onClick={run} disabled={running || (fn === "search" && !q.trim())}><Icon k="play" /> {t("ui.workshop.start")}</button>
            <button className="btn" onClick={() => abort.current?.abort()} disabled={!running}><Icon k="stop" /> {t("ui.common.cancel")}</button>
          </div>
          <div className="sec">
            <h4>{t("ui.workshop.for_all")}</h4>
            <div className="row">
              {can("change_settings") && <button className="btn" onClick={nightAll} disabled={busyAll !== null}><Icon k="play" /> {busyAll === "night" ? t("ui.workshop.night_running") : t("ui.workshop.night_now")}</button>}
              <button className="btn" onClick={reread} disabled={busyAll !== null}><Icon k="refresh" /> {t("ui.workshop.reread")}</button>
            </div>
          </div>
        </section>
        <section className="term" aria-label={t("ui.workshop.output")}>
          <div className="tb"><i /><i /><i /><span>{t("ui.workshop.output_of", { portal: cur ? pick(cur.name, lang) || cur.id : "" })}</span></div>
          <pre ref={term}>
            <span className="d">{t("ui.workshop.ready", { limits })}</span>
            {"\n"}
            {lines.map(([c, x], i) => (
              <span key={i}>
                <span className={c} dangerouslySetInnerHTML={{ __html: esc(x) }} />
                {"\n"}
              </span>
            ))}
            {!running && (<><span className="c">$</span> <span className="cursor" /></>)}
          </pre>
        </section>
      </div>
    </>
  );
}

async function walk(pid: string, name: string, get: (p: string, q?: Record<string, unknown>) => Promise<any>, out: (c: Line[0], s: string) => void, t: (k: string, o?: any) => string) {
  const p = encodeURIComponent(pid);
  out("d", `→ ${name} · ${t("ui.workshop.fn_walk")}`);
  let t0 = performance.now();
  const lap = () => {
    const ms = Math.round(performance.now() - t0);
    t0 = performance.now();
    return ms + " ms";
  };
  const m = await get(`/p/${p}/menu`);
  const entries: any[] = m.entries || [];
  out("", `menu ✓ ${lap()} · ${entries.length}`);
  if (!entries.length) return out("e", t("ui.workshop.nothing_playable"));
  let item: any = null;
  for (const e of entries.filter((x) => /folgen|next_|neu|new/i.test(x.name)).concat(entries).slice(0, 4)) {
    const s = await get(`/p/${p}/list`, { entry: e.id });
    const items: any[] = s.items || [];
    if (!items.length) continue;
    out("", `list ✓ ${lap()} · „${e.name}“ · ${items.length}`);
    item = await descend(p, items, 0, get, out);
    if (item) break;
  }
  if (!item) return out("e", t("ui.workshop.nothing_playable"));
  out("d", `${t("ui.workshop.target")}: ${item.title}`);
  const q = await get(`/p/${p}/sources`, { address: item.address, title: item.title || "" });
  const sources: any[] = q.sources || [];
  if (!sources.length) return out("e", `sources ✗ ${t("ui.workshop.no_source")}`);
  out("", `sources ✓ ${lap()} · ${sources.length}`);
  const played = await get("/play", { portal: pid, source: sources[0].id });
  out("", `play ✓ ${lap()}`);
  try {
    const head = await fetch(played.address, { method: "HEAD" });
    const kind = head.headers.get("content-type") || "?";
    const playable = /^video\/|mpegurl|octet-stream/.test(kind);
    out(playable ? "c" : "w", `HEAD ${head.status} · ${kind} · ${playable ? t("ui.workshop.playable") : t("ui.workshop.not_video")}`);
  } catch (err: any) {
    out("w", t("ui.workshop.no_head") + " " + String(err?.message || err).slice(0, 80));
  }
}

async function descend(p: string, list: any[], depth: number, get: (p: string, q?: Record<string, unknown>) => Promise<any>, out: (c: Line[0], s: string) => void): Promise<any> {
  if (depth > 3) return null;
  for (const e of list.slice(0, 3)) {
    if (!e.has_children) return e;
    const k = await get(`/p/${p}/children`, { address: e.address, title: e.title || "" });
    const items: any[] = k.items || [];
    if (!items.length) continue;
    out("", `children ✓ · ${items.length} · „${e.title || ""}“`);
    const deeper = await descend(p, items, depth + 1, get, out);
    if (deeper) return deeper;
  }
  return null;
}
