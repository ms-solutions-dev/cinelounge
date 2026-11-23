/**
 * The frame: icon rail (bottom nav on a phone), glass top bar with search and
 * the live service dot, the page, and the layers on top. Markup as in the
 * mockup's `mount()` / `paintChrome()`.
 */
import { createContext, type ReactNode, useContext, useEffect, useLayoutEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { get } from "./api";
import { enterAnim, layerIn } from "./motion";
import { ToastHost, type Mode, useApp } from "./state";
import { routeLabel } from "./model";
import { type AreaId, AREAS, Avatar, Icon, Logo, MORE_AREAS } from "./ui";

const PageReady = createContext<(ready: boolean) => void>(() => {});

/** A page calls this once its data is there; the entrance animation runs then. */
export function useEnter(ready: boolean) {
  const notify = useContext(PageReady);
  useLayoutEffect(() => notify(ready), [ready, notify]);
}

export function Shell({ children }: { children: ReactNode }) {
  const { t } = useTranslation();
  const app = useApp();
  const { page, go, door, dark, setNarrow, narrow, layer, setLayer, health, me } = app;
  const appEl = useRef<HTMLDivElement>(null);
  const pg = useRef<HTMLElement>(null);
  const animated = useRef<string>("");

  useEffect(() => {
    const el = appEl.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setNarrow(el.clientWidth <= 760));
    ro.observe(el);
    return () => ro.disconnect();
  }, [setNarrow]);

  // Ctrl+K: the palette.
  useEffect(() => {
    const f = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        setLayer(<Palette />);
      }
    };
    document.addEventListener("keydown", f);
    return () => document.removeEventListener("keydown", f);
  }, [setLayer]);

  const key = page + ":" + (app.ui.pid || "");
  const ready = (r: boolean) => {
    if (r && pg.current && animated.current !== key) {
      animated.current = key;
      enterAnim(pg.current);
    }
  };
  const more = MORE_AREAS;
  const svcOk = !health || health.ok;
  const area = (id: AreaId) => t(`ui.area.${id}.name`);

  return (
    <div className="frame">
      <div className="app" data-mode={dark ? "dark" : "light"} ref={appEl}>
        <nav className="rail" aria-label={t("ui.shell.areas")}>
          <button className="logo" onClick={() => go("home")} aria-label={t("ui.shell.logo")}>
            <Logo />
          </button>
          {AREAS.filter((a) => a !== "konto").map((a, i) => (
            <RailButton key={a} id={a} sep={i === 3} current={page === a} badge={a === "einlass" ? door.total : 0} label={area(a)} onClick={() => go(a)} />
          ))}
          <span className="rspace" />
          <RailButton id="konto" current={page === "konto"} label={area("konto")} onClick={() => go("konto")} />
          <button
            className="me"
            style={{ background: me.color }}
            aria-label={t("ui.shell.account", { name: me.name })}
            aria-haspopup="menu"
            onClick={() => setLayer(<AccountMenu />)}
          >
            {me.name.charAt(0).toUpperCase()}
          </button>
        </nav>
        <div className={"main w-" + page}>
          <header className="top">
            <button className="logo mlogo" onClick={() => go("home")} aria-label={area("home")}>
              <Logo />
            </button>
            <div className="crumb">
              <b>{area(page)}</b>
              <span>{t(`ui.area.${page}.sub`)}</span>
            </div>
            <button className="search" aria-label={t("ui.shell.search")} onClick={() => setLayer(<Palette />)}>
              <Icon k="search" />
              <span className="tx">{t("ui.shell.search_dots")}</span>
              <kbd>{t("ui.shell.ctrl_k")}</kbd>
            </button>
            <button className={"svc" + (svcOk ? "" : " busy")} aria-label={t("ui.shell.service")} onClick={() => setLayer(<ServicePop />)}>
              <i style={svcOk ? undefined : { background: "var(--bad)", animation: "none" }} />
              <span className="tx">{svcOk ? t("ui.shell.reachable_ms", { ms: health?.ms ?? "…" }) : t("ui.shell.unreachable")}</span>
            </button>
          </header>
          <main className="pg" ref={pg}>
            <PageReady.Provider value={ready}>{children}</PageReady.Provider>
          </main>
          <nav className="botnav" aria-label={t("ui.shell.areas")}>
            {(["home", "einlass", "haushalt", "portale"] as AreaId[]).map((id) => (
              <button key={id} className={"bn w-" + id} aria-current={page === id ? "page" : undefined} onClick={() => go(id)}>
                <Icon k={id} />
                <span>{area(id)}</span>
                {id === "einlass" && door.total > 0 && <span className="bdg">{door.total}</span>}
              </button>
            ))}
            <button className={"bn w-" + page} aria-current={more.includes(page) ? "page" : undefined} onClick={() => setLayer(<MoreMenu />)}>
              <Icon k="mehr" />
              <span>{t("ui.shell.more")}</span>
            </button>
          </nav>
        </div>
        <div id="layer">{layer && <LayerIn narrow={narrow}>{layer}</LayerIn>}</div>
        <ToastHost bind={app.toastRef} />
      </div>
    </div>
  );
}

