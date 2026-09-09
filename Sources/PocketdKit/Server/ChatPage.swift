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
      .bubble { max-width:82%; padding:11px 15px; border-radius:16px; white-space:pre-wrap;
                overflow-wrap:anywhere; }
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
      .empty h2 { color:var(--fg); font-weight:600; margin:0 0 6px; letter-spacing:-.02em; }
      dialog { border:1px solid var(--line); border-radius:14px; background:var(--bg); color:var(--fg);
               padding:26px; max-width:400px; }
      dialog::backdrop { background:rgba(0,0,0,.5); }
      dialog input { width:100%; font:600 30px/1.2 ui-monospace,Menlo,monospace; letter-spacing:.25em;
                     text-align:center; padding:12px; border-radius:10px; border:1px solid var(--line);
                     background:var(--panel); color:var(--fg); margin:14px 0; }
      .err { color:#c1121f; min-height:1.3em; font-size:14px; }
      .dot { width:8px; height:8px; border-radius:50%; background:#30d158; display:inline-block; }
    </style>
    </head>
    <body>

    <header>
      <span class="dot" id="dot"></span>
      <b>Pocketd</b>
      <select id="models" title="Model"></select>
      <span class="sp"></span>
      <button id="sys" title="System prompt">System</button>
      <button id="clear">New chat</button>
    </header>

    <div id="log"><div class="wrap" id="wrap">
      <div class="empty" id="empty">
        <h2>Your phone is the server</h2>
        <div>Everything you type here is answered on the device in your pocket.</div>
      </div>
    </div></div>

    <footer><div class="composer">
      <textarea id="input" rows="1" placeholder="Message…" autofocus></textarea>
      <button class="primary" id="send">Send</button>
      <button id="stop" style="display:none">Stop</button>
    </div></footer>

    <dialog id="pair">
      <h3 style="margin:0 0 4px">Connect to your phone</h3>
      <div style="color:var(--dim);font-size:14px">Enter the six digits shown on the Pocketd Server tab.</div>
      <input id="code" inputmode="numeric" maxlength="6" placeholder="000000">
      <div class="err" id="perr"></div>
      <button class="primary" id="pgo" style="width:100%">Connect</button>
    </dialog>

    <script>
    const $ = (id) => document.getElementById(id);
    const KEY = "pocketd.key";
    let apiKey = localStorage.getItem(KEY) || null;
    let messages = [];
    let system = localStorage.getItem("pocketd.system") || "";
    let controller = null;

    function headers() {
      const h = { "Content-Type": "application/json" };
      if (apiKey) h["Authorization"] = "Bearer " + apiKey;
      return h;
    }

    // --- pairing -------------------------------------------------------------
    async function ensureKey() {
      // A server with auth off needs no key at all; find out before asking.
      const probe = await fetch("/v1/models", { headers: headers() });
      if (probe.ok) { await loadModels(probe); return; }
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
      loadModels();
    };
    $("code").addEventListener("keydown", (e) => { if (e.key === "Enter") $("pgo").click(); });

    // --- models --------------------------------------------------------------
    async function loadModels(pre) {
      try {
        const r = pre || await fetch("/v1/models", { headers: headers() });
        const b = await r.json();
        $("models").innerHTML = "";
        (b.data || []).forEach((m) => {
          const o = document.createElement("option");
          o.value = m.id; o.textContent = m.id;
          $("models").appendChild(o);
        });
        if (!b.data || !b.data.length) {
          $("models").innerHTML = "<option>no model loaded</option>";
        }
      } catch (e) { $("dot").style.background = "#ff453a"; }
    }

    // --- rendering -----------------------------------------------------------
    function escapeHTML(s) {
      return s.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));
    }
    // Just enough markdown to make code readable; not a full parser, and it
    // escapes first so model output can never inject markup.
    function render(text) {
      let h = escapeHTML(text);
      h = h.replace(/```([\s\S]*?)```/g, (_, c) => "<pre>" + c.replace(/^\w*\n/, "") + "</pre>");
      h = h.replace(/`([^`\n]+)`/g, "<code>$1</code>");
      h = h.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
      return h;
    }

    function draw() {
      $("empty").style.display = messages.length ? "none" : "";
      const nodes = messages.map((m, i) => {
        const meta = m.meta ? `<div class="meta">${m.meta}</div>` : "";
        return `<div class="msg ${m.role === "user" ? "u" : "a"}">
                  <div><div class="bubble">${m.role === "user" ? escapeHTML(m.content) : render(m.content)}</div>${meta}</div>
                </div>`;
      });
      $("wrap").innerHTML = `<div class="empty" id="empty" style="display:${messages.length ? "none" : ""}">
          <h2>Your phone is the server</h2>
          <div>Everything you type here is answered on the device in your pocket.</div>
        </div>` + nodes.join("");
      $("log").scrollTop = $("log").scrollHeight;
    }

    // --- sending -------------------------------------------------------------
    async function send() {
      const text = $("input").value.trim();
      if (!text || controller) return;
      $("input").value = "";
      $("input").style.height = "auto";
      messages.push({ role: "user", content: text });
      messages.push({ role: "assistant", content: "" });
      draw();

      $("send").style.display = "none";
      $("stop").style.display = "";
      controller = new AbortController();

      const body = { model: $("models").value, messages: [], stream: true };
      if (system) body.messages.push({ role: "system", content: system });
      for (const m of messages.slice(0, -1)) body.messages.push({ role: m.role, content: m.content });

      const started = performance.now();
      let tokens = 0;
      try {
        const r = await fetch("/v1/chat/completions", {
          method: "POST", headers: headers(), body: JSON.stringify(body),
          signal: controller.signal,
        });
        if (!r.ok) {
          const e = await r.json().catch(() => ({}));
          messages[messages.length - 1].content =
            "⚠︎ " + (e.error ? e.error.message : "HTTP " + r.status);
          draw(); return;
        }
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
            try {
              const j = JSON.parse(p);
              const d = j.choices && j.choices[0] && j.choices[0].delta;
              if (d && d.content) {
                messages[messages.length - 1].content += d.content;
                tokens++;
                draw();
              }
            } catch (e) { /* a partial frame; the next read completes it */ }
          }
        }
        const secs = (performance.now() - started) / 1000;
        if (tokens) {
          messages[messages.length - 1].meta =
            `${tokens} chunks · ${(tokens / secs).toFixed(1)}/s · ${secs.toFixed(1)}s`;
        }
      } catch (e) {
        if (e.name !== "AbortError") {
          messages[messages.length - 1].content += "\n\n⚠︎ " + e;
        } else {
          messages[messages.length - 1].meta = "stopped";
        }
      }
      controller = null;
      $("send").style.display = "";
      $("stop").style.display = "none";
      draw();
      save();
    }

    function save() {
      try { localStorage.setItem("pocketd.chat", JSON.stringify(messages.slice(-40))); } catch (e) {}
    }

    $("send").onclick = send;
    $("stop").onclick = () => controller && controller.abort();
    $("clear").onclick = () => { messages = []; save(); draw(); };
    $("sys").onclick = () => {
      const v = prompt("System prompt (blank for none):", system);
      if (v !== null) { system = v; localStorage.setItem("pocketd.system", v); }
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
        $("dot").style.background = h.status === "ok" ? "#30d158" : "#ff9f0a";
      } catch (e) { $("dot").style.background = "#ff453a"; }
    }, 5000);
    </script>
    </body></html>
    """#
}
