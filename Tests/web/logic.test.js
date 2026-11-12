// Pure page logic. Run: node --test Tests/web
const test = require("node:test");
const assert = require("node:assert/strict");
const L = require("../../Resources/Web/logic.js");

test("clocks and durations", () => {
  assert.equal(L.clock(75), "01:15");
  assert.equal(L.clock(-3), "00:00");
  assert.equal(L.elapsed(42), "0:42");
  assert.equal(L.elapsed(3729), "1:02:09");
  assert.equal(L.dur(45), "45s");
  assert.equal(L.dur(250), "4m 10s");
  assert.equal(L.dur(720), "12m");
  assert.equal(L.dur(3900), "1h 5m");
  assert.equal(L.hoursShort(2700), "45m");
  assert.equal(L.hoursShort(5760), "1.6h");
});

test("limit rows", () => {
  const now = 1_800_000_000;
  assert.equal(L.limitReset(30), "1m");
  assert.equal(L.limitReset(67 * 60), "1h 07m");
  assert.equal(L.limitReset(4 * 86400 + 7 * 3600), "4d 7h");
  assert.equal(L.limitReset(0), "");
  assert.deepEqual([79, 80, 94.9, 95].map(L.limitLevel), ["ok", "warn", "warn", "high"]);
  assert.equal(L.limitRow(null, now).pct, "—");
  const row = L.limitRow({ percent: 63.4, resetsAt: now + 3600 }, now);
  assert.equal(row.pct, "63");
  assert.equal(row.level, "ok");
  assert.ok(row.reset.startsWith("resets in 1h 00m · "));
  const gone = L.limitRow({ percent: 99, resetsAt: now - 1 }, now);
  assert.equal(gone.level, "reset");
  assert.equal(gone.fill, 0);
  assert.equal(L.ageLabel(20), "just now");
  assert.equal(L.ageLabel(300), "5m ago");
  assert.equal(L.ageLabel(7300), "2h ago");
});

test("claude rows: urgent wins the slots, order stays stable, same folder is numbered", () => {
  const s = (id, project, state, firstSeenAt) => ({ id, project, state, firstSeenAt, activity: "" });
  const sessions = [s("a", "app", "working", 1), s("b", "app", "done", 2), s("c", "web", "waiting", 3),
    s("d", "api", "working", 4), s("e", "cli", "error", 5), s("f", "x", "idle", 0)];
  const { rows, hidden, total } = L.claudeRows(sessions, 4);
  assert.equal(total, 5);
  assert.equal(hidden, 1);
  assert.deepEqual(rows.map((r) => r.id), ["a", "b", "c", "e"]);   // "d" (working, newest) drops out
  assert.deepEqual(rows.map((r) => r.label), ["app", "app 2", "web", "cli"]);
  assert.deepEqual(L.claudeSummary(sessions).map((x) => x.text), ["1 needs you", "1 failed", "2 working", "1 done"]);
});

test("session timers", () => {
  const now = 1000;
  assert.deepEqual(L.sessionTimer({ state: "working", turnStartedAt: 958 }, now), { text: "0:42", live: true });
  assert.deepEqual(L.sessionTimer({ state: "waiting", stateSince: 880 }, now), { text: "2:00", live: true });
  assert.deepEqual(L.sessionTimer({ state: "done", lastTurnSeconds: 412 }, now), { text: "6:52", live: false });
  assert.equal(L.sessionTimer({ state: "error" }, now), null);
  assert.equal(L.stateWord("waiting"), "Needs you");
});

test("tasks, fan, swap gate, weather", () => {
  const sorted = L.sortTasks([{ id: 1, done: true, createdAt: 1 }, { id: 2, done: false, createdAt: 3 }, { id: 3, done: false, createdAt: 2 }]);
  assert.deepEqual(sorted.map((t) => t.id), [3, 2, 1]);
  assert.equal(L.fanState(null).label, "—");
  assert.equal(L.fanState(0).label, "fan off");
  assert.equal(L.fanState(0.2).label, "fan on");
  assert.equal(L.fanState(0.9).label, "fan max");
  let g = { on: false, since: null };
  g = L.swapGate(g, 8, 0); assert.equal(g.on, false);
  g = L.swapGate(g, 8, 3000); assert.equal(g.on, true);
  g = L.swapGate(g, 0.5, 4000); assert.equal(g.on, true);
  g = L.swapGate(g, 0.5, 14000); assert.equal(g.on, false);
  assert.equal(L.weatherKind(0, true), "sun");
  assert.equal(L.weatherKind(0, false), "moon");
  assert.equal(L.weatherKind(61, true), "rain");
  assert.equal(L.weatherKind(95, true), "storm");
  assert.equal(L.weatherKind(null, true), "none");
});

test("deep focus summary per state", () => {
  assert.equal(L.focusState(null), "idle");
  assert.equal(L.focusState({ phase: "focus", running: false }), "paused");
  assert.equal(L.focusState({ phase: "longBreak", running: true }), "break");
  const live = { phase: "focus", running: true, total: 1500,
    live: { purity: 88, focusBreaks: 2, distractions: [{ app: "X", visits: 2, seconds: 30 }], minutes: [false, true], currentMinuteDistracted: true, elapsedSeconds: 130 },
    todayLog: [{ durationSeconds: 1500, purity: 90, focusBreaks: 1, distractions: [{ app: "X", visits: 1, seconds: 10 }] }] };
  const s = L.focusSummary(live, "focus");
  assert.equal(s.scope, "this session");
  assert.equal(s.totalMinutes, 25);
  assert.deepEqual(s.currentMinute, { distracted: true });
  assert.equal(L.deepWorkToday(live), 1630);
  const idle = { phase: "idle", running: false, total: 1500, todayLog: [
    { durationSeconds: 1500, purity: 90, focusBreaks: 1, distractions: [{ app: "X", visits: 1, seconds: 10 }] },
    { durationSeconds: 500, purity: 50, focusBreaks: 2, distractions: [{ app: "X", visits: 2, seconds: 20 }, { app: "Y", visits: 1, seconds: 5 }] }] };
  const t = L.focusSummary(idle, "idle");
  assert.equal(t.scope, "today");
  assert.equal(t.purity, 80);
  assert.equal(t.breaks, 3);
  assert.deepEqual(t.distractions.map((d) => [d.app, d.visits, d.seconds]), [["X", 3, 30], ["Y", 1, 5]]);
  assert.equal(L.focusSummary(null, "idle").purity, null);
});