function RailButton({ id, current, label, onClick, badge = 0, sep }: { id: AreaId; current: boolean; label: string; onClick: () => void; badge?: number; sep?: boolean }) {
  return (
    <>
      {sep && <span className="rsep" />}
      <button className={"rl w-" + id} aria-current={current ? "page" : undefined} aria-label={label} onClick={onClick}>
        <Icon k={id} />
        {badge > 0 && <span className="bdg">{badge}</span>}
        <span className="tip">{label}</span>
      </button>
    </>
  );
}

/** Wraps a layer so it slides in the way the mockup's `layer()` does. */
function LayerIn({ children, narrow }: { children: ReactNode; narrow: boolean }) {
  const ref = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    layerIn(ref.current?.querySelector(".menu,.pop,.palette,.sheet") ?? null, narrow);
  }, [children, narrow]);
  return (
    <div ref={ref} style={{ display: "contents" }}>
      {children}
    </div>
  );
}

export function ModeSeg() {
  const { t } = useTranslation();
  const { mode, setMode } = useApp();
  return (
    <span className="mini-seg">
      {(["light", "dark", "system"] as Mode[]).map((k) => (
        <button key={k} aria-pressed={mode === k} onClick={() => setMode(k)}>
          {t(`ui.mode.${k}`)}
        </button>
      ))}
    </span>
  );
}

function AccountMenu() {
  const { t } = useTranslation();
  const { me, go, setLayer, signOut } = useApp();
  return (
    <>
      <div className="scrim" onClick={() => setLayer(null)} />
      <div className="menu" role="menu">
        <div className="who">
          <Avatar name={me.name} color={me.color} />
          <div>
            <b>{me.name}</b>
            <small>{t("ui.shell.console_holder")}</small>
          </div>
        </div>
        <button className="mi" role="menuitem" onClick={() => go("konto")}>
          {t("ui.area.konto.name")}
        </button>
        <div className="mi sub">
          <span>{t("ui.mode.label")}</span>
          <ModeSeg />
        </div>
        <button className="mi" role="menuitem" onClick={signOut}>
          {t("ui.shell.sign_out")}
        </button>
      </div>
    </>
  );
}

function MoreMenu() {
  const { t } = useTranslation();
  const { me, go, setLayer, signOut } = useApp();
  return (
    <>
      <div className="scrim" onClick={() => setLayer(null)} />
      <div className="menu" role="menu">
        {MORE_AREAS.map((id) => (
          <button key={id} className="mi" role="menuitem" onClick={() => go(id)}>
            <span>{t(`ui.area.${id}.name`)}</span>
            <span className="hint">{t(`ui.area.${id}.sub`).split(" · ")[0]}</span>
          </button>
        ))}
        <div className="mi sub">
          <span>{t("ui.mode.label")}</span>
          <ModeSeg />
        </div>
        <button className="mi" role="menuitem" onClick={signOut}>
          {t("ui.shell.sign_out_as", { name: me.name })}
        </button>
      </div>
    </>
  );
}

export function uptime(t: (k: string, o?: any) => string, s: number): string {
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  return h ? t("ui.time.uptime_hm", { h, m }) : t("ui.time.uptime_m", { m });
}

export function gb(bytes: number): string {
  return (bytes / 1e9).toLocaleString(undefined, { maximumFractionDigits: 1 }) + " GB";
}

function ServicePop() {
  const { t } = useTranslation();
  const { setLayer, health } = useApp();
  const h = health?.data;
  return (
    <>
      <div className="scrim" onClick={() => setLayer(null)} />
      <div className="pop" role="dialog" aria-label={t("ui.shell.service")}>
        <h4>{health?.ok === false ? t("ui.service.down") : t("ui.service.up")}</h4>
        {h && (
          <dl>
            <dt>{t("ui.service.answer")}</dt>
            <dd>{health?.ok ? health.ms + " ms" : "—"}</dd>
            <dt>{t("ui.service.uptime")}</dt>
            <dd>{uptime(t, h.uptime_s)}</dd>
            <dt>{t("ui.service.version")}</dt>
            <dd>{h.version}</dd>
            <dt>{t("ui.service.runner")}</dt>
            <dd>{h.fork ? t("ui.service.fork_on") : t("ui.service.fork_off")}</dd>
            <dt>{t("ui.service.stock")}</dt>
            <dd>{t("ui.service.stock_value", { n: h.buffer?.stock ?? 0, size: gb(h.buffer?.stock_bytes ?? 0) })}</dd>
            <dt>{t("ui.service.exits")}</dt>
            <dd>{t("ui.service.exits_value", { n: h.exits ?? 0 })}</dd>
          </dl>
        )}
        <p className="hint">{t("ui.service.hint")}</p>
      </div>
    </>
  );
}

type PalItem = { t: string; s: string; go: AreaId; ui?: Record<string, string> };

