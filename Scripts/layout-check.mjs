// Layout check: finds text that overlaps other text, text cut off without an ellipsis, and text
// that sticks out of its card. Runs headless Chrome (a throwaway profile) against a running demo.
//
//   export SECONDPAD_TOKEN=$(openssl rand -hex 32)   # the demo page's key (64 hex)
//   SECONDPAD_PORT=8771 build/SecondPad.app/Contents/MacOS/SecondPad --demo [worst] &
//   PORT=8771 node Scripts/layout-check.mjs
//
// Prints one line per problem and exits 1 when there are any.
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const port = process.env.PORT || 8770;
const sizes = (process.env.SIZES || "1280x800,1280x768,1280x650,1024x600").split(",");
const chrome = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const profile = mkdtempSync(join(tmpdir(), "secondpad-check-"));
const dev = 9400 + Math.floor(Math.random() * 500);
const proc = spawn(chrome, ["--headless=new", `--remote-debugging-port=${dev}`, `--user-data-dir=${profile}`,
  "--no-first-run", "--hide-scrollbars", "about:blank"], { stdio: "ignore" });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let wsUrl;
for (let i = 0; i < 50 && !wsUrl; i++) {
  try { wsUrl = (await (await fetch(`http://localhost:${dev}/json`)).json()).find((t) => t.type === "page")?.webSocketDebuggerUrl; } catch {}
  if (!wsUrl) await sleep(200);
}
const ws = new WebSocket(wsUrl);
await new Promise((r) => ws.addEventListener("open", r, { once: true }));
let id = 0;
const pending = new Map();
ws.addEventListener("message", (e) => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result); pending.delete(m.id); } });
const send = (method, params = {}) => new Promise((r) => { pending.set(++id, r); ws.send(JSON.stringify({ id, method, params })); });
const evaluate = async (expression) => (await send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true })).result?.value;

