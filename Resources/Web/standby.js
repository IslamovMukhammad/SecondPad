/* SecondPad — StandBy: an iPhone-StandBy-style clock, ported 1:1 from the original's standby.js.

   When the Mac's screen saver starts or it locks (SecondPad also: displays asleep, Mac asleep, or
   the Mac gone for 15 s), the tablet switches to this view.

   The digits are in the Mac's own SF Pro Rounded when "Use this Mac's SF Rounded on the tablet" is
   on in Settings: the tablet has no rounded font, so it is fetched from the Mac over the cable
   (with the page key) and cached. Off (the default), the original's fallback stack is used.

   The screen can stay on for hours, so there are two precautions: the colour is dimmed and the
   clock slowly drifts. */
(() => {
  "use strict";

  const L = window.Logic;
  let root = null;
  const slots = [];
  let ticker = null;
  let driftTimer = null;
  let visible = false;
  let status = null;
  let claudeState = null;
  let pomo = null;

  // SecondPad: why it shows (the original only had the Mac's message and the battery button).
  let macAway = false;
  let offlineSinceMs = null;
  let dismissed = false;
  let manual = false;
  let checkTimer = null;
  let macFontReady = false;

  /* ── One digit cell ─────────────────────────────────────────── */

  function makeSlot() {
    const slot = document.createElement("div");
    slot.className = "sb-slot";
    slot.__value = null;
    return slot;
  }

  function glyph(digit) {
    const span = document.createElement("span");
    span.className = "sb-glyph";
    span.textContent = digit;
    return span;
  }

  /* When a digit changes the old one leaves upward and the new one rises from below: exactly
     StandBy's motion. */
  function setSlot(slot, digit) {
    if (slot.__value === digit) return;
    const previous = slot.firstElementChild;
    const next = glyph(digit);
    next.classList.add("is-entering");
    slot.appendChild(next);

    /* The browser MUST compute the start state before the class is removed. A
       requestAnimationFrame isn't enough here: it runs before style recalculation, so both states
       merge into one frame and the entering digit appears in place without moving. Measured: the
       leaving one went 0 → -358px while the entering one stayed at Y=0, opacity 1 the whole time.
       Reading layout forces the computation. */
    void next.offsetWidth;
    next.classList.remove("is-entering");

    if (previous) {
      previous.classList.add("is-leaving");
      previous.addEventListener("transitionend", () => previous.remove(), { once: true });
      // The element must not stay behind even if the animation doesn't run for some reason.
      setTimeout(() => previous.remove(), 900);
    }
    slot.__value = digit;
  }

  /* ── Measuring ────────────────────────────────────────────────
     The font's real metrics are measured and the clock is scaled to fit the screen. The reference
     phone is 2.26:1 and this tablet 1.67:1, so width and height can't both be filled at the same
     share. Width wins: in StandBy, too, the clock stretches across the width. */
  function layoutClock() {
    if (!root) return;

    const probeSize = 400;
    const canvas = layoutClock.canvas || (layoutClock.canvas = document.createElement("canvas"));
    const ctx = canvas.getContext("2d");
    ctx.font = `840 ${probeSize}px "SF Rounded", sans-serif`;

    // The digits are tabular, i.e. all the same width.
    const advance = ctx.measureText("0").width / probeSize;
    /* SecondPad: the original's tight setting is made for SF Pro Rounded. Without it (the
       tablet's own font, checked on the tablet) the dots ran into the digits, so the fallback
       keeps each digit's own width and gives the colon room. */
    const rounded = macFontReady;
    const colonRatio = rounded ? 0.20 : 0.30;

    // In the reference the clock takes 80 % of the screen width. It was 0.90 and came out
    // noticeably wider than the real one.
    const available = window.innerWidth * 0.82;
    /* Five elements have four gaps between them, all negative. Without counting them the size came
       out larger than the real width and the clock smaller than the reference. */
    const overlap = rounded ? 0.13 : 0;
    const totalRatio = advance * 4 + colonRatio - advance * overlap * 4;
    const size = Math.round(available / totalRatio);

    /* The cell must not be shorter than the glyph, or the digit leaves its cell and touches the
       line below. */
    const style = root.style;
    style.setProperty("--sb-size", `${size}px`);
    style.setProperty("--sb-w", `${Math.round(advance * size)}px`);
    style.setProperty("--sb-h", `${Math.round(size * 1.02)}px`);
    style.setProperty("--sb-colon-w", `${Math.round(colonRatio * size)}px`);
    style.setProperty("--sb-dot", `${Math.round(0.155 * size)}px`);
    style.setProperty("--sb-dot-gap", `${Math.round(0.17 * size)}px`);
    // In the reference neighbouring digits run ~13 % of their width into each other.
    style.setProperty("--sb-tight", `${-Math.round(advance * size * overlap)}px`);
  }

  /* ── Clock ──────────────────────────────────────────────────── */

  function render() {
    const digits = L.clockDigits(new Date()).split("");
    slots.forEach((slot, index) => setSlot(slot, digits[index]));
  }

  /* Aligned to the start of the second: otherwise the digit change lags the real minute by a few
     hundred milliseconds. */
  function scheduleTick() {
    clearTimeout(ticker);
    const delay = 1000 - (Date.now() % 1000);
    ticker = setTimeout(() => {
      if (visible) { render(); scheduleTick(); }
    }, delay);
  }

  /* A bright digit standing in one place for hours can leave a mark on the screen. Every minute it
     moves a few pixels: the eye doesn't catch it, but the pixels take turns. */
  function drift() {
    clearInterval(driftTimer);
    let step = 0;
    const move = () => {
      step += 1;
      const angle = step * 0.7;
      const x = Math.cos(angle) * 14;
      const y = Math.sin(angle * 1.3) * 10;
      root.querySelector(".sb-inner").style.transform = `translate(${x.toFixed(1)}px, ${y.toFixed(1)}px)`;
    };
    move();
    driftTimer = setInterval(move, 60_000);
  }

  /* ── Showing ────────────────────────────────────────────────── */

  function build() {
    root = document.createElement("div");
    root.className = "standby";
    root.id = "standby";
    root.hidden = true;

    const inner = document.createElement("div");
    inner.className = "sb-inner";

    const clock = document.createElement("div");
    clock.className = "sb-clock";
    clock.setAttribute("aria-hidden", "true");

    for (let i = 0; i < 4; i++) {
      if (i === 2) {
        const colon = document.createElement("div");
        colon.className = "sb-colon";
        colon.append(document.createElement("span"), document.createElement("span"));
        clock.appendChild(colon);
      }
      const slot = makeSlot();
      clock.appendChild(slot);
      slots.push(slot);
    }

    // The status line: Claude and the Pomodoro stay visible during sleep too.
    status = document.createElement("div");
    status.className = "sb-status";
    status.hidden = true;
    const claude = document.createElement("span");
    claude.className = "sb-status-claude";
    claude.append(document.createElement("i"), document.createElement("span"));
    const sep = document.createElement("span");
    sep.className = "sb-status-sep";
    const pomoText = document.createElement("span");
    pomoText.className = "sb-status-pomo";
    status.append(claude, sep, pomoText);

    inner.append(clock, status);
    root.appendChild(inner);

    document.body.appendChild(root);
  }

  function show() {
    if (visible) return;
    visible = true;
    root.hidden = false;
    layoutClock();
    // Wait one frame so the opening animation runs.
    requestAnimationFrame(() => root.classList.add("is-on"));
    render();
    renderStatus();
    scheduleTick();
    drift();
  }

  function hide() {
    if (!visible) return;
    visible = false;
    clearTimeout(ticker);
    clearInterval(driftTimer);
    root.classList.remove("is-on");
    setTimeout(() => { if (!visible) root.hidden = true; }, 480);
  }

  build();

  /* The sizes are exact once the font has arrived: until then the metrics are the fallback
     font's and the clock came out smaller. */
  if (document.fonts) document.fonts.ready.then(layoutClock);
  window.addEventListener("resize", layoutClock);

  /* ── Status line ───────────────────────────────────────────────
     With several sessions, the most urgent: needs you > error > done > working. Pomodoro: the time
     left while one runs, otherwise today's result. (Logic.standbyStatus.) */
  function renderStatus() {
    if (!status) return;
    // SecondPad: with the Mac gone the last state may be long out of date: the clock alone.
    const st = offlineSinceMs != null ? L.standbyStatus([], null) : L.standbyStatus(claudeState, pomo);
    const claude = status.querySelector(".sb-status-claude");
    const pomoText = status.querySelector(".sb-status-pomo");

    claude.hidden = !st.claude;
    if (st.claude) {
      claude.querySelector("span").textContent = st.claudeText;
      claude.classList.toggle("is-waiting", st.claude === "waiting");
      claude.classList.toggle("is-error", st.claude === "error");
    }
    pomoText.textContent = st.pomodoro || "";
    status.querySelector(".sb-status-sep").hidden = !(st.claude && st.pomodoro);
    status.hidden = !st.claude && !st.pomodoro;
  }

  /* ── When it shows (SecondPad) ─────────────────────────────── */

  function update() {
    const want = manual || L.standbyWanted({ macAway, offlineSinceMs, nowMs: Date.now(), dismissed });
    if (want) show(); else hide();
    clearTimeout(checkTimer);
    // Gone, but not long enough yet: look again when the 15 s are up.
    if (!want && offlineSinceMs != null && !dismissed) {
      checkTimer = setTimeout(update, Math.max(200, offlineSinceMs + L.STANDBY_OFFLINE_MS - Date.now()));
    }
  }

  /* The Mac's own SF Pro Rounded, only when Settings allows it; the key goes with the request. */
  let macFontLoaded = false;
  function useMacFont(on) {
    if (!on || macFontLoaded || typeof FontFace === "undefined") return;
    macFontLoaded = true;
    const face = new FontFace("SF Rounded", `url("${window.withKey("/font/rounded")}")`, { weight: "1 1000", display: "block" });
    face.load().then((loaded) => { document.fonts.add(loaded); macFontReady = true; layoutClock(); }).catch(() => { macFontLoaded = false; });
  }

  window.standby = {
    /* The Mac's message. A new "away" starts a new standby (an earlier tap no longer counts). */
    mac(active) {
      if (active && !macAway) dismissed = false;
      macAway = !!active;
      if (!macAway) manual = false;
      update();
    },
    connected(on) {
      if (on) offlineSinceMs = null;
      else if (offlineSinceMs == null) { offlineSinceMs = Date.now(); if (!macAway) dismissed = false; }
      if (visible) renderStatus();
      update();
    },
    claude(m) { claudeState = m.sessions || []; renderStatus(); },
    pomodoro(m) { pomo = m; renderStatus(); },
    settings(m) { useMacFont(!!m.macFont); },
    open() { manual = true; dismissed = false; update(); },
  };

  /* A touch closes it for now: no need to walk to the Mac to look at something. It opens again by
     itself the next time the Mac goes away. */
  document.addEventListener("pointerdown", (event) => {
    if (visible && event.target.closest(".standby")) { manual = false; dismissed = true; update(); }
  });

  // The battery on the main page opens the big StandBy clock (a quick shortcut, as the original).
  document.getElementById("batt")?.addEventListener("click", () => window.standby.open());
})();
