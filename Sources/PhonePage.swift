import AppKit

/// The phone remote's page (see `PhoneRemote`), in either of Oyl's looks, as the Mac has it: Oyl's
/// own, black and rounded like the notch; or Midnight Oyl's, its sky turning slowly round a pole
/// off to one side, engraved rules in place of boxes, Victorian type, and each part drifting in.
/// Whatever it shows from the Mac goes in as text, never as markup.
enum PhonePage {
    static let html = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
    <meta name="apple-mobile-web-app-title" content="Oyl">
    <meta name="theme-color" content="#000000">
    <link rel="apple-touch-icon" href="/icon.png">
    <link rel="manifest" href="/manifest.json">
    <title>Oyl</title>
    <style>
    :root { color-scheme: dark; --bg: #000; --fg: #fff; --soft: rgba(255,255,255,.62); --faint: rgba(255,255,255,.36);
      --card: rgba(255,255,255,.07); --fill: rgba(255,255,255,.12); --accent: #d97757; --ok: #86e0a8; }
    * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
    html { background: var(--bg); }
    body { margin: 0; min-height: 100vh; background: var(--bg); color: var(--fg); -webkit-font-smoothing: antialiased;
      font: 15px/1.35 -apple-system, BlinkMacSystemFont, system-ui, sans-serif; overflow-x: hidden; }
    #sky { position: fixed; inset: 0; width: 100%; height: 100%; pointer-events: none; display: none; }
    main { position: relative; max-width: 560px; margin: 0 auto;
      padding: calc(env(safe-area-inset-top) + 18px) 16px calc(env(safe-area-inset-bottom) + 28px); }
    header { display: flex; align-items: baseline; justify-content: space-between; gap: 12px; margin: 4px 4px 16px; }
    h1 { margin: 0; font-size: 28px; font-weight: 700; letter-spacing: -.01em; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .quiet { color: var(--faint); font-size: 13px; margin: 0; flex: none; }
    section { background: var(--card); border-radius: 22px; padding: 14px 16px 16px; margin-bottom: 12px; }
    section > h2 { margin: 0 0 8px; font-size: 13px; font-weight: 600; color: var(--soft); }
    .row { display: flex; align-items: center; gap: 12px; padding: 9px 0; }
    .row + .row { border-top: 1px solid rgba(255,255,255,.06); }
    .grow { flex: 1; min-width: 0; }
    .name { font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .sub { color: var(--soft); font-size: 13px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .mono { font: 12.5px/1.35 ui-monospace, Menlo, monospace; color: var(--soft); overflow-wrap: anywhere; margin-top: 4px; }
    .dot { width: 9px; height: 9px; border-radius: 50%; background: var(--faint); flex: none; }
    .dot.working { background: var(--fg); animation: pulse 1.6s ease-in-out infinite; }
    .dot.waiting { background: var(--accent); animation: pulse .9s ease-in-out infinite; }
    .dot.done { background: var(--ok); }
    @keyframes pulse { 50% { opacity: .35; transform: scale(.75); } }
    button { font: inherit; font-size: 14px; font-weight: 600; color: var(--fg); background: var(--fill); border: 0; border-radius: 999px;
      padding: 9px 16px; cursor: pointer; transition: transform .12s ease, opacity .12s ease; }
    button:active { transform: scale(.94); opacity: .7; }
    button.primary { background: #fff; color: #000; }
    button.round { width: 52px; height: 52px; padding: 0; font-size: 19px; display: inline-flex; align-items: center; justify-content: center; }
    button.big { width: 64px; height: 64px; font-size: 24px; }
    button.x { width: 34px; height: 34px; padding: 0; font-size: 15px; flex: none; }
    .buttons { display: flex; gap: 8px; flex-wrap: wrap; margin-top: 10px; }
    .request { background: rgba(217,119,87,.15); border-radius: 16px; padding: 12px 14px; margin-bottom: 8px; position: relative; }
    .request .buttons button { flex: 1; }
    .now { display: flex; gap: 14px; align-items: center; }
    #art { width: 72px; height: 72px; border-radius: 14px; object-fit: cover; background: var(--fill); flex: none; }
    .controls { display: flex; justify-content: center; align-items: center; gap: 20px; margin-top: 14px; }
    .left { font-variant-numeric: tabular-nums; font-weight: 600; flex: none; }
    input { font: inherit; color: var(--fg); background: var(--fill); border: 0; border-radius: 12px; padding: 10px 12px; min-width: 0; outline: none; }
    input::placeholder { color: var(--faint); }
    .add { display: flex; gap: 8px; margin-top: 10px; }
    .add .minutes { width: 72px; text-align: center; }
    .add .label { flex: 1; }
    .chips { display: flex; gap: 8px; margin-top: 10px; flex-wrap: wrap; }
    .chips button { padding: 7px 13px; font-size: 13px; }
    .empty { color: var(--faint); font-size: 14px; padding: 2px 0; }
    .ringing { background: rgba(255,255,255,.14); border-radius: 14px; padding: 10px 12px; display: flex; align-items: center; gap: 10px; margin-bottom: 8px; }
    #pair p { margin: 0 0 6px; color: var(--soft); }
    #code { font-size: 30px; letter-spacing: .32em; text-align: center; width: 100%; margin: 12px 0 8px; font-variant-numeric: tabular-nums; }
    .error { color: var(--accent); font-size: 14px; min-height: 1.3em; margin: 4px 0 8px; }
    footer { text-align: center; color: var(--faint); font-size: 11px; letter-spacing: .12em; margin-top: 22px; }
    footer em { font-style: normal; letter-spacing: 0; }
    .gone .quiet { color: var(--accent); }
    [hidden] { display: none !important; }

    /* Midnight Oyl: the sky, engraved rules, no boxes, Victorian type, everything drifting in. */
    body[data-look=midnight] { --bg: #04050a; --fg: #f2f5fa; --soft: rgba(196,202,216,.92); --faint: rgba(179,186,204,.55);
      --accent: #fff3dc; --ok: #c4ecd0; font-family: Georgia, "Hoefler Text", serif; font-size: 16px; }
    body[data-look=midnight] #sky { display: block; }
    body[data-look=midnight] main { padding-left: 24px; padding-right: 18px; }
    body[data-look=midnight] header { flex-direction: column; align-items: flex-start; gap: 3px; margin: 10px 0 20px; }
    body[data-look=midnight] h1 { font-family: Superclarendon, "Bodoni 72", Didot, serif; font-weight: 300; font-size: 31px; }
    body[data-look=midnight] .quiet { font-family: Superclarendon, Georgia, serif; font-style: italic; font-size: 14px; }
    body[data-look=midnight] section { background: none; border-radius: 0; padding: 18px 0 10px; margin: 0 0 4px; position: relative;
      transition: opacity .8s cubic-bezier(.2,.7,.2,1), filter .8s cubic-bezier(.2,.7,.2,1), transform .8s cubic-bezier(.2,.7,.2,1);
      transition-delay: calc(var(--order, 0) * 70ms); }
    body[data-look=midnight].arriving section { opacity: 0; filter: blur(3px); transform: translateX(-8px); transition: none; }
    body[data-look=midnight] section:nth-of-type(even) { margin-left: 9%; }
    body[data-look=midnight] section::before { content: ""; position: absolute; left: -24px; right: 22%; top: 0; height: 1px;
      background: linear-gradient(90deg, transparent, rgba(214,222,237,.38) 16%, rgba(214,222,237,.1) 72%, transparent); }
    body[data-look=midnight] section > h2 { font-family: Copperplate, "Bodoni 72 Smallcaps", serif; font-weight: 400; font-size: 12px;
      letter-spacing: .16em; text-transform: uppercase; }
    body[data-look=midnight] .row + .row { border-top: 0; }
    body[data-look=midnight] .name { font-weight: 400; }
    body[data-look=midnight] .sub { font-style: italic; }
    body[data-look=midnight] .mono { font-family: Courier, monospace; font-weight: 700; }
    body[data-look=midnight] .left, body[data-look=midnight] #code { font-family: "Bodoni 72", Didot, serif; font-weight: 400; font-size: 19px; }
    body[data-look=midnight] #code { font-size: 32px; }
    body[data-look=midnight] .dot { width: 7px; height: 7px; background: var(--faint); }
    body[data-look=midnight] .dot.working { background: var(--fg); animation: twinkle 2.2s ease-in-out infinite; }
    body[data-look=midnight] .dot.waiting { background: var(--accent); animation: twinkle .9s ease-in-out infinite; }
    body[data-look=midnight] button { background: none; border-radius: 0; padding: 9px 2px 7px; font-family: Copperplate, serif; font-weight: 400;
      font-size: 13px; letter-spacing: .14em; text-transform: uppercase; color: var(--soft);
      background-image: linear-gradient(90deg, transparent, rgba(214,222,237,.5), transparent); background-size: 100% 1px;
      background-position: 0 100%; background-repeat: no-repeat; }
    body[data-look=midnight] .buttons { gap: 22px; }
    body[data-look=midnight] .request .buttons button { flex: none; }
    body[data-look=midnight] button.primary { color: var(--fg); }
    body[data-look=midnight] button.primary::before { content: "\2726\00a0"; }
    body[data-look=midnight] button.round { border-radius: 50%; background: radial-gradient(circle, rgba(214,222,237,.11), transparent 68%);
      font-family: Didot, serif; letter-spacing: 0; text-transform: none; }
    body[data-look=midnight] button.x { background: none; letter-spacing: 0; }
    body[data-look=midnight] .request { background: none; border-radius: 0; padding: 4px 0 12px 18px; }
    body[data-look=midnight] .request::before { content: "\2726"; position: absolute; left: 0; top: 5px; color: var(--accent); font-size: 11px;
      animation: twinkle 1.1s ease-in-out infinite; }
    body[data-look=midnight] .ringing { background: none; padding: 4px 0 10px; }
    body[data-look=midnight] #art { border-radius: 50%; }
    body[data-look=midnight] #art.turning { animation: turn 40s linear infinite; }
    body[data-look=midnight] input { background: none; border-radius: 0; padding: 9px 2px;
      background-image: linear-gradient(90deg, rgba(214,222,237,.42), rgba(214,222,237,.08)); background-size: 100% 1px;
      background-position: 0 100%; background-repeat: no-repeat; }
    body[data-look=midnight] footer { font-family: Copperplate, serif; letter-spacing: .2em; margin-left: 9%; text-align: left; }
    body[data-look=midnight] footer em { font-family: Superclarendon, Georgia, serif; font-style: italic; text-transform: none; font-size: 13px; }
    @keyframes twinkle { 50% { opacity: .3; } }
    @keyframes turn { to { transform: rotate(360deg); } }
    @media (prefers-reduced-motion: reduce) { *, *::before { animation: none !important; transition: none !important; } }
    </style>
    </head>
    <body data-look="standard">
    <canvas id="sky" aria-hidden="true"></canvas>
    <main>
      <header><h1 id="mac">Oyl</h1><p class="quiet" id="link">Reaching the Mac…</p></header>
      <section id="pair" hidden>
        <h2>Pair this phone</h2>
        <p>Open the notch on the Mac, then Settings, then Oyl, and choose Pair a phone. Enter the code it shows.</p>
        <input id="code" inputmode="numeric" autocomplete="one-time-code" maxlength="7" placeholder="000000" aria-label="Code">
        <div class="error" id="pairError"></div>
        <button class="primary" id="pairButton">Pair</button>
      </section>
      <section id="requests" hidden><h2>Waiting for you</h2><div id="requestList"></div></section>
      <section id="agents" hidden><h2>Agents</h2><div id="agentList"></div></section>
      <section id="music" hidden>
        <h2>Playing</h2>
        <div class="now"><img id="art" alt="" hidden><div class="grow"><div class="name" id="song"></div><div class="sub" id="artist"></div></div></div>
        <div class="controls">
          <button class="round" data-do="previous" aria-label="Previous">&#x23EE;&#xFE0E;</button>
          <button class="round big" data-do="playPause" id="playPause" aria-label="Play or pause">&#x25B6;&#xFE0E;</button>
          <button class="round" data-do="next" aria-label="Next">&#x23ED;&#xFE0E;</button>
        </div>
      </section>
      <section id="timers" hidden>
        <h2>Timers</h2>
        <div id="ringing"></div>
        <div id="timerList"></div>
        <div class="chips" id="quick"></div>
        <div class="add">
          <input class="minutes" id="minutes" inputmode="decimal" placeholder="min" aria-label="Minutes">
          <input class="label" id="timerLabel" maxlength="60" placeholder="What for" aria-label="What for">
          <button class="primary" id="startTimer">Start</button>
        </div>
      </section>
      <section id="awake" hidden>
        <h2>Keep awake</h2>
        <div class="row"><div class="grow"><div class="name" id="awakeState"></div></div></div>
        <div class="buttons" id="awakeButtons"></div>
      </section>
      <footer>OYL &nbsp;<em id="motto">— Own your life</em></footer>
    </main>
    <script src="/app.js"></script>
    </body>
    </html>
    """#

    static let script = #"""
    "use strict";
    const $ = (id) => document.getElementById(id);
    let state = null, skew = 0, polling = null, reached = false;

    function el(tag, cls, text) {
      const e = document.createElement(tag);
      if (cls) e.className = cls;
      if (text != null) e.textContent = text;
      return e;
    }
    function button(text, cls, onTap) {
      const b = el("button", cls, text);
      b.addEventListener("click", onTap);
      return b;
    }
    function clock() { return Date.now() + skew; }
    function length(seconds) {
      seconds = Math.max(0, Math.round(seconds));
      const h = Math.floor(seconds / 3600), m = Math.floor(seconds % 3600 / 60), s = seconds % 60;
      return h ? h + ":" + String(m).padStart(2, "0") + ":" + String(s).padStart(2, "0") : m + ":" + String(s).padStart(2, "0");
    }
    function lately(since) {
      const minutes = Math.round((clock() / 1000 - since) / 60);
      return minutes < 1 ? "just now" : minutes < 60 ? "for " + minutes + " min" : "for " + Math.round(minutes / 60) + " h";
    }
    function at(time) { return new Date(time * 1000 - skew).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }); }

    async function load() {
      try {
        const response = await fetch("/api/state", { cache: "no-store", credentials: "same-origin" });
        if (response.status === 401) return unpaired();
        if (!response.ok) throw new Error(String(response.status));
        show(await response.json());
      } catch (error) {
        gone();
      }
    }
    function poll() {
      clearTimeout(polling);
      const wait = document.hidden ? 15000 : state && state.requests.length ? 1000 : 2000;
      polling = setTimeout(async () => { await load(); poll(); }, wait);
    }
    async function act(body) {
      try {
        const response = await fetch("/api/do", { method: "POST", credentials: "same-origin",
          headers: { "Content-Type": "application/json", "X-Oyl": "1" }, body: JSON.stringify(body) });
        if (response.status === 401) return unpaired();
        if (response.ok) show(await response.json()); else load();
      } catch (error) {
        gone();
      }
    }
    function gone() {
      document.body.classList.add("gone");
      $("link").textContent = reached ? "Can't reach the Mac just now" : "Can't reach the Mac: is it on this Wi-Fi?";
    }

    // MARK: Pairing
    function unpaired() {
      state = null;
      for (const part of ["requests", "agents", "music", "timers", "awake"]) $(part).hidden = true;
      $("pair").hidden = false;
      $("link").textContent = "Not paired yet";
      if (location.search.includes("unpaired")) $("pairError").textContent = "That code didn't work: ask the Mac for a new one.";
    }
    async function pair() {
      const code = $("code").value.replace(/\D/g, "");
      if (code.length !== 6) { $("pairError").textContent = "The code's six digits."; return; }
      $("pairError").textContent = "";
      try {
        const response = await fetch("/api/pair", { method: "POST", credentials: "same-origin",
          headers: { "Content-Type": "application/json", "X-Oyl": "1" }, body: JSON.stringify({ code }) });
        const answer = await response.json();
        if (!response.ok) { $("pairError").textContent = answer.error || "That didn't work."; return; }
        $("pair").hidden = true;
        history.replaceState(null, "", "/");
        load();
      } catch (error) {
        $("pairError").textContent = "Can't reach the Mac.";
      }
    }
    $("pairButton").addEventListener("click", pair);
    $("code").addEventListener("input", () => { if ($("code").value.replace(/\D/g, "").length === 6) pair(); });

    // MARK: Showing
    function show(next) {
      state = next;
      reached = true;
      skew = next.now * 1000 - Date.now();
      document.body.classList.remove("gone");
      // Into Midnight Oyl's look: each part drifts in, out of a blur, one after another. (Shown
      // plainly to begin with, so a browser that doesn't move them still shows them.)
      if (next.look === "midnight" && document.body.dataset.look !== "midnight") {
        document.querySelectorAll("section").forEach((part, order) => part.style.setProperty("--order", String(order)));
        document.body.classList.add("arriving");
        void document.body.offsetWidth;
        setTimeout(() => document.body.classList.remove("arriving"), 30);
      }
      document.body.dataset.look = next.look;
      document.querySelector("meta[name=theme-color]").content = next.look === "midnight" ? "#04050a" : "#000000";
      $("motto").textContent = next.look === "midnight" ? "· Own your life" : "— Own your life";
      $("pair").hidden = true;
      $("mac").textContent = next.mac;
      $("link").textContent = "Connected";
      document.title = next.requests.length ? "(" + next.requests.length + ") Oyl" : "Oyl";
      showRequests(next.requests);
      showAgents(next.agents);
      showMusic(next);
      showTimers(next);
      showAwake(next);
      tick();
      sky.look(next.look);
    }

    function showRequests(requests) {
      $("requests").hidden = requests.length === 0;
      const list = $("requestList");
      list.replaceChildren(...requests.map((request) => {
        const card = el("div", "request");
        card.append(el("div", "name", request.project + (request.host ? " · " + request.host : "")), el("div", "sub", request.action));
        if (request.detail) card.append(el("div", "mono", request.detail));
        const buttons = el("div", "buttons");
        buttons.append(button("Allow", "primary", () => act({ do: "allow", id: request.id })),
                       button("Deny", "", () => act({ do: "deny", id: request.id })));
        card.append(buttons);
        return card;
      }));
    }

    const order = { waiting: 0, working: 1, done: 2, idle: 3 };
    function showAgents(agents) {
      $("agents").hidden = false;
      const list = $("agentList");
      if (!agents.length) { list.replaceChildren(el("div", "empty", "No agents at work")); return; }
      const sorted = agents.slice().sort((a, b) => order[a.state] - order[b.state]);
      list.replaceChildren(...sorted.map((agent) => {
        const row = el("div", "row");
        const text = el("div", "grow");
        text.append(el("div", "name", agent.name), el("div", "sub", agent.doing + (agent.host ? " · " + agent.host : "") + " · " + lately(agent.since)));
        row.append(el("span", "dot " + agent.state), text);
        return row;
      }));
    }

    function showMusic(next) {
      const music = next.music;
      $("music").hidden = !next.pages.includes("music");
      $("song").textContent = music ? music.title : "Nothing playing";
      $("artist").textContent = music ? music.artist + " · " + music.player : "";
      $("playPause").textContent = music && music.playing ? "\u23F8\uFE0E" : "\u25B6\uFE0E";
      const art = $("art");
      art.hidden = !(music && music.art);
      if (music && music.art && art.dataset.art !== music.art) { art.dataset.art = music.art; art.src = "/api/art?v=" + encodeURIComponent(music.art); }
      art.classList.toggle("turning", !!(music && music.playing));
    }

    function showTimers(next) {
      $("timers").hidden = !next.pages.includes("timers");
      const ringing = $("ringing");
      if (next.ringing) {
        const row = el("div", "ringing");
        row.append(el("div", "grow name", next.ringing + " is done"), button("Stop", "primary", () => act({ do: "dismissRinging" })));
        ringing.replaceChildren(row);
      } else {
        ringing.replaceChildren();
      }
      const list = $("timerList");
      if (!next.timers.length && !next.ringing) { list.replaceChildren(el("div", "empty", "No timers")); return; }
      list.replaceChildren(...next.timers.map((timer) => {
        const row = el("div", "row");
        const text = el("div", "grow");
        text.append(el("div", "name", timer.title));
        const left = el("span", "left");
        if (timer.ends) left.dataset.ends = String(timer.ends);
        else left.textContent = timer.endless ? "" : length(timer.left || 0);
        row.append(text, left);
        if (!timer.endless) row.append(button(timer.ends ? "❙❙" : "▶︎", "x", () => act({ do: "pauseTimer", id: timer.id })));
        row.append(button("✕", "x", () => act({ do: "cancelTimer", id: timer.id })));
        return row;
      }));
    }
    for (const minutes of [5, 10, 25, 60]) {
      $("quick").append(button(minutes === 60 ? "1 hour" : minutes + " min", "", () => act({ do: "startTimer", minutes, label: $("timerLabel").value.trim() })));
    }
    $("startTimer").addEventListener("click", () => {
      const minutes = parseFloat($("minutes").value.replace(",", "."));
      if (!(minutes > 0)) { $("minutes").focus(); return; }
      act({ do: "startTimer", minutes, label: $("timerLabel").value.trim() });
      $("minutes").value = ""; $("timerLabel").value = "";
    });

    function showAwake(next) {
      $("awake").hidden = !next.pages.includes("awake");
      const awake = next.awake;
      $("awakeState").textContent = !awake.on ? "Sleeping as usual" : awake.until ? "Awake till " + at(awake.until)
        : awake.app ? "Awake while " + awake.app + " runs" : "Awake till you stop it";
      const buttons = [button("2 hours", "", () => act({ do: "awake", hours: 2 })), button("Till I stop it", "", () => act({ do: "awake" }))];
      if (awake.on) buttons.push(button("Let it sleep", "primary", () => act({ do: "sleep" })));
      $("awakeButtons").replaceChildren(...buttons);
    }

    function tick() {
      for (const left of document.querySelectorAll("[data-ends]")) left.textContent = length(Number(left.dataset.ends) - clock() / 1000);
    }
    setInterval(tick, 1000);
    for (const control of document.querySelectorAll("[data-do]")) control.addEventListener("click", () => act({ do: control.dataset.do }));
    document.addEventListener("visibilitychange", () => { if (!document.hidden) { load(); poll(); } });

    // MARK: Midnight's sky: stars turning slowly round a pole off to the upper left, a few engraved
    // rings round it, the odd shooting star. Only drawn in Midnight Oyl's look.
    const sky = (() => {
      const canvas = $("sky"), pen = canvas.getContext("2d");
      const still = matchMedia("(prefers-reduced-motion: reduce)").matches;
      let width = 0, height = 0, on = false, frame = 0, shooting = null, last = 0;
      const stars = Array.from({ length: 170 }, (_, i) => ({ reach: Math.sqrt(Math.random()) * 1.5, turn: Math.random() * Math.PI * 2,
        size: Math.random() < .08 ? 1.5 : Math.random() * .8 + .35, phase: Math.random() * 7, rate: .6 + Math.random() * 1.6 }));
      function fit() {
        const scale = devicePixelRatio || 1;
        width = innerWidth; height = innerHeight;
        canvas.width = width * scale; canvas.height = height * scale;
        pen.setTransform(scale, 0, 0, scale, 0, 0);
      }
      function draw(now) {
        if (!on) return;
        frame = requestAnimationFrame(draw);
        if (now - last < 33) return;
        last = now;
        const t = now / 1000, pole = { x: width * .2, y: -height * .06 }, span = Math.hypot(width, height);
        pen.clearRect(0, 0, width, height);
        pen.strokeStyle = "rgba(214,222,237,.07)";
        pen.lineWidth = .6;
        for (const ring of [.32, .58, .86]) {
          pen.beginPath();
          pen.arc(pole.x, pole.y, span * ring, 0, Math.PI * 2);
          pen.stroke();
        }
        pen.save();
        pen.translate(pole.x, pole.y);
        pen.rotate(t * .012);
        pen.strokeStyle = "rgba(214,222,237,.1)";
        for (let i = 0; i < 72; i++) {
          const a = i / 72 * Math.PI * 2, r = span * .58, tick = i % 6 ? 4 : 9;
          pen.beginPath();
          pen.moveTo(Math.cos(a) * r, Math.sin(a) * r);
          pen.lineTo(Math.cos(a) * (r + tick), Math.sin(a) * (r + tick));
          pen.stroke();
        }
        pen.restore();
        for (const star of stars) {
          const a = star.turn + t * .006, r = star.reach * span;
          const x = pole.x + Math.cos(a) * r, y = pole.y + Math.sin(a) * r;
          if (x < -2 || y < -2 || x > width + 2 || y > height + 2) continue;
          pen.globalAlpha = .28 + .42 * (.5 + .5 * Math.sin(t * star.rate + star.phase));
          pen.fillStyle = "#f2f5fa";
          pen.beginPath();
          pen.arc(x, y, star.size, 0, Math.PI * 2);
          pen.fill();
        }
        pen.globalAlpha = 1;
        if (!shooting && Math.random() < .004) shooting = { x: Math.random() * width, y: Math.random() * height * .5, born: t };
        if (shooting) {
          const age = t - shooting.born, run = age * 520;
          if (age > .9) { shooting = null; } else {
            const fade = Math.sin(age / .9 * Math.PI), line = pen.createLinearGradient(shooting.x + run, shooting.y + run * .42,
              shooting.x + run - 90, shooting.y + run * .42 - 38);
            line.addColorStop(0, "rgba(242,245,250," + .7 * fade + ")");
            line.addColorStop(1, "rgba(242,245,250,0)");
            pen.strokeStyle = line;
            pen.lineWidth = 1;
            pen.beginPath();
            pen.moveTo(shooting.x + run, shooting.y + run * .42);
            pen.lineTo(shooting.x + run - 90, shooting.y + run * .42 - 38);
            pen.stroke();
          }
        }
        if (still) { on = false; cancelAnimationFrame(frame); }
      }
      addEventListener("resize", fit);
      return {
        look(look) {
          const want = look === "midnight";
          if (want === on) return;
          on = want;
          if (on) { fit(); last = 0; frame = requestAnimationFrame(draw); } else { cancelAnimationFrame(frame); pen.clearRect(0, 0, width, height); }
        },
      };
    })();

    load().then(poll);
    """#

    static let manifest = #"""
    {"name": "Oyl", "short_name": "Oyl", "start_url": "/", "display": "standalone", "background_color": "#000000",
     "theme_color": "#000000", "icons": [{"src": "/icon.png", "sizes": "180x180", "type": "image/png"}]}
    """#

    /// Oyl's icon, for the phone's home screen.
    @MainActor static let icon: Data = {
        let side = 180
        let image = NSApp?.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return Data() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:]) ?? Data()
    }()
}
