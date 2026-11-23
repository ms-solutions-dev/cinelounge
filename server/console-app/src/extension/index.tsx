/**
 * The console's side of the extension module (`cl-extension`, see `./types.ts`):
 * its areas, the `<Slot>` the pages render, and its texts laid over the core's.
 */
import type { ComponentType } from "react";
import extension from "cl-extension";
import i18n from "../i18n";
import { ICONS } from "../icons";
import type { AreaSpec, SlotName, SlotProps } from "./types";

export { extension };

/** The extension's own pages, in its order. */
export const EXTENSION_AREAS: AreaSpec[] = extension.areas ?? [];

for (const a of EXTENSION_AREAS) ICONS[a.id] ??= a.icon;

/** Lays the extension's texts over the core's, deeply: added keys and
 *  replaced sentences. Called once in `main.tsx`, before the first render. */
export function installLanguages(): void {
  for (const [lang, table] of Object.entries(extension.languages ?? {})) {
    if (table) i18n.addResourceBundle(lang, "translation", table, true, true);
  }
}

/** Whatever the extension renders at this place; nothing without one. */
export function Slot<N extends SlotName>(props: { name: N } & SlotProps[N]) {
  const { name, ...rest } = props;
  const parts = (extension.slots?.[name] ?? []) as ComponentType<any>[];
  if (!parts.length) return null;
  return (
    <>
      {parts.map((Part, i) => (
        <Part key={i} {...rest} />
      ))}
    </>
  );
}
