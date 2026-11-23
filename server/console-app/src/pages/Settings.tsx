/** Einstellungen — the mockup's `pageKonto()`, `tgSection()` and `restoreSheet()`. */
import { useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { del, get, post, put, ServerError } from "../api";
import { LoadFail, Loading, useLoad } from "../data";
import { errorText, type Language, LANGUAGES, setLanguage } from "../i18n";
import { gb, ModeSeg, Sheet, uptime, useEnter } from "../Shell";
import { useApp } from "../state";
import { TGI } from "../icons";
import { Avatar, Hero, HoldButton, Icon, Switch } from "../ui";

const TG_EVENTS = ["join_requested", "portal_failing", "exit_down"] as const;

export function Settings() {
  const { t } = useTranslation();
  const { ui } = useApp();
  const { data, error, reload } = useLoad(async () => {
    const [s, tg, h, members, roles, devices, portals] = await Promise.all([
      get("/household/settings"),
      get("/household/telegram"),
      get("/health"),
      get("/household/members"),
      get("/household/roles"),
      get("/household/devices"),
      get("/household/portals"),
    ]);
    return { settings: s.settings, tg, health: h, counts: { people: members.people.length, roles: roles.roles.length, devices: devices.devices.length, portals: portals.portals.length, on: portals.portals.filter((p: any) => p.on).length } };
  }, []);
  useEnter(!!data);
  // Coming from the palette ("Telegram", "Sicherung" …): straight to that section.
  useEffect(() => {
    if (data && ui.sec) setTimeout(() => document.getElementById(ui.sec)?.scrollIntoView({ behavior: "smooth", block: "start" }), 350);
  }, [data, ui.sec]);
  if (error) return (<><Hero id="konto" /><LoadFail error={error} retry={reload} /></>);
  if (!data) return (<><Hero id="konto" /><Loading /></>);
  const toc = [["s-tg", t("ui.settings.notifications")], ["s-bk", t("ui.settings.backup")], ["s-hh", t("ui.settings.household")], ["s-sv", t("ui.settings.service")], ["s-br", t("ui.settings.browser")]];
  return (
    <>
      <Hero id="konto" />
      <div className="set">
        <nav className="toc" aria-label={t("ui.settings.sections")}>
          {toc.map(([id, n]) => (
            <button key={id} onClick={() => document.getElementById(id)?.scrollIntoView({ behavior: "smooth", block: "start" })}>{n}</button>
          ))}
        </nav>
        <div className="setc">
          <Telegram state={data.tg} reload={reload} household={data.settings["haus.name"] || "CineLounge"} />
          <Backup counts={data.counts} />
          <HouseName value={data.settings["haus.name"] || ""} reload={reload} />
          <Service h={data.health} counts={data.counts} />
          <Browser />
        </div>
      </div>
    </>
  );
}

function Telegram({ state, reload, household }: { state: any; reload: () => void; household: string }) {
  const { t, i18n } = useTranslation();
  const { toast } = useApp();
  const [token, setToken] = useState("");
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [cands, setCands] = useState<any[]>([]);
  const [skipped, setSkipped] = useState<Set<string>>(new Set());
  const [preview, setPreview] = useState<Record<string, string>>({});
  const waiting = state.token_set && !state.connected;
  const st: "off" | "wait" | "found" | "on" = state.connected ? "on" : waiting ? (cands.filter((c) => !skipped.has(c.id)).length ? "found" : "wait") : "off";
  const bot = state.bot?.username || "";

  // While waiting: ask the server again and again (each call waits up to 20 s).
  const alive = useRef(true);
  useEffect(() => {
    alive.current = true;
    if (!waiting) return;
    let stop = false;
    (async () => {
      while (!stop && alive.current) {
        try {
          const r = await post("/household/telegram/wait");
          if (stop) break;
          setCands(r.candidates || []);
          if ((r.candidates || []).some((c: any) => !skipped.has(c.id))) break;
        } catch (e) {
          if (stop) break;
          setErr(errorText(e));
          await new Promise((r) => setTimeout(r, 3000));
        }
      }
    })();
    return () => {
      stop = true;
      alive.current = false;
    };
  }, [waiting, skipped]);

  useEffect(() => {
    if (st !== "on") return;
    get("/household/telegram/preview").then((r) => setPreview(r.messages)).catch(() => {});
  }, [st, state.language]);

  const check = async () => {
    setErr(null);
    setBusy(true);
    try {
      await post("/household/telegram/check", { token: token.trim(), language: i18n.language });
      setToken("");
      setCands([]);
      setSkipped(new Set());
      reload();
    } catch (e) {
      setErr(errorText(e));
    } finally {
      setBusy(false);
    }
  };
  const connect = async (id: string) => {
    try {
      await post("/household/telegram/chat", { chat: id });
      toast(t("ui.tg.connected_toast"));
      reload();
    } catch (e) {
      setErr(errorText(e));
    }
  };
  const setEvents = async (k: string, on: boolean) => {
    const next = on ? [...state.events, k] : state.events.filter((x: string) => x !== k);
    try {
      await put("/household/telegram/events", { events: next });
      reload();
    } catch (e) {
      toast(errorText(e));
    }
  };
  const test = async () => {
    try {
      await post("/household/telegram/test");
      toast(t("ui.tg.test_sent"));
      reload();
    } catch (e) {
      toast(errorText(e));
    }
  };
  const disconnect = async () => {
    try {
      await del("/household/telegram");
      toast(t("ui.tg.disconnected"));
      reload();
    } catch (e) {
      toast(errorText(e));
    }
  };
  const otherToken = async () => {
    await del("/household/telegram").catch(() => {});
    setCands([]);
    reload();
  };

  const steps = (
    <ol className="tg-steps" aria-label={t("ui.tg.steps")}>
      <li className={st === "off" ? "on" : ""}>{t("ui.tg.step1")}</li>
      <li className={st === "wait" || st === "found" ? "on" : ""}>{t("ui.tg.step2")}</li>
      <li>{t("ui.tg.step3")}</li>
    </ol>
  );
  const shown = cands.filter((c) => !skipped.has(c.id));

  return (
    <section className="panel w-konto" id="s-tg">
      <div className="ph">
        <h3>{t("ui.settings.notifications")}</h3>
        <span className={"chip " + (st === "on" ? "ok" : "")}>{st === "on" ? t("ui.tg.chip_on") : t("ui.tg.chip_off")}</span>
      </div>
      {st === "off" && (
        <>
          <p className="lead">{t("ui.tg.lead")}</p>
          {steps}
          <div className="field">
            <label htmlFor="tg-token">{t("ui.tg.token")}</label>
            <div className="row">
              <input className={"inp" + (err ? " err" : "")} id="tg-token" autoComplete="off" spellCheck={false} placeholder="123456789:AAH…" value={token} onChange={(e) => setToken(e.target.value)} onKeyDown={(e) => e.key === "Enter" && check()} aria-describedby="tg-msg" style={{ flex: 1, minWidth: "min(100%,260px)", fontFamily: "var(--fm)" }} />
              <button className="btn pri" onClick={check} disabled={busy || !token.trim()}>{busy ? t("ui.tg.checking") : t("ui.tg.check")}</button>
            </div>
          </div>
          <p className="hint" id="tg-msg" style={err ? { color: "var(--bad)" } : undefined}>{err || t("ui.tg.token_hint")}</p>
          <details className="tg-help">
            <summary>{t("ui.tg.help_title")}</summary>
            <ol>
              <li dangerouslySetInnerHTML={{ __html: t("ui.tg.help1") }} />
              <li dangerouslySetInnerHTML={{ __html: t("ui.tg.help2") }} />
              <li>{t("ui.tg.help3")}</li>
            </ol>
            <p className="hint" style={{ marginBottom: 10 }} dangerouslySetInnerHTML={{ __html: t("ui.tg.help_lost") }} />
          </details>
        </>
      )}
      {st === "wait" && (
        <>
          {steps}
          <div className="row">
            <span className="tgbot"><span style={{ display: "contents" }} dangerouslySetInnerHTML={{ __html: TGI }} /> @{bot}</span>
            <span className="chip ok">{t("ui.tg.token_ok")}</span>
          </div>
          <div className="tg-wait" aria-live="polite">
            <i />
            <span dangerouslySetInnerHTML={{ __html: t("ui.tg.write_start", { bot: `<b>@${bot}</b>` }) }} />
          </div>
          <div className="row">
            <a className="btn pri" href={`https://t.me/${bot}`} target="_blank" rel="noopener">{t("ui.tg.open")}</a>
            <button className="copyname" onClick={() => navigator.clipboard?.writeText("@" + bot).then(() => toast(t("ui.tg.copied")))}>{t("ui.tg.copy", { bot: "@" + bot })}</button>
          </div>
          {err && <p className="hint" style={{ color: "var(--bad)" }}>{err}</p>}
          <p className="hint" dangerouslySetInnerHTML={{ __html: t("ui.tg.wait_hint", { bot: `<b>@${bot}</b>` }) }} />
          <button className="linkbtn" onClick={otherToken}>{t("ui.tg.other_token")}</button>
        </>
      )}
      {st === "found" && (
        <>
          {steps}
          {shown.slice(0, 1).map((c) => (
            <div key={c.id}>
              <div className="toggle-row">
                <div>
                  <b>{t(c.type === "private" ? "ui.tg.wrote" : "ui.tg.group_wrote", { name: c.title })}</b>
                  <small>{t("ui.tg.just_now_start")}</small>
                </div>
                <Avatar name={c.title} color="#2aabee" />
              </div>
              <p className="hint">{t("ui.tg.only_this_chat")}</p>
              <div className="row">
                <button className="btn pri" onClick={() => connect(c.id)}>{t("ui.tg.yes_me")}</button>
                <button className="btn" onClick={() => setSkipped(new Set([...skipped, c.id]))}>{t("ui.tg.no_wait")}</button>
              </div>
            </div>
          ))}
        </>
      )}
      {st === "on" && (
        <>
          <div className="row">
            <span className="tgbot"><span style={{ display: "contents" }} dangerouslySetInnerHTML={{ __html: TGI }} /> @{bot}</span>
            <span className="chip ok">{t("ui.tg.connected_to", { name: state.chat?.title || "" })}</span>
          </div>
          {state.last_error && <div className="flag bad">{t("ui.tg.last_error", { why: errorText(new ServerError(state.last_error)) })}</div>}
          <div className="rights">
            {TG_EVENTS.map((k) => (
              <div key={k} className="toggle-row">
                <div>
                  <b>{t(`ui.tg.ev_${k}`)}</b>
                  <small>{t(`ui.tg.ev_${k}_hint`)}</small>
                </div>
                <Switch on={state.events.includes(k)} label={t(`ui.tg.ev_${k}`)} onChange={(on) => setEvents(k, on)} />
              </div>
            ))}
          </div>
          <div className="field">
            <span className="lbl">{t("ui.tg.looks_like")}</span>
            <div className="tg-chat">
              {state.events.length ? (
                TG_EVENTS.filter((k) => state.events.includes(k)).map((k) => (
                  <div key={k} className="tg-bub">
                    <b>CineLounge · {household}</b>
                    <br />
                    {(preview[k] || "").split("\n").map((l, i) => (
                      <span key={i}>
                        {i > 0 && <br />}
                        {l}
                      </span>
                    ))}
                    <small>{t("ui.tg.example")}</small>
                  </div>
                ))
              ) : (
                <div className="tg-bub">{t("ui.tg.all_off")}</div>
              )}
            </div>
            <p className="hint">{t("ui.tg.texts_hint", { lang: t(`ui.lang.${state.language}`) })}</p>
          </div>
          <p className="hint" dangerouslySetInnerHTML={{ __html: t("ui.tg.group_hint") }} />
          <div className="row">
            <button className="btn" onClick={test}>{t("ui.tg.test")}</button>
            <HoldButton label={t("ui.tg.hold_disconnect")} onDone={disconnect} />
          </div>
        </>
      )}
    </section>
  );
}

function Backup({ counts }: { counts: any }) {
  const { t } = useTranslation();
  const { toast, setLayer } = useApp();
  const file = useRef<HTMLInputElement>(null);
  const download = async () => {
    try {
      await downloadBackup(t);
      toast(t("ui.backup.downloaded"));
    } catch (e) {
      toast(errorText(e));
    }
  };
  const chosen = async (f: File | undefined) => {
    if (!f) return;
    try {
      const data = JSON.parse(await f.text());
      if (!data || typeof data !== "object" || !data.tables) throw new Error("x");
      setLayer(<RestoreSheet name={f.name} data={data} counts={counts} />);
    } catch {
      toast(t("ui.backup.not_a_backup"));
    }
    if (file.current) file.current.value = "";
  };
  return (
    <section className="panel w-konto" id="s-bk">
      <div className="ph"><h3>{t("ui.settings.backup")}</h3></div>
      <p className="hint">{t("ui.backup.hint")}</p>
      <div className="row">
        <button className="btn" onClick={download}><Icon k="download" /> {t("ui.backup.download")}</button>
        <label className="btn"><Icon k="upload" /> {t("ui.backup.restore")}<input ref={file} type="file" accept=".json" hidden onChange={(e) => chosen(e.target.files?.[0])} /></label>
      </div>
    </section>
  );
}

async function downloadBackup(_t: unknown): Promise<void> {
  const data = await get("/household/backup");
  const blob = new Blob([JSON.stringify(data, null, 2)], { type: "application/json" });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = `cinelounge-${new Date().toISOString().slice(0, 10)}.json`;
  a.click();
  URL.revokeObjectURL(a.href);
}

function RestoreSheet({ name, data, counts }: { name: string; data: any; counts: any }) {
  const { t, i18n } = useTranslation();
  const { setLayer } = useApp();
  const [msg, setMsg] = useState<string | null>(null);
  const tb = data.tables || {};
  const n = (k: string) => (Array.isArray(tb[k]) ? tb[k].length : 0);
  const date = data.created ? new Date(data.created * 1000).toLocaleDateString(i18n.language) : "—";
  const backupNow = () => downloadBackup(t);
  const switchedOn = Array.isArray(tb.portal_switch) ? tb.portal_switch.filter((r: any) => r.on_air).length : 0;
  const go = async () => {
    try {
      await post("/household/restore", { data, replace: true });
      // The household from the file holds now — including who may sign in.
      location.reload();
    } catch (e) {
      setMsg(errorText(e));
    }
  };
  return (
    <Sheet>
      <span className="eyebrow w-konto">{t("ui.backup.restore_eyebrow")}</span>
      <h3>{t("ui.backup.replace_all")}</h3>
      <p className="lead" dangerouslySetInnerHTML={{ __html: t("ui.backup.lead", { name: `<b>${name.replace(/[<>&]/g, "")}</b>`, date }) }} />
      <dl className="dl">
        <dt>{t("ui.household.people")}</dt><dd>{t("ui.backup.instead", { a: n("person"), b: counts.people })}</dd>
        <dt>{t("ui.household.roles")}</dt><dd>{t("ui.backup.instead", { a: n("role") || "—", b: counts.roles })}</dd>
        <dt>{t("ui.household.devices")}</dt><dd>{t("ui.backup.instead", { a: n("device"), b: counts.devices })}</dd>
        <dt>{t("ui.backup.switched_on")}</dt><dd>{t("ui.backup.instead", { a: switchedOn, b: counts.on })}</dd>
      </dl>
      <div className="flag bad">{t("ui.backup.flag", { date })}</div>
      <div className="row">
        <button className="btn" onClick={backupNow}><Icon k="download" /> {t("ui.backup.first_save")}</button>
        <span className="hint">{t("ui.backup.first_save_hint")}</span>
      </div>
      {msg && <div className="flag bad">{msg}</div>}
      <div className="req-act">
        <HoldButton label={t("ui.backup.hold_replace")} onDone={go} />
        <button className="btn ghost" onClick={() => setLayer(null)}>{t("ui.common.cancel")}</button>
      </div>
    </Sheet>
  );
}

function HouseName({ value, reload }: { value: string; reload: () => void }) {
  const { t } = useTranslation();
  const { toast } = useApp();
  const [v, setV] = useState(value);
  const save = async () => {
    try {
      await put("/household/settings", { settings: { "haus.name": v.trim() } });
      toast(t("ui.settings.name_saved"));
      reload();
    } catch (e) {
      toast(errorText(e));
    }
  };
  return (
    <section className="panel w-konto" id="s-hh">
      <div className="ph"><h3>{t("ui.settings.household")}</h3></div>
      <div className="field">
        <label htmlFor="hh-n">{t("ui.settings.household_name")}</label>
        <div className="row">
          <input className="inp" id="hh-n" value={v} placeholder="CineLounge" maxLength={60} onChange={(e) => setV(e.target.value)} onKeyDown={(e) => e.key === "Enter" && save()} />
          <button className="btn" onClick={save} disabled={v.trim() === value}>{t("ui.common.save")}</button>
        </div>
      </div>
      <p className="hint">{t("ui.settings.name_hint")}</p>
    </section>
  );
}

function Service({ h, counts }: { h: any; counts: any }) {
  const { t } = useTranslation();
  const { health } = useApp();
  const ok = !health || health.ok;
  return (
    <section className="panel w-konto" id="s-sv">
      <div className="ph"><h3>{t("ui.settings.service")}</h3><span className={"chip " + (ok ? "ok" : "bad")}>{ok ? t("ui.service.reachable") : t("ui.shell.unreachable")}</span></div>
      <dl className="dl">
        <dt>{t("ui.service.version")}</dt><dd>{h.version}</dd>
        <dt>{t("ui.service.uptime")}</dt><dd>{uptime(t, (health?.data ?? h).uptime_s)}</dd>
        <dt>{t("ui.service.runner")}</dt><dd>{h.fork ? t("ui.service.fork_on") : t("ui.service.fork_off")}</dd>
        <dt>{t("ui.service.people_devices")}</dt><dd>{counts.people} · {counts.devices}</dd>
        <dt>{t("ui.service.stock")}</dt><dd>{t("ui.service.stock_of", { n: h.buffer?.stock ?? 0, size: gb(h.buffer?.stock_bytes ?? 0), limit: gb(h.buffer?.stock_limit_bytes ?? 0) })}</dd>
        <dt>{t("ui.service.readable")}</dt><dd>{t("ui.service.readable_value", { n: h.portals, broken: (h.broken || []).length })}</dd>
        <dt>{t("ui.service.exits")}</dt><dd>{t("ui.service.exits_value", { n: h.exits ?? 0 })}</dd>
      </dl>
    </section>
  );
}

function Browser() {
  const { t, i18n } = useTranslation();
  return (
    <section className="panel w-konto" id="s-br">
      <div className="ph"><h3>{t("ui.settings.browser")}</h3><span className="eyebrow">{t("ui.settings.only_here")}</span></div>
      <div className="grid2">
        <div className="field">
          <span className="lbl">{t("ui.settings.language")}</span>
          <span className="mini-seg">
            {LANGUAGES.map((k) => (
              <button key={k} aria-pressed={i18n.language === k} onClick={() => setLanguage(k as Language)}>{t(`ui.lang.${k}`)}</button>
            ))}
          </span>
        </div>
        <div className="field">
          <span className="lbl">{t("ui.mode.label")}</span>
          <ModeSeg />
        </div>
      </div>
      <p className="hint">{t("ui.settings.lang_hint")}</p>
    </section>
  );
}
