/**
 * Languages: German, English, Turkish — every visible sentence lives in
 * `languages/*.json`, none in the components.
 *
 * Placeholders are `{name}` (single braces), the same as the server's error
 * and event texts have always used.
 */
import i18n from "i18next";
import { initReactI18next } from "react-i18next";
import de from "./languages/de.json";
import en from "./languages/en.json";
import tr from "./languages/tr.json";
import { ServerError } from "./api";
import { routeLabel } from "./model";

export const LANGUAGES = ["de", "en", "tr"] as const;
export type Language = (typeof LANGUAGES)[number];
const KEY = "cl.console.lang";

function initial(): Language {
  try {
    const stored = localStorage.getItem(KEY);
    if (stored && (LANGUAGES as readonly string[]).includes(stored)) return stored as Language;
  } catch {
    /* no storage */
  }
  const nav = (navigator.language || "de").slice(0, 2);
  return (LANGUAGES as readonly string[]).includes(nav) ? (nav as Language) : "de";
}

i18n.use(initReactI18next).init({
  resources: { de: { translation: de }, en: { translation: en }, tr: { translation: tr } },
  lng: initial(),
  fallbackLng: "de",
  // Keys contain dots (`errors.auth.locked_out`); only `.` separates levels,
  // and error codes are looked up through `errorText` below.
  keySeparator: ".",
  nsSeparator: false,
  interpolation: { escapeValue: false, prefix: "{", suffix: "}" },
  returnNull: false,
});
document.documentElement.lang = i18n.language;

export function setLanguage(lang: Language): void {
  i18n.changeLanguage(lang);
  document.documentElement.lang = lang;
  try {
    localStorage.setItem(KEY, lang);
  } catch {
    /* no storage */
  }
}

/** Error codes contain a dot themselves, so they are looked up flat. */
export function errorText(err: unknown): string {
  const t = i18n.t.bind(i18n);
  if (err instanceof ServerError) {
    const table = (i18n.getResourceBundle(i18n.language, "translation") as any)?.errors ?? {};
    const fallback = (i18n.getResourceBundle("de", "translation") as any)?.errors ?? {};
    const sentence: string | undefined = table[err.code] ?? fallback[err.code];
    if (sentence) return fill(sentence, err.values);
    return t("ui.common.error_code", { code: err.code });
  }
  return t("ui.common.error_unknown");
}

/** An event line from the book; values are escaped because the text carries `<b>`. */
export function eventHtml(code: string, values: Record<string, unknown>, portalNames: Record<string, string> = {}): string {
  const key = variant(code.replace(/^event\./, ""), values || {});
  values = { ...(values || {}) };
  // Ids become names: a route through `routeLabel`, a portal id its name.
  if (typeof values.exit === "string") values.exit = routeLabel(i18n.t.bind(i18n), values.exit);
  if (typeof values.portal === "string" && portalNames[values.portal]) values.portal = portalNames[values.portal];
  const table = (i18n.getResourceBundle(i18n.language, "translation") as any)?.events ?? {};
  const sentence: string = table[key] ?? key;
  const safe: Record<string, string> = {};
  for (const [k, v] of Object.entries(values || {})) safe[k] = esc(String(v ?? ""));
  return fill(sentence, safe);
}

/** Two events have one sentence per outcome (as in the old console). */
function variant(key: string, values: Record<string, unknown>): string {
  if (key === "portal_switched") return values.on ? "portal_switched_on" : "portal_switched_off";
  if (key === "access_changed") return values.allowed ? "access_granted" : "access_revoked";
  return key;
}

function fill(s: string, values: Record<string, unknown>): string {
  return s.replace(/\{(\w+)\}/g, (m, k) => (k in values ? String(values[k]) : m));
}

export const esc = (s: string) =>
  s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);

export default i18n;
