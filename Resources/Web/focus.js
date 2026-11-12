/* SecondPad — Deep Focus page (Pomodoro only).
   States: idle · focus · paused · break, plus the end-of-period prompt. The Mac sends the
   running period (purity, focus breaks, visits, minute strip), today's log and the week. */
(() => {
  "use strict";

  const $ = (id) => document.getElementById(id);
  const L = window.Logic;
  const root = $("focusPage");
  if (!root) return;

  let pomo = null;
  let lastPhase = null;
  let settings = { breathingPattern: "box" };
  let returnTimer = null;

  /* ═══ From app.js ═══════════════════════════════════════════ */

  window.focusPage = {
    pomodoro(m) { autoOpen(m); pomo = m; render(); },
    week(m) { renderWeek(m.days || []); },
    settings(m) { settings = { ...settings, ...m }; breathing.sync(L.focusState(pomo) === "break"); },
    claude(rows) {
      const top = [...rows].sort((a, b) => ({ waiting: 0, error: 1, working: 2, done: 3 }[a.state] ?? 9)
        - ({ waiting: 0, error: 1, working: 2, done: 3 }[b.state] ?? 9))[0];
      const el = $("fpClaude");
      el.hidden = !top;
      if (!top) return;
      el.dataset.state = top.state;
      $("fpClaudeState").textContent = L.stateWord(top.state);
      const act = $("fpClaudeAct");
      act.textContent = top.activity || "";
      act.hidden = !top.activity;
    },
    // The original's wording, with the numbers: "CPU peak · 100%", "Overheating · 98°C",
    // "Low memory · swap 8.2 GB", or "CPU 100% + Heat 98°" when several.
    system(cpu, heat, memory, s = {}) {
      const el = $("fpSys");
      el.hidden = !(cpu || heat || memory);
      if (el.hidden) return;
      const c = `${Math.round(s.cpuPercent ?? 0)}%`;
      const t = s.temperature != null ? `${Math.round(s.temperature)}°` : "";
      const sw = `swap ${(s.swapUsedGB ?? 0).toFixed(1)} GB`;
      const parts = [cpu && `CPU ${c}`, memory && "Memory", heat && `Heat ${t}`].filter(Boolean);
      $("fpSysText").textContent = parts.length > 1 ? parts.join(" + ")
        : cpu ? `CPU peak · ${c}` : memory ? `Low memory · ${sw}` : `Overheating · ${t}C`;
    },
  };

  /* Focus started on the Mac → this page opens (only at that moment, so you can still leave).
     Reset → back to the main page after 3 s, if you're still here. */
  function autoOpen(m) {
    const started = m.phase === "focus" && m.running && lastPhase !== "focus";
    const ended = lastPhase != null && lastPhase !== "idle" && m.phase === "idle";
    lastPhase = m.phase;
    if (started && !window.pagePinned) window.showFocusPage?.();
    if (m.phase !== "idle") { clearTimeout(returnTimer); returnTimer = null; }
    if (ended && document.body.dataset.page === "focus") {
      window.toast?.("Session ended · back to main");
      clearTimeout(returnTimer);
      returnTimer = setTimeout(() => {
        returnTimer = null;
        if ((!pomo || pomo.phase === "idle") && document.body.dataset.page === "focus") window.showMainPage?.();
      }, 3000);
    }
  }

  /* ═══ Drawing ═══════════════════════════════════════════════ */

  function render() {
    const m = pomo;
    const state = L.focusState(m);
    root.dataset.state = state;
    const kind = m?.phase === "longBreak" ? "long" : m?.phase === "break" ? "short" : "";
    if (kind) root.dataset.breakKind = kind; else delete root.dataset.breakKind;
    root.dataset.ask = m?.prompt || "";
    const s = L.focusSummary(m, state);
    renderHead(m, state, s);
    renderHero(m, state);
    renderAsk(m);
    renderStrip(s, state);
    renderStats(m, s);
    renderWent(s, state);
    breathing.sync(state === "break");
  }

  function renderHead(m, state, s) {
    const every = m?.longBreakEvery || 4;
    const done = m?.completedSinceLongBreak || 0;
    const cycle = $("fpCycle");
    if (cycle.children.length !== every) cycle.replaceChildren(...Array.from({ length: every }, () => document.createElement("li")));
    [...cycle.children].forEach((li, i) => {
      li.classList.toggle("is-done", i < done);
      li.classList.toggle("is-now", i === done && (state === "focus" || state === "paused"));
    });
    $("fpStatusText").textContent = m?.prompt ? "Up next" : { idle: "Ready", focus: "Focusing", paused: "Paused", break: "Break" }[state];

    let sub;
    if (m?.prompt === "focus") sub = "Break's over. Start the next session when you're ready";
    else if (m?.prompt) sub = `Session done. ${m.completed} today`;
    else if (m?.autoPaused) sub = "Paused while the Mac was asleep or locked";
    else if (state === "focus" || state === "paused") sub = `Pomodoro ${done + 1} of ${every} in this cycle`;
    else if (state === "break" && m?.phase === "longBreak") sub = "Long break. Walk away from the screen.";
    else if (state === "break") sub = s.purity != null ? `Breathe. Last session: ${s.purity}% on task` : "Breathe.";
    else sub = (m?.completed || 0) > 0 ? `${m.completed} done today. Start the next one on the Mac` : "Start a Pomodoro on the Mac";
    $("fpSub").textContent = sub;
  }

  function renderHero(m, state) {
    $("fpPhase").textContent = {
      idle: "Ready",
      focus: "Focus",
      paused: m?.phase === "focus" ? "Focus · paused" : "Break · paused",
      break: m?.phase === "longBreak" ? "Long break" : "Break",
    }[state];
    $("fpTime").textContent = L.clock(m ? m.remaining : 1500);

    // The one loud moment: you just went to a distracting app.
    const app = state === "focus" ? m.live?.distractedNow : null;
    root.classList.toggle("is-distracted", Boolean(app));
    if (!app) return;
    $("fpNowApp").textContent = app;
    const id = m.live.distractedNowBundleId;
    const icon = $("fpNowIcon"), mono = $("fpNowMono");
    const hit = (m.live.distractions || []).find((d) => d.app === app);
    mono.textContent = app.trim().charAt(0).toUpperCase();
    mono.style.setProperty("--mono", hit?.colorHex || "#ff9f0a");
    const src = id ? window.withKey(`/appicon?id=${encodeURIComponent(id)}`) : null;
    if (src && icon.dataset.failed !== src) {
      if (icon.getAttribute("src") !== src) { icon.hidden = true; mono.hidden = false; icon.src = src; }
    } else { icon.hidden = true; mono.hidden = false; }
  }

  const ASK = {
    break: { q: "Focus done · take a break?", yes: "Start break", no: "Skip" },
    longBreak: { q: "4 in a row · long break?", yes: "Start break", no: "Skip" },
    focus: { q: "Break's over · focus again?", yes: "Start focus", no: "Not now" },
  };
  function renderAsk(m) {
    const a = m?.prompt && ASK[m.prompt];
    if (!a) return;
    $("fpPhase").textContent = a.q;
    $("fpAskYes").textContent = a.yes;
    $("fpAskNo").textContent = a.no;
    $("fpTime").textContent = L.clock(m.prompt === "focus" ? (m.focusMinutes || 25) * 60 : m.total);
  }
  // The real icon replaces the letter once it has loaded; a missing one keeps the letter.
  $("fpNowIcon").addEventListener("load", () => { $("fpNowIcon").hidden = false; $("fpNowMono").hidden = true; });
  $("fpNowIcon").addEventListener("error", () => { $("fpNowIcon").dataset.failed = $("fpNowIcon").getAttribute("src"); });
  $("fpAskYes").addEventListener("click", () => pomo?.prompt && window.sendCommand?.("pomodoro.answer", { yes: true }));
  $("fpAskNo").addEventListener("click", () => pomo?.prompt && window.sendCommand?.("pomodoro.answer", { yes: false }));

  function renderStrip(s, state) {
    const strip = $("fpStrip");
    const count = Math.max(1, s.totalMinutes);
    if (strip.children.length !== count) strip.replaceChildren(...Array.from({ length: count }, () => document.createElement("i")));
    const done = s.minutes;
    [...strip.children].forEach((bar, i) => {
      const finished = i < done.length;
      const now = !finished && i === done.length && s.currentMinute;
      bar.classList.toggle("is-on", finished && !done[i]);
      bar.classList.toggle("is-off", finished && done[i]);
      bar.classList.toggle("is-now", Boolean(now));
      bar.classList.toggle("is-off-now", Boolean(now && s.currentMinute.distracted));
    });
    const distracted = done.filter(Boolean).length;
    const text = state === "idle" ? `${count}-minute sessions`
      : state === "break" ? `Last session · ${done.length} min, ${distracted} distracted`
      : `${done.length} of ${count} min${distracted ? ` · ${distracted} distracted` : ""}`;
    $("fpStripText").textContent = text;
    strip.setAttribute("aria-label", text);
  }

  let logosKey = "";
  function renderStats(m, s) {
    $("fpPurity").textContent = s.purity == null ? "—" : `${s.purity}%`;
    $("fpPurityBar").style.transform = `scaleX(${(s.purity ?? 0) / 100})`;

    $("fpBreaks").textContent = String(s.breaks);
    const shown = Math.min(s.breaks, 14);
    $("fpBreakTicks").replaceChildren(...(shown === 0 ? [tick(true)] : Array.from({ length: shown }, () => tick(false))));
    $("fpBreaksNote").textContent = s.breaks === 0 ? "no slips yet" : `left focus ${s.breaks === 1 ? "1 time" : `${s.breaks} times`}`;

    $("fpDistracted").textContent = L.dur(s.distractions.reduce((sum, d) => sum + d.seconds, 0));
    const key = s.distractions.slice(0, 6).map((d) => d.app).join("␟");
    if (key !== logosKey) {
      logosKey = key;
      $("fpLogos").replaceChildren(...s.distractions.slice(0, 6).map((d) => logo(d, 24)));
    }
    const top = s.distractions[0];
    $("fpMost").textContent = top ? `most: ${top.app} ×${top.visits}` : "nothing yet";

    const completed = m?.completed || 0;
    $("fpToday").textContent = String(completed);
    const count = Math.min(Math.max(completed, m?.longBreakEvery || 4), 10);
    $("fpTodayDots").replaceChildren(...Array.from({ length: count }, (_, i) => {
      const dot = document.createElement("i");
      if (i < completed) dot.className = "is-done";
      return dot;
    }));
    $("fpTodayNote").textContent = completed === 1 ? "pomodoro completed" : "pomodoros completed";
  }

  function tick(empty) {
    const i = document.createElement("i");
    if (empty) i.className = "is-empty";
    return i;
  }

  /* The real app icon comes from the Mac; sites and unknown apps get a letter in their colour. */
  function logo(d, size) {
    const mono = () => {
      const span = document.createElement("span");
      span.className = "fp-mono";
      span.textContent = (d.app || "?").trim().charAt(0).toUpperCase();
      span.style.setProperty("--mono", d.colorHex || "#ff9f0a");
      span.style.width = span.style.height = `${size}px`;
      return span;
    };
    if (!d.bundleId) return mono();
    const img = document.createElement("img");
    img.alt = "";
    img.width = img.height = size;
    img.src = window.withKey(`/appicon?id=${encodeURIComponent(d.bundleId)}`);
    img.addEventListener("error", () => img.replaceWith(mono()), { once: true });
    return img;
  }

  let wentKey = "";
  function renderWent(s, state) {
    $("fpWentNote").textContent = s.scope;
    const list = $("fpWent");
    const rows = s.distractions.slice(0, 5);
    const max = Math.max(1, ...rows.map((d) => d.seconds));
    const key = rows.map((d) => d.app).join("␟");
    if (key !== wentKey) {
      wentKey = key;
      list.replaceChildren(...rows.map((d) => {
        const li = document.createElement("li");
        const name = document.createElement("span");
        name.className = "fp-name";
        name.textContent = d.app;
        const track = document.createElement("span");
        track.className = "fp-track";
        track.append(document.createElement("span"));
        const visits = document.createElement("span");
        visits.className = "fp-visits";
        const secs = document.createElement("span");
        secs.className = "fp-secs";
        li.append(logo(d, 32), name, track, visits, secs);
        return li;
      }));
    }
    [...list.children].forEach((li, i) => {
      const d = rows[i];
      li.querySelector(".fp-track span").style.transform = `scaleX(${d.seconds / max})`;
      li.querySelector(".fp-visits").textContent = `×${d.visits}`;
      li.querySelector(".fp-secs").textContent = L.dur(d.seconds);
    });
    const empty = $("fpWentEmpty");
    empty.hidden = rows.length > 0;
    empty.textContent = state === "idle" ? "No distractions logged today."
      : state === "break" ? "Clean session. Nothing pulled you away." : "Nothing pulled you away. Keep going.";
  }

  /* Height = focus time that day, colour = quality (70 %+ on task). */
  function renderWeek(days) {
    if (!days.length) return;
    const { total, bars } = L.weekBars(days);
    $("fpWeekTotal").textContent = `${total.toFixed(1)}h`;
    const names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    $("fpWeek").replaceChildren(...bars.map((b, i) => {
      const col = document.createElement("div");
      col.className = "fp-bar" + (i === bars.length - 1 ? " is-today" : "");
      const value = document.createElement("b");
      value.textContent = b.hours >= 0.05 ? `${b.hours.toFixed(1)}h` : "";
      const bar = document.createElement("i");
      bar.className = b.kind === "none" ? "is-none" : b.kind === "low" ? "is-low" : "";
      bar.style.height = `calc((100% - 20px) * ${b.height})`;
      const well = document.createElement("div");
      well.className = "fp-bar-well";
      well.append(value, bar);
      const label = document.createElement("span");
      const [y, mo, da] = b.date.split("-").map(Number);
      label.textContent = names[new Date(y, mo - 1, da).getDay()];
      col.append(well, label);
      return col;
    }));
  }

  /* ═══ Breathing guide during breaks ═════════════════════════
     box 4-4-4-4 · 4-7-8 · cyclic sighing (2 in + 1 sip + 6 out). The orb grows on the in-breath,
     holds, shrinks on the out-breath; the ring fills once per step. It moves even with Reduce
     Motion on: the motion is the guide, not decoration. */
  const BREATH = {
    box: { name: "Box breathing · 4-4-4-4", steps: [["in", 4, 1], ["hold", 4], ["out", 4, 0.34], ["hold", 4]] },
    478: { name: "4-7-8 breathing", steps: [["in", 4, 1], ["hold", 7], ["out", 8, 0.34]] },
    sigh: { name: "Cyclic sighing · long exhale", steps: [["in", 2, 0.8], ["sip", 1, 1], ["out", 6, 0.34]] },
  };
  const SAY = { in: "Breathe in", sip: "One more sip", hold: "Hold", out: "Breathe out" };
  const SMOOTH = "cubic-bezier(0.45, 0, 0.55, 1)";

  const breathing = (() => {
    const orb = $("fpBreathOrb"), arc = $("fpBreathArc");
    const say = $("fpBreathSay"), count = $("fpBreathCount"), hint = $("fpBreathHint");
    let running = false, key = null, step = 0, scale = 0.34;
    let stepTimer = null, countTimer = null, orbAnim = null, arcAnim = null;
    const pattern = () => BREATH[settings.breathingPattern] || BREATH.box;

    function stop() {
      running = false;
      clearTimeout(stepTimer); clearInterval(countTimer);
      orbAnim?.cancel(); arcAnim?.cancel();
      orb.style.transform = `scale(${scale = 0.34})`;
      count.textContent = "";
    }
    function start() {
      running = true;
      key = settings.breathingPattern;
      step = 0;
      hint.textContent = pattern().name;
      run();
    }
    function run() {
      if (!running) return;
      const steps = pattern().steps;
      const [kind, secs, target] = steps[step % steps.length];
      const ms = secs * 1000;
      say.textContent = SAY[kind];
      say.classList.toggle("is-hold", kind === "hold");
      say.animate([{ opacity: 0.35 }, { opacity: 1 }], { duration: 180, easing: "ease-out" });
      let left = secs;
      count.textContent = left;
      clearInterval(countTimer);
      countTimer = setInterval(() => { left -= 1; if (left > 0) count.textContent = left; }, 1000);
      const to = target ?? scale;
      orbAnim?.cancel();
      orbAnim = orb.animate([{ transform: `scale(${scale})` }, { transform: `scale(${to})` }],
        { duration: ms, easing: kind === "hold" ? "linear" : SMOOTH, fill: "forwards" });
      scale = to;
      orb.style.transform = `scale(${to})`;
      arcAnim?.cancel();
      arcAnim = arc.animate([{ strokeDashoffset: 100 }, { strokeDashoffset: 0 }], { duration: ms, easing: "linear", fill: "forwards" });
      stepTimer = setTimeout(() => { step += 1; run(); }, ms);
    }
    return {
      sync(active) {
        const changed = key !== settings.breathingPattern;
        if (active && (!running || changed)) { stop(); start(); }
        else if (!active && running) stop();
        if (!active) hint.textContent = pattern().name;
      },
    };
  })();

  render();
})();
