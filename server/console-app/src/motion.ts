/**
 * Motion, ported 1:1 from the mockup (`enterAnim`, `startDust`, `layer`,
 * `removeEl`). Nothing here runs when the system asks for reduced motion.
 */
import { gsap } from "gsap";
import * as THREE from "three";
import { G, RM } from "./ui";

/** The page's entrance: hero image settles, title words rise, tiles follow. */
export function enterAnim(pg: HTMLElement): void {
  if (!G) return;
  const T = gsap.timeline({ defaults: { ease: "power3.out" } });
  const all = (sel: string) => Array.from(pg.querySelectorAll<HTMLElement>(sel));
  const from = (targets: Element[] | Element | null, vars: gsap.TweenVars, pos: number) => {
    const a = (Array.isArray(targets) ? targets : [targets]).filter(Boolean) as Element[];
    if (a.length) T.from(a, vars, pos);
  };
  const h = pg.querySelector(".hero");
  if (h) {
    from(h.querySelector(".img"), { scale: 1.12, duration: 1.8, ease: "power2.out" }, 0);
    from(h.querySelector(".cone"), { opacity: 0, rotate: -8, transformOrigin: "100% 0", duration: 1.6 }, 0);
    from(all(".hero h2 span"), { yPercent: 60, opacity: 0, stagger: 0.08, duration: 0.7 }, 0.15);
    from(all(".hero .eyebrow,.hero p"), { y: 12, opacity: 0, stagger: 0.07, duration: 0.5 }, 0.3);
  }
  from(all(".roll>span"), { yPercent: 110, stagger: 0.05, duration: 0.8 }, 0.3);
  from(
    all(".kpi,.panel,.req,.prow,.tile,.xc,.term,.tabs,.toolbar,.pick .pi").slice(0, 24),
    { y: 20, opacity: 0, stagger: 0.045, duration: 0.5, clearProps: "transform,opacity" },
    0.25,
  );
}

/** A layer (menu, pop-over, palette, sheet) slides in. */
export function layerIn(el: Element | null, narrow: boolean): void {
  if (!G || !el) return;
  gsap.from(el, { y: narrow && el.classList.contains("sheet") ? 60 : 10, opacity: 0, duration: 0.3, ease: "power2.out" });
}

/** An element folds away before it leaves the list. */
export function removeEl(el: Element | null, done: () => void): void {
  if (G && el) {
    gsap.to(el, { opacity: 0, y: -12, height: 0, paddingTop: 0, paddingBottom: 0, duration: 0.38, ease: "power2.in", onComplete: done });
  } else done();
}

/** The dust in the projector beam of the overview hero (three.js). */
export function startDust(cv: HTMLCanvasElement | null, dark: boolean): () => void {
  if (!cv) return () => {};
  let r: THREE.WebGLRenderer;
  try {
    r = new THREE.WebGLRenderer({ canvas: cv, alpha: true, antialias: true });
  } catch {
    return () => {};
  }
  r.setPixelRatio(Math.min(devicePixelRatio, 2));
  const sc = new THREE.Scene();
  const cam = new THREE.PerspectiveCamera(50, 1, 0.1, 100);
  cam.position.z = 8;
  const N = 700;
  const pos = new Float32Array(N * 3);
  const sp = new Float32Array(N);
  for (let i = 0; i < N; i++) {
    const t = Math.random();
    pos[i * 3] = 6 - t * 11 + (Math.random() - 0.5) * t * 2.5;
    pos[i * 3 + 1] = 4.2 - t * 3.6 + (Math.random() - 0.5) * (0.4 + t * 2.2);
    pos[i * 3 + 2] = (Math.random() - 0.5) * 3;
    sp[i] = 0.002 + Math.random() * 0.005;
  }
  const g = new THREE.BufferGeometry();
  g.setAttribute("position", new THREE.BufferAttribute(pos, 3));
  const pts = new THREE.Points(
    g,
    new THREE.PointsMaterial({
      color: dark ? 0xffd9a0 : 0x8f6500,
      size: 0.034,
      transparent: true,
      opacity: dark ? 0.8 : 0.5,
      blending: dark ? THREE.AdditiveBlending : THREE.NormalBlending,
      depthWrite: false,
    }),
  );
  sc.add(pts);
  const size = () => {
    const w = cv.clientWidth;
    const h = cv.clientHeight;
    if (!w || !h) return;
    r.setSize(w, h, false);
    cam.aspect = w / h;
    cam.updateProjectionMatrix();
  };
  size();
  const ro = new ResizeObserver(size);
  ro.observe(cv);
  const t0 = performance.now();
  let raf = 0;
  let alive = true;
  const loop = () => {
    if (!alive || !cv.isConnected) return;
    const t = (performance.now() - t0) / 1000;
    const p = pos; // the attribute holds this very array
    for (let i = 0; i < N; i++) {
      p[i * 3] -= sp[i] * 0.35;
      p[i * 3 + 1] += Math.sin(t * 0.7 + i) * sp[i] * 0.25;
      if (p[i * 3] < -6) p[i * 3] = 6;
    }
    g.attributes.position.needsUpdate = true;
    r.render(sc, cam);
    if (!RM) raf = requestAnimationFrame(loop);
  };
  loop();
  return () => {
    alive = false;
    cancelAnimationFrame(raf);
    ro.disconnect();
    g.dispose();
    r.dispose();
  };
}
