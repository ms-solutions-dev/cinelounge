/**
 * Building blocks shared by every page. Each one renders exactly the markup the
 * approved mockup renders (same element, same classes), so mockup.css applies
 * unchanged.
 */
import { gsap } from "gsap";
import { type CSSProperties, Fragment, type ReactNode, useEffect, useRef } from "react";
import { useTranslation } from "react-i18next";
import { EXTENSION_AREAS } from "./extension";
import { ICONS, LOGO } from "./icons";
import imgHome from "./assets/hero-home.jpg";
import imgEinlass from "./assets/hero-einlass.jpg";
import imgHaushalt from "./assets/hero-haushalt.jpg";
import imgPortale from "./assets/hero-portale.jpg";
import imgMarkt from "./assets/hero-markt.jpg";
import imgNetz from "./assets/hero-netz.jpg";
import imgWerk from "./assets/hero-werk.jpg";
import imgKonto from "./assets/hero-konto.jpg";
export { default as imgLogin } from "./assets/hero-login.jpg";

/** The core's areas. */
export type CoreAreaId = "home" | "einlass" | "haushalt" | "portale" | "markt" | "netz" | "werk" | "konto";
/** A core area or one an extension brings (`src/extension/types.ts`). */
export type AreaId = CoreAreaId | (string & {});
/** Every area in rail order: the extension's stand before "Konto". */
export const AREAS: AreaId[] = ["home", "einlass", "haushalt", "portale", "markt", "netz", "werk", ...EXTENSION_AREAS.map((a) => a.id), "konto"];
/** The areas that live behind "Mehr" on a phone. */
export const MORE_AREAS: AreaId[] = ["markt", "netz", "werk", ...EXTENSION_AREAS.map((a) => a.id), "konto"];
const IMG: Record<CoreAreaId, string> = {
  home: imgHome,
  einlass: imgEinlass,
  haushalt: imgHaushalt,
  portale: imgPortale,
  markt: imgMarkt,
  netz: imgNetz,
  werk: imgWerk,
  konto: imgKonto,
};

/** An area's hero picture; an extension area without one shows the network's. */
function heroImage(id: AreaId): string {
  return IMG[id as CoreAreaId] ?? EXTENSION_AREAS.find((a) => a.id === id)?.image ?? imgNetz;
}

/** Motion is on unless the system asks for less. */
export const RM = typeof matchMedia !== "undefined" && matchMedia("(prefers-reduced-motion: reduce)").matches;
export const G = !RM;

export function Icon({ k }: { k: string }) {
  return <svg viewBox="0 0 24 24" aria-hidden="true" dangerouslySetInnerHTML={{ __html: ICONS[k] ?? "" }} />;
}

export function Logo() {
  return <span style={{ display: "contents" }} dangerouslySetInnerHTML={{ __html: LOGO }} />;
}

export const ini = (n: string) => n.trim().charAt(0).toUpperCase();
export const first = (n: string) => n.split(/[\s–-]/)[0];

export function Avatar({ name, color, size = "s", style }: { name: string; color: string; size?: "s" | "l" | ""; style?: CSSProperties }) {
  return (
    <span className={"av" + (size ? " " + size : "")} style={{ background: color, ...style }}>
      {ini(name)}
    </span>
  );
}

export function Hero({ id, title }: { id: AreaId; title?: string }) {
  const { t } = useTranslation();
  const name = title || t(`ui.area.${id}.name`);
  return (
    <section className={`hero w-${id}`} aria-label={t(`ui.area.${id}.name`)}>
      <div className="img" style={{ backgroundImage: `url(${heroImage(id)})` }} />
      <div className="tint" />
      <div className="cone" />
      {id === "home" && <canvas id="dust" />}
      <div className="veil" />
      <div className="ht">
        <span className="eyebrow">{t(`ui.area.${id}.sub`)}</span>
        <h2>
          {name.split(" ").map((w, i) => (
            <Fragment key={i}>
              {i > 0 && " "}
              <span>{w}</span>
            </Fragment>
          ))}
        </h2>
        <p>{t(`ui.area.${id}.line`)}</p>
      </div>
    </section>
  );
}

/** The rolling counter of the overview tiles. */
export function Roll({ n }: { n: number | string }) {
  return (
    <span className="roll" aria-label={String(n)}>
      {String(n)
        .split("")
        .map((c, i) => (
          <span key={i}>{c}</span>
        ))}
    </span>
  );
}

/** Night strip: 1 carried, 0 failed, u unchecked — oldest first. */
export type Strip = (0 | 1 | null)[];
export const stripOk = (s: Strip) => s.filter((x) => x === 1).length;
export const stripTotal = (s: Strip) => s.filter((x) => x !== null).length;

export function Marks({ s, cls = "" }: { s: Strip; cls?: string }) {
  const { t } = useTranslation();
  return (
    <span className={`marks ${cls}`} aria-label={t("ui.nights.carried_of", { ok: stripOk(s), total: stripTotal(s) })}>
      {s.map((c, i) => (
        <i key={i} className={c === 0 ? "f" : c === null ? "u" : ""} />
      ))}
    </span>
  );
}

