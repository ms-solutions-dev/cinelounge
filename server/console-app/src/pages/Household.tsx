/** Haushalt — the mockup's `pageHaushalt()`: people and roles. */
import { useState } from "react";
import { useTranslation } from "react-i18next";
import { del, patch, post } from "../api";
import { LoadFail, Loading, useLoad } from "../data";
import { errorText } from "../i18n";
import { type All, APP_RIGHTS, type Device, isLegacyPerson, loadAll, type Person, type Role, ROLE_COLORS, roleSees } from "../model";
import { removeEl } from "../motion";
import { Sheet, useEnter } from "../Shell";
import { useApp } from "../state";
import { Avatar, first, Hero, HoldButton, Icon, ini, Switch, useWhen } from "../ui";

export function Household() {
  const { t } = useTranslation();
  const { ui, setUi } = useApp();
  const { data, error, reload } = useLoad(() => loadAll({ exits: false }), []);
  useEnter(!!data);
  if (error) return (<><Hero id="haushalt" /><LoadFail error={error} retry={reload} /></>);
  if (!data) return (<><Hero id="haushalt" /><Loading /></>);
  const tab = ui.tab || "ppl";
  return (
    <>
      <Hero id="haushalt" />
      <div className="tabs" role="tablist">
        <button className="tab" role="tab" aria-selected={tab === "ppl"} onClick={() => setUi({ tab: "ppl" })}>
          {t("ui.household.people")} <b>{data.people.length}</b>
        </button>
        <button className="tab" role="tab" aria-selected={tab === "rol"} onClick={() => setUi({ tab: "rol" })}>
          {t("ui.household.roles")} <b>{data.roles.length}</b>
        </button>
      </div>
      {tab === "ppl" ? <People d={data} reload={reload} /> : <Roles d={data} reload={reload} />}
    </>
  );
}

function useRsum(d: All) {
  const { t } = useTranslation();
  const sees = (r: Role) => d.portals.filter((p) => roleSees(r, p));
  const rsum = (r: Role) => t("ui.role.summary", { rights: r.rights.length, portals: sees(r).length }) + (r.rights.includes("view_adult") ? t("ui.role.summary_adult") : "");
  return { sees, rsum };
}

// ── People ───────────────────────────────────────────────────────────────────

function People({ d, reload }: { d: All; reload: () => void }) {
  const { t } = useTranslation();
  const { ui, setUi, narrow, setLayer } = useApp();
  const sel = d.people.find((p) => p.id === ui.sel);
  const p = sel || (!narrow ? d.people[0] : undefined);
  const devsOf = (id: string) => d.devices.filter((x) => x.person === id);
  const roleName = (id: string) => d.roles.find((r) => r.id === id)?.name ?? id;
  return (
    <>
    {!(narrow && p) && <SafetyCard d={d} />}
    <div className={"split" + (narrow && p ? " has-sel" : "")}>
      <div className="pick" role="listbox" aria-label={t("ui.household.people")}>
        {d.people.map((x) => {
          const n = devsOf(x.id).length;
          return (
            <button key={x.id} className="pi" role="option" aria-selected={!!p && x.id === p.id} onClick={() => setUi({ sel: x.id, grant: null })}>
              <Avatar name={x.name} color={x.color} />
              <span style={{ minWidth: 0 }}>
                <b>{x.name}</b>
                <small>
                  {roleName(x.role_id)} · {t("ui.household.devices_n", { count: n })}
                  {x.console ? " · " + t("ui.household.console") : ""}
                </small>
              </span>
              {isLegacyPerson(x, d.devices) && <span className="dot warn" title={t("ui.household.legacy")} />}
            </button>
          );
        })}
        <button className="pi add" onClick={() => setLayer(<AddPerson d={d} done={(id) => { reload(); setUi({ tab: "ppl", sel: id }); }} />)}>
          {t("ui.household.add_person")}
        </button>
      </div>
      {p ? <PersonDetail key={p.id} p={p} d={d} reload={reload} /> : <div className="detail" />}
    </div>
    {!(narrow && p) && <SharedDevices d={d} reload={reload} />}
    </>
  );
}

