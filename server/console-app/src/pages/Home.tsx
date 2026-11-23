/** Übersicht — the mockup's `pageHome()`. */
import { useEffect } from "react";
import { useTranslation } from "react-i18next";
import { get } from "../api";
import { LoadFail, Loading, useLoad } from "../data";
import { Slot } from "../extension";
import { eventHtml } from "../i18n";
import { exitWhy, failedLast, isLegacyPerson, loadAll, routeLabel, strip } from "../model";
import { startDust } from "../motion";
import { useEnter } from "../Shell";
import { useApp } from "../state";
import { type AreaId, Hero, isOutside, Marks, Roll, stripOk, stripTotal } from "../ui";

type Att = { w: AreaId; ico: string; t: string; s: string; go: AreaId; ui?: Record<string, string>; btn: string; n?: number };

export function Home() {
  const { t, i18n } = useTranslation();
  const { go, dark } = useApp();
  const { data, error, reload } = useLoad(async () => {
    const [all, door, events] = await Promise.all([loadAll(), get("/household/door"), get("/household/events", { limit: 7 })]);
    return { ...all, door, events: events.events as any[] };
  }, []);
  useEnter(!!data);
  useEffect(() => {
    if (!data) return;
    return startDust(document.getElementById("dust") as HTMLCanvasElement | null, dark);
  }, [data, dark]);

  if (error) return (<><Hero id="home" /><LoadFail error={error} retry={reload} /></>);
  if (!data) return (<><Hero id="home" /><Loading /></>);

  const { portals, roles, people, devices, nights, exits, withoutExit, door } = data;
  const joins = door.items.filter((x: any) => x.type === "join" && !x.expired);
  const on = portals.filter((p) => p.on);
  // A portal waiting for a value is named apart: it is a task, not a defect.
  const setup = portals.filter((p) => p.state === "needs_setting");
  const broken = portals.filter((p) => p.state !== "ready" && p.state !== "needs_setting");
  const exitRows = [{ id: "direct", state: "running" as const, portals: [] as string[], why: "", ms: null }, ...exits];
  const okEx = exitRows.filter((e) => e.state === "running").length;
  const portalsOn = (net: string) => portals.filter((p) => p.on && p.exit_net === net).length;

  const att: Att[] = [];
  if (joins.length)
    att.push({
      w: "einlass", ico: "einlass", go: "einlass", btn: t("ui.home.to_door"), n: joins.length,
      t: t("ui.home.joins_waiting", { count: joins.length }),
      s: joins.map((j: any) => `${j.name} (${isOutside(j.from) ? t("ui.door.outside_short") : t("ui.door.home_short")})`).join(", "),
    });
  // One line per cause, not per portal (redesign 09.11.2026, approved variant A):
  // two dead exits and four broken portals were seven look-alike rows.
  const down = exits.filter((e) => e.state !== "running");
  if (down.length)
    att.push({
      w: "netz", ico: "netz", go: "netz", btn: t("ui.home.to_network"), n: down.length,
      t: t("ui.home.exits_down_n", { count: down.length }),
      s: down.map((e) => routeLabel(t, e.id)).join(", ") + " · " + exitWhy(t, down[0].why, down[0].state) + " · " + t("ui.home.affected", { count: down.reduce((a, e) => a + portalsOn(e.id), 0) }),
    });
  const failing = on.filter((p) => failedLast(nights, p.id) && p.state === "ready");
  const noExit = withoutExit.map((w) => portals.find((x) => x.id === w.id)).filter((p): p is (typeof portals)[number] => !!p?.on);
  const problems = broken.length + setup.length + failing.length + noExit.length;
  if (problems) {
    const parts: string[] = [];
    if (failing.length) parts.push(t("ui.home.part_failing", { list: failing.map((p) => p.name).join(", ") }));
    if (broken.length) parts.push(t("ui.home.part_broken", { list: broken.map((p) => p.name).join(", ") }));
    if (setup.length) parts.push(t("ui.home.part_needs_setting", { list: setup.map((p) => p.name).join(", ") }));
    if (noExit.length) parts.push(t("ui.home.part_noexit", { list: noExit.map((p) => p.name).join(", ") }));
    att.push({ w: "portale", ico: "alert", go: "portale", ui: { pf: "fault" }, btn: t("ui.home.show"), n: problems, t: t("ui.home.portals_problems", { count: problems }), s: parts.join(" · ") });
  }
  people.filter((p) => isLegacyPerson(p, devices)).forEach((p) =>
    att.push({ w: "haushalt", ico: "haushalt", go: "haushalt", ui: { tab: "ppl", sel: p.id }, btn: t("ui.home.look"), n: 1, t: t("ui.home.legacy", { name: p.name }), s: t("ui.home.legacy_sub") }),
  );

  const kpis = [
    { w: "portale" as AreaId, k: t("ui.home.kpi_on_air"), v: on.length, m: portals.length, s: t("ui.home.kpi_on_air_sub", { broken: broken.length, noexit: withoutExit.length }) },
    { w: "einlass" as AreaId, k: t("ui.area.einlass.name"), v: door.counts.join + door.counts.code + door.counts.invite, s: t("ui.home.kpi_door_sub", { join: door.counts.join, code: door.counts.code, invite: door.counts.invite }) },
    { w: "haushalt" as AreaId, k: t("ui.area.haushalt.name"), v: people.length, s: t("ui.home.kpi_household_sub", { roles: roles.length, console: people.filter((p) => p.console).length }) },
    { w: "netz" as AreaId, k: t("ui.home.kpi_exits"), v: okEx, m: exitRows.length, s: okEx < exitRows.length ? t("ui.home.kpi_exits_down", { n: exitRows.length - okEx }) : t("ui.home.kpi_exits_all") },
  ];

  const names = Object.fromEntries(portals.map((p) => [p.id, p.name]));
  const lastRun = Object.values(nights.last).map((l) => l.night).sort().pop();
  const evTime = (at: number) => {
    const d = new Date(at * 1000);
    const today = new Date();
    if (d.toDateString() === today.toDateString()) return d.toLocaleTimeString(i18n.language, { hour: "2-digit", minute: "2-digit" });
    const y = new Date(today);
    y.setDate(today.getDate() - 1);
    if (d.toDateString() === y.toDateString()) return t("ui.time.yesterday");
    return d.toLocaleDateString(i18n.language, { day: "2-digit", month: "2-digit" });
  };

  return (
    <>
      <Hero id="home" />
      <div className="kpis">
        {kpis.map((x) => (
          <button key={x.w} className={"kpi w-" + x.w} onClick={() => go(x.w)}>
            <span className="k">{x.k}</span>
            <span className="v at">
              <Roll n={x.v} />
              {x.m !== undefined && <small>/ {x.m}</small>}
            </span>
            <span className="s">{x.s}</span>
          </button>
        ))}
      </div>
      <div className="home-grid">
        <div className="col">
          <section className="panel w-home">
            <div className="ph">
              <h3>{t("ui.home.attention")}</h3>
              <span className={"chip " + (att.length ? "warn" : "ok")}>{t("ui.home.topics", { count: att.length })}</span>
            </div>
            {att.length ? (
              <div className="list">
                {att.map((x, i) => (
                  <div key={i} className={"cause w-" + x.w}>
                    <span className="n at">{x.n ?? 1}</span>
                    <div>
                      <b>{x.t}</b>
                      <small>{x.s}</small>
                    </div>
                    <button className="btn" onClick={() => go(x.go, x.ui)}>{x.btn}</button>
                  </div>
                ))}
              </div>
            ) : (
              <div className="empty">{t("ui.home.all_fine")}</div>
            )}
          </section>
          <section className="panel w-werk">
            <div className="ph">
              <h3>{t("ui.home.nightly")}</h3>
              <span className="eyebrow">{lastRun ? t("ui.home.nightly_sub", { n: nights.nights, last: lastRun.split("-").reverse().slice(0, 2).join(".") + "." }) : t("ui.home.nightly_never")}</span>
            </div>
            <div className="nights">
              {on.map((p) => {
                const s = strip(nights, p.id);
                return (
                  <button key={p.id} className="nrow" onClick={() => go("portale", { pid: p.id })}>
                    <span className="nm">{p.name}</span>
                    <Marks s={s} />
                    <span className="cnt">{stripOk(s)}/{stripTotal(s)}</span>
                  </button>
                );
              })}
            </div>
            <p className="hint">{t("ui.home.nightly_hint")}</p>
          </section>
        </div>
        <div className="col">
          <section className="panel w-netz">
            <div className="ph">
              <h3>{t("ui.home.kpi_exits")}</h3>
              <button className="btn ghost sm" onClick={() => go("netz")}>{t("ui.home.to_network")}</button>
            </div>
            <div>
              {exitRows.map((e) => (
                <div key={e.id} className="exit">
                  <span className="fl">{e.id === "direct" ? "··" : e.id.toUpperCase()}</span>
                  <div>
                    <b>{routeLabel(t, e.id)}</b>
                    <small>{(e.id === "direct" ? t("ui.network.direct_sub") : e.id.toUpperCase()) + " · " + t("ui.home.portals_n", { count: portalsOn(e.id === "direct" ? "direct" : e.id) })}</small>
                  </div>
                  {e.state === "running" ? (
                    e.ms != null ? <span className="ms" style={{ color: "var(--ok)" }}>{e.ms} ms</span> : <span className="chip ok">{t("ui.network.running")}</span>
                  ) : (
                    <span className="chip bad">{exitWhy(t, e.why, e.state)}</span>
                  )}
                </div>
              ))}
            </div>
          </section>
          <section className="panel w-konto">
            <div className="ph">
              <h3>{t("ui.home.recent")}</h3>
              <span className="eyebrow">{t("ui.home.events")}</span>
            </div>
            <div>
              {data.events.slice(0, 7).map((ev, i) => (
                <div key={i} className="ev">
                  <time>{evTime(ev.at)}</time>
                  <span dangerouslySetInnerHTML={{ __html: eventHtml(ev.code, ev.values, names) }} />
                </div>
              ))}
              {!data.events.length && <div className="empty">{t("ui.home.no_events")}</div>}
            </div>
          </section>
        </div>
      </div>
      <Slot name="home" />
    </>
  );
}
