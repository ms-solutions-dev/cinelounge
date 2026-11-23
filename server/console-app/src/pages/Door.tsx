/** Einlass — the mockup's `pageEinlass()`: requests, codes, invitations in one list. */
import { useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { del, get, post } from "../api";
import { LoadFail, Loading, useLoad } from "../data";
import { errorText } from "../i18n";
import { type Person, type Role, roleSees } from "../model";
import { removeEl } from "../motion";
import { useEnter } from "../Shell";
import { useApp } from "../state";
import { Hero, Icon, ini, isOutside, useLeft, useWhen } from "../ui";

type Item = { type: "join" | "code" | "invite"; id: string; created: number; expires_in_s: number; expired: boolean; [k: string]: any };
const KINDS = ["tv", "phone", "tablet", "web"] as const;
const UNDO_MS = 7000;

export function Door() {
  const { t } = useTranslation();
  const { ui, setUi, toast, refreshDoor, setLayer } = useApp();
  const when = useWhen();
  const left = useLeft();
  const { data, error, reload, setData } = useLoad(async () => {
    const [door, roles, members, portals] = await Promise.all([get("/household/door"), get("/household/roles"), get("/household/members"), get("/household/portals")]);
    return { items: door.items as Item[], roles: roles.roles as Role[], people: members.people as Person[], portals: portals.portals };
  }, []);
  useEnter(!!data);
  // Countdown of the codes, once a second; a code that runs out is redrawn.
  const [, tick] = useState(0);
  useEffect(() => {
    const h = setInterval(() => tick((n) => n + 1), 1000);
    return () => clearInterval(h);
  }, []);
  const loadedAt = useRef(Date.now());
  useEffect(() => {
    if (data) loadedAt.current = Date.now();
  }, [data]);
  const remaining = (q: Item) => (q.expired ? 0 : Math.max(0, Math.round(q.expires_in_s - (Date.now() - loadedAt.current) / 1000)));

  if (error) return (<><Hero id="einlass" /><LoadFail error={error} retry={reload} /></>);
  if (!data) return (<><Hero id="einlass" /><Loading /></>);

  const { items, roles, people, portals } = data;
  const filter: string = ui.filter || "all";
  const shown = items.filter((x) => filter === "all" || x.type === filter);
  const rsum = (r: Role) => {
    const sees = portals.filter((p: any) => roleSees(r, p)).length;
    return t("ui.role.summary", { rights: r.rights.length, portals: sees }) + (r.rights.includes("view_adult") ? t("ui.role.summary_adult") : "");
  };
  const done = () => {
    reload();
    refreshDoor();
  };
  const drop = (id: string) => setData((d) => (d ? { ...d, items: d.items.filter((x) => x.id !== id) } : d));
  const elOf = (id: string) => document.querySelector(`.req[data-id="${CSS.escape(id)}"]`);

  /** Decline / withdraw: gone at once, really gone after the toast — unless undone. */
  const deferred = (q: Item, message: string, call: () => Promise<unknown>) => {
    removeEl(elOf(q.id), () => {
      drop(q.id);
      let undone = false;
      const h = setTimeout(async () => {
        if (undone) return;
        try {
          await call();
        } catch (e) {
          toast(errorText(e));
        }
        done();
      }, UNDO_MS);
      toast(message, () => {
        undone = true;
        clearTimeout(h);
        reload();
      });
    });
  };

  const approve = async (q: Item) => {
    const roleId = ui.pick?.[q.id];
    if (!roleId) return;
    try {
      await post(`/household/joins/${q.id}/approve`, { role: roleId });
      const r = roles.find((x) => x.id === roleId);
      removeEl(elOf(q.id), () => {
        drop(q.id);
        toast(t("ui.door.approved", { name: q.name, role: r?.name ?? roleId }));
        setUi({ open: null });
        done();
      });
    } catch (e) {
      toast(errorText(e));
    }
  };

  const assign = async (q: Item) => {
    const sel = document.getElementById("code-person-" + q.id) as HTMLSelectElement | null;
    const v = sel?.value ?? "";
    if (!v) {
      sel?.classList.add("err");
      sel?.focus();
      toast(t("ui.door.pick_owner_first"));
      return;
    }
    const person = v === "__shared" ? null : v;
    try {
      await post(`/household/pending/${q.id}/person`, { person });
      toast(person ? t("ui.door.code_reserved", { name: people.find((p) => p.id === person)?.name ?? person, device: q.device }) : t("ui.door.code_shared", { device: q.device }));
      reload();
    } catch (e) {
      toast(errorText(e));
      reload();
    }
  };

  const types = { all: t("ui.door.f_all"), join: t("ui.door.f_join"), code: t("ui.door.f_code"), invite: t("ui.door.f_invite") } as const;
  const count = (k: string) => items.filter((x) => (k === "all" || x.type === k) && !x.expired).length;

  const item = (q: Item) => {
    if (q.type === "join") {
      const open = ui.open === q.id;
      const pk: string | undefined = ui.pick?.[q.id];
      const outside = isOutside(q.from);
      return (
        <article key={q.id} className="req w-einlass" data-id={q.id}>
          <div className="req-card">
            <div className="req-main">
              <div className="req-who">
                <span className="av" style={{ background: q.color }}>{ini(q.name)}</span>
                <div>
                  <strong>{q.name}</strong>
                  <small>{t("ui.door.wants_in", { device: q.device })}</small>
                </div>
              </div>
              <div className="meta">
                <span className={outside ? "warn" : ""}>{(outside ? t("ui.door.outside") : t("ui.door.home")) + " · " + q.from}</span>
                <span>{when(q.created)}</span>
                <span>{left(remaining(q))}</span>
              </div>
              {outside && !open && <div className="flag">{t("ui.door.outside_flag")}</div>}
              {!open && (
                <div className="req-act">
                  <button className="btn pri" onClick={() => setUi({ open: q.id })}>{t("ui.door.choose_role")}</button>
                  <button className="btn ghost" onClick={() => deferred(q, t("ui.door.declined", { name: q.name }), () => post(`/household/joins/${q.id}/decline`))}>{t("ui.door.decline")}</button>
                </div>
              )}
            </div>
            <div className="req-side">
              <span className="kind">{t("ui.door.k_join")}</span>
              <span className="big">{outside ? t("ui.door.outside_big") : t("ui.door.home_big")}</span>
              <small>{outside ? t("ui.door.not_your_net") : t("ui.door.your_net")}</small>
            </div>
          </div>
          {open && (
            <div className="req-decide">
              <span className="lbl">{t("ui.door.which_role", { name: q.name })}</span>
              <div className="rolecards">
                {roles.map((r) => (
                  <button key={r.id} className="rc" style={{ ["--rc" as any]: r.color }} aria-pressed={pk === r.id} onClick={() => setUi({ pick: { ...(ui.pick || {}), [q.id]: r.id } })}>
                    <b>{r.name}</b>
                    <span>{rsum(r)}</span>
                  </button>
                ))}
              </div>
              {outside && <div className="flag">{t("ui.door.outside_flag_long")}</div>}
              <p className="hint">{t("ui.door.no_console_here")}</p>
              <div className="req-act">
                <button className="btn pri" disabled={!pk} onClick={() => approve(q)}>
                  {pk ? t("ui.door.let_in_as", { role: roles.find((r) => r.id === pk)?.name }) : t("ui.door.pick_role_first")}
                </button>
                <button className="btn ghost" onClick={() => setUi({ open: null })}>{t("ui.common.cancel")}</button>
              </div>
            </div>
          )}
        </article>
      );
    }
    if (q.type === "code") {
      const sec = remaining(q);
      const kind = (KINDS as readonly string[]).includes(q.kind) ? q.kind : "tv";
      return (
        <article key={q.id} className="req w-netz" data-id={q.id}>
          <div className="req-card">
            <div className="req-main">
              <div className="req-who">
                <span className="av" style={{ background: "var(--surface2)", color: "var(--muted)" }}><Icon k={kind} /></span>
                <div>
                  <strong>{t("ui.door.code_waits", { device: q.device })}</strong>
                  <small>{q.person !== undefined && q.person !== null ? t("ui.door.code_for", { name: people.find((p) => p.id === q.person)?.name ?? q.person }) : t("ui.door.code_hint")}</small>
                </div>
              </div>
              <div className="row">
                <select className="sel" id={"code-person-" + q.id} aria-label={t("ui.door.owner_for", { device: q.device })} disabled={!sec} defaultValue={q.person ?? ""} onChange={(e) => e.target.classList.remove("err")}>
                  <option value="">{t("ui.door.choose_person")}</option>
                  <option value="__shared">{t("ui.door.shared")}</option>
                  {people.map((p) => (
                    <option key={p.id} value={p.id}>{p.name}</option>
                  ))}
                </select>
                <button className="btn pri" disabled={!sec} onClick={() => assign(q)}>{t("ui.door.assign")}</button>
                <button className="btn ghost" onClick={() => deferred(q, t("ui.door.code_withdrawn"), () => del(`/household/pending/${q.id}`))}>{t("ui.door.withdraw")}</button>
              </div>
            </div>
            <div className="req-side">
              <span className="kind">{t("ui.door.k_code")}</span>
              <span className="code">{q.code.length === 6 ? q.code.slice(0, 3) + " " + q.code.slice(3) : q.code}</span>
              <small>{sec ? t("ui.door.expires_in", { time: `${Math.floor(sec / 60)}:${String(sec % 60).padStart(2, "0")}` }) : t("ui.door.expired")}</small>
            </div>
          </div>
        </article>
      );
    }
    const p = people.find((x) => x.id === q.person);
    const name = p?.name ?? q.person;
    const hours = Math.max(1, Math.round(remaining(q) / 3600));
    return (
      <article key={q.id} className="req w-haushalt" data-id={q.id}>
        <div className="req-card">
          <div className="req-main">
            <div className="req-who">
              <span className="av" style={{ background: p?.color ?? "#4A7FD9" }}><Icon k="link" /></span>
              <div>
                <strong>{t("ui.door.invite_for", { name })}</strong>
                <small>{t("ui.door.invite_hint", { name })}</small>
              </div>
            </div>
            <div className="meta">
              <span>{t("ui.door.created", { when: when(q.created) })}</span>
              <span>{left(remaining(q))}</span>
            </div>
            <div className="req-act">
              <button className="btn" onClick={() => copy(`${location.origin}/?invite=${q.id}`)}>{t("ui.door.copy_link")}</button>
              <button className="btn ghost" onClick={() => deferred(q, t("ui.door.invite_withdrawn", { name }), () => del(`/household/pending/${q.id}`))}>{t("ui.door.withdraw")}</button>
            </div>
          </div>
          <div className="req-side">
            <span className="kind">{t("ui.door.k_invite")}</span>
            <span className="big">{hours}h</span>
            <small>{t("ui.door.valid")}</small>
          </div>
        </div>
      </article>
    );
  };

  const copy = (url: string) => {
    try {
      navigator.clipboard.writeText(url).then(
        () => toast(t("ui.door.copied")),
        () => toast(t("ui.door.copy_failed", { url })),
      );
    } catch {
      toast(t("ui.door.copy_failed", { url }));
    }
  };

  const mkcode = async () => {
    const name = (document.getElementById("c-name") as HTMLInputElement).value.trim() || t("ui.door.new_device");
    const kind = (document.getElementById("c-kind") as HTMLSelectElement).value;
    const owner = (document.getElementById("c-owner") as HTMLSelectElement).value;
    try {
      const made = await post("/household/devices/code", { name, kind });
      // Whom it belongs to is decided here, before the code is typed in
      // (usability review: the owner used to come only after the code).
      if (owner) await post(`/household/pending/${made.code}/person`, { person: owner === "__shared" ? null : owner });
      setUi({ compose: null });
      toast(t("ui.door.code_made", { name }));
      done();
    } catch (e) {
      toast(errorText(e));
    }
  };
  const mkinvite = async () => {
    const person = (document.getElementById("i-person") as HTMLSelectElement).value;
    const hours = Number((document.getElementById("i-h") as HTMLSelectElement).value);
    try {
      await post("/household/invite", { person, hours });
      setUi({ compose: null });
      toast(t("ui.door.invite_made", { name: people.find((p) => p.id === person)?.name ?? person }));
      done();
    } catch (e) {
      toast(errorText(e));
    }
  };

  const roleOf = (p: Person) => roles.find((r) => r.id === p.role_id);
  const makeMenu = () =>
    setLayer(
      <>
        <div className="scrim" onClick={() => setLayer(null)} />
        <div className="menu" role="menu">
          <button className="mi" role="menuitem" onClick={() => { setLayer(null); setUi({ compose: "code" }); }}>{t("ui.door.make_code")}</button>
          <button className="mi" role="menuitem" onClick={() => { setLayer(null); setUi({ compose: "invite" }); }}>{t("ui.door.make_invite")}</button>
        </div>
      </>,
    );
  return (
    <>
      <button className="fab" aria-label={t("ui.door.make_menu")} onClick={makeMenu}><Icon k="plus" /></button>
      <Hero id="einlass" />
      <div className="toolbar">
        <div className="filters" role="group" aria-label={t("ui.common.filter")}>
          {Object.entries(types).map(([k, n]) => (
            <button key={k} className="fchip" aria-pressed={filter === k} onClick={() => setUi({ filter: k })}>
              {n} <b>{count(k)}</b>
            </button>
          ))}
        </div>
        <div className="row door-make">
          <button className="btn" onClick={() => setUi({ compose: "code" })}><Icon k="plus" /> {t("ui.door.make_code")}</button>
          <button className="btn" onClick={() => setUi({ compose: "invite" })}><Icon k="link" /> {t("ui.door.make_invite")}</button>
        </div>
      </div>
      {ui.compose === "code" && (
        <section className="composer w-netz">
          <b>{t("ui.door.code_title")}</b>
          <div className="grid2">
            <div className="field">
              <label htmlFor="c-name">{t("ui.door.device_name")}</label>
              <input className="inp" id="c-name" defaultValue={t("ui.door.device_example")} maxLength={60} />
            </div>
            <div className="field">
              <label htmlFor="c-kind">{t("ui.door.kind")}</label>
              <select className="sel" id="c-kind" defaultValue="tv">
                {KINDS.map((k) => (
                  <option key={k} value={k}>{t(`ui.kind.${k}`)}</option>
                ))}
              </select>
            </div>
            <div className="field">
              <label htmlFor="c-owner">{t("ui.door.for_whom")}</label>
              <select className="sel" id="c-owner" defaultValue="__shared">
                <option value="__shared">{t("ui.door.shared")}</option>
                {people.map((p) => (
                  <option key={p.id} value={p.id}>{p.name}</option>
                ))}
              </select>
            </div>
          </div>
          <p className="hint">{t("ui.door.shared_hint")}</p>
          <div className="req-act">
            <button className="btn pri" onClick={mkcode}>{t("ui.door.make_code")}</button>
            <button className="btn ghost" onClick={() => setUi({ compose: null })}>{t("ui.common.cancel")}</button>
          </div>
        </section>
      )}
      {ui.compose === "invite" && (
        <section className="composer w-haushalt">
          <b>{t("ui.door.invite_title")}</b>
          <div className="grid2">
            <div className="field">
              <label htmlFor="i-person">{t("ui.door.for_whom")}</label>
              <select className="sel" id="i-person" defaultValue={people.find((p) => roleOf(p)?.rights.includes("own_devices"))?.id}>
                {people.map((p) => {
                  const ok = !!roleOf(p)?.rights.includes("own_devices");
                  return (
                    <option key={p.id} value={p.id} disabled={!ok}>
                      {p.name}
                      {ok ? "" : " " + t("ui.door.role_forbids")}
                    </option>
                  );
                })}
              </select>
            </div>
            <div className="field">
              <label htmlFor="i-h">{t("ui.door.valid_for")}</label>
              <select className="sel" id="i-h" defaultValue="24">
                <option value="24">{t("ui.door.hours", { n: 24 })}</option>
                <option value="2">{t("ui.door.hours", { n: 2 })}</option>
              </select>
            </div>
          </div>
          <div className="req-act">
            <button className="btn pri" onClick={mkinvite}>{t("ui.door.make_invite")}</button>
            <button className="btn ghost" onClick={() => setUi({ compose: null })}>{t("ui.common.cancel")}</button>
          </div>
        </section>
      )}
      {shown.length ? (
        <div className="queue">{shown.map(item)}</div>
      ) : (
        <div className="empty">
          <Icon k="einlass" />
          <b>{t("ui.door.nobody")}</b>
          <span>{t("ui.door.nobody_hint")}</span>
        </div>
      )}
    </>
  );
}
