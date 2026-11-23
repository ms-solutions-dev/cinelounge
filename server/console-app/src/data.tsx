/**
 * Loading data for a page. **A failed request is said, never shown as empty**
 * — the old console's `load()` swallowed errors, and a broken route looked like
 * "nothing there" (inventory finding, 09.11.2026).
 */
import { type DependencyList, useCallback, useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { errorText } from "./i18n";

export function useLoad<T>(fn: () => Promise<T>, deps: DependencyList = []) {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<unknown>(null);
  const seq = useRef(0);
  const reload = useCallback(async () => {
    const n = ++seq.current;
    try {
      const d = await fn();
      if (n === seq.current) {
        setData(d);
        setError(null);
      }
    } catch (e) {
      if (n === seq.current) setError(e);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);
  useEffect(() => {
    reload();
  }, [reload]);
  return { data, error, reload, setData };
}

export function Loading() {
  const { t } = useTranslation();
  return <div className="loading">{t("ui.common.loading")}</div>;
}

export function LoadFail({ error, retry }: { error: unknown; retry: () => void }) {
  const { t } = useTranslation();
  return (
    <section className="panel loadfail">
      <div className="flag bad">{errorText(error)}</div>
      <button className="btn" onClick={retry}>
        {t("ui.common.retry")}
      </button>
    </section>
  );
}
