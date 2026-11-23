/**
 * App state shared by the frame and the pages: who is signed in, which page
 * is open (kept in the address as `#/einlass`), light/dark, phone width,
 * the toast and the layer (menu, sheet, palette).
 */
import { gsap } from "gsap";
import { createContext, type ReactNode, useCallback, useContext, useEffect, useMemo, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { get } from "./api";
import { type AreaId, AREAS, G } from "./ui";

export type Me = {
  id: string;
  name: string;
  color: string;
  role_id: string;
  console: boolean;
  rights: Record<string, boolean>;
};

export type Mode = "light" | "dark" | "system";
export type Ui = Record<string, any>;

type Ctx = {
  me: Me;
  page: AreaId;
  ui: Ui;
  go: (page: AreaId, ui?: Ui) => void;
  setUi: (patch: Ui) => void;
  mode: Mode;
  setMode: (m: Mode) => void;
  dark: boolean;
  narrow: boolean;
  setNarrow: (n: boolean) => void;
  toast: (msg: string, undo?: () => void) => void;
  layer: ReactNode;
  setLayer: (n: ReactNode) => void;
  door: { join: number; code: number; invite: number; total: number };
  refreshDoor: () => void;
  health: { ok: boolean; ms: number; data: any } | null;
  signOut: () => void;
  can: (right: string) => boolean;
  toastRef: React.MutableRefObject<ToastApi | null>;
};
type ToastApi = { show: (msg: string, undo?: () => void) => void };

const C = createContext<Ctx | null>(null);
export const useApp = () => useContext(C)!;

const MODE_KEY = "cl.console.mode";
function readMode(): Mode {
  try {
    const m = localStorage.getItem(MODE_KEY);
    if (m === "light" || m === "dark" || m === "system") return m;
  } catch {
    /* no storage */
  }
  return "system";
}

function pageFromHash(): AreaId {
  const h = location.hash.replace(/^#\/?/, "") as AreaId;
  return AREAS.includes(h) ? h : "home";
}

export function useSystemDark(): boolean {
  const q = typeof matchMedia !== "undefined" ? matchMedia("(prefers-color-scheme: dark)") : null;
  const [d, setD] = useState(!!q?.matches);
  useEffect(() => {
    if (!q) return;
    const f = () => setD(q.matches);
    q.addEventListener("change", f);
    return () => q.removeEventListener("change", f);
  }, [q]);
  return d;
}

export function useMode() {
  const [mode, setModeState] = useState<Mode>(readMode);
  const sys = useSystemDark();
  const setMode = useCallback((m: Mode) => {
    setModeState(m);
    try {
      localStorage.setItem(MODE_KEY, m);
    } catch {
      /* no storage */
    }
  }, []);
  return { mode, setMode, dark: mode === "system" ? sys : mode === "dark" };
}

export function AppProvider({ me, signOut, children }: { me: Me; signOut: () => void; children: ReactNode }) {
  const [page, setPage] = useState<AreaId>(pageFromHash);
  const [ui, setUiState] = useState<Ui>({});
  const { mode, setMode, dark } = useMode();
  const [narrow, setNarrow] = useState(false);
  const [layer, setLayer] = useState<ReactNode>(null);
  const [door, setDoor] = useState({ join: 0, code: 0, invite: 0, total: 0 });
  const [health, setHealth] = useState<Ctx["health"]>(null);

  const go = useCallback((p: AreaId, next: Ui = {}) => {
    setLayer(null);
    setUiState(next);
    setPage(p);
    if (location.hash !== "#/" + p) history.pushState(null, "", "#/" + p);
    window.scrollTo({ top: 0 });
  }, []);
  const setUi = useCallback((patch: Ui) => setUiState((u) => ({ ...u, ...patch })), []);

  useEffect(() => {
    const f = () => {
      setUiState({});
      setPage(pageFromHash());
    };
    window.addEventListener("popstate", f);
    return () => window.removeEventListener("popstate", f);
  }, []);

  const can = useCallback((r: string) => !!me.rights?.[r], [me]);

  const refreshDoor = useCallback(() => {
    if (!me.rights?.pair_devices) return;
    get("/household/door")
      .then((d) => setDoor({ ...d.counts, total: d.counts.join + d.counts.code + d.counts.invite }))
      .catch(() => {});
  }, [me]);

  // The live service dot: asked every 5 seconds, as the mockup promises.
  useEffect(() => {
    let stop = false;
    const tick = async () => {
      const t0 = performance.now();
      try {
        const data = await get("/health");
        if (!stop) setHealth({ ok: true, ms: Math.round(performance.now() - t0), data });
      } catch {
        if (!stop) setHealth((h) => ({ ok: false, ms: 0, data: h?.data }));
      }
    };
    tick();
    const h = setInterval(tick, 5000);
    return () => {
      stop = true;
      clearInterval(h);
    };
  }, []);
  useEffect(() => {
    refreshDoor();
    const h = setInterval(refreshDoor, 15000);
    return () => clearInterval(h);
  }, [refreshDoor]);

  // Ctrl+K opens the palette; Escape closes any layer.
  useEffect(() => {
    const f = (e: KeyboardEvent) => {
      if (e.key === "Escape") setLayer(null);
    };
    document.addEventListener("keydown", f);
    return () => document.removeEventListener("keydown", f);
  }, []);

  const toastRef = useRef<ToastApi | null>(null);
  const toast = useCallback((msg: string, undo?: () => void) => toastRef.current?.show(msg, undo), []);

  const value = useMemo<Ctx>(
    () => ({ me, page, ui, go, setUi, mode, setMode, dark, narrow, setNarrow, toast, layer, setLayer, door, refreshDoor, health, signOut, can, toastRef }),
    [me, page, ui, go, setUi, mode, setMode, dark, narrow, toast, layer, door, refreshDoor, health, signOut, can],
  );
  return <C.Provider value={value}>{children}</C.Provider>;
}

/**
 * The toast, with an optional "Rückgängig". The mockup's `toast()`: in with a
 * small bounce, out after 3 s (7 s when it can be undone).
 */
export function ToastHost({ bind }: { bind: React.MutableRefObject<ToastApi | null> }) {
  const el = useRef<HTMLDivElement>(null);
  const [msg, setMsg] = useState("");
  const [undo, setUndo] = useState<(() => void) | null>(null);
  const timer = useRef<number>(0);
  bind.current = {
    show: (m, u) => {
      setMsg(m);
      setUndo(() => u ?? null);
      const t = el.current;
      if (!t) return;
      if (G) {
        gsap.killTweensOf(t);
        gsap.fromTo(t, { y: 16, opacity: 0 }, { y: 0, opacity: 1, duration: 0.3, ease: "back.out(2)" });
        gsap.to(t, { opacity: 0, y: 8, delay: u ? 7 : 3, duration: 0.3, onComplete: () => setUndo(null) });
      } else {
        t.style.opacity = "1";
        clearTimeout(timer.current);
        timer.current = window.setTimeout(() => {
          t.style.opacity = "0";
          setUndo(null);
        }, u ? 7000 : 3000);
      }
    },
  };
  return (
    <ToastBody el={el} msg={msg} undo={undo} clear={() => setUndo(null)} />
  );
}

function ToastBody({ el, msg, undo, clear }: { el: React.RefObject<HTMLDivElement>; msg: string; undo: (() => void) | null; clear: () => void }) {
  const { t } = useTranslation();
  return (
    <div className={"toast" + (undo ? " act" : "")} role="status" ref={el}>
      {msg}
      {undo && (
        <button
          onClick={() => {
            undo();
            clear();
            if (el.current) {
              gsap.killTweensOf(el.current);
              el.current.style.opacity = "0";
            }
          }}
        >
          {t("ui.common.undo")}
        </button>
      )}
    </div>
  );
}

