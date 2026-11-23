/**
 * Console extensions — the shape of what an extension may add to the console.
 *
 * The console builds with exactly one extension module, imported as
 * `cl-extension`. Without one it is `none.ts` (nothing added). When the folder
 * `src/extension/local/` exists, its `index.ts` is taken instead (see
 * `vite.config.ts`); the folder is ignored by Git and belongs to whoever runs
 * the server. Extension files sit inside `src/` so that they resolve `react`,
 * `i18next` and the console's own modules (`../../api`, `../../ui`, …) the
 * same way the core pages do. `docs/EXTENSIONS.md` describes the server side.
 *
 * Three things can be added, all optional:
 *
 * - **areas**: whole pages with their own place in the rail, before "Konto".
 *   Their texts follow the core's convention: `ui.area.<id>.name|sub|line`.
 * - **slots**: components the core pages render at named places, with the
 *   props listed in `SlotProps`.
 * - **languages**: texts per language, merged deeply over the core's. An
 *   extension may add keys and replace core sentences.
 *
 * A route's display name is a text too: `ui.route.<name>`, falling back to the
 * name in capitals (`routeLabel` in `../model.ts`).
 */
import type { ComponentType } from "react";
import type { Exit, Portal } from "../model";

/** The answer of `GET /network/exits`, with whatever extensions add to it. */
export type NetworkAnswer = {
  exits: Exit[];
  without_exit: { id: string; net: string }[];
} & Record<string, unknown>;

/** One offer of the marketplace as `GET /household/market` lists it. The core
 *  names its own fields; whatever an extension publishes as a manifest field
 *  (`FieldSpec.public_json`) stands beside them under its key. */
export type MarketEntry = {
  id: string;
  version: string;
  source: string;
  trust: "signed" | "unsigned" | "bad";
  installed: boolean;
} & Record<string, unknown>;

/** What each slot passes to the components rendered in it. */
export type SlotProps = {
  /** The network page, below the routes. */
  network: { answer: NetworkAnswer; reload: () => void };
  /** Inside one route's card on the network page (`direct` included). */
  "network.route": { route: Exit; answer: NetworkAnswer; reload: () => void };
  /** A portal's detail page, below the operation panel. */
  "portal.detail": { portal: Portal; reload: () => void };
  /** A portal's row in the list, below its name. */
  "portal.row": { portal: Portal };
  /** The overview, below the panels. */
  home: {};
  /** A marketplace tile, in the row of chips. */
  "market.tile": { entry: MarketEntry; exits: Exit[] };
  /** The install sheet, above the switch "on right away". `hold(why)` keeps
   *  that switch off while `why` is not null — the portal is installed, but
   *  something it needs is not there yet. */
  "market.install": { entry: MarketEntry; exits: Exit[]; hold: (why: string | null) => void };
};

export type SlotName = keyof SlotProps;

/** A page of its own. `icon` is SVG markup for a 24×24 view box, like `icons.ts`. */
export type AreaSpec = {
  id: string;
  icon: string;
  page: ComponentType;
  /** The hero picture; without one the area shows the network picture. */
  image?: string;
};

export interface ConsoleExtension {
  areas?: AreaSpec[];
  slots?: { [N in SlotName]?: ComponentType<SlotProps[N]>[] };
  languages?: Partial<Record<"de" | "en" | "tr", object>>;
}