/** One device: name, how it came, last seen; change name or owner, sign off. */
function DeviceRow({ dev, d, reload, onSignOff }: { dev: Device; d: All; reload: () => void; onSignOff: () => void }) {
  const { t } = useTranslation();
  const { toast } = useApp();
  const when = useWhen();
  const [edit, setEdit] = useState(false);
  const [name, setName] = useState(dev.name);
  const [owner, setOwner] = useState(dev.person ?? "__shared");
  const via = dev.via_mark ? t("ui.household.via_mark") : dev.kind === "web" ? t("ui.household.via_signin") : t("ui.household.via_code");
  const icon = ["tv", "phone", "tablet", "web"].includes(dev.kind) ? dev.kind : dev.kind === "ios" ? "phone" : "tv";
  const save = async () => {
    try {
      if (name.trim() && name.trim() !== dev.name) await post(`/household/devices/${dev.id}/name`, { name: name.trim() });
      const next = owner === "__shared" ? null : owner;
      if (next !== dev.person) await post(`/household/devices/${dev.id}/person`, { person: next });
      toast(t("ui.devices.saved", { device: name.trim() || dev.name }));
      setEdit(false);
      reload();
    } catch (e) {
      toast(errorText(e));
    }
  };
  return (
    <div className="dev" data-id={dev.id} style={edit ? { flexWrap: "wrap" } : undefined}>
      <span className="di"><Icon k={icon} /></span>
      <div>
        <b>{dev.name}</b>
        <small>{via} · {when(dev.last_seen)}</small>
      </div>
      {!edit && <button className="linkbtn" onClick={() => setEdit(true)}>{t("ui.devices.change")}</button>}
      <button className="linkbtn danger" onClick={onSignOff}>{t("ui.household.sign_off")}</button>
      {edit && (
        <div className="grid2" style={{ flexBasis: "100%", marginTop: 10 }}>
          <div className="field">
            <label htmlFor={"dn-" + dev.id}>{t("ui.door.device_name")}</label>
            <input className="inp" id={"dn-" + dev.id} value={name} maxLength={60} onChange={(e) => setName(e.target.value)} />
          </div>
          <div className="field">
            <label htmlFor={"do-" + dev.id}>{t("ui.devices.belongs_to")}</label>
            <select className="sel" id={"do-" + dev.id} value={owner} onChange={(e) => setOwner(e.target.value)}>
              <option value="__shared">{t("ui.door.shared")}</option>
              {d.people.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
            </select>
          </div>
          <div className="req-act" style={{ gridColumn: "1/-1" }}>
            <button className="btn pri" onClick={save}>{t("ui.common.save")}</button>
            <button className="btn ghost" onClick={() => { setEdit(false); setName(dev.name); setOwner(dev.person ?? "__shared"); }}>{t("ui.common.cancel")}</button>
          </div>
        </div>
      )}
    </div>
  );
}

/** Devices that belong to nobody — the TV in the living room with its profile
 *  choice. They hang on no person, so they get a place of their own. */
function SharedDevices({ d, reload }: { d: All; reload: () => void }) {
  const { t } = useTranslation();
  const { toast } = useApp();
  const shared = d.devices.filter((x) => x.person === null);
  const signOff = (dev: Device) => {
    const el = document.querySelector<HTMLElement>(`.dev[data-id="${CSS.escape(dev.id)}"]`);
    removeEl(el, () => {
      let undone = false;
      const h = setTimeout(async () => {
        if (undone) return;
        try {
          await del(`/household/devices/${dev.id}`);
        } catch (e) {
          toast(errorText(e));
        }
        reload();
      }, 7000);
      toast(t("ui.household.device_off", { device: dev.name }), () => {
        undone = true;
        clearTimeout(h);
        if (el) el.removeAttribute("style");
        reload();
      });
    });
  };
  return (
    <section className="panel w-haushalt">
      <div className="ph"><h3>{t("ui.devices.shared_title")}</h3><span className="chip">{shared.length}</span></div>
      <p className="hint">{t("ui.devices.shared_hint")}</p>
      <div className="list">
        {shared.length ? shared.map((x) => <DeviceRow key={x.id} dev={x} d={d} reload={reload} onSignOff={() => signOff(x)} />) : <div className="empty">{t("ui.devices.shared_none")}</div>}
      </div>
    </section>
  );
}

/** What each person sees of 18+ — and what keeps it that way (owner, 09.11.2026). */
function SafetyCard({ d }: { d: All }) {
  const { t } = useTranslation();
  const { setUi } = useApp();
  const rows = d.people.map((p) => {
    const r = d.roles.find((x) => x.id === p.role_id);
    const adultSeen = r ? d.portals.filter((x) => x.adult && roleSees(r, x)) : [];
    const adultRole = !!r?.rights.includes("view_adult");
    const state: "bad" | "lock" | "nolock" | "adult" = adultSeen.length && !adultRole ? "bad" : adultRole ? "adult" : r?.child_lock ? "lock" : "nolock";
    return { p, r, adultSeen, state };
  });
  const worst = rows.some((x) => x.state === "bad") ? "bad" : rows.some((x) => x.state === "nolock") ? "warn" : "ok";
  return (
    <section className="panel w-haushalt">
      <div className="ph">
        <h3>{t("ui.safety.title")}</h3>
        <span className={"chip " + worst}>{t(`ui.safety.chip_${worst}`)}</span>
      </div>
      {rows.map(({ p, r, adultSeen, state }) => (
        <div key={p.id} className="toggle-row">
          <div>
            <b>{p.name} · {r?.name ?? "?"}</b>
            <small>
              {state === "lock" && (<><span style={{ color: "var(--ok)" }}>{t("ui.safety.sees_none")}</span> · {t("ui.safety.locked")}</>)}
              {state === "nolock" && (<><span style={{ color: "var(--ok)" }}>{t("ui.safety.sees_none")}</span> · <span style={{ color: "var(--warn)" }}>{t("ui.safety.no_lock")}</span></>)}
              {state === "adult" && (adultSeen.length ? t("ui.safety.adult_sees", { list: adultSeen.map((x) => x.name).join(", ") }) : t("ui.safety.adult_none_on"))}
              {state === "bad" && <span style={{ color: "var(--bad)" }}>{t("ui.safety.bad", { list: adultSeen.map((x) => x.name).join(", "), role: r?.name })}</span>}
            </small>
          </div>
          {state === "nolock" || state === "bad" ? (
            <button className="btn sm" onClick={() => setUi({ tab: "rol", role: r?.id })}>{t("ui.safety.to_role")}</button>
          ) : (
            <span className="av s" style={{ background: p.color }}>{ini(p.name)}</span>
          )}
        </div>
      ))}
    </section>
  );
}

function PersonDetail({ p, d, reload }: { p: Person; d: All; reload: () => void }) {
  const { t } = useTranslation();
  const { ui, setUi, toast, setLayer, me } = useApp();
  const { sees, rsum } = useRsum(d);
  const r = d.roles.find((x) => x.id === p.role_id) ?? d.roles[0];
  const holders = d.people.filter((x) => x.console).length;
  const last = p.console && holders === 1;
  const devs = d.devices.filter((x) => x.person === p.id);
  const grant = ui.grant === p.id;
  const [msg, setMsg] = useState<{ text: string; bad: boolean } | null>(null);

  const setRole = async (role: string, confirmed = false) => {
    const next = d.roles.find((x) => x.id === role);
    const opens = !!next?.rights.includes("view_adult") && !r?.rights.includes("view_adult");
    if (opens && !confirmed) {
      setLayer(<AdultConfirm d={d} names={[p.name]} role={next!} onConfirm={() => { setLayer(null); setRole(role, true); }} />);
      return;
    }
    try {
      await post(`/household/people/${p.id}/role`, { role });
      toast(t("ui.household.role_set", { name: first(p.name), role: d.roles.find((x) => x.id === role)?.name }));
      reload();
    } catch (e) {
      toast(errorText(e));
    }
  };
  const access = async () => {
    const pin = (document.getElementById("g-pin") as HTMLInputElement | null)?.value.trim() ?? "";
    const mine = (document.getElementById("g-me") as HTMLInputElement).value.trim();
    if (!p.console && !/^\d{4,8}$/.test(pin)) return setMsg({ text: t("ui.household.pin_for_needs", { name: first(p.name) }), bad: true });
    if (!/^\d{4,8}$/.test(mine)) return setMsg({ text: t("ui.household.my_pin_missing"), bad: true });
    try {
      await post(`/household/people/${p.id}/console`, p.console ? { on: false, my_pin: mine } : { on: true, my_pin: mine, pin });
      setUi({ grant: null });
      setMsg(null);
      toast(p.console ? t("ui.household.console_revoked", { name: first(p.name) }) : t("ui.household.console_granted", { name: first(p.name) }));
      if (p.id === me.id && p.console) location.reload();
      reload();
    } catch (e) {
      setMsg({ text: errorText(e), bad: true });
    }
  };
  /** Sign a device off — gone at once, really gone after the toast unless undone
   *  (usability review: it cut off the family TV with one click). */
  const signOff = (dev: Device) => {
    const el = document.querySelector<HTMLElement>(`.dev[data-id="${CSS.escape(dev.id)}"]`);
    removeEl(el, () => {
      let undone = false;
      const h = setTimeout(async () => {
        if (undone) return;
        try {
          await del(`/household/devices/${dev.id}`);
        } catch (e) {
          toast(errorText(e));
        }
        reload();
      }, 7000);
      toast(t("ui.household.device_off", { device: dev.name }), () => {
        undone = true;
        clearTimeout(h);
        if (el) el.removeAttribute("style");
        reload();
      });
    });
  };
  const renewMark = async () => {
    try {
      const a = await del(`/household/people/${p.id}/mark`);
      toast(t("ui.household.mark_renewed", { count: a.devices_removed ?? 0 }));
      reload();
    } catch (e) {
      toast(errorText(e));
    }
  };
  const remove = async () => {
    try {
      await del(`/household/people/${p.id}`);
      toast(t("ui.household.removed", { name: p.name }));
      setUi({ sel: null });
      reload();
    } catch (e) {
      toast(errorText(e));
    }
  };

  return (
    <section className="detail panel" aria-label={p.name}>
      <button className="btn ghost back" onClick={() => setUi({ sel: null })}>
        <Icon k="back" /> {t("ui.household.all_people")}
      </button>
      <div className="dhead">
        <span className="av l" style={{ background: p.color }}>{ini(p.name)}</span>
        <div>
          <h2>{p.name}</h2>
          <div className="row">
            <span className="chip role" style={{ ["--rc" as any]: r?.color }}>{r?.name}</span>
            {p.console && <span className="chip ok">{t("ui.household.console")}</span>}
          </div>
        </div>
      </div>
      {isLegacyPerson(p, d.devices) && <div className="flag">{t("ui.household.legacy_flag")}</div>}
      <div className="sec">
        <h4>{t("ui.household.role")}</h4>
        <div className="row">
          <select className="sel" aria-label={t("ui.household.role")} value={p.role_id} onChange={(e) => setRole(e.target.value)}>
            {d.roles.map((x) => (
              <option key={x.id} value={x.id}>{x.name}</option>
            ))}
          </select>
          {r && <span className="hint">{rsum(r)}</span>}
          <button className="linkbtn" onClick={() => setUi({ tab: "rol", role: r?.id })}>{t("ui.household.edit_role")}</button>
        </div>
        {r && (() => {
          const adultSeen = sees(r).filter((x) => x.adult);
          return adultSeen.length ? (
            <div className="flag bad">{t("ui.household.sees_adult", { name: first(p.name), list: adultSeen.map((x) => x.name).join(", ") })}</div>
          ) : (
            <p className="hint" style={{ color: "var(--ok)" }}>✓ {t("ui.household.no_adult", { name: first(p.name) })}{r.child_lock ? " · " + t("ui.safety.locked") : ""}</p>
          );
        })()}
        <div className="sights">
          {r && sees(r).map((x) => <span key={x.id} className="chip">{x.name}</span>)}
        </div>
      </div>
      <div className="sec">
        <h4>
          {t("ui.household.devices")}{" "}
          {p.has_mark && (
            <HoldButton small label={t("ui.household.renew_mark_hold")} onDone={renewMark} />
          )}
        </h4>
        <div className="list">
          {devs.length ? (
            devs.map((x) => <DeviceRow key={x.id} dev={x} d={d} reload={reload} onSignOff={() => signOff(x)} />)
          ) : (
            <div className="empty">{t("ui.household.no_device")}</div>
          )}
        </div>
        <p className="hint">{t("ui.household.mark_hint") + (r && !r.rights.includes("own_devices") ? t("ui.household.mark_hint_forbidden", { role: r.name }) : "") + "."}</p>
      </div>
      <div className="sec w-konto">
        <h4>{t("ui.household.console_access")}</h4>
        <div className="toggle-row">
          <div>
            <b>{p.console ? t("ui.household.has_console") : t("ui.household.no_console")}</b>
            <small>{p.console ? (last ? t("ui.household.only_holder") : t("ui.household.may_manage")) : t("ui.household.console_separate")}</small>
          </div>
          <Switch on={p.console} label={t("ui.household.console_access")} disabled={last} onChange={() => { setMsg(null); setUi({ grant: grant ? null : p.id }); }} />
        </div>
        {grant && (
          <div className="composer">
            <div className="grid2">
              {!p.console && (
                <div className="field">
                  <label htmlFor="g-pin">{t("ui.household.pin_for", { name: first(p.name) })}</label>
                  <input className="inp pin" id="g-pin" inputMode="numeric" maxLength={8} placeholder="4–8" type="password" autoFocus />
                </div>
              )}
              <div className="field">
                <label htmlFor="g-me">{t("ui.household.my_pin")}</label>
                <input className="inp pin" id="g-me" inputMode="numeric" maxLength={8} type="password" autoFocus={p.console} onKeyDown={(e) => e.key === "Enter" && access()} />
              </div>
            </div>
            <p className="hint" style={msg?.bad ? { color: "var(--bad)" } : undefined}>
              {msg?.text ?? (p.console ? t("ui.household.revoke_hint", { name: first(p.name) }) : t("ui.household.grant_hint"))}
            </p>
            <div className="req-act">
              <button className="btn pri" onClick={access}>{p.console ? t("ui.household.revoke") : t("ui.household.grant")}</button>
              <button className="btn ghost" onClick={() => setUi({ grant: null })}>{t("ui.common.cancel")}</button>
            </div>
          </div>
        )}
        {p.console && (
          <div className="row">
            <button className="btn" onClick={() => setLayer(<PinSheet p={p} />)}>
              <Icon k="key" /> {t("ui.household.change_pin")}
            </button>
          </div>
        )}
      </div>
      <div className="sec">
        <h4>{t("ui.household.remove")}</h4>
        <p className="hint">{t("ui.household.remove_hint")}</p>
        <div className="row">
          {last ? <span className="hint">{t("ui.household.last_stays")}</span> : p.id === me.id ? <span className="hint">{t("ui.household.not_yourself")}</span> : <HoldButton label={t("ui.household.hold_remove")} onDone={remove} />}
        </div>
      </div>
    </section>
  );
}

function PinSheet({ p }: { p: Person }) {
  const { t } = useTranslation();
  const { setLayer, toast } = useApp();
  const [msg, setMsg] = useState<string | null>(null);
  const save = async () => {
    const v = (id: string) => (document.getElementById(id) as HTMLInputElement).value;
    const a = v("pn1"), b = v("pn2"), c = v("pn3");
    if (!/^\d{4,8}$/.test(a)) return setMsg(t("ui.household.pin_new_format"));
    if (a !== b) return setMsg(t("ui.household.pin_mismatch"));
    if (!/^\d{4,8}$/.test(c)) return setMsg(t("ui.household.my_pin_missing_short"));
    try {
      await post(`/household/people/${p.id}/pin`, { pin: a, my_pin: c });
      setLayer(null);
      toast(t("ui.household.pin_changed"));
    } catch (e) {
      setMsg(errorText(e));
    }
  };
  return (
    <Sheet>
      <span className="eyebrow w-konto">{t("ui.household.console")}</span>
      <h3>{t("ui.household.change_pin")}</h3>
      <p className="lead">{t("ui.household.pin_lead", { name: p.name })}</p>
      <div className="grid2">
        <div className="field"><label htmlFor="pn1">{t("ui.household.pin_new")}</label><input className="inp pin" id="pn1" inputMode="numeric" maxLength={8} type="password" autoFocus /></div>
        <div className="field"><label htmlFor="pn2">{t("ui.household.pin_again")}</label><input className="inp pin" id="pn2" inputMode="numeric" maxLength={8} type="password" /></div>
        <div className="field"><label htmlFor="pn3">{t("ui.household.pin_mine_now")}</label><input className="inp pin" id="pn3" inputMode="numeric" maxLength={8} type="password" onKeyDown={(e) => e.key === "Enter" && save()} /></div>
      </div>
      <p className="hint" style={msg ? { color: "var(--bad)" } : undefined}>{msg ?? t("ui.household.pin_digits")}</p>
      <div className="req-act">
        <button className="btn pri w-konto" onClick={save}>{t("ui.household.change_pin")}</button>
        <button className="btn ghost" onClick={() => setLayer(null)}>{t("ui.common.cancel")}</button>
      </div>
    </Sheet>
  );
}

function AddPerson({ d, done }: { d: All; done: (id: string) => void }) {
  const { t } = useTranslation();
  const { setLayer, toast } = useApp();
  const [msg, setMsg] = useState<string | null>(null);
  const make = async () => {
    const name = (document.getElementById("np-n") as HTMLInputElement).value.trim();
    const role = (document.getElementById("np-r") as HTMLSelectElement).value;
    if (!name) return setMsg(t("ui.setup.name_missing"));
    const used = new Set(d.people.map((p) => p.color));
    const color = ["#C47A3A", "#5BAE6E", "#C46BD6", "#D6A13A", "#4A90D9", "#E2564A"].find((c) => !used.has(c)) ?? "#C47A3A";
    try {
      const p = await post("/household/people", { name, role, color });
      setLayer(null);
      toast(t("ui.household.person_made", { name }));
      done(p.id);
    } catch (e) {
      setMsg(errorText(e));
    }
  };
  return (
    <Sheet>
      <span className="eyebrow w-haushalt">{t("ui.household.by_hand")}</span>
      <h3>{t("ui.household.add_person_title")}</h3>
      <p className="lead">{t("ui.household.add_person_lead")}</p>
      <div className="grid2">
        <div className="field"><label htmlFor="np-n">{t("ui.household.name")}</label><input className="inp" id="np-n" maxLength={60} autoFocus /></div>
        <div className="field">
          <label htmlFor="np-r">{t("ui.household.role")}</label>
          <select className="sel" id="np-r" defaultValue={d.roles.find((r) => r.id === "child")?.id ?? d.roles[0]?.id}>
            {d.roles.map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}
          </select>
        </div>
      </div>
      {msg && <p className="hint" style={{ color: "var(--bad)" }}>{msg}</p>}
      <div className="req-act">
        <button className="btn pri w-haushalt" onClick={make}>{t("ui.household.create")}</button>
        <button className="btn ghost" onClick={() => setLayer(null)}>{t("ui.common.cancel")}</button>
      </div>
    </Sheet>
  );
}

/** Before anybody gets to see 18+ portals: who, which portals — press and hold. */
function AdultConfirm({ d, names, role, onConfirm }: { d: All; names: string[]; role: Role; onConfirm: () => void }) {
  const { t } = useTranslation();
  const { setLayer } = useApp();
  const adult = d.portals.filter((x) => x.adult && role.portals.includes(x.id));
  return (
    <Sheet>
      <span className="eyebrow w-haushalt">{t("ui.household.adult_eyebrow")}</span>
      <h3>{t("ui.household.adult_title")}</h3>
      <p className="lead">{t("ui.household.adult_lead", { names: names.join(", "), role: role.name })}</p>
      <div className="flag bad">
        {adult.length ? t("ui.household.adult_list", { list: adult.map((x) => x.name + (x.on ? "" : " " + t("ui.household.adult_off"))).join(", ") }) : t("ui.household.adult_none_yet")}
      </div>
      <div className="req-act">
        <HoldButton label={t("ui.household.adult_hold")} onDone={onConfirm} />
        <button className="btn ghost" onClick={() => setLayer(null)}>{t("ui.common.cancel")}</button>
      </div>
    </Sheet>
  );
}

function NewRole({ onPick }: { onPick: (forChildren: boolean) => void }) {
  const { t } = useTranslation();
  const { setLayer } = useApp();
  return (
    <Sheet>
      <span className="eyebrow w-haushalt">{t("ui.household.roles")}</span>
      <h3>{t("ui.household.new_role_q")}</h3>
      <p className="lead">{t("ui.household.new_role_lead")}</p>
      <div className="req-act">
        <button className="btn pri w-haushalt" onClick={() => onPick(true)}>{t("ui.household.new_role_kids")}</button>
        <button className="btn" onClick={() => onPick(false)}>{t("ui.household.new_role_other")}</button>
        <button className="btn ghost" onClick={() => setLayer(null)}>{t("ui.common.cancel")}</button>
      </div>
    </Sheet>
  );
}

/** Lifting the child lock: own PIN, names, press and hold. */
function UnlockSheet({ r, names, done }: { r: Role; names: string[]; done: () => void }) {
  const { t } = useTranslation();
  const { setLayer, toast } = useApp();
  const [msg, setMsg] = useState<string | null>(null);
  const go = async () => {
    const pin = (document.getElementById("ul-pin") as HTMLInputElement).value.trim();
    if (!/^\d{4,8}$/.test(pin)) return setMsg(t("ui.household.my_pin_missing"));
    try {
      await post(`/household/roles/${r.id}/child_lock`, { on: false, my_pin: pin });
      setLayer(null);
      toast(t("ui.household.lock_lifted", { role: r.name }));
      done();
    } catch (e) {
      setMsg(errorText(e));
    }
  };
  return (
    <Sheet>
      <span className="eyebrow w-haushalt">{t("ui.household.adult_eyebrow")}</span>
      <h3>{t("ui.household.unlock_title")}</h3>
      <p className="lead">{names.length ? t("ui.household.unlock_lead", { names: names.join(", "), role: r.name }) : t("ui.household.unlock_lead_empty", { role: r.name })}</p>
      <div className="field">
        <label htmlFor="ul-pin">{t("ui.household.my_pin")}</label>
        <input className="inp pin" id="ul-pin" inputMode="numeric" maxLength={8} type="password" autoFocus />
      </div>
      {msg && <p className="hint" style={{ color: "var(--bad)" }}>{msg}</p>}
      <div className="req-act">
        <HoldButton label={t("ui.household.unlock_hold")} onDone={go} />
        <button className="btn ghost" onClick={() => setLayer(null)}>{t("ui.common.cancel")}</button>
      </div>
    </Sheet>
  );
}

// ── Roles ────────────────────────────────────────────────────────────────────

function Roles({ d, reload }: { d: All; reload: () => void }) {
  const { t } = useTranslation();
  const { ui, setUi, narrow, toast, setLayer } = useApp();
  const { sees } = useRsum(d);
  const sel = d.roles.find((r) => r.id === ui.role);
  const r = sel || (!narrow ? d.roles[0] : undefined);
  const add = () => setLayer(<NewRole onPick={make} />);
  const make = async (forChildren: boolean) => {
    setLayer(null);
    const used = new Set(d.roles.map((x) => x.color));
    try {
      const nr = await post("/household/roles", {
        name: t("ui.household.new_role"),
        color: ROLE_COLORS.find((c) => !used.has(c)) ?? ROLE_COLORS[2],
        rights: ["watch", "track_progress"],
        portals: d.portals.filter((p) => p.on && !p.adult).map((p) => p.id),
        child_lock: forChildren,
      });
      toast(t("ui.household.role_made"));
      setUi({ tab: "rol", role: nr.id });
      reload();
      setTimeout(() => (document.getElementById("r-name") as HTMLInputElement | null)?.select(), 300);
    } catch (e) {
      toast(errorText(e));
    }
  };
  return (
    <div className={"split" + (narrow && r ? " has-sel" : "")}>
      <div className="pick" role="listbox" aria-label={t("ui.household.roles")}>
        {d.roles.map((x) => (
          <button key={x.id} className="pi" role="option" style={{ ["--rc" as any]: x.color }} aria-selected={!!r && x.id === r.id} onClick={() => setUi({ role: x.id })}>
            <span className="rdot" />
            <span style={{ minWidth: 0 }}>
              <b>{x.name}</b>
              <small>{t("ui.household.people_n", { count: x.members })} · {t("ui.household.portals_n", { count: sees(x).length })}</small>
            </span>
          </button>
        ))}
        <button className="pi add" onClick={add}>{t("ui.household.add_role")}</button>
        <p className="hint" style={{ padding: "6px 4px" }}>{t("ui.household.roles_hint")}</p>
      </div>
      {r ? <RoleDetail key={r.id} r={r} d={d} reload={reload} /> : <div className="detail" />}
    </div>
  );
}

function RoleDetail({ r, d, reload }: { r: Role; d: All; reload: () => void }) {
  const { t } = useTranslation();
  const { setUi, toast, setLayer } = useApp();
  const { sees, rsum } = useRsum(d);
  const [name, setName] = useState(r.name);
  const members = d.people.filter((p) => p.role_id === r.id);
  const save = async (body: Record<string, unknown>) => {
    try {
      await patch(`/household/roles/${r.id}`, body);
      reload();
    } catch (e) {
      toast(errorText(e));
      reload();
    }
  };
  const toggleRight = (k: string) => {
    const on = !r.rights.includes(k);
    const body = { rights: on ? [...r.rights, k] : r.rights.filter((x) => x !== k) };
    // Opening 18+ for people who already hold this role needs a deliberate act.
    if (k === "view_adult" && on && members.length) {
      setLayer(<AdultConfirm d={d} names={members.map((x) => x.name)} role={{ ...r, rights: body.rights }} onConfirm={() => { setLayer(null); save(body); }} />);
      return;
    }
    save(body);
  };
  const togglePortal = async (pid: string, on: boolean, pname: string) => {
    try {
      await post(`/household/roles/${r.id}/portals`, { portal: pid, on });
      toast(t(on ? "ui.household.portal_visible" : "ui.household.portal_hidden", { portal: pname, role: r.name }));
      reload();
    } catch (e) {
      toast(errorText(e));
    }
  };
  const remove = async () => {
    try {
      await del(`/household/roles/${r.id}`);
      toast(t("ui.household.role_deleted", { role: r.name }));
      setUi({ role: null });
      reload();
    } catch (e) {
      toast(errorText(e));
    }
  };
  // With the child lock, 18+ portals are not even offered.
  const listed = d.portals.filter((p) => (p.on || p.adult) && !(r.child_lock && p.adult));
  const lockOn = async () => {
    try {
      await post(`/household/roles/${r.id}/child_lock`, { on: true });
      toast(t("ui.household.lock_set", { role: r.name }));
      reload();
    } catch (e) {
      toast(errorText(e));
    }
  };
  const hiddenOff = d.portals.filter((p) => !p.on && !p.adult).length;
  return (
    <section className="detail panel" style={{ ["--rc" as any]: r.color }}>
      <button className="btn ghost back" onClick={() => setUi({ role: null })}>
        <Icon k="back" /> {t("ui.household.all_roles")}
      </button>
      <div className="dhead">
        <h2 style={{ color: `color-mix(in srgb,${r.color} var(--mix),var(--ink))` }}>{r.name}</h2>
        <span className="hint">{rsum(r)}</span>
      </div>
      <div className="sec">
        <div className="grid2">
          <div className="field">
            <label htmlFor="r-name">{t("ui.household.name")}</label>
            <input className="inp" id="r-name" value={name} maxLength={30} onChange={(e) => setName(e.target.value)} onBlur={() => name.trim() && name.trim() !== r.name && save({ name: name.trim() })} onKeyDown={(e) => e.key === "Enter" && (e.target as HTMLInputElement).blur()} />
          </div>
          <div className="field">
            <span className="lbl">{t("ui.household.color")}</span>
            <div className="swatches">
              {ROLE_COLORS.map((c) => (
                <button key={c} className="swatch" style={{ ["--sc" as any]: c }} aria-pressed={c === r.color} aria-label={t("ui.household.color_n", { c })} onClick={() => save({ color: c })} />
              ))}
            </div>
          </div>
        </div>
      </div>
      <div className="sec">
        <div className="toggle-row" style={r.child_lock ? { border: "1px solid color-mix(in srgb,var(--ok) 45%,transparent)" } : undefined}>
          <div>
            <b><span className="ico-inline"><Icon k="shield" /></span> {t("ui.household.lock")}</b>
            <small>{r.child_lock ? t("ui.household.lock_on_hint") : t("ui.household.lock_off_hint")}</small>
          </div>
          <Switch on={r.child_lock} label={t("ui.household.lock")} onChange={(on) => (on ? lockOn() : setLayer(<UnlockSheet r={r} names={members.map((x) => x.name)} done={reload} />))} />
        </div>
        <h4>{t("ui.household.app_rights")}</h4>
        <div className="rights">
          {APP_RIGHTS.map((k) => {
            const locked = k === "view_adult" && r.child_lock;
            return (
              <div key={k} className="toggle-row">
                <div>
                  <b>{t(`ui.right.${k}`)}</b>
                  <small>{locked ? t("ui.household.locked_by_lock") : t(`ui.right.${k}_hint`)}</small>
                </div>
                <Switch on={r.rights.includes(k)} label={t(`ui.right.${k}`)} disabled={locked} onChange={() => toggleRight(k)} />
              </div>
            );
          })}
        </div>
      </div>
      <div className="sec">
        <h4>
          {t("ui.household.role_portals")} <span className="hint">{t("ui.household.visible_n", { n: sees(r).length })}</span>
        </h4>
        <div className="ports">
          {listed.map((p) => {
            const blk = p.adult && !r.rights.includes("view_adult");
            const off = !p.on;
            return (
              <div key={p.id} className="toggle-row">
                <div>
                  <b>{p.name}</b>
                  <small>{off ? t("ui.household.p_off") : blk ? t("ui.household.p_needs_adult") : p.adult ? t("ui.household.p_adult") : t("ui.household.p_all")}</small>
                </div>
                <Switch on={r.portals.includes(p.id) && !blk} label={p.name} disabled={blk} onChange={(on) => togglePortal(p.id, on, p.name)} />
              </div>
            );
          })}
        </div>
        <p className="hint">{t("ui.household.more_off", { count: hiddenOff })}</p>
      </div>
      <div className="sec">
        <h4>{t("ui.household.with_role")}</h4>
        <div className="row">
          {members.length ? members.map((p) => (
            <button key={p.id} className="chip role" style={{ ["--rc" as any]: p.color }} onClick={() => setUi({ tab: "ppl", sel: p.id, role: null })}>{p.name}</button>
          )) : <span className="hint">{t("ui.household.nobody_yet")}</span>}
        </div>
        <div className="row">
          {members.length ? <span className="hint">{t("ui.household.delete_later")}</span> : <HoldButton label={t("ui.household.hold_delete")} onDone={remove} />}
        </div>
      </div>
    </section>
  );
}
