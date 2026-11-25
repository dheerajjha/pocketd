import Foundation

/// A full chat client, served by the phone to any browser on the network.
///
/// The alternative was telling people to install Open WebUI, which means Docker,
/// which on a Mac cannot reach a phone on the host network without extra flags.
/// A server that can hand out a UI should hand out a UI: open the phone's
/// address on a laptop and it is a chat app, with nothing installed and nothing
/// configured.
enum ChatPage {
    static let html = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Pocketd</title>
    <style>
      :root {
        color-scheme: light dark;
        --bg:#fff; --fg:#1d1d1f; --dim:#86868b; --line:#e5e5ea;
        --user:#0071e3; --panel:#f5f5f7; --accent:#0071e3;
      }
      @media (prefers-color-scheme: dark) {
        :root { --bg:#000; --fg:#f5f5f7; --dim:#8e8e93; --line:#2c2c2e;
                --user:#0a84ff; --panel:#1c1c1e; --accent:#0a84ff; }
      }
      * { box-sizing:border-box; }
      html, body { height:100%; }
      body { margin:0; background:var(--bg); color:var(--fg); display:flex; flex-direction:column;
             font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif; }
      header { display:flex; align-items:center; gap:12px; padding:12px 20px;
               border-bottom:1px solid var(--line); flex:0 0 auto; }
      header b { font-size:15px; letter-spacing:-.01em; }
      header .sp { flex:1; }
      select, button { font:inherit; font-size:14px; color:var(--fg); background:var(--panel);
                       border:1px solid var(--line); border-radius:8px; padding:7px 11px; cursor:pointer; }
      button.primary { background:var(--accent); color:#fff; border-color:var(--accent); }
      button:disabled { opacity:.4; cursor:default; }
      #log { flex:1 1 auto; overflow-y:auto; padding:28px 20px; }
      .wrap { max-width:760px; margin:0 auto; }
      .msg { margin-bottom:22px; display:flex; }
      .msg.u { justify-content:flex-end; }
      /* The column has to be a flex item with a max, or the bubble shrink-wraps
         to its longest unbreakable word and wraps at ~250px in a 760px page. */
      .col { max-width:82%; min-width:0; }
      .msg.u .col { display:flex; flex-direction:column; align-items:flex-end; }
      .bubble { padding:11px 15px; border-radius:16px; white-space:pre-wrap;
                overflow-wrap:anywhere; display:inline-block; text-align:left; }
      .u .bubble { background:var(--user); color:#fff; border-bottom-right-radius:5px; }
      .a .bubble { background:var(--panel); border-bottom-left-radius:5px; }
      .a .bubble code, .a .bubble pre { font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:13px; }
      .a .bubble pre { background:var(--bg); border:1px solid var(--line); border-radius:9px;
                       padding:12px; overflow-x:auto; }
      .meta { font-size:12px; color:var(--dim); margin-top:6px; }
      footer { flex:0 0 auto; border-top:1px solid var(--line); padding:14px 20px; }
      .composer { max-width:760px; margin:0 auto; display:flex; gap:10px; align-items:flex-end; }
      textarea { flex:1; resize:none; font:inherit; padding:11px 14px; border-radius:12px;
                 border:1px solid var(--line); background:var(--panel); color:var(--fg);
                 max-height:180px; min-height:46px; }
      textarea:focus { outline:2px solid var(--accent); outline-offset:-1px; }
      .empty { text-align:center; color:var(--dim); margin-top:18vh; }
      .thumbs { display:flex; gap:8px; flex-wrap:wrap; margin-bottom:8px; }
      .thumb { position:relative; width:60px; height:60px; border-radius:9px; overflow:hidden;
               border:1px solid var(--line); }
      .thumb img { width:100%; height:100%; object-fit:cover; display:block; }
      .thumb button { position:absolute; top:1px; right:1px; width:19px; height:19px; padding:0;
                      border-radius:50%; background:rgba(0,0,0,.65); color:#fff; font-size:12px;
                      line-height:19px; border:0; }
      .bubble img { max-width:220px; border-radius:10px; display:block; margin-bottom:8px; }
      #attach.on { background:var(--accent); color:#fff; border-color:var(--accent); }
      .empty h2 { color:var(--fg); font-weight:600; margin:0 0 6px; letter-spacing:-.02em; }
      dialog { border:1px solid var(--line); border-radius:14px; background:var(--bg); color:var(--fg);
               padding:26px; max-width:400px; }
      dialog::backdrop { background:rgba(0,0,0,.5); }
      dialog input { width:100%; font:600 30px/1.2 ui-monospace,Menlo,monospace; letter-spacing:.25em;
                     text-align:center; padding:12px; border-radius:10px; border:1px solid var(--line);
                     background:var(--panel); color:var(--fg); margin:14px 0; }
      .err { color:#c1121f; min-height:1.3em; font-size:14px; }
      .dot { width:8px; height:8px; border-radius:50%; background:#30d158; display:inline-block; }
      .budget { font-size:12px; color:var(--dim); font-variant-numeric:tabular-nums; }
      .budget.warn { color:#ff9f0a; }
      .budget.over { color:#ff453a; font-weight:600; }
      .err-frame { color:#ff453a; font-size:14px; }
    </style>
    </head>
    <body>

    <header>
      <span class="dot" id="dot" role="img" aria-label="Connection status" title="Connection status"></span>
      <span id="dotText" class="budget" style="min-width:0"></span>
      <b>Pocketd</b>
      <select id="models" title="Model"></select>
      <span class="sp"></span>
      <span id="budget" class="budget" title="Estimated prompt size against the server's context limit"></span>
      <button id="connect" style="display:none" title="Pair with the phone again">Connect</button>
      <button id="sys" title="System prompt">System</button>
      <button id="clear">New chat</button>
    </header>

    <div id="log"><div class="wrap" id="wrap">
      <div class="empty" id="empty">
        <h2>Your phone is the server</h2>
        <div>Keep Pocketd open on your iPhone while you chat.</div>
      </div>
    </div></div>

    <footer>
    <div class="composer" style="display:block"><div class="thumbs" id="thumbs"></div></div>
    <div class="composer">
      <input type="file" id="file" accept="image/*" multiple hidden>
      <button id="attach" title="Attach an image">Image</button>
      <textarea id="input" rows="1" placeholder="Message…" autofocus></textarea>
      <button class="primary" id="send">Send</button>
      <button id="stop" style="display:none">Stop</button>
    </div></footer>

    <dialog id="pair">
      <h3 style="margin:0 0 4px">Connect to your phone</h3>
      <div style="color:var(--dim);font-size:14px">Enter the six digits Pocketd shows on your phone, under You › Use from your laptop.</div>
      <input id="code" inputmode="numeric" maxlength="6" placeholder="000000">
      <div class="err" id="perr"></div>
      <div class="row" style="margin-top:0">
        <button class="primary" id="pgo" style="flex:1">Connect</button>
        <button id="pcancel">Cancel</button>
      </div>
      <div style="color:var(--dim);font-size:13px;margin-top:14px">
        No code on the phone? In Pocketd, open You › Use from your laptop and
        tap <b>New code</b>.
      </div>
    </dialog>

    <script>
    const $ = (id) => document.getElementById(id);
    const KEY = "pocketd.key";
    let apiKey = localStorage.getItem(KEY) || null;
    let messages = [];
    let system = localStorage.getItem("pocketd.system") || "";
    let maxTokens = parseInt(localStorage.getItem("pocketd.maxTokens") || "512", 10);
    let contextLimit = 4096;
    let active = null;        // exactly one browser submission, including an explicit retry
    let attachments = [];     // data: URIs staged for the next message
    let visionModels = new Set();

    function setStatus(text) {
      $("dotText").textContent = text;
      $("dot").setAttribute("aria-label", "Connection status: " + (text || "connected"));
      $("dot").title = text || "Connected";
    }

    function headers() {
      const h = { "Content-Type": "application/json" };
      if (apiKey) h["Authorization"] = "Bearer " + apiKey;
      return h;
    }

    // --- pairing -------------------------------------------------------------
    async function ensureKey() {
      let probe;
      try { probe = await fetch("/v1/models", { headers: headers() }); }
      catch (_) { $("dot").style.background = "#ff453a"; setStatus("phone unreachable"); return; }
      if (probe.ok) { await loadModels(probe); return; }
      // A stored key that no longer works — the phone's key was regenerated —
      // is indistinguishable from having none, so drop it and re-pair.
      if (probe.status === 401) { apiKey = null; localStorage.removeItem(KEY); $("pair").showModal(); }
    }

    $("pgo").onclick = async () => {
      const code = $("code").value.trim();
      $("perr").textContent = "";
      if (!/^\d{6}$/.test(code)) { $("perr").textContent = "Six digits."; return; }
      const r = await fetch("/pair", {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ code }),
      });
      const b = await r.json();
      if (!r.ok) { $("perr").textContent = b.error ? b.error.message : "Failed."; return; }
      apiKey = b.apiKey;
      if (apiKey) localStorage.setItem(KEY, apiKey);
      $("pair").close();
      $("connect").style.display = "none";
      loadModels();
    };

    // Escape closes a <dialog>, and without a way back the page became a dead
    // end: no control anywhere reopened it, every message failed with an auth
    // error, and only someone who thought to reload the page recovered.
    $("pair").addEventListener("close", () => {
      if (!apiKey) $("connect").style.display = "";
    });
    $("pcancel").onclick = () => $("pair").close();
    $("connect").onclick = () => { $("perr").textContent = ""; $("pair").showModal(); };
    $("code").addEventListener("keydown", (e) => { if (e.key === "Enter") $("pgo").click(); });

    // --- models --------------------------------------------------------------
    async function loadModels(pre) {
      try {
        const r = pre || await fetch("/v1/models", { headers: headers() });
        const b = await r.json();
        $("models").innerHTML = "";
        visionModels = new Set();
        (b.data || []).forEach((m) => {
          const o = document.createElement("option");
          const sees = (m.capabilities || []).indexOf("vision") >= 0;
          if (sees) visionModels.add(m.id);
          o.value = m.id;
          o.textContent = sees ? m.id + " \u25c9" : m.id;
          $("models").appendChild(o);
        });
        updateAttachButton();
        if (!b.data || !b.data.length) {
          $("models").innerHTML = "<option>no model loaded</option>";
        }
      } catch (e) { $("dot").style.background = "#ff453a"; }
    }

    // --- rendering -----------------------------------------------------------
    function escapeHTML(s) {
      return s.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));
    }
    // Just enough markdown to make code readable; escapes first, so model
    // output can never inject markup.
    function render(text) {
      let h = escapeHTML(text);
      h = h.replace(/```([\s\S]*?)```/g, (_, c) => "<pre>" + c.replace(/^\w*\n/, "") + "</pre>");
      h = h.replace(/`([^`\n]+)`/g, "<code>$1</code>");
      h = h.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
      return h;
    }

    function bubbleFor(m) {
      const wrap = document.createElement("div");
      wrap.className = "msg " + (m.role === "user" ? "u" : "a");
      const col = document.createElement("div");
      col.className = "col";
      const b = document.createElement("div");
      b.className = "bubble";
      for (const src of (m.images || [])) {
        const img = document.createElement("img");
        img.src = src;
        b.appendChild(img);
      }
      if (m.role === "user") {
        b.appendChild(document.createTextNode(m.content));
      } else {
        const span = document.createElement("span");
        span.innerHTML = render(m.content);
        b.appendChild(span);
      }
      col.appendChild(b);
      if (m.error) {
        const err = document.createElement("div");
        err.className = "err-frame";
        err.textContent = "\u26A0\uFE0E " + m.error;
        col.appendChild(err);
      }
      if (m.meta) {
        const meta = document.createElement("div");
        meta.className = "meta";
        meta.textContent = m.meta;
        col.appendChild(meta);
      }
      if (m.role === "assistant" && canRetry(m) && m === messages[messages.length-1] && !active) {
        const user = messages[messages.length-2];
        if (user && user.role === "user") {
          if (contextRows(messages.slice(0, -1)).some(row => row.imagesOmitted)) {
            const note = document.createElement("div");
            note.className = "meta";
            note.textContent = "The original images weren’t saved. Reattach them to send this question again.";
            col.appendChild(note);
          } else {
            const retry = document.createElement("button");
            retry.textContent = "Retry";
            retry.onclick = () => { if (!active && messages[messages.length-1] === m && canRetry(m)) generate(m); };
            col.appendChild(retry);
          }
        }
      }
      wrap.appendChild(col);
      return { wrap, bubble: b, col };
    }

    // Rebuilds everything. Used on load and on structural changes only — never
    // per token, which would destroy the user's selection sixty times a second.
    function draw() {
      $("wrap").innerHTML = "";
      if (!messages.length) {
        const e = document.createElement("div");
        e.className = "empty";
        e.innerHTML = "<h2>Your phone is the server</h2><div>Keep Pocketd open on your iPhone while you chat.</div>";
        $("wrap").appendChild(e);
      }
      for (const m of messages) $("wrap").appendChild(bubbleFor(m).wrap);
      scrollToBottom(true);
      updateBudget();
    }

    // Only follow the stream if the reader is already at the bottom. Forcing it
    // makes scrolling back through a long reply impossible while it generates.
    function nearBottom() {
      const el = $("log");
      return el.scrollHeight - el.scrollTop - el.clientHeight < 120;
    }
    function scrollToBottom(force) {
      if (force || nearBottom()) $("log").scrollTop = $("log").scrollHeight;
    }

    function paint(run) {
      run.raf = 0;
      if (active !== run) return;
      const stick = nearBottom();
      run.bubble.innerHTML = render(run.reply.content);
      if (stick) $("log").scrollTop = $("log").scrollHeight;
    }

    const interrupted = "Reply interrupted. Reopen Pocketd on your iPhone, then retry.";
    function canRetry(m) { return ["interrupted", "cancelled", "error"].includes(m.state); }
    function usable(m) {
      // Old transcripts predate finish reasons. Preserve their ordinary replies,
      // but never send known errors, deliberate stops, or interrupted prefixes.
      return m.content && !m.error && (m.state === "complete" || m.state === "length" || (!m.state && m.meta !== "stopped"));
    }
    function contextRows(rows) {
      return rows.filter((m, i) => m.role === "assistant" ? usable(m) :
        m.role === "user" && (rows[i+1]?.role !== "assistant" || usable(rows[i+1])));
    }

    // --- context budget ------------------------------------------------------
    // Mirrors ContextGuard on the server: 3 characters per token, 4 tokens per
    // message, and a reserve for the answer. Better to show the wall coming
    // than to hand someone a 413 they cannot explain.
    function estimateTokens() {
      let chars = system.length;
      let count = system ? 1 : 0;
      for (const m of contextRows(active ? messages.slice(0, -1) : messages)) { chars += m.content.length; count++; }
      return Math.ceil(chars / 3) + count * 4;
    }
    function updateBudget() {
      const used = estimateTokens();
      const budget = Math.max(1, contextLimit - Math.min(64, Math.max(1, Math.floor(contextLimit / 4))));
      const pct = used / budget;
      const el = $("budget");
      el.textContent = `${used} / ${budget}`;
      el.className = "budget" + (pct > 1 ? " over" : pct > 0.75 ? " warn" : "");
      el.title = pct > 1
        ? "This conversation is past the server's context window. Start a new chat, or raise the limit in Settings on the phone."
        : "Estimated prompt size against the server's context limit";
    }

    // --- sending -------------------------------------------------------------
    function send() {
      const text = $("input").value.trim();
      if (!text || active) return;
      $("input").value = "";
      $("input").style.height = "auto";

      const staged = attachments.slice();
      attachments = [];
      drawThumbs();
      // Only the latest turn is retryable; never fork under newer replies.
      if (messages.length) delete messages[messages.length-1].options;
      messages.push({ role: "user", content: text, images: staged });
      const reply = { role: "assistant", content: "", options: { model: $("models").value, system, maxTokens } };
      messages.push(reply);
      generate(reply);
    }

    async function generate(reply) {
      if (active) return;
      const run = { reply, controller: new AbortController(), chunks: 0, bytes: 0, misses: 0,
                    stopped: false, finish: null, error: null, invalid: false, raf: 0, checkpoint: 0 };
      active = run;
      reply.state = "streaming";
      delete reply.error;
      reply.meta = reply.content ? "Retrying…" : "";
      save();  // persist the question before fetching, even if no first token ever arrives
      draw();
      run.bubble = $("wrap").lastElementChild.querySelector(".bubble span");

      $("send").style.display = "none";
      $("stop").style.display = "";
      const options = reply.options || { model: $("models").value, system, maxTokens };
      const body = {
        model: options.model,
        messages: [],
        stream: true,
        max_tokens: options.maxTokens,
      };
      if (options.system) body.messages.push({ role: "system", content: options.system });
      for (const m of contextRows(messages.slice(0, -1))) {
        if (m.images && m.images.length) {
          // The /v1 dialect's typed content parts. The /api dialect's shape
          // is a flat images[] array instead; the server accepts both, and
          // this page speaks /v1.
          const parts = [{ type: "text", text: m.content }];
          for (const src of m.images) parts.push({ type: "image_url", image_url: { url: src } });
          body.messages.push({ role: m.role, content: parts });
        } else {
          // Only content. An error row is ours, not the model's.
          body.messages.push({ role: m.role, content: m.content });
        }
      }

      const started = performance.now();
      try {
        const r = await fetch("/v1/chat/completions", {
          method: "POST", headers: headers(), body: JSON.stringify(body),
          mode: "same-origin", redirect: "error", signal: run.controller.signal,
        });
        if (!r.ok) {
          run.error = "HTTP " + r.status;
          try { const e = await r.json(); if (typeof e.error?.message === "string" && e.error.message) run.error = e.error.message; } catch (_) {}
          if (r.status === 401 && active === run) {
            // Almost always the phone's key was regenerated. Say so and put
            // the way back on screen rather than leaving a bare error.
            apiKey = null;
            localStorage.removeItem(KEY);
            run.error = "This phone's API key changed. Tap Connect to pair again.";
            $("connect").style.display = "";
          }
        } else {
          await receive(r.body, run);
        }
      } catch (_) {
        // A dropped connection and an aborted read both throw. Only the Stop
        // control sets run.stopped; neither a socket error nor EOF proves success.
      } finally {
        cancelAnimationFrame(run.raf);
        clearTimeout(run.checkpoint);
        if (active === run) {
          active = null;
          $("send").style.display = "";
          $("stop").style.display = "none";
          // [DONE] also follows server errors. The engine's finish reason is
          // authoritative, even if the connection drops after that complete frame.
          if (run.error) reply.state = "error";
          else if (run.stopped) reply.state = "stopped";
          else if (run.finish === "cancelled") reply.state = "cancelled";
          else if (!run.invalid && run.finish === "stop") reply.state = "complete";
          else if (!run.invalid && run.finish === "length") reply.state = "length";
          else reply.state = "interrupted";
          const secs = Math.max(0.001, (performance.now()-started)/1000);
          if (reply.state === "error") { reply.error = run.error; reply.meta = ""; }
          if (reply.state === "stopped") reply.meta = "Stopped by you.";
          if (reply.state === "cancelled") reply.meta = "Pocketd cancelled this reply.";
          if (reply.state === "interrupted") reply.meta = interrupted;
          if (reply.state === "complete" || reply.state === "length") {
            if (!run.chunks) reply.content = ""; // a successful empty retry cannot certify an older prefix
            reply.meta = reply.state === "length" ? "Response limit reached." : run.chunks
              ? `${run.chunks} chunks · ${(run.chunks / secs).toFixed(1)}/s · ${secs.toFixed(1)}s` : "Finished without text.";
          }
          if (!canRetry(reply)) delete reply.options;
          save(); draw();
        }
      }
    }

    async function receive(body, run) {
      const reader = body.getReader(), decoder = new TextDecoder();
      let buffer = "", data = [];
      try {
        while (active === run && !run.controller.signal.aborted) {
          const {done, value} = await reader.read();
          if (done || active !== run || run.controller.signal.aborted) return;
          run.bytes += value.length; run.misses = 0;
          buffer += decoder.decode(value, {stream:true});
          let nl;
          while ((nl = buffer.indexOf("\n")) >= 0) {
            const line = buffer.slice(0,nl).replace(/\r$/, "");
            buffer = buffer.slice(nl+1);
            if (line.startsWith("data:")) data.push(line.slice(5).replace(/^ /, ""));
            if (line !== "" || !data.length) continue;
            const payload = data.join("\n"); data = [];
            if (payload === "[DONE]") return;
            let frame;
            try { frame = JSON.parse(payload); } catch (_) { run.invalid = true; continue; }
            if (frame?.error) { run.error = typeof frame.error.message === "string" && frame.error.message || "Server error"; continue; }
            const choice = frame?.choices?.[0];
            if (!choice || run.error) continue; // optional usage-only frame
            const text = choice.delta?.content;
            if (typeof text === "string" && text.length) {
              // On a retry retain the previous partial until replacement text arrives.
              run.reply.content = (run.chunks ? run.reply.content : "") + text;
              run.chunks++;
              if (!run.raf) run.raf = requestAnimationFrame(() => paint(run));
              if (run.chunks === 1) save();
              else if (!run.checkpoint) run.checkpoint = setTimeout(() => { run.checkpoint = 0; if (active === run) save(); }, 1000);
            }
            if (choice.finish_reason != null) run.finish = choice.finish_reason;
          }
        }
      } finally { reader.releaseLock(); }
    }

    function save() {
      // Data URIs are large and localStorage is a few megabytes, so a chat
      // with images overflows far sooner than one without. Drop the images
      // from history rather than losing the conversation.
      try {
        localStorage.setItem("pocketd.chat", JSON.stringify(messages.slice(-40)));
      } catch (e) {
        try {
          localStorage.setItem("pocketd.chat", JSON.stringify(
            messages.slice(-40).map(({images, ...m}) => images?.length ? {...m, imagesOmitted:true} : m)
          ));
        } catch (_) {}
      }
    }

    // The attach button is only offered for a model that can actually see.
    // Letting someone pick an image for a text model produces a 500 from the
    // engine, which is a worse way to learn the model has no eyes.
    function updateAttachButton() {
      const sees = visionModels.has($("models").value);
      $("attach").disabled = !sees;
      $("attach").title = sees
        ? "Attach an image"
        : "This model cannot see images. Pick one marked \u25c9.";
      if (!sees && attachments.length) { attachments = []; drawThumbs(); }
    }
    $("models").addEventListener("change", updateAttachButton);

    function drawThumbs() {
      $("thumbs").innerHTML = "";
      attachments.forEach((src, i) => {
        const d = document.createElement("div");
        d.className = "thumb";
        const img = document.createElement("img");
        img.src = src;
        const x = document.createElement("button");
        x.textContent = "\u00d7";
        x.onclick = () => { attachments.splice(i, 1); drawThumbs(); };
        d.appendChild(img); d.appendChild(x);
        $("thumbs").appendChild(d);
      });
      $("attach").className = attachments.length ? "on" : "";
    }

    $("attach").onclick = () => $("file").click();
    $("file").onchange = () => {
      for (const f of $("file").files) {
        const reader = new FileReader();
        reader.onload = () => { attachments.push(reader.result); drawThumbs(); };
        reader.readAsDataURL(f);
      }
      $("file").value = "";
    };

    $("send").onclick = send;
    $("stop").onclick = () => {
      if (!active) return;
      active.stopped = true;
      active.reply.state = "stopped"; active.reply.meta = "Stopped by you.";
      save(); active.controller.abort();
    };
    $("clear").onclick = () => {
      if (active) { active.controller.abort(); active = null; }
      $("send").style.display = ""; $("stop").style.display = "none";
      messages = []; save(); draw();
    };
    $("sys").onclick = () => {
      const v = prompt("System prompt (blank for none):", system);
      if (v !== null) { system = v; localStorage.setItem("pocketd.system", v); updateBudget(); }
    };
    $("input").addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); send(); }
    });
    $("input").addEventListener("input", function () {
      this.style.height = "auto";
      this.style.height = Math.min(this.scrollHeight, 180) + "px";
    });

    try { messages = JSON.parse(localStorage.getItem("pocketd.chat") || "[]"); } catch (e) {}
    if (!Array.isArray(messages)) messages = [];
    if (messages.some(m => m.state === "streaming")) {
      for (const m of messages) {
        if (m.state === "streaming") { m.state = "interrupted"; m.meta = interrupted; }
      }
      save();
    }
    window.addEventListener("pagehide", () => { if (active) save(); });
    document.addEventListener("visibilitychange", () => { if (document.hidden && active) save(); });
    draw();
    ensureKey();
    let probing = false;
    async function checkHealth() {
      if (probing) return;
      probing = true;
      const run = active, bytes = run?.bytes, probe = new AbortController();
      const deadline = setTimeout(() => probe.abort(), 6000);
      try {
        const h = await (await fetch("/health", {signal:probe.signal, cache:"no-store"})).json();
        if (run) run.misses = 0;
        const up = h.status === "ok";
        $("dot").style.background = up ? "#30d158" : "#ff9f0a";
        setStatus(up ? "" : "degraded");
        if (h.maxContextTokens) { contextLimit = h.maxContextTokens; updateBudget(); }
      } catch (e) {
        $("dot").style.background = "#ff453a";
        // Colour alone told a sighted user nothing specific and a screen
        // reader nothing at all.
        setStatus("phone unreachable");
        // A suspended phone can leave TCP open. Two failed probes without
        // stream progress release the composer. Slow but reachable inference
        // has no token deadline, and reconnecting never posts a question.
        if (run && active === run && run.bytes === bytes && ++run.misses >= 2) run.controller.abort();
      } finally { clearTimeout(deadline); probing = false; }
    }
    setInterval(checkHealth, 5000);
    </script>
    </body></html>
    """#
}
