/* SecondPad — pure helpers shared by app.js and focus.js. No DOM here, so node can test it
   (Tests/web/logic.test.js). */
(function (root) {
  "use strict";

  const pad = (n) => String(n).padStart(2, "0");

  /* 75 → "01:15" */
  function clock(seconds) {
    const s = Math.max(0, Math.round(seconds));
    return `${pad(Math.floor(s / 60))}:${pad(s % 60)}`;
  }

  /* Elapsed for a Claude row: "0:42", "12:05", "1:02:09" */
  function elapsed(seconds) {
    const s = Math.max(0, Math.floor(seconds));
    const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), r = s % 60;
    return h ? `${h}:${pad(m)}:${pad(r)}` : `${m}:${pad(r)}`;
  }

  /* Durations on the Deep Focus page: "45s", "4m 10s", "12m", "1h 5m" */
  function dur(seconds) {
    const s = Math.max(0, Math.round(seconds));
    if (s < 60) return `${s}s`;
    const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), r = s % 60;
    if (h > 0) return `${h}h ${m}m`;
    return r && m < 10 ? `${m}m ${r}s` : `${m}m`;
  }

  /* Deep work time: "0m", "45m", "1.6h" */
  function hoursShort(seconds) {
    const s = Math.max(0, seconds || 0);
    return s >= 3600 ? `${(s / 3600).toFixed(1)}h` : `${Math.round(s / 60)}m`;
  }

  /* ── Claude limits ─────────────────────────────────────────── */

  /* Time until a reset: "12m", "1h 07m", "4d 7h" ("" when past) */
  function limitReset(seconds) {
    if (!(seconds > 0)) return "";
    const minutes = Math.round(seconds / 60);
    if (minutes < 60) return `${Math.max(1, minutes)}m`;
    const hours = Math.floor(minutes / 60);
    if (hours < 24) return `${hours}h ${pad(minutes % 60)}m`;
    return `${Math.floor(hours / 24)}d ${hours % 24}h`;
  }

  /* Calm under 80 %, amber 80–94 %, red from 95 %. */
  function limitLevel(percent) {
    return percent >= 95 ? "high" : percent >= 80 ? "warn" : "ok";
  }

  /* Age of the last update: "just now", "5m ago", "2h ago" */
  function ageLabel(seconds) {
    const minutes = Math.floor(Math.max(0, seconds) / 60);
    if (minutes < 1) return "just now";
    if (minutes < 60) return `${minutes}m ago`;
    return `${Math.floor(minutes / 60)}h ago`;
  }

  /* "15:40" today, "Tue 15:40" another day. `now`/`at` epoch seconds. */
  function resetAt(at, now) {
    const d = new Date(at * 1000), n = new Date(now * 1000);
    const time = `${pad(d.getHours())}:${pad(d.getMinutes())}`;
    const sameDay = d.getFullYear() === n.getFullYear() && d.getMonth() === n.getMonth() && d.getDate() === n.getDate();
    return sameDay ? time : `${["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][d.getDay()]} ${time}`;
  }

  /* One limit window → what its row shows. */
  function limitRow(win, now) {
    if (!win || typeof win.percent !== "number") return { level: "none", fill: 0, pct: "—", reset: "" };
    if (win.resetsAt != null && win.resetsAt <= now) return { level: "reset", fill: 0, pct: "0", reset: "reset · new window" };
    const pct = Math.round(win.percent);
    const left = win.resetsAt != null ? limitReset(win.resetsAt - now) : "";
    return {
      level: limitLevel(win.percent),
      fill: Math.min(1, Math.max(0, win.percent / 100)),
      pct: String(pct),
      reset: left ? `resets in ${left} · ${resetAt(win.resetsAt, now)}` : "",
    };
  }

  /* ── Claude sessions ───────────────────────────────────────── */

  const URGENCY = { waiting: 0, error: 1, done: 2, working: 3 };
  const STATE_WORD = { working: "Working", waiting: "Needs you", done: "Done", error: "Failed" };

  /* The rows the card shows: active sessions only; the most urgent win the slots, but the
     order stays stable (first seen), so rows don't jump when a state changes. Same-folder
     sessions get "project 2", "project 3" by start order. */
  function claudeRows(sessions, max) {
    const active = (sessions || []).filter((s) => s.state && s.state !== "idle");
    const byStart = [...active].sort((a, b) => (a.firstSeenAt || 0) - (b.firstSeenAt || 0) || String(a.id).localeCompare(String(b.id)));
    const counts = new Map();
    const labelled = byStart.map((s) => {
      const n = (counts.get(s.project) || 0) + 1;
      counts.set(s.project, n);
      return { ...s, label: n > 1 ? `${s.project} ${n}` : s.project };
    });
    const urgent = [...labelled].sort((a, b) => (URGENCY[a.state] ?? 9) - (URGENCY[b.state] ?? 9));
    const keep = new Set(urgent.slice(0, max).map((s) => s.id));
    return { rows: labelled.filter((s) => keep.has(s.id)), hidden: Math.max(0, labelled.length - max), total: labelled.length };
  }

  function claudeSummary(sessions) {
    const counts = {};
    for (const s of sessions || []) if (s.state && s.state !== "idle") counts[s.state] = (counts[s.state] || 0) + 1;
    return [["waiting", "need you", "needs you"], ["error", "failed", "failed"], ["working", "working", "working"], ["done", "done", "done"]]
      .filter(([key]) => counts[key])
      .map(([key, many, one]) => ({ state: key, count: counts[key], text: `${counts[key]} ${counts[key] === 1 ? one : many}` }));
  }

  /* The row's timer: working → since the prompt; needs you → how long it waits; done → the turn's
     length, frozen. Returns { text, live } or null. `now` in Mac epoch seconds. */
  function sessionTimer(s, now) {
    if (s.state === "working" && s.turnStartedAt) return { text: elapsed(now - s.turnStartedAt), live: true };
    if (s.state === "waiting" && s.stateSince) return { text: elapsed(now - s.stateSince), live: true };
    if (s.state === "done" && s.lastTurnSeconds != null) return { text: elapsed(s.lastTurnSeconds), live: false };
    return null;
  }

  function stateWord(state) { return STATE_WORD[state] || "Idle"; }

  /* ── Tasks ─────────────────────────────────────────────────── */

  function sortTasks(items) {
    return [...(items || [])].sort((a, b) => (a.done !== b.done ? (a.done ? 1 : -1) : (a.createdAt || 0) - (b.createdAt || 0)));
  }

  /* Open tasks (plus ones just ticked here and still held in place), in creation order; then the
     done ones. `held` is anything with .has(id). */
  function taskGroups(items, held) {
    const all = sortTasks(items);
    const keep = (t) => !t.done || (held && held.has(t.id));
    return {
      open: all.filter(keep).sort((a, b) => (a.createdAt || 0) - (b.createdAt || 0)),
      done: all.filter((t) => !keep(t)),
    };
  }

  /* ── Mac health ────────────────────────────────────────────── */

  /* Fan: motion, not numbers. load 0…1 → state, label, spin seconds per turn. */
  function fanState(load) {
    if (load == null) return { css: "", label: "—", spin: 0, bar: 0 };
    if (load <= 0) return { css: "is-off", label: "fan off", spin: 0, bar: 0 };
    const bar = Math.max(0.06, Math.min(1, load));
    if (load < 0.35) return { css: "is-on", label: "fan on", spin: Math.max(0.3, 3.4 - load * 5), bar };
    if (load < 0.62) return { css: "is-hard", label: "fan busy", spin: Math.max(0.3, 1.6 - (load - 0.35) * 3), bar };
    return { css: "is-hard", label: "fan max", spin: Math.max(0.3, 0.8 - (load - 0.62) * 1.2), bar };
  }

  /* Swap speed shows in the title slot only while it is real: on after 3 s above 5 MB/s,
     off after 10 s below 1 MB/s. Returns the next gate state. */
  function swapGate(gate, io, nowMs) {
    const on = gate.on ? io >= 1 : io >= 5;
    if (on === gate.on) return { on: gate.on, since: null };
    const since = gate.since ?? nowMs;
    const hold = gate.on ? 10000 : 3000;
    return nowMs - since >= hold ? { on, since: null } : { on: gate.on, since };
  }

  /* The original's 5-minute view: each process's average and peak over the samples. A process
     missing from a sample counts as 0 there. Newest bundle id wins (for its icon). */
  function processAverages(procSamples, limit) {
    const count = procSamples.length;
    if (!count) return [];
    const byName = new Map();
    for (const sample of procSamples) {
      for (const p of sample.list) {
        const row = byName.get(p.name) || { name: p.name, sum: 0, peak: 0, bundleId: null };
        row.sum += p.cpu;
        row.peak = Math.max(row.peak, p.cpu);
        if (p.bundleId) row.bundleId = p.bundleId;
        byName.set(p.name, row);
      }
    }
    return [...byName.values()].map((r) => ({ name: r.name, bundleId: r.bundleId, avg: r.sum / count, peak: r.peak }))
      .sort((a, b) => b.avg - a.avg || b.peak - a.peak).slice(0, limit);
  }

  function pressureWord(level) { return level >= 4 ? "critical" : level >= 2 ? "warning" : "normal"; }

  /* 950 → "950 MB", 3420 → "3.3 GB" */
  function megabytes(mb) { return mb >= 1024 ? `${(mb / 1024).toFixed(1)} GB` : `${Math.round(mb)} MB`; }

  /* 74.6 → "1:14" */
  function trackTime(seconds) {
    const s = Math.max(0, Math.floor(seconds || 0));
    return `${Math.floor(s / 60)}:${pad(s % 60)}`;
  }

  /* ── Weather ───────────────────────────────────────────────── */

  /* Open-Meteo (WMO) code → icon kind */
  function weatherKind(code, isDay) {
    if (code == null) return "none";
    if (code === 0) return isDay ? "sun" : "moon";
    if (code <= 2) return isDay ? "sun-cloud" : "moon-cloud";
    if (code === 3) return "cloud";
    if (code <= 48) return "fog";
    if (code <= 67) return "rain";
    if (code <= 77) return "snow";
    if (code <= 82) return "rain";
    if (code <= 86) return "snow";
    return "storm";
  }

  /* ── Pomodoro / Deep Focus ─────────────────────────────────── */

  function focusState(m) {
    if (!m || m.phase === "idle") return "idle";
    if (!m.running) return "paused";
    return m.phase === "focus" ? "focus" : "break";
  }

  /* One shape for every state, so the page draws it one way. */
  function focusSummary(m, state) {
    const log = (m && m.todayLog) || [];
    if ((state === "focus" || state === "paused") && m.live) {
      const l = m.live;
      return {
        purity: l.purity, breaks: l.focusBreaks, distractions: l.distractions || [], minutes: l.minutes || [],
        currentMinute: state === "focus" ? { distracted: l.currentMinuteDistracted } : null,
        totalMinutes: Math.round(m.total / 60), scope: "this session",
      };
    }
    if (state === "break" || (state === "paused" && !m.live)) {
      const last = log[log.length - 1];
      if (last) {
        return {
          purity: last.purity, breaks: last.focusBreaks ?? 0, distractions: last.distractions || [],
          minutes: last.minutes || [], currentMinute: null,
          totalMinutes: Math.max((last.minutes || []).length, 1), scope: "last session",
        };
      }
    }
    const merged = new Map();
    let weighted = 0, weight = 0, breaks = 0;
    for (const e of log) {
      weighted += e.purity * e.durationSeconds;
      weight += e.durationSeconds;
      breaks += e.focusBreaks ?? 0;
      for (const d of e.distractions || []) {
        const prev = merged.get(d.app) || { ...d, visits: 0, seconds: 0 };
        prev.visits += d.visits;
        prev.seconds += d.seconds;
        merged.set(d.app, prev);
      }
    }
    return {
      purity: weight > 0 ? Math.round(weighted / weight) : null, breaks,
      distractions: [...merged.values()].sort((a, b) => b.visits - a.visits || b.seconds - a.seconds),
      minutes: [], currentMinute: null, totalMinutes: Math.round(((m && m.total) || 1500) / 60), scope: "today",
    };
  }

  /* Deep work today = focus time of today's periods (+ the running one). */
  function deepWorkToday(m) {
    if (!m) return 0;
    const logged = (m.todayLog || []).reduce((sum, e) => sum + (e.durationSeconds || 0), 0);
    const live = m.phase === "focus" && m.live ? m.live.elapsedSeconds || 0 : 0;
    return logged + live;
  }

  /* Week chart bars from the Mac's 7 days. */
  function weekBars(days) {
    const hours = (days || []).map((d) => (d.focusSeconds || 0) / 3600);
    const max = Math.max(1, ...hours);
    return {
      total: hours.reduce((a, b) => a + b, 0),
      bars: (days || []).map((d, i) => ({
        date: d.date, hours: hours[i], height: Math.max(0.03, hours[i] / max),
        kind: hours[i] < 0.05 ? "none" : (d.purity ?? 0) >= 70 ? "good" : "low",
      })),
    };
  }

  /* The page's key: SecondPad opens the page with ?k=<64 hex>; after that the saved one is used
     (the installed web app starts at "/" without it). */
  const KEY_SHAPE = /^[0-9a-f]{64}$/;
  function pageKey(search, stored) {
    const given = new URLSearchParams(search || "").get("k");
    if (given && KEY_SHAPE.test(given)) return { key: given, fromURL: true };
    return { key: stored && KEY_SHAPE.test(stored) ? stored : "", fromURL: false };
  }
  function withKey(url, key) {
    if (!url || !key) return url;
    return `${url}${url.includes("?") ? "&" : "?"}k=${key}`;
  }

  /* ── StandBy clock ──────────────────────────────────────────── */

  /* "0907" for 09:07: four digits, 24-hour (as the original). */
  function clockDigits(date) {
    return String(date.getHours()).padStart(2, "0") + String(date.getMinutes()).padStart(2, "0");
  }

  /* The line under the clock: the most urgent Claude state, and the Pomodoro (time left while a
     focus runs, otherwise today's result). Empty parts are null. */
  const STANDBY_CLAUDE = { waiting: "Claude needs you", error: "Claude hit an error", done: "Claude is done", working: "Claude is working" };
  function standbyStatus(sessions, pomo) {
    const states = (sessions || []).map((s) => s.state);
    const claude = ["waiting", "error", "done", "working"].find((s) => states.includes(s)) || null;
    let pomodoro = null;
    if (pomo && pomo.phase === "focus" && pomo.running) {
      const left = Math.max(0, Math.round(pomo.remaining || 0));
      pomodoro = `Focus · ${Math.floor(left / 60)}:${String(left % 60).padStart(2, "0")} left`;
    } else if (pomo && pomo.completed > 0) {
      const log = pomo.todayLog || [];
      const weight = log.reduce((a, e) => a + (e.durationSeconds || 0), 0);
      const purity = weight ? Math.round(log.reduce((a, e) => a + (e.purity || 0) * (e.durationSeconds || 0), 0) / weight) : null;
      pomodoro = `${pomo.completed} pomodoro${pomo.completed === 1 ? "" : "s"} today` + (purity != null ? ` · ${purity}% on task` : "");
    }
    return { claude, claudeText: claude ? STANDBY_CLAUDE[claude] : null, pomodoro };
  }

  /* Should the clock show? The Mac says it's away, or the Mac has been gone this long
     (asleep, cable out). A tap hides it until the next time either starts. */
  const STANDBY_OFFLINE_MS = 15000;
  function standbyWanted({ macAway, offlineSinceMs, nowMs, dismissed }) {
    const offline = offlineSinceMs != null && nowMs - offlineSinceMs >= STANDBY_OFFLINE_MS;
    return !dismissed && (!!macAway || offline);
  }

  const Logic = {
    pageKey, withKey, clockDigits, standbyStatus, standbyWanted, STANDBY_OFFLINE_MS,
    clock, elapsed, dur, hoursShort, limitReset, limitLevel, ageLabel, resetAt, limitRow,
    claudeRows, claudeSummary, sessionTimer, stateWord, sortTasks, taskGroups, fanState, swapGate, weatherKind,
    focusState, focusSummary, deepWorkToday, weekBars, processAverages, pressureWord, megabytes, trackTime,
  };
  if (typeof module !== "undefined" && module.exports) module.exports = Logic;
  else root.Logic = Logic;
})(typeof window !== "undefined" ? window : globalThis);
