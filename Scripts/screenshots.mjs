// Demo screenshots at tablet size (1280 × 800 CSS px, 2×), through headless Chrome's DevTools
// protocol, after a real wait so live data and animations have settled.
//
//   export SECONDPAD_TOKEN=$(openssl rand -hex 32)   # the demo page's key (64 hex)
//   build/SecondPad.app/Contents/MacOS/SecondPad --demo &
//   node Scripts/screenshots.mjs ../screenshots
//
// Uses a throwaway Chrome profile in a temp folder; nothing else is touched.
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const out = resolve(process.argv[2] || "screenshots");
const chrome = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const profile = mkdtempSync(join(tmpdir(), "secondpad-shots-"));
const port = 9400 + Math.floor(Math.random() * 500);
const proc = spawn(chrome, [
  "--headless=new", `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`,
  "--no-first-run", "--no-default-browser-check", "--hide-scrollbars", "about:blank",
], { stdio: "ignore" });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function target() {
  for (let i = 0; i < 50; i++) {
    try {
      const list = await (await fetch(`http://localhost:${port}/json`)).json();
      const page = list.find((t) => t.type === "page");
      if (page) return page.webSocketDebuggerUrl;
    } catch {}
    await sleep(200);
  }
  throw new Error("Chrome did not start");
}

const ws = new WebSocket(await target());
await new Promise((r, reject) => {
  ws.addEventListener("open", r, { once: true });
  ws.addEventListener("error", () => reject(new Error("DevTools socket refused")), { once: true });
});
let id = 0;
const pending = new Map();
ws.addEventListener("message", (e) => {
  const msg = JSON.parse(e.data);
  if (msg.id && pending.has(msg.id)) { pending.get(msg.id)(msg.result); pending.delete(msg.id); }
});
const send = (method, params = {}) => new Promise((r) => { pending.set(++id, r); ws.send(JSON.stringify({ id, method, params })); });

// SIZE=1280x650 checks other screens (a Chrome tab on the tablet is about that tall).
const [width, height] = (process.env.SIZE || "1280x800").split("x").map(Number);
await send("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 2, mobile: false });
// [page, file, script run before the shot]. SHOTS=main,cpu picks some.
const all = [
  ["main", "main-page.png"],
  ["focus", "pomodoro-page.png"],
  ["main", "sheet-cpu.png", `document.querySelector('[data-sheet="cpu"]').click()`, 90000],
  ["main", "sheet-heat.png", `document.querySelector('[data-sheet="heat"]').click()`],
  ["main", "now-playing.png", `document.getElementById("npOpen").click()`],
  ["main", "standby.png", `window.standby.open()`],
];
const wanted = (process.env.SHOTS || "").split(",").filter(Boolean);
// OUT_PREFIX names the files (e.g. "warnings-" for the worst-case run).
const prefix = process.env.OUT_PREFIX || "";
for (const [page, file, script, wait = 4000] of all.filter(([, f]) => !wanted.length || wanted.some((w) => f.startsWith(w)))) {
  await send("Page.navigate", { url: "about:blank" });   // a hash-only change wouldn't reload the page
  await sleep(300);
  await send("Page.navigate", { url: `http://127.0.0.1:${process.env.PORT || 8770}/?k=${process.env.SECONDPAD_TOKEN || ""}#${page}` });
  await sleep(wait);
  if (script) { await send("Runtime.evaluate", { expression: script }); await sleep(1200); }
  const shot = await send("Page.captureScreenshot", { format: "png" });
  writeFileSync(join(out, prefix + file), Buffer.from(shot.data, "base64"));
  console.log("wrote", join(out, prefix + file));
}
ws.close();
proc.kill();
await sleep(300);
rmSync(profile, { recursive: true, force: true });
