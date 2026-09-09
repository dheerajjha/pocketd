import Foundation

/// The page the phone serves to the laptop.
///
/// Kept as one Swift string rather than a bundled resource on purpose:
/// PocketdKit has no resources, and staying that way is what keeps `swift test`
/// sub-second and the package Linux-clean. One literal is a smaller price.
enum SetupPage {
    static func html(serverName: String) -> String {
        #"""
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Connect to __NAME__</title>
        <style>
          :root {
            color-scheme: light dark;
            --bg: #fbfbfd; --fg: #1d1d1f; --dim: #6e6e73;
            --card: #fff; --line: #e3e3e8; --accent: #0071e3; --code: #f5f5f7;
            --ok: #1d8a44; --bad: #c1121f;
          }
          @media (prefers-color-scheme: dark) {
            :root { --bg:#000; --fg:#f5f5f7; --dim:#8e8e93; --card:#1c1c1e;
                    --line:#2c2c2e; --accent:#0a84ff; --code:#161618;
                    --ok:#30d158; --bad:#ff453a; }
          }
          * { box-sizing: border-box; }
          body { margin:0; background:var(--bg); color:var(--fg);
                 font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
                 display:flex; justify-content:center; padding:48px 20px; }
          main { width:100%; max-width:680px; }
          h1 { font-size:28px; margin:0 0 6px; letter-spacing:-.02em; }
          p.sub { color:var(--dim); margin:0 0 32px; }
          .card { background:var(--card); border:1px solid var(--line);
                  border-radius:14px; padding:24px; margin-bottom:20px; }
          label { display:block; font-weight:600; margin-bottom:10px; }
          input[type=text] { width:100%; font:600 32px/1.2 ui-monospace,SFMono-Regular,Menlo,monospace;
                 letter-spacing:.28em; text-align:center; padding:14px;
                 border:1px solid var(--line); border-radius:10px;
                 background:var(--bg); color:var(--fg); }
          button { font:600 15px/1 inherit; padding:12px 18px; border:0;
                   border-radius:9px; background:var(--accent); color:#fff; cursor:pointer; }
          button:disabled { opacity:.45; cursor:default; }
          button.ghost { background:transparent; color:var(--accent);
                         border:1px solid var(--line); }
          .row { display:flex; gap:10px; align-items:center; margin-top:14px; flex-wrap:wrap; }
          .err { color:var(--bad); margin-top:12px; min-height:1.4em; }
          .hidden { display:none; }
          dl { display:grid; grid-template-columns:auto 1fr; gap:8px 18px; margin:0 0 18px; }
          dt { color:var(--dim); }
          dd { margin:0; font-family:ui-monospace,SFMono-Regular,Menlo,monospace;
               overflow-wrap:anywhere; }
          .tabs { display:flex; gap:6px; flex-wrap:wrap; margin-bottom:14px; }
          .tabs button { background:transparent; color:var(--fg);
                         border:1px solid var(--line); font-weight:500; padding:8px 14px; }
          .tabs button[aria-selected=true] { background:var(--accent); color:#fff; border-color:var(--accent); }
          pre { background:var(--code); border:1px solid var(--line); border-radius:10px;
                padding:16px; overflow-x:auto; margin:0;
                font:13px/1.55 ui-monospace,SFMono-Regular,Menlo,monospace; }
          .note { color:var(--dim); font-size:14px; margin-top:12px; }
          #out { white-space:pre-wrap; min-height:3em; }
          .dot { width:9px; height:9px; border-radius:50%; background:var(--ok);
                 display:inline-block; margin-right:8px; }
        </style>
        </head>
        <body><main>

          <h1>Connect to __NAME__</h1>
          <p class="sub">This page is served by the phone itself. Enter the six digits it is showing.</p>

          <section class="card" id="pair">
            <label for="code">Pairing code</label>
            <input id="code" type="text" inputmode="numeric" autocomplete="off"
                   maxlength="6" pattern="[0-9]*" placeholder="000000" autofocus>
            <div class="row"><button id="go">Connect</button></div>
            <div class="err" id="err"></div>
          </section>

          <section class="card hidden" id="done">
            <dl>
              <dt>Base URL</dt><dd id="base"></dd>
              <dt>API key</dt><dd id="key"></dd>
              <dt>Model</dt><dd id="model"></dd>
            </dl>
            <div class="tabs" id="tabs"></div>
            <pre id="snippet"></pre>
            <div class="note" id="note"></div>
            <div class="row">
              <button id="copy">Copy</button>
              <button class="ghost" id="test" disabled>Checking model…</button>
            </div>
            <pre id="out" class="hidden"></pre>
          </section>

        <script>
        const $ = (id) => document.getElementById(id);
        let snippets = [], active = 0, conf = null;

        async function pair() {
          const code = $("code").value.trim();
          $("err").textContent = "";
          if (!/^\d{6}$/.test(code)) { $("err").textContent = "Six digits."; return; }
          $("go").disabled = true;
          try {
            const r = await fetch("/pair", {
              method: "POST",
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify({ code }),
            });
            const body = await r.json();
            if (!r.ok) {
              $("err").textContent = body.error ? body.error.message : "Pairing failed.";
              $("go").disabled = false;
              return;
            }
            conf = body;
            snippets = body.snippets || [];
            $("pair").classList.add("hidden");
            $("done").classList.remove("hidden");
            $("base").textContent = body.baseURL;
            $("key").textContent = body.apiKey || "(auth is off)";
            $("model").textContent = body.model || "(none loaded)";
            renderTabs();
            pollHealth();
          } catch (e) {
            $("err").textContent = "Could not reach the phone. Is it still on screen?";
            $("go").disabled = false;
          }
        }

        function renderTabs() {
          $("tabs").innerHTML = "";
          snippets.forEach((s, i) => {
            const b = document.createElement("button");
            b.textContent = s.title;
            b.setAttribute("aria-selected", i === active);
            b.onclick = () => { active = i; renderTabs(); };
            $("tabs").appendChild(b);
          });
          const s = snippets[active];
          if (!s) return;
          $("snippet").textContent = s.body;
          $("note").textContent = s.note || "";
        }

        $("copy").onclick = async () => {
          await navigator.clipboard.writeText(snippets[active].body);
          $("copy").textContent = "Copied";
          setTimeout(() => ($("copy").textContent = "Copy"), 1200);
        };

        async function pollHealth() {
          try {
            const h = await (await fetch("/health")).json();
            if (h.model) {
              $("test").disabled = false;
              $("test").textContent = "Send a test message";
              $("model").textContent = h.model;
              return;
            }
            $("test").textContent = "No model loaded yet";
          } catch (e) { /* the phone went away; the test button stays disabled */ }
          setTimeout(pollHealth, 2000);
        }

        // Streams a real completion over the exact URL and key the user just
        // received, so "it works" is demonstrated rather than asserted.
        $("test").onclick = async () => {
          $("test").disabled = true;
          $("out").classList.remove("hidden");
          $("out").textContent = "";
          const headers = { "Content-Type": "application/json" };
          if (conf.apiKey) headers["Authorization"] = "Bearer " + conf.apiKey;
          try {
            const r = await fetch("/v1/chat/completions", {
              method: "POST", headers,
              body: JSON.stringify({
                model: $("model").textContent,
                messages: [{ role: "user", content: "Say hello in one short sentence." }],
                stream: true,
              }),
            });
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
                const payload = line.slice(6);
                if (payload === "[DONE]") continue;
                try {
                  const j = JSON.parse(payload);
                  const t = j.choices && j.choices[0] && j.choices[0].delta
                          ? j.choices[0].delta.content : null;
                  if (t) $("out").textContent += t;
                } catch (e) { /* a partial frame; the next read completes it */ }
              }
            }
          } catch (e) {
            $("out").textContent = "Request failed: " + e;
          }
          $("test").disabled = false;
        };

        $("go").onclick = pair;
        $("code").addEventListener("keydown", (e) => { if (e.key === "Enter") pair(); });
        </script>
        </main></body></html>
        """#
        .replacingOccurrences(of: "__NAME__", with: serverName)
    }
}
