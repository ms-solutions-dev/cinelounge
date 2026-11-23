import { useCallback, useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { get, post, setAccessLost, setToken, token } from "./api";
import { Login, Setup } from "./Gate";
import { Door } from "./pages/Door";
import { Home } from "./pages/Home";
import { Household } from "./pages/Household";
import { Market } from "./pages/Market";
import { Network } from "./pages/Network";
import { Portals } from "./pages/Portals";
import { Settings } from "./pages/Settings";
import { Workshop } from "./pages/Workshop";
import { EXTENSION_AREAS } from "./extension";
import { Shell } from "./Shell";
import { AppProvider, type Me, useApp } from "./state";
import "./styles/mockup.css";
import "./styles/app.css";

type Boot =
  | { kind: "loading" }
  | { kind: "setup" }
  | { kind: "login"; people: any[]; household: string; notice?: string }
  | { kind: "app"; me: Me };

export default function App() {
  const { t } = useTranslation();
  const [boot, setBoot] = useState<Boot>({ kind: "loading" });

  const start = useCallback(
    async (notice?: string) => {
      if (token()) {
        try {
          const me: Me = await get("/household/me");
          if (me.console) return setBoot({ kind: "app", me });
          // Signed in, but without console access: this is not the place.
          setToken(null);
          notice = t("ui.login.no_console", { name: me.name });
        } catch {
          setToken(null);
        }
      }
      try {
        const who = await get("/login/who");
        if (who.setup_required) return setBoot({ kind: "setup" });
        const wk = await get("/.well-known/cinelounge").catch(() => ({}));
        setBoot({ kind: "login", people: who.people, household: wk.name || "CineLounge", notice });
      } catch {
        setBoot({ kind: "login", people: [], household: "CineLounge", notice: t("errors.net.unreachable") });
      }
    },
    [t],
  );

  useEffect(() => {
    setAccessLost(() => start(t("ui.login.signed_out")));
    (async () => {
      // An invitation link carries its token in the address; it is redeemed at
      // once and taken out of the address bar (a token in the history is a
      // token on the next person's screen).
      const invite = new URLSearchParams(location.search).get("invite");
      if (invite) {
        history.replaceState(null, "", location.pathname + location.hash);
        try {
          const d = await post("/redeem", { token: invite, name: t("ui.login.device_name"), kind: "web" }, true);
          setToken(d.device_token);
        } catch {
          /* expired or used — the PIN way remains */
        }
      }
      start();
    })();
  }, [start, t]);

  const signOut = useCallback(async () => {
    try {
      await post("/logout");
    } catch {
      /* gone anyway */
    }
    setToken(null);
    start();
  }, [start]);

  if (boot.kind === "loading") return null;
  if (boot.kind === "setup") return <Setup onDone={() => start()} />;
  if (boot.kind === "login") return <Login people={boot.people} household={boot.household} notice={boot.notice} onSignedIn={() => start()} />;
  return (
    <AppProvider me={boot.me} signOut={signOut}>
      <Shell>
        <Page />
      </Shell>
    </AppProvider>
  );
}

function Page() {
  const { page, ui } = useApp();
  const key = page + ":" + (ui.pid || "");
  switch (page) {
    case "home":
      return <Home key={key} />;
    case "einlass":
      return <Door key={key} />;
    case "haushalt":
      return <Household key={key} />;
    case "portale":
      return <Portals key={key} />;
    case "markt":
      return <Market key={key} />;
    case "netz":
      return <Network key={key} />;
    case "werk":
      return <Workshop key={key} />;
    case "konto":
      return <Settings key={key} />;
  }
  const Area = EXTENSION_AREAS.find((a) => a.id === page)?.page;
  return Area ? <Area key={key} /> : null;
}
