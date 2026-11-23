/**
 * Sign-in and first run — the mockup's `loginScreen()` and `setupScreen()`.
 * Only people with console access are offered; the PIN is typed on the pad
 * or the keyboard.
 */
import { gsap } from "gsap";
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { get, post, ServerError, setToken } from "./api";
import { errorText } from "./i18n";
import { useMode } from "./state";
import { first, G, imgLogin, ini, Logo } from "./ui";

type Who = { id: string; name: string; color: string; console?: boolean };

function useCardIn() {
  const root = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    if (!G || !root.current) return;
    gsap.from(root.current.querySelector(".lcard"), { y: 30, opacity: 0, duration: 0.7, ease: "power3.out" });
    gsap.from(root.current.querySelector(".login .img"), { scale: 1.1, duration: 2, ease: "power2.out" });
  }, []);
  return root;
}

function Frame({ children, rootRef }: { children: React.ReactNode; rootRef: React.RefObject<HTMLDivElement> }) {
  const { dark } = useMode();
  return (
    <div className="frame" ref={rootRef}>
      <div className="app" data-mode={dark ? "dark" : "light"}>
        <div className="login">
          <div className="img" style={{ backgroundImage: `url(${imgLogin})` }} />
          <div className="lcard">{children}</div>
        </div>
      </div>
    </div>
  );
}

export function Login({ people, household, notice, onSignedIn }: { people: Who[]; household: string; notice?: string; onSignedIn: () => void }) {
  const { t } = useTranslation();
  const root = useCardIn();
  const holders = people.filter((p) => p.console);
  const [who, setWho] = useState(holders[0]?.id ?? "");
  const [pin, setPin] = useState("");
  const [msg, setMsg] = useState<string>(notice ?? "");
  const [lockUntil, setLockUntil] = useState(0);
  const [now, setNow] = useState(Date.now());
  const [busy, setBusy] = useState(false);
  const [diag, setDiag] = useState<any>(null);
  const locked = lockUntil > now;

  useEffect(() => {
    if (!lockUntil) return;
    const h = setInterval(() => setNow(Date.now()), 500);
    return () => clearInterval(h);
  }, [lockUntil]);

  const submit = useCallback(async () => {
    if (busy || locked || !who) return;
    if (!/^\d{4,8}$/.test(pin)) {
      setMsg(t("ui.login.pin_format"));
      return;
    }
    setBusy(true);
    try {
      const d = await post("/login", { name: who, pin, device: t("ui.login.device_name") }, true);
      setToken(d.device_token);
      onSignedIn();
    } catch (e) {
      setPin("");
      if (e instanceof ServerError && e.code === "auth.locked_out") {
        setLockUntil(Date.now() + Number(e.values.seconds ?? 60) * 1000);
        setNow(Date.now());
        setMsg("");
      } else setMsg(errorText(e));
    } finally {
      setBusy(false);
    }
  }, [busy, locked, who, pin, onSignedIn, t]);

  const key = useCallback(
    (k: string) => {
      if (locked) return;
      if (k === "←") setPin((p) => p.slice(0, -1));
      else if (k === "OK") submit();
      else setPin((p) => (p.length < 8 ? p + k : p));
      setMsg("");
    },
    [locked, submit],
  );

  useEffect(() => {
    const f = (e: KeyboardEvent) => {
      if (/^\d$/.test(e.key)) key(e.key);
      else if (e.key === "Backspace") key("←");
      else if (e.key === "Enter") key("OK");
    };
    window.addEventListener("keydown", f);
    return () => window.removeEventListener("keydown", f);
  }, [key]);

  const check = async () => {
    const t0 = performance.now();
    try {
      const h = await get("/health");
      setDiag({ ok: true, ms: Math.round(performance.now() - t0), h });
    } catch {
      setDiag({ ok: false });
    }
  };

  const secondsLeft = Math.ceil((lockUntil - now) / 1000);
  return (
    <Frame rootRef={root}>
      <div className="brand">
        <span className="logo">
          <Logo />
        </span>
        <h2>
          CineLounge<small>{t("ui.login.subtitle", { household: household.toUpperCase() })}</small>
        </h2>
      </div>
      <div className="field">
        <span className="lbl">{t("ui.login.who")}</span>
        <div className="who-pick">
          {holders.map((p) => (
            <button key={p.id} aria-pressed={who === p.id} onClick={() => setWho(p.id)}>
              <span className="av s" style={{ background: p.color }}>
                {ini(p.name)}
              </span>
              {first(p.name)}
            </button>
          ))}
        </div>
        <p className="hint">{t("ui.login.only_console")}</p>
      </div>
      <div className="field">
        <span className="lbl">{t("ui.login.pin")}</span>
        <div className="pinbox" aria-live="polite">
          {Array.from({ length: Math.max(4, pin.length) }, (_, i) => (
            <i key={i} className={i < pin.length ? "on" : ""} />
          ))}
        </div>
      </div>
      <div className="pinpad">
        {["1", "2", "3", "4", "5", "6", "7", "8", "9", "←", "0", "OK"].map((k) => (
          <button key={k} disabled={locked || busy} aria-label={k === "←" ? t("ui.login.delete") : k === "OK" ? t("ui.login.sign_in") : k} onClick={() => key(k)}>
            {k}
          </button>
        ))}
      </div>
      <p className="hint" style={msg || locked ? { color: "var(--bad)" } : undefined}>
        {locked ? <span dangerouslySetInnerHTML={{ __html: t("ui.login.locked", { seconds: `<b>${secondsLeft}</b>` }) }} /> : msg || t("ui.login.pin_hint")}
      </p>
      <button className="linkbtn" onClick={check}>
        {t("ui.login.check")}
      </button>
      {diag && (
        <dl className="dl">
          <dt>{t("ui.login.diag_service")}</dt>
          <dd style={{ color: diag.ok ? "var(--ok)" : "var(--bad)" }}>{diag.ok ? t("ui.shell.reachable_ms", { ms: diag.ms }) : t("ui.shell.unreachable")}</dd>
          {diag.ok && (
            <>
              <dt>{t("ui.service.version")}</dt>
              <dd>{diag.h.version}</dd>
              <dt>{t("ui.login.diag_people")}</dt>
              <dd>{diag.h.household?.people}</dd>
              <dt>{t("ui.service.runner")}</dt>
              <dd>{diag.h.fork ? t("ui.service.fork_on") : t("ui.service.fork_off")}</dd>
            </>
          )}
        </dl>
      )}
    </Frame>
  );
}

