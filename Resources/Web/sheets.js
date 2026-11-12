/* SecondPad — detail sheets (CPU / Memory / Swap / Heat) and the Now Playing screen.
   The Mac sends a sample every second; the page keeps the last 5 minutes for the charts and the
   "average · peak" process list (as the original did). A short copy is kept in localStorage so a
   reload doesn't start from empty; it is only this tablet's convenience. */
(() => {
  "use strict";

  const $ = (id) => document.getElementById(id);
  const L = window.Logic;
  const esc = (t) => window.escapeHTML(t);
  /* The tablet this runs on has Android's animations switched off, which makes Chrome report
     "reduce motion". Here motion carries meaning (the fan's speed, Claude working, a task just done,
     a peak starting), so it stays on, as in the original. */
  const reduceMotion = false;
  const WINDOW_MS = 5 * 60 * 1000;
  const STORE = "secondpad.samples";

  const samples = [];       // { at, cpu, ram, io, temp }
  const procSamples = [];   // { at, list: [{ name, cpu, bundleId }] }
  let latest = null;
  let openKind = null;

  try {
    const saved = JSON.parse(localStorage.getItem(STORE) || "null");
    const cutoff = Date.now() - WINDOW_MS;
    if (saved) {
      samples.push(...(saved.s || []).filter((x) => x.at > cutoff));
      procSamples.push(...(saved.p || []).filter((x) => x.at > cutoff));
    }
  } catch { /* private mode or blocked storage: start empty */ }
  let savedAt = 0;
  function save() {
    savedAt = Date.now();
    try { localStorage.setItem(STORE, JSON.stringify({ s: samples, p: procSamples })); } catch {}
  }
  window.addEventListener("pagehide", save);

  function trim(list, now) { while (list.length && now - list[0].at > WINDOW_MS) list.shift(); }

  /* ═══ From app.js ═══════════════════════════════════════════ */

  window.sheets = {
    stats(s) {
      latest = s;
      const now = Date.now();
      samples.push({ at: now, cpu: s.cpuPercent, ram: s.ramPercent, io: (s.swapInMBs || 0) + (s.swapOutMBs || 0), temp: s.temperature });
      if (s.topCPU?.length) procSamples.push({ at: now, list: s.topCPU.map((p) => ({ name: p.name, cpu: p.cpu, bundleId: p.bundleId })) });
      trim(samples, now);
      trim(procSamples, now);
      if (now - savedAt > 15000) save();
      if (openKind) update();
    },
    media(m) { media = { ...m, arrival: Date.now() }; paintMedia(); },
  };

  /* ═══ Opening and closing ═══════════════════════════════════
     Enter 240 ms, exit 160 ms (the system answering is faster than the user asking). */

  function show(scrim) {
    clearTimeout(scrim._t);
    scrim.hidden = false;
    scrim.classList.remove("is-closing");
    if (!reduceMotion) { scrim.classList.remove("is-opening"); void scrim.offsetWidth; scrim.classList.add("is-opening"); }
  }
  function hide(scrim, after) {
    if (scrim.hidden) return;
    scrim.classList.add("is-closing");
    scrim._t = setTimeout(() => { scrim.hidden = true; scrim.classList.remove("is-closing", "is-opening"); after?.(); }, reduceMotion ? 0 : 160);
  }
  for (const scrim of [$("sheetScrim"), $("npScrim")]) {
    scrim.addEventListener("click", (e) => {
      if (e.target === scrim || e.target.closest("[data-close]")) close(scrim);
    });
  }
  function close(scrim) {
    if (scrim === $("sheetScrim")) hide(scrim, () => { openKind = null; });
    else { hide(scrim); npOpen = false; }
  }
  document.addEventListener("keydown", (e) => {
    if (e.key !== "Escape") return;
    if (!$("sheetScrim").hidden) close($("sheetScrim"));
    if (!$("npScrim").hidden) close($("npScrim"));
  });
  // A page swipe or reconnect never leaves a sheet over the wrong page.
  window.closeSheets = () => { close($("sheetScrim")); close($("npScrim")); };

  document.querySelectorAll("[data-sheet]").forEach((el) => el.addEventListener("click", () => openSheet(el.dataset.sheet)));

  /* ═══ Sheets ════════════════════════════════════════════════ */

  const KINDS = {
    cpu: { title: "CPU", sub: "Last 5 minutes" },
    memory: { title: "Memory", sub: "Last 5 minutes" },
    swap: { title: "Swap", sub: "Memory written to disk" },
    heat: { title: "Heat", sub: "Last 5 minutes" },
  };

  function openSheet(kind) {
    if (!KINDS[kind]) return;
    openKind = kind;
    $("sheetTitle").textContent = KINDS[kind].title;
    $("sheetSub").textContent = KINDS[kind].sub;
    $("sheet").dataset.kind = kind;
    $("sheetBody").innerHTML = skeleton(kind);
    listKeys.clear();
    show($("sheetScrim"));
    update();
  }

  function hero(items) {
    return `<div class="sh-hero">${items.map(([id, label]) =>
      `<div class="sh-stat"><span>${label}</span><b id="${id}">—</b></div>`).join("")}</div>`;
  }
  const chartBox = `<div class="sh-chart"><svg viewBox="0 0 600 140" preserveAspectRatio="none" aria-hidden="true">
      <line class="sh-limit" id="shLimit" x1="0" x2="600" y1="-10" y2="-10"/>
      <path class="sh-area" id="shArea" d=""/><path class="sh-line" id="shLine" d=""/></svg>
      <div class="sh-axis"><span>5 min ago</span><span id="shCover"></span><span>now</span></div></div>`;
  const card = (title, body, cls = "") => `<section class="sh-card ${cls}"><h3>${title}</h3>${body}</section>`;

  function skeleton(kind) {
    if (kind === "cpu") {
      return hero([["shNow", "Now"], ["shAvg", "5 min average"], ["shPeak", "5 min peak"]]) + chartBox
        + `<div class="sh-grid">${card("Busiest apps · last 5 min", `<ul class="sh-list" id="shList"></ul>`)}
           ${card("Cores", `<div class="sh-cores"><div class="sh-core-set" id="shCoresP"></div><div class="sh-core-set" id="shCoresE"></div></div>
              <div class="sh-core-key"><span id="shPKey">Performance</span><span id="shEKey">Efficiency</span></div>`)}</div>`;
    }
    if (kind === "memory") {
      return hero([["shNow", "Used now"], ["shUsed", "In use"], ["shZip", "Compressed"], ["shPress", "Pressure"]]) + chartBox
        + `<div class="sh-grid">${card("Biggest apps now", `<ul class="sh-list" id="shList"></ul>`)}
           ${card("What it means", `<ul class="sh-facts" id="shFacts"></ul>`)}</div>`;
    }
    if (kind === "swap") {
      return hero([["shNow", "On disk"], ["shIn", "Reading in"], ["shOut", "Writing out"], ["shPeak", "5 min peak"]]) + chartBox
        + `<div class="sh-grid">${card("Now", `<ul class="sh-facts" id="shFacts"></ul>`)}
           ${card("Biggest apps now", `<ul class="sh-list" id="shList"></ul>`)}</div>`;
    }
    return hero([["shNow", "Hottest now"], ["shAvg", "5 min average"], ["shPeak", "5 min peak"], ["shFan", "Fan"]]) + chartBox
      + `<div class="sh-grid">${card("Sensors", `<ul class="sh-list sh-sensors" id="shList"></ul>`)}
         ${card("Cooling", `<ul class="sh-facts" id="shFacts"></ul>`)}</div>`;
  }

  function set(id, text, level) {
    const el = $(id);
    if (!el) return;
    el.textContent = text;
    if (level !== undefined) el.dataset.level = level;
  }

  function update() {
    const s = latest;
    if (!s || !openKind) return;
    const covered = samples.length ? Date.now() - samples[0].at : 0;
    set("shCover", covered < WINDOW_MS - 15000 ? `collecting · ${L.clock(covered / 1000)} of 5:00` : "");
    const stat = (key) => {
      const v = samples.map((x) => x[key]).filter((x) => typeof x === "number");
      return { avg: v.length ? v.reduce((a, b) => a + b, 0) / v.length : null, peak: v.length ? Math.max(...v) : null };
    };

    if (openKind === "cpu") {
      const st = stat("cpu");
      set("shNow", `${Math.round(s.cpuPercent)}%`, L.limitLevel(s.cpuPercent >= 85 ? 95 : s.cpuPercent >= 60 ? 80 : 0));
      set("shAvg", st.avg == null ? "—" : `${Math.round(st.avg)}%`);
      set("shPeak", st.peak == null ? "—" : `${Math.round(st.peak)}%`, st.peak >= 85 ? "high" : "ok");
      chart("cpu", 0, 100, 85);
      list(L.processAverages(procSamples, 6).map((p) => ({
        key: p.name, name: p.name, bundleId: p.bundleId, value: `${Math.round(p.avg)}% avg · ${Math.round(p.peak)}% peak`,
        fill: p.avg / 100, mark: p.peak / 100, hot: p.peak >= 85,
      })), "measuring");
      cores(s.coreLoads || [], s.performanceCores);
    } else if (openKind === "memory") {
      set("shNow", `${Math.round(s.ramPercent)}%`, s.ramPercent >= 93 ? "high" : s.ramPercent >= 85 ? "warn" : "ok");
      set("shUsed", `${s.ramUsedGB.toFixed(1)} of ${s.ramTotalGB.toFixed(0)} GB`);
      set("shZip", `${(s.compressedGB || 0).toFixed(1)} GB`);
      set("shPress", L.pressureWord(s.memoryPressure), s.memoryPressure >= 4 ? "high" : s.memoryPressure >= 2 ? "warn" : "ok");
      chart("ram", 0, 100, 93);
      memoryList(s);
      facts([
        ["In use", "apps + wired + compressed, like Activity Monitor"],
        ["Compressed", "memory macOS squeezed to make room"],
        ["Pressure", L.pressureWord(s.memoryPressure) === "normal" ? "normal: there is room" : "high: the Mac is swapping to disk"],
      ]);
    } else if (openKind === "swap") {
      const io = (s.swapInMBs || 0) + (s.swapOutMBs || 0);
      const st = stat("io");
      set("shNow", `${(s.swapUsedGB || 0).toFixed(1)} GB`, (s.swapUsedGB || 0) >= 0.5 && s.memoryPressure >= 2 ? "warn" : "ok");
      set("shIn", `${(s.swapInMBs || 0).toFixed(1)} MB/s`, (s.swapInMBs || 0) >= 5 ? "warn" : "ok");
      set("shOut", `${(s.swapOutMBs || 0).toFixed(1)} MB/s`, (s.swapOutMBs || 0) >= 5 ? "warn" : "ok");
      set("shPeak", st.peak == null ? "—" : `${st.peak.toFixed(1)} MB/s`, st.peak >= 20 ? "high" : st.peak >= 5 ? "warn" : "ok");
      chart("io", 0, Math.max(40, st.peak || 0), 20);
      facts([
        ["Swap file", `${(s.swapUsedGB || 0).toFixed(1)} of ${(s.swapTotalGB || 0).toFixed(1)} GB`],
        ["Swap speed now", `${io.toFixed(1)} MB/s${io >= 20 ? " · the Mac is stalling" : io >= 5 ? " · noticeable" : ""}`],
        ["Memory pressure", L.pressureWord(s.memoryPressure)],
        ["Up for", `${(s.uptimeDays || 0).toFixed(1)} days`],
      ]);
      memoryList(s);
    } else {
      const st = stat("temp");
      const t = s.temperature;
      set("shNow", t == null ? "—" : `${Math.round(t)}°C`, t >= 95 ? "high" : t >= 70 ? "warn" : "ok");
      set("shAvg", st.avg == null ? "—" : `${Math.round(st.avg)}°C`);
      set("shPeak", st.peak == null ? "—" : `${Math.round(st.peak)}°C`, st.peak >= 95 ? "high" : st.peak >= 70 ? "warn" : "ok");
      set("shFan", s.fanRPM == null ? "—" : s.fanRPM <= 0 ? "off" : `${s.fanRPM.toLocaleString("en-US")} rpm`);
      chart("temp", 30, 105, 95);
      list((s.sensors || []).map((x) => ({
        key: x.name, name: x.name, value: `${Math.round(x.celsius)}°C`, fill: Math.min(1, Math.max(0, (x.celsius - 30) / 75)),
        hot: x.celsius >= 95, warm: x.celsius >= 70, noIcon: true,
      })), "no sensors on this Mac");
      facts([
        ["Fan", s.fanRPM == null ? "no fan reading" : s.fanRPM <= 0 ? "off (silent)"
          : `${s.fanRPM.toLocaleString("en-US")} of ${(s.fanMaxRPM || 0).toLocaleString("en-US")} rpm`],
        ["macOS thermal state", s.thermalState || "—"],
      ]);
    }
  }

  function chart(key, min, max, limit) {
    const now = Date.now(), W = 600, H = 140, pad = 6;
    const y = (v) => H - pad - ((Math.min(max, Math.max(min, v)) - min) / (max - min)) * (H - pad * 2);
    const x = (at) => W - ((now - at) / WINDOW_MS) * W;
    const pts = samples.filter((p) => typeof p[key] === "number").map((p) => `${x(p.at).toFixed(1)},${y(p[key]).toFixed(1)}`);
    $("shLine").setAttribute("d", pts.length > 1 ? `M${pts.join("L")}` : "");
    $("shArea").setAttribute("d", pts.length > 1 ? `M${pts[0].split(",")[0]},${H}L${pts.join("L")}L${W},${H}Z` : "");
    const ly = y(limit).toFixed(1);
    $("shLimit").setAttribute("y1", ly);
    $("shLimit").setAttribute("y2", ly);
  }

  /* Rows are rebuilt only when the names change; values and bars update in place, so icons
     don't reload every second. */
  const listKeys = new Map();
  function list(rows, emptyText) {
    const ul = $("shList");
    if (!ul) return;
    const key = rows.map((r) => r.key).join("␟");
    if (listKeys.get(ul) !== key) {
      listKeys.set(ul, key);
      ul.innerHTML = rows.length ? rows.map((r) => `
        <li>${r.noIcon ? "" : icon(r.name, r.bundleId)}<span class="sh-name">${esc(r.name)}</span><span class="sh-val"></span>
          <span class="sh-bar"><i></i>${r.mark != null ? `<i class="sh-mark"></i>` : ""}</span></li>`).join("")
        : `<li class="sh-empty">${esc(emptyText)}</li>`;
      ul.querySelectorAll("img[data-mono]").forEach((img) => img.addEventListener("error", () => {
        const span = document.createElement("span");
        span.className = "sh-icon sh-mono";
        span.textContent = img.dataset.mono;
        img.replaceWith(span);
      }, { once: true }));
    }
    [...ul.querySelectorAll("li:not(.sh-empty)")].forEach((li, i) => {
      const r = rows[i];
      li.querySelector(".sh-val").textContent = r.value;
      li.classList.toggle("is-hot", !!r.hot);
      li.classList.toggle("is-warm", !r.hot && !!r.warm);
      const [bar, mark] = li.querySelectorAll(".sh-bar > i");
      bar.style.transform = `scaleX(${Math.max(0, Math.min(1, r.fill)).toFixed(3)})`;
      if (mark) mark.style.left = `${(Math.max(0, Math.min(1, r.mark)) * 100).toFixed(1)}%`;
    });
  }

  function icon(name, bundleId) {
    const letter = esc((name || "?").trim().charAt(0).toUpperCase());
    return bundleId
      ? `<img class="sh-icon" alt="" src="${window.withKey(`/appicon?id=${encodeURIComponent(bundleId)}`)}" data-mono="${letter}">`
      : `<span class="sh-icon sh-mono">${letter}</span>`;
  }

  function memoryList(s) {
    const top = s.topMemory || [];
    const max = Math.max(1, ...top.map((p) => p.memoryMB));
    list(top.map((p) => ({ key: p.name, name: p.name, bundleId: p.bundleId, value: L.megabytes(p.memoryMB), fill: p.memoryMB / max })), "measuring");
  }

  function facts(rows) {
    const ul = $("shFacts");
    if (!ul) return;
    const html = rows.map(([k, v]) => `<li><span>${esc(k)}</span><b>${esc(v)}</b></li>`).join("");
    if (ul.innerHTML !== html) ul.innerHTML = html;
  }

  function cores(loads, performance) {
    const p = $("shCoresP"), e = $("shCoresE");
    if (!p || !loads.length) return;
    const pCount = Math.min(loads.length, performance || Math.ceil(loads.length / 2));
    if (p.children.length + e.children.length !== loads.length) {
      p.replaceChildren(...loads.slice(0, pCount).map(() => document.createElement("i")));
      e.replaceChildren(...loads.slice(pCount).map(() => document.createElement("i")));
      p.style.flexGrow = String(pCount);
      e.style.flexGrow = String(Math.max(1, loads.length - pCount));
      $("shPKey").textContent = `Performance · ${pCount}`;
      $("shEKey").textContent = loads.length - pCount ? `Efficiency · ${loads.length - pCount}` : "";
    }
    [...p.children, ...e.children].forEach((bar, i) => {
      const v = Math.max(0, Math.min(100, loads[i] || 0));
      bar.style.transform = `scaleY(${(Math.max(5, v) / 100).toFixed(3)})`;
      bar.classList.toggle("is-hot", v >= 70);
    });
  }

  /* ═══ Now Playing ═══════════════════════════════════════════ */

  let media = null;
  let lastKey = null;
  let npOpen = false;
  let npTimer = null;

  $("npOpen").addEventListener("click", () => {
    if (!media || !media.running || !media.title) return;
    npOpen = true;
    paintMedia();
    show($("npScrim"));
  });

  function paintMedia() {
    clearInterval(npTimer);
    if (!media) return;
    $("npOpen").disabled = !media.running || !media.title;   // nothing to show: the strip says why
    if (npOpen && (!media.running || !media.title)) { close($("npScrim")); return; }
    $("npBigTitle").textContent = media.title || "—";
    $("npBigArtist").textContent = [media.artist, media.album].filter(Boolean).join(" · ") || "—";
    $("npBigPlay").classList.toggle("is-playing", !!media.playing);
    const art = $("npBigArt");
    const url = media.artwork ? `url("${window.withKey(media.artwork)}")` : "";
    if (art.style.backgroundImage !== url) art.style.backgroundImage = url;
    art.classList.toggle("has-art", !!media.artwork);
    // The cover, blurred, fills the background (the original's ambient light); it fades in.
    const amb = $("npAmbient");
    if (amb.style.backgroundImage !== url) amb.style.backgroundImage = url;
    amb.classList.toggle("is-visible", !!media.artwork);
    // A new track while the screen is open: the cover gives a small kick (never on the first one).
    const key = `${media.title}\u241f${media.artist}`;
    if (npOpen && lastKey !== null && key !== lastKey) {
      art.classList.remove("is-kicking"); void art.offsetWidth; art.classList.add("is-kicking");
      setTimeout(() => art.classList.remove("is-kicking"), 200);
    }
    lastKey = key;
    tickProgress();
    if (media.playing) npTimer = setInterval(tickProgress, 500);
  }

  function tickProgress() {
    if (!media || !npOpen) return;
    const elapsed = media.playing ? (Date.now() - media.arrival) / 1000 : 0;
    const pos = Math.min(media.duration || 0, (media.position || 0) + elapsed);
    const dur = media.duration || 0;
    $("npBar").style.transform = `scaleX(${dur > 0 ? (pos / dur).toFixed(4) : 0})`;
    $("npPos").textContent = L.trackTime(pos);
    $("npDur").textContent = L.trackTime(dur);
  }
})();