test("week bars", () => {
  const { total, bars } = L.weekBars([{ date: "2026-11-06", focusSeconds: 0 }, { date: "2026-11-07", focusSeconds: 7200, purity: 80 },
    { date: "2026-11-08", focusSeconds: 3600, purity: 40 }]);
  assert.equal(total, 3);
  assert.deepEqual(bars.map((b) => b.kind), ["none", "good", "low"]);
  assert.equal(bars[1].height, 1);
  assert.equal(bars[0].height, 0.03);
});

test("task groups keep a just-ticked task in place", () => {
  const items = [{ id: "a", done: false, createdAt: 1 }, { id: "b", done: true, createdAt: 2 }, { id: "c", done: false, createdAt: 3 }, { id: "d", done: true, createdAt: 0 }];
  const plain = L.taskGroups(items, new Set());
  assert.deepEqual(plain.open.map((t) => t.id), ["a", "c"]);
  assert.deepEqual(plain.done.map((t) => t.id), ["d", "b"]);
  const held = L.taskGroups(items, new Set(["b"]));
  assert.deepEqual(held.open.map((t) => t.id), ["a", "b", "c"]);   // b stays between a and c
  assert.deepEqual(held.done.map((t) => t.id), ["d"]);
});

test("sheet helpers", () => {
  const rows = L.processAverages([
    { list: [{ name: "Xcode", cpu: 30, bundleId: "com.apple.dt.Xcode" }, { name: "x", cpu: 10 }] },
    { list: [{ name: "Xcode", cpu: 10 }] },
  ], 5);
  assert.deepEqual(rows.map((r) => [r.name, r.avg, r.peak, r.bundleId]), [["Xcode", 20, 30, "com.apple.dt.Xcode"], ["x", 5, 10, null]]);
  assert.deepEqual(L.processAverages([], 5), []);
  assert.deepEqual([1, 2, 4].map(L.pressureWord), ["normal", "warning", "critical"]);
  assert.equal(L.megabytes(950), "950 MB");
  assert.equal(L.megabytes(3420), "3.3 GB");
  assert.equal(L.trackTime(74.6), "1:14");
  assert.equal(L.trackTime(null), "0:00");
});

test("page key", () => {
  const key = "ab".repeat(32);
  assert.deepEqual(L.pageKey(`?k=${key}`, ""), { key, fromURL: true });
  assert.deepEqual(L.pageKey("", key), { key, fromURL: false });                 // installed app, start URL "/"
  assert.deepEqual(L.pageKey("?k=nope", key), { key, fromURL: false });          // a bad one doesn't replace the saved one
  assert.deepEqual(L.pageKey("", "short"), { key: "", fromURL: false });
  assert.equal(L.withKey("/appicon?id=com.x", key), `/appicon?id=com.x&k=${key}`);
  assert.equal(L.withKey("ws://127.0.0.1:8770/ws", key), `ws://127.0.0.1:8770/ws?k=${key}`);
  assert.equal(L.withKey("/artwork?v=3", ""), "/artwork?v=3");
});

test("standby clock", () => {
  assert.equal(L.clockDigits(new Date(2026, 10, 12, 9, 7)), "0907");
  assert.equal(L.clockDigits(new Date(2026, 10, 12, 23, 59)), "2359");
  // Most urgent Claude state wins; Pomodoro: time left while focusing, else today's result.
  const s = L.standbyStatus([{ state: "working" }, { state: "waiting" }, { state: "done" }], { phase: "focus", running: true, remaining: 754 });
  assert.equal(s.claudeText, "Claude needs you");
  assert.equal(s.pomodoro, "Focus · 12:34 left");
  const today = L.standbyStatus([], { phase: "idle", completed: 3, todayLog: [{ durationSeconds: 1500, purity: 90 }, { durationSeconds: 1500, purity: 70 }] });
  assert.equal(today.claude, null);
  assert.equal(today.pomodoro, "3 pomodoros today · 80% on task");
  assert.equal(L.standbyStatus([{ state: "idle" }], { phase: "idle", completed: 0 }).pomodoro, null);
  assert.equal(L.standbyStatus(null, null).claude, null);
  // When it shows: Mac away (sleep, lock, screen saver), or 15 s without the Mac; a tap hides it.
  const now = 1_000_000;
  assert.equal(L.standbyWanted({ macAway: true, offlineSinceMs: null, nowMs: now, dismissed: false }), true);
  assert.equal(L.standbyWanted({ macAway: false, offlineSinceMs: now - 3000, nowMs: now, dismissed: false }), false);   // a cable wobble
  assert.equal(L.standbyWanted({ macAway: false, offlineSinceMs: now - 15000, nowMs: now, dismissed: false }), true);   // the Mac is gone
  assert.equal(L.standbyWanted({ macAway: true, offlineSinceMs: null, nowMs: now, dismissed: true }), false);
  assert.equal(L.standbyWanted({ macAway: false, offlineSinceMs: null, nowMs: now, dismissed: false }), false);          // back
});