export function Setup({ onDone }: { onDone: () => void }) {
  const { t } = useTranslation();
  const root = useCardIn();
  const [step, setStep] = useState(0);
  const [code, setCode] = useState("");
  const [name, setName] = useState("");
  const [pin, setPin] = useState("");
  const [msg, setMsg] = useState("");
  const [busy, setBusy] = useState(false);

  const next = async () => {
    setMsg("");
    if (step === 0) {
      if (!code.trim()) return setMsg(t("ui.setup.code_missing"));
      return setStep(1);
    }
    if (step === 1) {
      if (!name.trim()) return setMsg(t("ui.setup.name_missing"));
      return setStep(2);
    }
    if (!/^\d{4,8}$/.test(pin)) return setMsg(t("ui.login.pin_format"));
    setBusy(true);
    try {
      const d = await post("/setup", { code: code.trim(), name: name.trim(), pin }, true);
      setToken(d.device_token);
      onDone();
    } catch (e) {
      setMsg(errorText(e));
      if (e instanceof ServerError && e.code === "setup.bad_code") setStep(0);
    } finally {
      setBusy(false);
    }
  };

  return (
    <Frame rootRef={root}>
      <div className="brand">
        <span className="logo">
          <Logo />
        </span>
        <h2>
          {t("ui.setup.welcome")}
          <small>{t("ui.setup.step_of", { n: step + 1 })}</small>
        </h2>
      </div>
      <div className="steps-h">
        {[0, 1, 2].map((i) => (
          <i key={i} className={i <= step ? "on" : ""} />
        ))}
      </div>
      {step === 0 && (
        <>
          <p className="lead">{t("ui.setup.code_lead")}</p>
          <div className="secret">
            <code style={{ font: "500 14px var(--fm)" }}>docker compose logs cinelounge</code>
          </div>
          <div className="field">
            <label htmlFor="su-code">{t("ui.setup.code")}</label>
            <input className="inp" id="su-code" placeholder={t("ui.setup.code_example")} autoComplete="off" value={code} onChange={(e) => setCode(e.target.value)} onKeyDown={(e) => e.key === "Enter" && next()} autoFocus />
          </div>
        </>
      )}
      {step === 1 && (
        <>
          <div className="field">
            <label htmlFor="su-name">{t("ui.setup.name")}</label>
            <input className="inp" id="su-name" value={name} onChange={(e) => setName(e.target.value)} onKeyDown={(e) => e.key === "Enter" && next()} autoFocus />
          </div>
          <p className="hint">{t("ui.setup.name_hint")}</p>
        </>
      )}
      {step === 2 && (
        <>
          <div className="field">
            <label htmlFor="su-pin">{t("ui.setup.pin")}</label>
            <input className="inp pin" id="su-pin" inputMode="numeric" maxLength={8} type="password" value={pin} onChange={(e) => setPin(e.target.value.replace(/\D/g, ""))} onKeyDown={(e) => e.key === "Enter" && next()} autoFocus />
          </div>
          <p className="hint">{t("ui.setup.pin_hint")}</p>
        </>
      )}
      {msg && (
        <p className="hint" style={{ color: "var(--bad)" }}>
          {msg}
        </p>
      )}
      <div className="req-act">
        {step > 0 && (
          <button className="btn ghost" onClick={() => setStep(step - 1)}>
            {t("ui.common.back")}
          </button>
        )}
        <button className="btn pri" onClick={next} disabled={busy}>
          {step < 2 ? t("ui.common.next") : t("ui.setup.create")}
        </button>
      </div>
    </Frame>
  );
}
