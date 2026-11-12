/* SecondPad — the tablet page: connection, main page, pages, side panel. */
(() => {
  "use strict";

  const $ = (id) => document.getElementById(id);
  const L = window.Logic;
  /* The tablet this runs on has Android's animations switched off, which makes Chrome report
     "reduce motion". Here motion carries meaning (the fan's speed, Claude working, a task just done,
     a peak starting), so it stays on, as in the original. */
  const reduceMotion = false;

  /* ═══ The page's key ════════════════════════════════════════
     SecondPad opens this page with ?k=<key>. It is kept here (so the installed web app, which
     starts at "/", still works), dropped from the address bar, and sent on the WebSocket and on
     the cover-art and app-icon addresses. */
  const PAGE_KEY_STORE = "secondpad.key";
  let pageKey = "";
  {
    let stored = "";
    try { stored = localStorage.getItem(PAGE_KEY_STORE) || ""; } catch {}
    const found = L.pageKey(location.search, stored);
    pageKey = found.key;
    if (found.fromURL) {
      try { localStorage.setItem(PAGE_KEY_STORE, found.key); } catch {}
      history.replaceState(null, "", location.pathname + location.hash);
    }
  }
  window.withKey = (url) => L.withKey(url, pageKey);

  /* ═══ Connection ═════════════════════════════════════════════ */

  let socket = null;
  let retry = 400;

  function send(command, payload = {}) {
    if (!socket || socket.readyState !== WebSocket.OPEN) { toast("No connection to the Mac"); return false; }
    socket.send(JSON.stringify({ command, ...payload }));
    return true;
  }
  window.sendCommand = send;

  /* The Mac's clock: timers are counted in Mac time, so a tablet clock that is off doesn't matter. */
  let pageBuild = null;
  let clockOffset = 0;
  const macNow = () => Date.now() / 1000 + clockOffset;
  function syncClock(sentAt) { if (typeof sentAt === "number") clockOffset = sentAt - Date.now() / 1000; }

  const handlers = {
    hello: (m) => {
      document.body.classList.toggle("is-demo", !!m.demo);
      // The Mac app was updated while this page stayed open: load the new page.
      if (pageBuild && m.build && m.build !== pageBuild) { location.reload(); return; }
      pageBuild = pageBuild || m.build;
    },
    stats: renderStats,
    claude: (m) => { renderClaude(m); window.standby?.claude(m); },
    standby: (m) => window.standby?.mac(!!m.active),
    limits: renderLimits,
    media: renderMedia,
    weather: renderWeather,
    tasks: renderTasks,
    pomodoro: (m) => { pomo = m; renderFoot(); window.focusPage?.pomodoro(m); window.standby?.pomodoro(m); },
    week: (m) => window.focusPage?.week(m),
    quicktimer: renderQuick,
    "quicktimer.done": (m) => quickFinish(m.sound),
    netstatus: (m) => renderNet(m.online),
    settings: (m) => { window.focusPage?.settings(m); window.standby?.settings(m); },
  };

  /* While the Mac is away, it's asked with a plain request first and the WebSocket opens only
     once the Mac answers. Chrome slows down WebSocket retries after failures (measured: gaps of
     7 s and growing; longer on the tablet, so a relaunched SecondPad wasn't seen for 30 s+). */
  let wasOpen = true;
  function connect() {
    if (wasOpen) { open(); return; }
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 1500);
    fetch("/manifest.webmanifest", { cache: "no-store", signal: controller.signal })
      .then((r) => { clearTimeout(timer); if (r.ok) open(); else later(); })
      .catch(() => { clearTimeout(timer); later(); });
  }
  function later() {
    setTimeout(connect, retry);
    retry = Math.min(retry * 1.6, 2000);   // the cable comes back fast; don't wait long
  }
  function open() {
    socket = new WebSocket(L.withKey(`ws://${location.host}/ws`, pageKey));
    socket.onopen = () => { setConn(true); retry = 400; wasOpen = true; };
    socket.onmessage = (event) => {
      let message;
      try { message = JSON.parse(event.data); } catch { return; }
      handlers[message.type]?.(message);
    };
    socket.onclose = () => {
      setConn(false);
      wasOpen = false;
      later();
    };
    socket.onerror = () => socket.close();
  }

  function setConn(on) {
    window.standby?.connected(on);
    $("conn").dataset.on = String(on);
    // Without a key the Mac refuses the page: "On Tablet" in SecondPad's menu opens it with one.
    $("connText").textContent = on ? "Mac connected" : pageKey ? "Mac disconnected" : "Open from the Mac menu";
    document.body.classList.toggle("is-offline", !on);
  }

  /* ═══ The Mac's internet (Tasks header) ═══
     The first message only sets the state; every later change blips three times (green back
     online, red gone). Offline stays red and breathes until it's back. */
  let netOnline = null;
  function renderNet(online) {
    const el = $("netPulse");
    const changed = netOnline !== null && netOnline !== online;
    netOnline = online;
    el.classList.toggle("is-offline", !online);
    if (!changed || reduceMotion) return;
    el.classList.remove("is-pulsing", "is-online-pulse", "is-offline-pulse");
    void el.offsetWidth;
    el.classList.add("is-pulsing", online ? "is-online-pulse" : "is-offline-pulse");
    setTimeout(() => el.classList.remove("is-pulsing", "is-online-pulse", "is-offline-pulse"), 1700);
  }

  /* ═══ Low battery (as the original) ═══
     10 %: the whole screen flashes red three times and closes by itself. 5 %: five times, then a
     dark "Plug in your Mac" screen stays until the Mac charges; it can't be tapped away. The first
     message after loading only sets the state (a reload never flashes). */
  const LOWBATT_ORDER = { normal: 0, low: 1, critical: 2 };
  let lowSeverity = null;
  function batterySeverity(percent, charging) {
    if (charging || typeof percent !== "number") return "normal";
    return percent <= 5 ? "critical" : percent <= 10 ? "low" : "normal";
  }
  function renderLowBattery(percent, charging) {
    const box = $("lowBatt");
    if (typeof percent === "number") {
      $("lowBattPct").textContent = `${Math.round(percent)}%`;
      $("lowBattFill").setAttribute("width", Math.max(2, 74 * percent / 100).toFixed(1));
    }
    const severity = batterySeverity(percent, charging);
    if (lowSeverity === null) {
      lowSeverity = severity;
      if (severity === "critical") { box.hidden = false; box.classList.add("is-settled"); }
      return;
    }
    if (severity === lowSeverity) return;
    const worse = LOWBATT_ORDER[severity] > LOWBATT_ORDER[lowSeverity];
    lowSeverity = severity;
    box.classList.remove("is-flashing-low", "is-flashing-critical");
    if (severity === "normal") { box.classList.remove("is-settled"); box.hidden = true; return; }
    if (!worse) {
      box.hidden = severity !== "critical";
      box.classList.toggle("is-settled", severity === "critical");
      return;
    }
    box.hidden = false;
    box.classList.remove("is-settled");
    void box.offsetWidth;
    box.classList.add(`is-flashing-${severity}`);
    box.addEventListener("animationend", function done(e) {
      if (e.target !== box && e.pseudoElement !== "::before") return;
      box.removeEventListener("animationend", done);
      box.classList.remove(`is-flashing-${severity}`);
      if (severity === "critical") box.classList.add("is-settled"); else box.hidden = true;
    });
  }

  /* ═══ Claude ═════════════════════════════════════════════════
     Each session is a small card: coloured state edge, name, a filled state pill, the current step,
     model and context fill, and a big timer. While Claude works a line runs along the bottom.
     One session becomes the hero: a big state word and the original's "Last steps". */

  const CLAUDE_MAX = 4;
  const SETTLE_MS = 20000;
  let claude = { sessions: [], hooksInstalled: true };
  const rowEls = new Map();
  const lastState = new Map();
  const lastStep = new Map();
  let settleTimer = null;

  const pad2 = (n) => String(n).padStart(2, "0");
  const hhmm = (epoch) => { const d = new Date(epoch * 1000); return `${pad2(d.getHours())}:${pad2(d.getMinutes())}`; };

  function renderClaude(m) {
    syncClock(m.sentAt);
    claude = m;
    const tile = $("claudeTile");
    const list = $("ccList");
    // As many rows as fit (each needs ~84 px), at most four; the rest go into "+N more".
    const room = list.clientHeight || tile.clientHeight - 70;
    const { rows, hidden, total } = L.claudeRows(m.sessions, Math.max(1, Math.min(CLAUDE_MAX, Math.floor((room - 26) / 84))));

    const mood = rows.some((s) => s.state === "waiting") ? "waiting"
      : rows.some((s) => s.state === "error") ? "error"
      : rows.some((s) => s.state === "working") ? "working"
      : rows.some((s) => s.state === "done") ? "done" : "idle";
    if (tile.dataset.mood !== mood) {
      tile.dataset.mood = mood;
      tile.classList.remove("is-settled");
      clearTimeout(settleTimer);
      if (mood === "waiting") settleTimer = setTimeout(() => tile.classList.add("is-settled"), SETTLE_MS);
    }

    $("ccSummary").innerHTML = L.claudeSummary(m.sessions)
      .map((x) => `<span class="cc-chip is-${x.state}"><i></i>${escapeHTML(x.text)}</span>`).join("");

    tile.classList.toggle("is-empty", total === 0);
    tile.classList.toggle("is-single", total === 1);
    $("ccEmptyTitle").textContent = m.hooksInstalled ? "No active sessions" : "Claude hooks not installed";
    $("ccEmptyNote").textContent = m.hooksInstalled ? "Start Claude Code and it shows up here"
      : "Install them from the menu bar: SecondPad → Settings";

    const keep = new Set(rows.map((s) => s.id));
    for (const [id, el] of rowEls) {
      if (keep.has(id)) continue;
      rowEls.delete(id);
      lastStep.delete(id);
      el.classList.add("is-leaving");
      setTimeout(() => el.remove(), 240);
    }

    rows.forEach((s, index) => {
      let el = rowEls.get(s.id);
      const fresh = !el;
      if (fresh) {
        el = document.createElement("li");
        el.className = "cc-row is-entering";
        el.innerHTML = `
          <span class="cc-edge" aria-hidden="true"></span>
          <span class="cc-dot" aria-hidden="true">
            <svg viewBox="0 0 24 24"><circle class="cc-dot-ring" cx="12" cy="12" r="9.5"/><path class="cc-dot-check" d="M7.6 12.3l3 3 5.8-6.4"/></svg>
            <i></i>
          </span>
          <div class="cc-main">
            <div class="cc-top"><b class="cc-name"></b><span class="cc-pill"></span></div>
            <div class="cc-step"></div>
            <div class="cc-meta"><span class="cc-model"></span><span class="cc-ctx"><i></i></span><span class="cc-ctx-num"></span></div>
            <ol class="cc-steps" aria-label="Last steps"></ol>
          </div>
          <span class="cc-timer"></span>
          <i class="cc-run" aria-hidden="true"></i>`;
        setTimeout(() => el.classList.remove("is-entering"), 400);
        rowEls.set(s.id, el);
      }
      if (list.children[index] !== el) list.insertBefore(el, list.children[index] || null);

      const before = lastState.get(s.id);
      el.dataset.state = s.state;
      el.querySelector(".cc-name").textContent = s.label;
      el.querySelector(".cc-pill").textContent = L.stateWord(s.state);
      if (before !== undefined && before !== s.state) {
        el.classList.remove("just-changed"); void el.offsetWidth; el.classList.add("just-changed");
        announce(s);   // the card itself lights; no screen-edge flash (the user found it too much)
      }
      lastState.set(s.id, s.state);

      // The current step: ONE text that changes in place with a short fade-in. (Two texts
      // cross-fading in the same spot stacked on top of each other when steps came fast.)
      const stepBox = el.querySelector(".cc-step");
      if (lastStep.get(s.id) !== s.activity) {
        let span = stepBox.firstElementChild;
        if (!span) { span = document.createElement("span"); stepBox.append(span); }
        span.textContent = s.activity || "";
        if (!fresh) { span.classList.remove("is-in"); void span.offsetWidth; span.classList.add("is-in"); }
        lastStep.set(s.id, s.activity);
      }

      // Model and context fill: amber from 80 %, red from 95 % (as the original's foot).
      el.querySelector(".cc-model").textContent = s.model || "";
      const ctx = el.querySelector(".cc-ctx");
      const hasCtx = typeof s.contextPercent === "number";
      ctx.hidden = !hasCtx;
      if (hasCtx) {
        ctx.firstElementChild.style.transform = `scaleX(${Math.min(1, s.contextPercent / 100)})`;
        ctx.dataset.level = s.contextPercent >= 95 ? "high" : s.contextPercent >= 80 ? "warn" : "ok";
      }
      el.querySelector(".cc-ctx-num").textContent = hasCtx ? `ctx ${s.contextPercent}%` : "";
      el.querySelector(".cc-meta").hidden = !s.model && !hasCtx;

      // Last steps (shown in the single-session hero): newest first and brightest; the current
      // step is already written large above, so it isn't repeated.
      let steps = (s.steps || []).slice().reverse();
      if (steps[0] && s.activity && steps[0].text.toLowerCase() === s.activity.toLowerCase()) steps = steps.slice(1);
      steps = steps.slice(0, 4);
      const ol = el.querySelector(".cc-steps");
      const key = steps.map((x) => `${x.at}|${x.text}`).join("␟");
      if (ol.dataset.key !== key) {
        const isNew = ol.dataset.key !== undefined && steps[0] && !ol.dataset.key.startsWith(`${steps[0].at}|`);
        ol.dataset.key = key;
        ol.innerHTML = steps.map((x, i) => `<li class="${i === 0 ? "is-latest" : ""}${/^Asked you/.test(x.text) ? " is-ask" : /^Failed/.test(x.text) ? " is-fail" : ""}">`
          + `<span class="cs-time">${hhmm(x.at)}</span><span class="cs-text">${escapeHTML(x.text)}</span></li>`).join("");
        if (isNew) { ol.classList.remove("has-new"); void ol.offsetWidth; ol.classList.add("has-new"); }
      }
      el._session = s;
    });

    let more = list.querySelector(".cc-more");
    if (hidden > 0) {
      if (!more) { more = document.createElement("li"); more.className = "cc-more"; }
      more.textContent = `+${hidden} more`;
      list.append(more);
    } else more?.remove();

    for (const id of lastState.keys()) if (!rowEls.has(id)) lastState.delete(id);
    tickClaudeTimers();
    window.focusPage?.claude(rows);
  }

  function tickClaudeTimers() {
    const now = macNow();
    for (const el of rowEls.values()) {
      const t = el._session ? L.sessionTimer(el._session, now) : null;
      const cell = el.querySelector(".cc-timer");
      cell.textContent = t ? t.text : "";
      cell.classList.toggle("is-frozen", !!t && !t.live);
    }
  }

  function announce(s) {
    const word = { waiting: "needs you", done: "done", error: "failed" }[s.state];
    if (word) $("ccLive").textContent = `Claude ${s.label}: ${word}`;
  }

  /* ═══ Claude limits ══════════════════════════════════════════ */

  const STALE_S = 30 * 60, LATE_S = 12 * 60;
  let limits = null;

  function renderLimits(m) {
    syncClock(m.sentAt);
    const before = limits;
    limits = m;
    paintLimits(before);
  }

  function paintLimits(before = limits) {
    const box = $("limits");
    const m = limits;
    const now = macNow();
    const hasData = !!(m && (m.fiveHour || m.sevenDay));
    const age = hasData ? now - m.receivedAt : 0;
    box.dataset.state = !hasData ? "empty" : age > STALE_S ? "stale" : "fresh";

    [["lim5", m?.fiveHour, before?.fiveHour], ["lim7", m?.sevenDay, before?.sevenDay]].forEach(([id, win, prev]) => {
      const row = $(id);
      const r = L.limitRow(win, now);
      row.dataset.level = r.level;
      row.querySelector(".lim-bar > i").style.transform = `scaleX(${r.fill})`;
      const pct = row.querySelector(".lim-pct b");
      if (pct.textContent !== r.pct) {
        pct.textContent = r.pct;
        if (prev && win && Math.round(prev.percent) !== Math.round(win.percent) && !reduceMotion) {
          pct.classList.remove("is-bump"); void pct.offsetWidth; pct.classList.add("is-bump");
        }
      }
      row.querySelector(".lim-reset").textContent = r.reset;
    });

    const ageBox = $("limAge");
    if (!hasData) {
      ageBox.dataset.level = "none";
      const hint = m && m.foreignStatusLine && !m.liveUsage ? "turn on Live usage" : "no data yet";
      $("limAgeText").textContent = hint;
      $("lim5").querySelector(".lim-reset").textContent = m && m.foreignStatusLine && !m.liveUsage
        ? "your own statusLine is set" : "waiting for Claude Code";
    } else {
      ageBox.dataset.level = age > STALE_S ? "stale" : age > LATE_S ? "late" : "fresh";
      $("limAgeText").textContent = m.source === "live" ? `Live · ${L.ageLabel(age)}` : L.ageLabel(age);
    }
  }
  setInterval(() => { if (!document.hidden) paintLimits(); }, 20000);

  /* ═══ Quick timer ═══════════════════════════════════════════ */

  let quick = { minutes: 10, endsAt: null, totalMs: 0, sound: true, known: false };
  let quickTicker = null;
  let doneTimer = null;

  function renderQuick(m) {
    const wasRunning = quick.endsAt !== null;
    const endedNaturally = wasRunning && !m.running && quick.endsAt - Date.now() <= 3000;
    showMinutes(m.minutes);
    quick.sound = m.soundTablet;
    $("quickSound").classList.toggle("is-off", !quick.sound);
    quick.endsAt = m.running ? Date.now() + m.remainingMs : null;
    quick.totalMs = m.running ? m.totalMs : 0;
    const running = quick.endsAt !== null;
    const moment = quick.known && running !== wasRunning ? (running ? "start" : endedNaturally ? "done" : "stop") : null;
    quick.known = true;
    paintQuick(moment);
  }

  function showMinutes(value) {
    quick.minutes = Math.max(1, Math.min(60, Math.round(value)));
    $("quickMinutes").textContent = quick.minutes;
    document.querySelectorAll(".qt-pill").forEach((p) => p.classList.toggle("is-on", Number(p.dataset.min) === quick.minutes));
  }

  function paintQuick(moment) {
    const box = $("quick");
    const running = quick.endsAt !== null;
    clearTimeout(doneTimer);
    if (moment === "done") {
      // Time's up: the ring fills green, the clock turns into a check; then back to setup.
      box.dataset.state = "done";
      $("quickSetup").hidden = true;
      $("quickLive").hidden = false;
      $("quickTime").textContent = "00:00";
      $("quickLabel").textContent = "Time's up";
      $("quickArc").style.strokeDashoffset = "0";
      doneTimer = setTimeout(() => paintQuick(null), 5000);
      return;
    }
    box.dataset.state = running ? "running" : "setup";
    $("quickSetup").hidden = running;
    $("quickLive").hidden = !running;
    if (running) {
      $("quickLabel").textContent = `Timer · ${Math.round(quick.totalMs / 60000)} min`;
      if (moment === "start" && !reduceMotion) {
        // The ring fills from empty to where the timer is, once (700 ms), then counts down. The
        // target is set right away; before, it was only set after the start phase, so the ring
        // sat empty for a second and then jumped.
        const arc = $("quickArc");
        const frac = quick.totalMs > 0 ? Math.min(1, Math.max(0, quick.endsAt - Date.now()) / quick.totalMs) : 0;
        arc.style.transition = "none";
        arc.style.strokeDashoffset = "100";
        void arc.getBoundingClientRect();
        box.classList.remove("is-starting"); void box.offsetWidth; box.classList.add("is-starting");
        arc.style.transition = "stroke-dashoffset 700ms var(--ease)";
        arc.style.strokeDashoffset = String(100 * (1 - frac));
        clearTimeout(paintQuick.startTimer);
        paintQuick.startTimer = setTimeout(() => { arc.style.transition = ""; box.classList.remove("is-starting"); }, 720);
      }
    }
    tickQuick();
  }

  function tickQuick() {
    clearTimeout(quickTicker);
    if (quick.endsAt === null) return;
    const left = Math.max(0, quick.endsAt - Date.now());
    $("quickTime").textContent = L.clock(Math.ceil(left / 1000));
    const frac = quick.totalMs > 0 ? Math.min(1, left / quick.totalMs) : 0;
    if (!$("quick").classList.contains("is-starting")) $("quickArc").style.strokeDashoffset = String(100 * (1 - frac));   // the fill-in owns the ring for its 700 ms
    $("quick").classList.toggle("is-ending", left <= 30000);
    if (left > 0) quickTicker = setTimeout(tickQuick, left % 1000 || 1000);
  }

  /* The chime: the Mac's own Glass sound (as WAV), or soft beeps when it can't load. Audio only
     plays after a touch, so it is prepared on the first tap. */
  let audio = null, glass = null, glassLoading = false;
  function prepareSound() {
    try {
      audio = audio || new (window.AudioContext || window.webkitAudioContext)();
      if (audio.state === "suspended") audio.resume();
      if (!glass && !glassLoading) {
        glassLoading = true;
        fetch("/sound/glass.wav").then((r) => (r.ok ? r.arrayBuffer() : null))
          .then((b) => (b ? audio.decodeAudioData(b) : null)).then((buf) => { glass = buf; })
          .catch(() => {}).finally(() => { glassLoading = false; });
      }
    } catch { audio = null; }
  }
  document.addEventListener("pointerdown", prepareSound, { once: true, passive: true });

  function beep(when, frequency) {
    const gain = audio.createGain(), osc = audio.createOscillator();
    osc.type = "sine";
    osc.frequency.value = frequency;
    gain.gain.setValueAtTime(0, when);
    gain.gain.linearRampToValueAtTime(0.22, when + 0.02);
    gain.gain.exponentialRampToValueAtTime(0.001, when + 0.42);
    osc.connect(gain).connect(audio.destination);
    osc.start(when);
    osc.stop(when + 0.45);
  }

  function quickFinish(sound) {
    flash();
    // Opened on the Mac itself (testing)? The Mac already chimes.
    if (/Macintosh|Mac OS X/.test(navigator.userAgent)) sound = false;
    if (!sound) return;
    prepareSound();
    if (!audio) return;
    const start = audio.currentTime + 0.02;
    [0, 0.52, 1.04].forEach((offset, i) => {
      if (glass) { const src = audio.createBufferSource(); src.buffer = glass; src.connect(audio.destination); src.start(start + offset); }
      else beep(start + offset, [880, 1108, 1318][i]);
    });
  }

  function flash() {
    const el = $("flash");
    el.hidden = false;
    el.classList.remove("is-on"); void el.offsetWidth; el.classList.add("is-on");
    setTimeout(() => { el.hidden = true; el.classList.remove("is-on"); }, 1700);
  }

  function bindRepeat(button, step) {
    let timer = null;
    const stop = () => { clearTimeout(timer); timer = null; };
    button.addEventListener("pointerdown", (event) => {
      event.preventDefault();
      step();
      let delay = 380;
      const again = () => { step(); delay = Math.max(60, delay * 0.82); timer = setTimeout(again, delay); };
      timer = setTimeout(again, delay);
    });
    ["pointerup", "pointerleave", "pointercancel"].forEach((t) => button.addEventListener(t, stop));
  }

  document.querySelectorAll(".qt-pill").forEach((pill) => pill.addEventListener("click", () => {
    prepareSound();
    send("timer.start", { minutes: Number(pill.dataset.min) });
  }));
  bindRepeat($("quickMinus"), () => { showMinutes(quick.minutes - 1); send("timer.minutes", { minutes: quick.minutes }); });
  bindRepeat($("quickPlus"), () => { showMinutes(quick.minutes + 1); send("timer.minutes", { minutes: quick.minutes }); });
  $("quickStart").addEventListener("click", () => { prepareSound(); send("timer.start", { minutes: quick.minutes }); });
  $("quickStop").addEventListener("click", () => send("timer.stop"));
  $("quickSound").addEventListener("click", () => { if (!quick.sound) prepareSound(); send("timer.sound", { on: !quick.sound }); });

  /* ═══ Pomodoro foot ══════════════════════════════════════════ */

  let pomo = null;

  function renderFoot() {
    const p = pomo;
    const done = p?.completed || 0;
    $("pfDeep").textContent = L.hoursShort(L.deepWorkToday(p));
    const slots = Math.min(8, Math.max(4, done));
    const dots = $("pfDots");
    if (dots.children.length !== slots) dots.replaceChildren(...Array.from({ length: slots }, () => document.createElement("i")));
    [...dots.children].forEach((dot, i) => dot.classList.toggle("is-done", i < done));
    $("pfCount").textContent = done === 1 ? "1 pomodoro" : `${done} pomodoros`;
    const live = $("pfLive");
    const state = L.focusState(p);
    live.hidden = state === "idle" && !p?.prompt;
    if (!live.hidden) {
      const label = p.prompt ? "Up next" : state === "focus" ? "Focus" : state === "paused" ? "Paused" : p.phase === "longBreak" ? "Long break" : "Break";
      live.textContent = `${label} · ${L.clock(p.remaining)}`;
      live.dataset.kind = p.phase === "focus" ? "focus" : "break";
    }
  }
  $("pomoFoot").addEventListener("click", () => showPage(0));

  /* ═══ Tasks ══════════════════════════════════════════════════
     A tick is easy to take back: the row stays where it was, checked, with "Undo" and a
     4-second countdown, then folds away into "done". Tapping a done row un-ticks it.
     A drag or a scroll never toggles anything. */

  const HOLD_MS = 4000;
  let showDone = false;
  let tasksKnown = null;
  let lastTasks = { items: [] };
  const held = new Map();      // id → { timer, start }: ticked here, still shown in place
  const leaving = new Set();   // ids folding away right now
  const flashes = new Map();   // id → { kind: "done" | "undone", start }

  function renderTasks(m) {
    lastTasks = m;
    const list = $("taskList");
    const items = L.sortTasks(m.items);
    for (const id of [...held.keys()]) {
      const t = items.find((x) => x.id === id);
      if (!t || !t.done) { clearTimeout(held.get(id).timer); held.delete(id); }   // undone elsewhere, or deleted
    }
    if (!items.length) {
      list.innerHTML = `<li class="task-empty"><svg viewBox="0 0 24 24" class="ico"><path d="M9 11l3 3 8-8"/><path d="M20 12v6a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h9"/></svg><b>No tasks</b><span>Add one from the Mac</span></li>`;
      if (tasksKnown) tasksKnown = new Set();   // the first (empty) paint doesn't make later tasks "new"
      return;
    }
    const L2 = L.taskGroups(items, held);
    const known = tasksKnown;
    tasksKnown = new Set(items.map((t) => t.id));
    const row = (t) => {
      const isHeld = held.has(t.id);
      return `
      <li class="task${t.done ? " is-done" : ""}${isHeld ? " is-held" : ""}${leaving.has(t.id) ? " is-leaving" : ""}${known && !known.has(t.id) ? " is-new" : ""}" data-id="${escapeHTML(t.id)}">
        <span class="task-box"><svg viewBox="0 0 16 16"><path d="M3 8.5l3.2 3.2L13 5"/></svg></span>
        <span class="task-text">${escapeHTML(t.text)}</span>
        ${isHeld ? `<button class="task-undo" type="button" data-undo="${escapeHTML(t.id)}">Undo</button><i class="task-count"></i>` : ""}
      </li>`;
    };
    list.innerHTML = L2.open.map(row).join("")
      + (L2.done.length ? `<li class="task-more"><button type="button" id="taskDoneToggle">✓ ${L2.done.length} done · ${showDone ? "hide" : "show"}</button></li>` : "")
      + (showDone ? L2.done.map(row).join("") : "")
      + (!L2.open.length && !showDone ? `<li class="task-all">All done for today</li>` : "");
    $("taskDoneToggle")?.addEventListener("click", () => { showDone = !showDone; renderTasks(lastTasks); });
    paintTaskFade();
    // The 1.7 s flash survives re-renders (the Mac's update arrives mid-flash).
    for (const [id, f] of flashes) {
      const age = Date.now() - f.start;
      if (age > 1700) { flashes.delete(id); continue; }
      const el = list.querySelector(`.task[data-id="${CSS.escape(id)}"]`);
      if (!el || reduceMotion) continue;
      el.classList.add(`flash-${f.kind}`);
      el.style.animationDelay = `${-age}ms`;
    }
    // A re-render mustn't restart a hold's countdown: continue it where it is.
    for (const [id, h] of held) {
      const bar = list.querySelector(`.task[data-id="${CSS.escape(id)}"] .task-count`);
      if (bar) bar.style.animationDelay = `${-(Date.now() - h.start)}ms`;
    }
  }

  function hold(id) {
    if (held.has(id)) clearTimeout(held.get(id).timer);
    held.set(id, { start: Date.now(), timer: setTimeout(() => {
      held.delete(id);
      const el = $("taskList").querySelector(`.task[data-id="${CSS.escape(id)}"]`);
      if (!el || reduceMotion) { renderTasks(lastTasks); return; }
      leaving.add(id);
      el.classList.add("is-leaving");
      setTimeout(() => { leaving.delete(id); renderTasks(lastTasks); }, 240);
    }, HOLD_MS) });
  }

  function toggleTask(id) {
    if (!send("task.toggle", { id })) return;
    const t = lastTasks.items.find((x) => x.id === id);
    if (!t) return;
    const nowDone = !t.done;
    t.done = nowDone;   // answer the finger at once; the Mac's update follows
    if (nowDone && !showDone) hold(id);
    else { if (held.has(id)) clearTimeout(held.get(id).timer); held.delete(id); }
    flashes.set(id, { kind: nowDone ? "done" : "undone", start: Date.now() });
    renderTasks(lastTasks);
    const el = $("taskList").querySelector(`.task[data-id="${CSS.escape(id)}"]`);
    if (el && !reduceMotion) el.classList.add(nowDone ? "just-done" : "just-undone");
  }

  // A list longer than its card fades out at the bottom, so it reads as "more below".
  function paintTaskFade() {
    const list = $("taskList");
    list.classList.toggle("is-scrollable", list.scrollHeight > list.clientHeight + 4);
    list.classList.toggle("is-end", list.scrollTop + list.clientHeight >= list.scrollHeight - 4);
  }
  $("taskList").addEventListener("scroll", paintTaskFade, { passive: true });
  window.addEventListener("resize", paintTaskFade);

  // Tap, not drag: a finger that moves more than 10 px, or a list that scrolled, toggles nothing.
  let press = null;
  const taskList = $("taskList");
  taskList.addEventListener("pointerdown", (e) => { press = { x: e.clientX, y: e.clientY, top: taskList.scrollTop, moved: false }; }, { passive: true });
  taskList.addEventListener("pointermove", (e) => {
    if (press && Math.hypot(e.clientX - press.x, e.clientY - press.y) > 10) press.moved = true;
  }, { passive: true });
  taskList.addEventListener("click", (event) => {
    const dragged = press && (press.moved || Math.abs(taskList.scrollTop - press.top) > 2);
    press = null;
    if (dragged) return;
    const undo = event.target.closest("[data-undo]");
    if (undo) { toggleTask(undo.dataset.undo); return; }
    const row = event.target.closest(".task[data-id]");
    if (row && !row.classList.contains("is-leaving")) toggleTask(row.dataset.id);
  });

  /* ═══ Mac health ═════════════════════════════════════════════ */

  let swap = { on: false, since: null };

  function seg(id, warn, danger) {
    const el = $(id);
    el.classList.toggle("is-warn", warn && !danger);
    el.classList.toggle("is-danger", danger);
  }
  const bar = (id, fraction) => { $(id).style.transform = `scaleX(${Math.max(0, Math.min(1, fraction))})`; };

  function renderStats(s) {
    const cpu = Math.round(s.cpuPercent);
    $("cpuVal").textContent = cpu;
    bar("cpuBar", cpu / 100);
    seg("cpuSeg", cpu >= 60, cpu >= 85);
    $("cpuNote").textContent = s.topProcess ? `${s.topProcess} · ${Math.round(s.topProcessCPU || 0)}%` : "measuring";

    const ram = Math.round(s.ramPercent);
    $("ramVal").textContent = ram;
    bar("ramBar", ram / 100);
    seg("ramSeg", ram >= 85, ram >= 93);
    $("ramNote").textContent = s.compressedGB >= 0.1
      ? `${s.ramUsedGB.toFixed(1)} GB · ${s.compressedGB.toFixed(1)} compr.`
      : `${s.ramUsedGB.toFixed(1)} / ${s.ramTotalGB.toFixed(0)} GB`;

    const used = s.swapUsedGB || 0;
    $("swapVal").textContent = used < 10 ? used.toFixed(1) : Math.round(used);
    bar("swapBar", s.swapTotalGB > 0 ? used / s.swapTotalGB : 0);
    const days = Math.floor(s.uptimeDays || 0);
    $("swapNote").textContent = (s.memoryPressure >= 4 ? "pressure critical" : s.memoryPressure >= 2 ? "pressure high" : "on disk")
      + (days >= 3 ? ` · up ${days} d` : "");
    seg("swapSeg", s.memoryPressure === 2 && used >= 0.5, s.memoryPressure >= 4);

    const io = (s.swapInMBs || 0) + (s.swapOutMBs || 0);
    $("swapIoVal").textContent = io < 10 ? io.toFixed(1) : Math.round(io);
    bar("swapIoBar", io / 40);
    $("swapIoNote").textContent = `in ${(s.swapInMBs || 0).toFixed(1)} · out ${(s.swapOutMBs || 0).toFixed(1)}`;
    seg("swapIoSeg", io >= 5, io >= 20);
    swap = L.swapGate(swap, io, Date.now());
    $("hlLead").dataset.swap = swap.on ? "on" : "off";

    const heat = $("heatSeg");
    if (s.temperature == null) {
      $("tempVal").textContent = "—";
      heat.dataset.level = "none";
    } else {
      const t = Math.round(s.temperature);
      $("tempVal").textContent = t;
      heat.dataset.level = t >= 95 ? "hot" : t >= 70 ? "warm" : "cool";
    }
    const fan = L.fanState(s.fanLoad);
    $("fan").className = `fan ${fan.css}`;
    $("fan").style.setProperty("--spin", `${fan.spin.toFixed(2)}s`);
    $("fan").hidden = s.fanLoad == null;
    $("fanState").textContent = s.fanLoad == null ? (s.temperature == null ? "no sensor" : "") : fan.label;
    $("fanState").classList.toggle("is-on", (s.fanLoad || 0) > 0);
    bar("fanBar", fan.bar);

    // Peaks (decided on the Mac: 5 s sustained, with hysteresis). The edge half lights up and
    // blinks twice as it does; the segment's number turns red. Memory stalls: Swap breathes purple.
    const health = $("health");
    for (const [key, on, seg] of [["cpu", !!s.cpuPeak, "cpuSeg"], ["heat", !!s.heatPeak, "heatSeg"]]) {
      const was = health.classList.contains(`is-${key}-peak`);
      health.classList.toggle(`is-${key}-peak`, on);
      $(seg).classList.toggle("is-peak", on);
      if (on && !was && !reduceMotion) {
        const enter = `is-${key}-enter`;
        health.classList.remove(enter); void health.offsetWidth; health.classList.add(enter);
        setTimeout(() => health.classList.remove(enter), 1000);
      }
    }
    $("swapSeg").classList.toggle("is-peak", !!s.memoryPeak);
    window.focusPage?.system(!!s.cpuPeak, !!s.heatPeak, !!s.memoryPeak, s);
    window.sheets?.stats(s);

    renderLowBattery(s.batteryPercent, !!s.batteryCharging);
    const batt = $("batt");
    batt.hidden = s.batteryPercent == null;
    if (s.batteryPercent != null) {
      $("battVal").textContent = s.batteryPercent;
      $("battBolt").toggleAttribute("hidden", !s.batteryCharging);   // an SVG has no .hidden
      batt.classList.toggle("is-charging", !!s.batteryCharging);
      batt.classList.toggle("is-low", !s.batteryCharging && s.batteryPercent < 20);
    }
  }

  /* ═══ Now playing ════════════════════════════════════════════ */

  let lastTrack = null;
  function renderMedia(m) {
    const box = $("media");
    const state = !m.running ? "closed" : m.title ? (m.playing ? "playing" : "paused") : "stopped";
    box.dataset.state = state;
    $("npTitle").textContent = state === "closed" ? "Spotify isn't open" : m.title || "Nothing playing";
    $("npArtist").textContent = state === "closed" ? "Play opens it on the Mac" : m.artist || "Spotify";
    $("npPlay").classList.toggle("is-playing", !!m.playing);
    // Previous / next only mean something while Spotify runs with a track.
    document.querySelectorAll('.np-skip[data-cmd]').forEach((b) => { b.disabled = state === "closed" || state === "stopped"; });
    $("npPlay").setAttribute("aria-label", state === "closed" ? "Open Spotify and play" : "Play or pause");
    const art = $("npArt");
    const url = m.artwork ? `url("${window.withKey(m.artwork)}")` : "";
    if (art.style.backgroundImage !== url) art.style.backgroundImage = url;
    art.classList.toggle("has-art", !!m.artwork);
    const key = `${m.title}␟${m.artist}`;
    if (lastTrack !== null && key !== lastTrack && m.title && !reduceMotion) {
      box.classList.remove("is-new-track"); void box.offsetWidth; box.classList.add("is-new-track");
    }
    lastTrack = key;
    window.sheets?.media(m);
  }

  document.querySelectorAll("[data-cmd]").forEach((button) => button.addEventListener("click", () => {
    if (!send(button.dataset.cmd)) return;
    if (!reduceMotion) { button.classList.remove("is-pressed"); void button.offsetWidth; button.classList.add("is-pressed"); }
  }));

  /* ═══ Clock, weather, battery ════════════════════════════════ */

  const WEEKDAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
  const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

  function tickClock() {
    const now = new Date();
    const time = `${String(now.getHours()).padStart(2, "0")}:${String(now.getMinutes()).padStart(2, "0")}`;
    $("clock").textContent = time;
    $("dateLine").textContent = `${WEEKDAYS[now.getDay()]}, ${MONTHS[now.getMonth()]} ${now.getDate()}`;
    $("fpMiniClock").textContent = time;
  }

  const WEATHER_SVG = {
    sun: '<circle cx="12" cy="12" r="4.2"/><path d="M12 2.5v2.2M12 19.3v2.2M2.5 12h2.2M19.3 12h2.2M5.3 5.3l1.6 1.6M17.1 17.1l1.6 1.6M5.3 18.7l1.6-1.6M17.1 6.9l1.6-1.6"/>',
    moon: '<path d="M19.5 14.6A8 8 0 0 1 9.4 4.5a8 8 0 1 0 10.1 10.1z"/>',
    "sun-cloud": '<path d="M8 3v1.6M3.6 8H2M4.6 4.6l1.1 1.1M11.4 4.6l-1.1 1.1"/><path d="M5.6 10.4a3.4 3.4 0 0 1 6-2.6"/><path d="M8 20h9.5a3.5 3.5 0 0 0 .4-7A5 5 0 0 0 8.3 14 3 3 0 0 0 8 20z"/>',
    "moon-cloud": '<path d="M11.8 5.6A4 4 0 0 1 6 10.3"/><path d="M8 20h9.5a3.5 3.5 0 0 0 .4-7A5 5 0 0 0 8.3 14 3 3 0 0 0 8 20z"/>',
    cloud: '<path d="M7 19h10.5a4 4 0 0 0 .5-8 6 6 0 0 0-11.4 1.9A3.6 3.6 0 0 0 7 19z"/>',
    fog: '<path d="M4 9h16M6 13h12M4 17h16"/>',
    rain: '<path d="M7 15h10.5a4 4 0 0 0 .5-8 6 6 0 0 0-11.4 1.9A3.6 3.6 0 0 0 7 15z"/><path d="M9 18l-1 2.5M13 18l-1 2.5M17 18l-1 2.5"/>',
    snow: '<path d="M7 15h10.5a4 4 0 0 0 .5-8 6 6 0 0 0-11.4 1.9A3.6 3.6 0 0 0 7 15z"/><path d="M9 19h.01M13 20h.01M17 19h.01"/>',
    storm: '<path d="M7 14h10.5a4 4 0 0 0 .5-8 6 6 0 0 0-11.4 1.9A3.6 3.6 0 0 0 7 14z"/><path d="M12.5 15l-2 3.5h3l-2 3.5"/>',
  };

  let weather = null;
  function renderWeather(w) {
    weather = w;
    const box = $("weather");
    if (!w.city) {
      box.dataset.state = "none";
      $("wIcon").innerHTML = "";
      $("wTemp").textContent = "";
      $("wCity").textContent = "Set a city";
      return;
    }
    $("wCity").textContent = String(w.city).split(",")[0];
    if (w.temperature == null) {
      box.dataset.state = "waiting";
      $("wIcon").innerHTML = "";
      $("wTemp").textContent = "—";
      return;
    }
    const kind = L.weatherKind(w.code, w.isDay);
    $("wIcon").innerHTML = WEATHER_SVG[kind] ? `<svg viewBox="0 0 24 24" class="ico">${WEATHER_SVG[kind]}</svg>` : "";
    $("wTemp").textContent = `${w.temperature}°`;
    paintWeatherAge();
  }
  function paintWeatherAge() {
    if (!weather || weather.updatedAt == null) return;
    const age = Date.now() / 1000 - weather.updatedAt;
    const old = age > 3600;
    $("weather").dataset.state = old ? "old" : "fresh";
    let tag = $("weather").querySelector(".w-age");
    if (old) {
      if (!tag) { tag = document.createElement("span"); tag.className = "w-age"; $("weather").append(tag); }
      tag.textContent = L.ageLabel(age);
    } else tag?.remove();
  }

  /* ═══ Pages: Deep Focus ← → main, two-finger swipe ═══════════
     One finger stays free for the task list and buttons. */

  const PAGES = ["focus", "main"];
  const HOME = 1;
  const track = $("pagerTrack");
  const dots = [...document.querySelectorAll(".page-dot")];
  let pageIndex = HOME;
  let swipe = null;

  function showPage(index, animate = true) {
    pageIndex = Math.max(0, Math.min(PAGES.length - 1, index));
    track.classList.toggle("is-dragging", !animate);
    track.style.transform = `translate3d(${-pageIndex * 100}%, 0, 0)`;
    if (!animate) requestAnimationFrame(() => track.classList.remove("is-dragging"));
    dots.forEach((dot, i) => dot.classList.toggle("is-on", i === pageIndex));
    if (document.body.dataset.page !== PAGES[pageIndex]) window.closeSheets?.();
    document.body.dataset.page = PAGES[pageIndex];
  }
  window.showFocusPage = () => showPage(0);
  window.showMainPage = () => showPage(1);

  const mid = (t) => (t[0].clientX + t[1].clientX) / 2;
  $("pager").addEventListener("touchstart", (e) => {
    if (e.touches.length !== 2) { swipe = null; return; }
    e.preventDefault();
    swipe = { start: mid(e.touches), last: mid(e.touches), at: e.timeStamp, v: 0, width: $("pager").clientWidth || 1, axis: null };
  }, { passive: false });
  $("pager").addEventListener("touchmove", (e) => {
    if (!swipe || e.touches.length !== 2) return;
    e.preventDefault();
    const x = mid(e.touches);
    if (swipe.axis === null) {
      if (Math.abs(x - swipe.start) < 10) return;
      swipe.axis = "x";
      track.classList.add("is-dragging");
    }
    const dt = e.timeStamp - swipe.at;
    if (dt > 0) swipe.v = (x - swipe.last) / dt;
    swipe.last = x;
    swipe.at = e.timeStamp;
    let shift = x - swipe.start;
    if ((pageIndex === 0 && shift > 0) || (pageIndex === PAGES.length - 1 && shift < 0)) shift *= 0.28;
    track.style.transform = `translate3d(${-pageIndex * swipe.width + shift}px, 0, 0)`;
  }, { passive: false });
  function endSwipe() {
    if (!swipe) return;
    const s = swipe;
    swipe = null;
    if (s.axis !== "x") return;
    const shift = s.last - s.start;
    const flick = Math.abs(s.v) > 0.55, far = Math.abs(shift) > s.width * 0.18;
    const dir = flick ? Math.sign(s.v) : Math.sign(shift);
    showPage(flick || far ? pageIndex - dir : pageIndex);
  }
  $("pager").addEventListener("touchend", endSwipe);
  $("pager").addEventListener("touchcancel", endSwipe);
  document.addEventListener("gesturestart", (e) => e.preventDefault());

  /* ═══ Bits ═══════════════════════════════════════════════════ */

  function escapeHTML(text) {
    return String(text ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
  }
  window.escapeHTML = escapeHTML;

  let toastTimer = null;
  function toast(text) {
    const el = $("toast");
    el.textContent = text;
    el.hidden = false;
    el.classList.remove("is-on"); void el.offsetWidth; el.classList.add("is-on");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { el.hidden = true; }, 2600);
  }
  window.toast = toast;

  setInterval(() => {
    if (document.hidden) return;
    tickClock();
    tickClaudeTimers();
    if (pomo && pomo.running) renderFoot();
  }, 1000);
  setInterval(paintWeatherAge, 60000);

  tickClock();
  // "#focus" / "#main" pick the first page (used for screenshots); otherwise the main page.
  const pinned = location.hash.slice(1);
  window.pagePinned = PAGES.includes(pinned);
  showPage(window.pagePinned ? PAGES.indexOf(pinned) : HOME, false);
  renderTasks({ items: [] });
  connect();
})();
