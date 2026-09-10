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
        <div>Everything you type here is answered on the device in your pocket.</div>
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
      <div style="color:var(--dim);font-size:14px">Enter the six digits shown on the Pocketd Server tab.</div>
      <input id="code" inputmode="numeric" maxlength="6" placeholder="000000">
      <div class="err" id="perr"></div>
      <div class="row" style="margin-top:0">
        <button class="primary" id="pgo" style="flex:1">Connect</button>
        <button id="pcancel">Cancel</button>
      </div>
      <div style="color:var(--dim);font-size:13px;margin-top:14px">
        No code on the phone? Open Pocketd, go to the Server tab, and tap
        <b>New code</b>.
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
    let controller = null;
    let attachments = [];     // data: URIs staged for the next message
    let visionModels = new Set();
    let live = null;          // the assistant bubble currently streaming into
    let pending = "";         // text not yet flushed to the DOM
    let raf = 0;

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
      const probe = await fetch("/v1/models", { headers: headers() });
      if (probe.ok) { await loadModels(probe); return; }
      // A stored key that no longer works — the phone's key was regenerated —
      // is indistinguishable from having none, so drop it and re-pair.
      if (probe.status === 401) { apiKey = null; localStorage.removeItem(KEY); }
      $("pair").showModal();
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
        e.innerHTML = "<h2>Your phone is the server</h2><div>Everything you type here is answered on the device in your pocket.</div>";
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

    function flush() {
      raf = 0;
      if (!live || !pending) return;
      const stick = nearBottom();
      messages[messages.length - 1].content += pending;
      pending = "";
      live.innerHTML = render(messages[messages.length - 1].content);
      if (stick) $("log").scrollTop = $("log").scrollHeight;
    }
    function schedule() { if (!raf) raf = requestAnimationFrame(flush); }

    // --- context budget ------------------------------------------------------
    // Mirrors ContextGuard on the server: 3 characters per token, 4 tokens per
    // message, and a reserve for the answer. Better to show the wall coming
    // than to hand someone a 413 they cannot explain.
    function estimateTokens() {
      let chars = system.length;
      let count = system ? 1 : 0;
      for (const m of messages) { chars += m.content.length; count++; }
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
    async function send() {
      const text = $("input").value.trim();
      if (!text || controller) return;
      $("input").value = "";
      $("input").style.height = "auto";

      const staged = attachments.slice();
      attachments = [];
      drawThumbs();
      messages.push({ role: "user", content: text, images: staged });
      messages.push({ role: "assistant", content: "" });
      draw();
      live = $("wrap").lastElementChild.querySelector(".bubble span");
      pending = "";

      $("send").style.display = "none";
      $("stop").style.display = "";
      controller = new AbortController();

      const body = {
        model: $("models").value,
        messages: [],
        stream: true,
        max_tokens: maxTokens,
      };
      if (system) body.messages.push({ role: "system", content: system });
      for (const m of messages.slice(0, -1)) {
        // A turn that failed before producing anything is not context.
        if (m.role === "assistant" && !m.content) continue;
        if (m.images && m.images.length) {
          // OpenAI's typed content parts. Ollama's shape is a flat images[]
          // array instead; the server accepts both, this page speaks OpenAI.
          const parts = [{ type: "text", text: m.content }];
          for (const src of m.images) parts.push({ type: "image_url", image_url: { url: src } });
          body.messages.push({ role: m.role, content: parts });
        } else {
          // Only content. An error row is ours, not the model's.
          body.messages.push({ role: m.role, content: m.content });
        }
      }

      const started = performance.now();
      let chunks = 0;
      let failed = null;

      try {
        const r = await fetch("/v1/chat/completions", {
          method: "POST", headers: headers(), body: JSON.stringify(body),
          signal: controller.signal,
        });
        if (!r.ok) {
          let detail = "HTTP " + r.status;
          try { const e = await r.json(); if (e.error) detail = e.error.message; } catch (_) {}
          failed = detail;
          if (r.status === 401) {
            // Almost always the phone's key was regenerated. Say so and put
            // the way back on screen rather than leaving a bare error.
            apiKey = null;
            localStorage.removeItem(KEY);
            failed = "This phone's API key changed. Tap Connect to pair again.";
            $("connect").style.display = "";
          }
        } else {
          const reader = r.body.getReader();
          const dec = new TextDecoder();
          let buf = "";
          for (;;) {
            const { done, value } = await reader.read();
            if (done) break;
            buf += dec.decode(value, { stream: true });
            const lines = buf.split("\n");
            buf = lines.pop();
            for (const line of lines) {
              if (!line.startsWith("data: ")) continue;
              const p = line.slice(6);
              if (p === "[DONE]") continue;
              let j;
              try { j = JSON.parse(p); } catch (_) { continue; }
              // The server yields an error frame into the stream when
              // generation fails after the headers are gone. Ignoring it makes
              // a server fault look like the model simply stopping.
              if (j.error) { failed = j.error.message || "server error"; continue; }
              const d = j.choices && j.choices[0] && j.choices[0].delta;
              if (d && d.content) { pending += d.content; chunks++; schedule(); }
            }
          }
        }
      } catch (e) {
        if (e.name !== "AbortError") failed = String(e);
      } finally {
        // Everything below MUST run on every path. An early return here was
        // leaving `controller` set, and `send()` guards on it — so one failed
        // request bricked the composer until the page was reloaded.
        if (raf) { cancelAnimationFrame(raf); raf = 0; }
        flush();
        controller = null;
        live = null;
        $("send").style.display = "";
        $("stop").style.display = "none";

        const last = messages[messages.length - 1];
        const secs = (performance.now() - started) / 1000;
        if (failed) {
          // On `last.error`, never appended to `last.content`. The next
          // send builds history from the transcript, so an error written
          // into the message came back to the model as its own prior turn
          // — and it would then apologise for a transport failure it had
          // never produced.
          last.error = failed;
        } else if (chunks) {
          last.meta = `${chunks} chunks · ${(chunks / secs).toFixed(1)}/s · ${secs.toFixed(1)}s`;
        } else {
          last.meta = "stopped";
        }
        draw();
        save();
      }
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
            messages.slice(-40).map((m) => ({ role: m.role, content: m.content, meta: m.meta }))
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
    $("stop").onclick = () => controller && controller.abort();
    $("clear").onclick = () => { messages = []; save(); draw(); };
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
    draw();
    ensureKey();
    setInterval(async () => {
      try {
        const h = await (await fetch("/health")).json();
        const up = h.status === "ok";
        $("dot").style.background = up ? "#30d158" : "#ff9f0a";
        setStatus(up ? "" : "degraded");
        if (h.maxContextTokens) { contextLimit = h.maxContextTokens; updateBudget(); }
      } catch (e) {
        $("dot").style.background = "#ff453a";
        // Colour alone told a sighted user nothing specific and a screen
        // reader nothing at all.
        setStatus("phone unreachable");
      }
    }, 5000);
    </script>
    </body></html>
    """#
}