export function Switch({
  on,
  label,
  onChange,
  disabled,
  className = "",
  style,
}: {
  on: boolean;
  label: string;
  onChange?: (next: boolean) => void;
  disabled?: boolean;
  className?: string;
  style?: CSSProperties;
}) {
  return (
    <button
      className={"sw" + (className ? " " + className : "")}
      role="switch"
      aria-checked={on}
      aria-label={label}
      disabled={disabled}
      style={style}
      onClick={() => onChange?.(!on)}
    />
  );
}

/**
 * Press and hold (~1.2 s) for dangerous acts — the mockup's `holdStart`.
 * Pointer and keyboard (Space/Enter) both work; letting go early cancels.
 */
export function HoldButton({ label, onDone, small }: { label: string; onDone: () => void; small?: boolean }) {
  const fill = useRef<HTMLSpanElement>(null);
  const tw = useRef<{ kill: () => void } | null>(null);
  const start = (e: React.SyntheticEvent) => {
    e.preventDefault();
    if (tw.current || !fill.current) return;
    const done = () => {
      tw.current = null;
      if (fill.current) gsap.set(fill.current, { scaleX: 0 });
      onDone();
    };
    if (G) tw.current = gsap.fromTo(fill.current, { scaleX: 0 }, { scaleX: 1, duration: 1.2, ease: "none", onComplete: done });
    else {
      fill.current.style.transform = "scaleX(1)";
      const h = setTimeout(done, 1200);
      tw.current = {
        kill: () => {
          clearTimeout(h);
          if (fill.current) fill.current.style.transform = "scaleX(0)";
        },
      };
    }
  };
  const end = () => {
    if (!tw.current) return;
    tw.current.kill();
    tw.current = null;
    if (fill.current) G ? gsap.to(fill.current, { scaleX: 0, duration: 0.25 }) : (fill.current.style.transform = "scaleX(0)");
  };
  useEffect(() => () => tw.current?.kill(), []);
  return (
    <button
      className={"btn hold" + (small ? " sm" : "")}
      onPointerDown={start}
      onPointerUp={end}
      onPointerLeave={end}
      onPointerCancel={end}
      onKeyDown={(e) => {
        if ((e.key === " " || e.key === "Enter") && !e.repeat) start(e);
      }}
      onKeyUp={(e) => {
        if (e.key === " " || e.key === "Enter") end();
      }}
      onClick={(e) => e.preventDefault()}
    >
      <span className="fill" ref={fill} />
      <span>{label}</span>
    </button>
  );
}

export function Chip({ cls = "", children, style }: { cls?: string; children: ReactNode; style?: CSSProperties }) {
  return (
    <span className={"chip" + (cls ? " " + cls : "")} style={style}>
      {children}
    </span>
  );
}

/** "vor 2 Std.", "gestern, 21:40" — relative time in the current language. */
export function useWhen() {
  const { t, i18n } = useTranslation();
  return (at: number) => {
    const s = Math.max(0, Date.now() / 1000 - at);
    if (s < 60) return t("ui.time.just_now");
    if (s < 3600) return t("ui.time.minutes_ago", { n: Math.round(s / 60) });
    const d = new Date(at * 1000);
    const hm = d.toLocaleTimeString(i18n.language, { hour: "2-digit", minute: "2-digit" });
    const today = new Date();
    if (d.toDateString() === today.toDateString()) return s < 6 * 3600 ? t("ui.time.hours_ago", { n: Math.round(s / 3600) }) : t("ui.time.today_at", { time: hm });
    const y = new Date(today);
    y.setDate(today.getDate() - 1);
    if (d.toDateString() === y.toDateString()) return t("ui.time.yesterday_at", { time: hm });
    return d.toLocaleDateString(i18n.language, { day: "2-digit", month: "2-digit" }) + ", " + hm;
  };
}

/** "noch 6 Tage", "noch 18 Std.", "noch 4 Min." */
export function useLeft() {
  const { t } = useTranslation();
  return (seconds: number) => {
    if (seconds >= 2 * 86400) return t("ui.time.days_left", { n: Math.floor(seconds / 86400) });
    if (seconds >= 3600) return t("ui.time.hours_left", { n: Math.floor(seconds / 3600) });
    return t("ui.time.minutes_left", { n: Math.max(1, Math.ceil(seconds / 60)) });
  };
}

/** Private addresses count as "home network". */
export function isOutside(ip: string): boolean {
  if (!ip) return false;
  if (/^(10\.|127\.|192\.168\.|169\.254\.|::1$|fe80:|fc|fd)/i.test(ip)) return false;
  const m = ip.match(/^172\.(\d+)\./);
  if (m && +m[1] >= 16 && +m[1] <= 31) return false;
  return true;
}