function Palette() {
  const { t } = useTranslation();
  const { go, setLayer, me } = useApp();
  const [q, setQ] = useState("");
  const [sel, setSel] = useState(0);
  // Areas first, then the jobs people look for by name (usability review:
  // "telegram", "sicherung", "pin" found nothing).
  const [items, setItems] = useState<PalItem[]>(() => [
    ...AREAS.map((a) => ({ t: t(`ui.area.${a}.name`), s: t("ui.palette.area"), go: a })),
    ...(
      [
        ["ui.palette.a_code", "einlass", { compose: "code" }],
        ["ui.palette.a_invite", "einlass", { compose: "invite" }],
        ["ui.palette.a_role", "haushalt", { tab: "rol" }],
        ["ui.palette.a_pin", "haushalt", { tab: "ppl", sel: me.id }],
        ["ui.palette.a_telegram", "konto", { sec: "s-tg" }],
        ["ui.palette.a_backup", "konto", { sec: "s-bk" }],
        ["ui.palette.a_name", "konto", { sec: "s-hh" }],
        ["ui.palette.a_language", "konto", { sec: "s-br" }],
        ["ui.palette.a_night", "werk", {}],
      ] as [string, AreaId, Record<string, string>][]
    ).map(([k, g, u]) => ({ t: t(k), s: t("ui.palette.action"), go: g, ui: u })),
  ]);
  const input = useRef<HTMLInputElement>(null);
  // Focus right away and once more after the layer has settled: the palette's
  // node is moved once while it mounts, which drops the focus to <body>
  // (found by the usability review, 09.11.2026 — typing went nowhere).
  useEffect(() => {
    const h = requestAnimationFrame(() => requestAnimationFrame(() => input.current?.focus()));
    // And whatever is typed while the palette is open goes into its field:
    // focusing during keydown sends the character there, however early it came.
    const f = (e: KeyboardEvent) => {
      if (input.current && document.activeElement !== input.current && !e.ctrlKey && !e.metaKey && e.key !== "Escape") input.current.focus();
    };
    document.addEventListener("keydown", f, true);
    return () => {
      cancelAnimationFrame(h);
      document.removeEventListener("keydown", f, true);
    };
  }, []);
  useEffect(() => {
    input.current?.focus();
    // People, roles, portals and exits come from the server; whatever fails stays out.
    Promise.allSettled([get("/household/members"), get("/household/roles"), get("/household/portals"), get("/network/exits")]).then(([p, r, po, x]) => {
      const more: PalItem[] = [];
      if (p.status === "fulfilled") p.value.people.forEach((x: any) => more.push({ t: x.name, s: t("ui.palette.person"), go: "haushalt", ui: { tab: "ppl", sel: x.id } }));
      if (r.status === "fulfilled") r.value.roles.forEach((x: any) => more.push({ t: x.name, s: t("ui.palette.role"), go: "haushalt", ui: { tab: "rol", role: x.id } }));
      if (po.status === "fulfilled") po.value.portals.forEach((x: any) => more.push({ t: x.name, s: t("ui.palette.portal"), go: "portale", ui: { pid: x.id } }));
      if (x.status === "fulfilled") x.value.exits.forEach((e: any) => more.push({ t: routeLabel(t, e.id), s: t("ui.palette.exit"), go: "netz" }));
      setItems((old) => [...old, ...more]);
    });
  }, [t]);
  const shown = q.trim() ? items.filter((x) => x.t.toLowerCase().includes(q.toLowerCase().trim())) : items.slice(0, 8);

  const pick = (x: PalItem) => go(x.go, x.ui ?? {});
  return (
    <>
      <div className="backdrop" onClick={() => setLayer(null)} />
      <div className="palette" role="dialog" aria-label={t("ui.shell.search")}>
        <input
          ref={input}
          placeholder={t("ui.palette.placeholder")}
          autoComplete="off"
          value={q}
          onChange={(e) => {
            setQ(e.target.value);
            setSel(0);
          }}
          onKeyDown={(e) => {
            if (e.key === "ArrowDown") {
              setSel((s) => Math.min(s + 1, shown.length - 1));
              e.preventDefault();
            }
            if (e.key === "ArrowUp") {
              setSel((s) => Math.max(s - 1, 0));
              e.preventDefault();
            }
            if (e.key === "Enter" && shown[sel]) pick(shown[sel]);
          }}
        />
        <ul>
          {shown.length ? (
            shown.map((x, i) => (
              <li key={i}>
                <button className={i === sel ? "on" : ""} onClick={() => pick(x)}>
                  {x.t}
                  <small>{x.s}</small>
                </button>
              </li>
            ))
          ) : (
            <li className="none">{t("ui.palette.none")}</li>
          )}
        </ul>
      </div>
    </>
  );
}

/** A dialog sheet with a close button — the mockup's `sheet()`. */
export function Sheet({ children }: { children: ReactNode }) {
  const { t } = useTranslation();
  const { setLayer } = useApp();
  return (
    <>
      <div className="backdrop" onClick={() => setLayer(null)} />
      <div className="sheet" role="dialog" aria-modal="true">
        <button className="btn ghost sm x" onClick={() => setLayer(null)}>
          {t("ui.common.close")}
        </button>
        {children}
      </div>
    </>
  );
}