// Runs inside the page.
const probe = `(() => {
  const visible = (el) => {
    for (let n = el; n && n.nodeType === 1; n = n.parentElement) {
      const cs = getComputedStyle(n);
      if (cs.display === "none" || cs.visibility === "hidden" || parseFloat(cs.opacity) < 0.05 || n.hidden) return false;
    }
    return true;
  };
  const onScreenPage = (el) => {
    const r = el.getBoundingClientRect();
    return r.right > 0 && r.left < innerWidth && r.bottom > 0 && r.top < innerHeight;
  };
  // When a sheet, the Now Playing screen or the low-battery screen is open, only what is on it counts.
  const overlay = [...document.querySelectorAll(".scrim, .lowbatt, .standby")].find((o) => !o.hidden && visible(o));
  const root = overlay || document.body;
  // A text's box clipped by every ancestor that hides overflow (ellipsized text isn't "outside").
  const clip = (el, r) => {
    let box = { left: r.left, right: r.right, top: r.top, bottom: r.bottom };
    for (let n = el; n && n !== document.body; n = n.parentElement) {
      const cs = getComputedStyle(n);
      if (cs.overflowX !== "visible" || cs.overflowY !== "visible") {
        const c = n.getBoundingClientRect();
        box = { left: Math.max(box.left, c.left), right: Math.min(box.right, c.right), top: Math.max(box.top, c.top), bottom: Math.min(box.bottom, c.bottom) };
      }
    }
    return box;
  };
  const items = [];
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  for (let t = walker.nextNode(); t; t = walker.nextNode()) {
    if (!t.textContent.trim()) continue;
    const el = t.parentElement;
    if (!el || ["SCRIPT", "STYLE"].includes(el.tagName) || el.closest(".sr-only") || !visible(el) || !onScreenPage(el)) continue;
    // The StandBy digits overlap on purpose (the original's tight setting) and their text boxes are
    // far larger than their ink: they are checked against the original by eye (standby-compare.png).
    if (el.classList.contains("sb-glyph")) continue;
    const range = document.createRange(); range.selectNodeContents(t);
    for (const raw of range.getClientRects()) {
      const r = clip(el, raw);
      if (r.right - r.left > 1 && r.bottom - r.top > 1) items.push({ el, r, text: t.textContent.trim().slice(0, 40) });
    }
  }
  const name = (el) => (el.id ? "#" + el.id : el.className ? "." + String(el.className).split(" ")[0] : el.tagName.toLowerCase());
  const problems = new Set();
  // 1) Text over text (different elements, not one inside the other).
  for (let i = 0; i < items.length; i++) for (let j = i + 1; j < items.length; j++) {
    const a = items[i], b = items[j];
    if (a.el === b.el || a.el.contains(b.el) || b.el.contains(a.el)) continue;
    const w = Math.min(a.r.right, b.r.right) - Math.max(a.r.left, b.r.left);
    const h = Math.min(a.r.bottom, b.r.bottom) - Math.max(a.r.top, b.r.top);
    if (w > 2 && h > 3) problems.add("OVERLAP " + name(a.el) + " \\"" + a.text + "\\" × " + name(b.el) + " \\"" + b.text + "\\"");
  }
  // 2) Cut text without an ellipsis or clamp, and 3) text outside its card.
  for (const { el, r, text } of items) {
    const cs = getComputedStyle(el);
    const clamped = cs.webkitLineClamp !== "none" && cs.webkitLineClamp !== "";
    if (el.scrollWidth > el.clientWidth + 1 && cs.overflowX !== "visible" && cs.textOverflow !== "ellipsis" && !clamped)
      problems.add("CUT " + name(el) + " \\"" + text + "\\"");
    const card = el.closest(".tile, .fp-card, .fp-panel, .fp-hero, .sh-card, .sh-stat, .sheet, .np-screen, .qt-pill, .cc-row");
    if (card) {
      const c = card.getBoundingClientRect();
      if (r.left < c.left - 1 || r.right > c.right + 1 || r.top < c.top - 1 || r.bottom > c.bottom + 1)
        problems.add("OUTSIDE " + name(el) + " \\"" + text + "\\" sticks out of " + name(card));
    }
  }
  // 4) A card's own content taller than the card (clipped at the bottom).
  for (const card of root.querySelectorAll(".tile, .fp-card, .fp-panel, .sh-card")) {
    if (!visible(card) || !onScreenPage(card)) continue;
    if (card.scrollHeight > card.clientHeight + 2 && getComputedStyle(card).overflowY !== "auto")
      problems.add("CLIPPED " + name(card) + " content " + card.scrollHeight + "px in " + card.clientHeight + "px");
  }
  return [...problems];
})()`;

const views = [
  ["main", null], ["focus", null],
  ["main", `document.querySelector('[data-sheet="cpu"]').click()`],
  ["main", `document.querySelector('[data-sheet="memory"]').click()`],
  ["main", `document.querySelector('[data-sheet="swap"]').click()`],
  ["main", `document.querySelector('[data-sheet="heat"]').click()`],
  ["main", `document.getElementById("npOpen").click()`],
  ["main", `window.standby.open()`],
];
let total = 0;
for (const size of sizes) {
  const [width, height] = size.split("x").map(Number);
  await send("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 1, mobile: false });
  for (const [page, script] of views) {
    await send("Page.navigate", { url: "about:blank" });
    await sleep(200);
    await send("Page.navigate", { url: `http://127.0.0.1:${port}/?k=${process.env.SECONDPAD_TOKEN || ""}#${page}` });
    await sleep(2500);
    if (script) { await evaluate(script); await sleep(700); }
    const found = (await evaluate(probe)) || [];
    for (const p of found) console.log(`${size} ${page}${script ? " +" + (script.match(/"(\w+)"/)?.[1] || "") : ""}: ${p}`);
    total += found.length;
  }
}
ws.close();
proc.kill();
await sleep(300);
rmSync(profile, { recursive: true, force: true });
console.log(total ? `${total} problem(s)` : "no problems");
process.exit(total ? 1 : 0);
