#!/usr/bin/env node
// reader-probe.mjs -- check, in a running debug build, that the feed
// article view's reader rendering runs no script from the article.
//
// It drives the app's article WebView over the devtools socket a debug
// build exposes, and serves a real article to it with test markup added:
// markup a publisher could put in an article. Each piece of script in it,
// if it runs, sets document.title to js-ran-<kind>, stamps
// <html data-probe-<kind>="ran"> and hangs a red "SCRIPT RAN" banner off
// <html> (outside <body>, so Readability never carries a banner from the
// publisher's page into the reader document). `state` reads all of that
// back through the DOM domain, which needs no script in the page.
//
// Needs Node 22 or later (the built-in WebSocket) and adb. With the app
// running on an emulator or device:
//
//   adb forward tcp:9223 localabstract:webview_devtools_remote_$(adb shell pidof com.cabalmail.android)
//   node reader-probe.mjs serve example.org/ &     # a substring of the article's URL
//   ... open the article in the app ...
//   node reader-probe.mjs state
//
//   pages            the WebView's pages: url and title
//   state            per page: title, history, the document's content
//                    policies, and what the probe left in the DOM
//   html             the current page's outer HTML
//   serve SUBSTR     keep running; any document whose URL contains SUBSTR
//                    is served with the probe markup after its second
//                    paragraph
//   reload           reload the current page (through serve, if running)
//
// What to expect. On the publisher's page: title js-ran-onerror, the
// inline and onerror stamps, both banners, one iframe. In the reader
// rendering: the probe paragraph present with its handlers still in the
// markup, no stamp, no banner, no iframe, the title left alone, and a
// content policy with script-src 'none'; a tap on "probe click link"
// changes none of that.
//
// Things that cost time when this was first used:
// - The socket exists only once the app has made its first WebView, so
//   the first article opened after a launch loads before `serve` can
//   attach. Open any article, go back, then open the one to probe.
// - `uiautomator dump` waits for the screen to go idle, and the probed
//   publisher's page (it holds a video player) never does. Tap by
//   coordinate there, and dump only on the reader rendering.
// - The forward names the app's pid: set it again after a reinstall.

const PORT = process.env.CDP_PORT || "9223";
const BASE = `http://localhost:${PORT}`;

function probe(kind) {
  return (
    "(function(k){document.title='js-ran-'+k;var d=document.documentElement;" +
    "d.setAttribute('data-probe-'+k,'ran');var b=document.createElement('div');" +
    "b.className='cabal-probe-banner';b.textContent='SCRIPT RAN: '+k;" +
    "b.style.cssText='position:fixed;left:0;right:0;bottom:'+(d.querySelectorAll('.cabal-probe-banner').length*56)+'px;" +
    "background:#c00;color:#fff;font:bold 20px sans-serif;padding:12px;z-index:99999';" +
    "d.appendChild(b)})('" + kind + "')"
  );
}

const PAYLOAD =
  '<p id="cabal-probe">Probe paragraph for the reader check. ' +
  `<img alt="probe image" src="/cabal-probe-missing.png" onerror="${probe("onerror")}"> ` +
  `<a id="cabal-probe-click" href="#cabal-probe" onclick="${probe("onclick")};return false">probe click link</a> ` +
  `<a id="cabal-probe-jsurl" href="javascript:${probe("jsurl")}">probe javascript link</a></p>` +
  `<script>${probe("inline")}</script>` +
  '<p><iframe src="https://www.youtube.com/embed/aqz-KE-bpKQ" width="560" height="315" title="probe video"></iframe></p>' +
  '<p><object data="/cabal-probe-missing.swf" type="application/x-shockwave-flash" width="50" height="50"></object>' +
  '<embed src="/cabal-probe-missing.swf" type="application/x-shockwave-flash" width="50" height="50"></p>';

function inject(html) {
  // After the second paragraph: inside the article on the pages this was tried on.
  let at = html.indexOf("</p>");
  if (at >= 0) {
    const next = html.indexOf("</p>", at + 4);
    if (next >= 0) at = next;
  }
  if (at < 0) return null;
  return html.slice(0, at + 4) + PAYLOAD + html.slice(at + 4);
}

class Cdp {
  constructor(url) {
    this.ws = new WebSocket(url);
    this.next = 1;
    this.pending = new Map();
    this.handlers = [];
    this.ready = new Promise((resolve, reject) => {
      this.ws.onopen = resolve;
      this.ws.onerror = (e) => reject(new Error("websocket error: " + (e.message || url)));
    });
    this.ws.onmessage = (event) => {
      const msg = JSON.parse(event.data);
      if (msg.id && this.pending.has(msg.id)) {
        const { resolve, reject } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.error) reject(new Error(JSON.stringify(msg.error)));
        else resolve(msg.result);
      } else if (msg.method) {
        for (const handler of this.handlers) handler(msg);
      }
    };
  }
  send(method, params = {}, sessionId) {
    const id = this.next++;
    const payload = { id, method, params };
    if (sessionId) payload.sessionId = sessionId;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify(payload));
    });
  }
  on(handler) {
    this.handlers.push(handler);
  }
  close() {
    this.ws.close();
  }
}

async function pages() {
  const list = await (await fetch(`${BASE}/json`)).json();
  return list.filter((p) => p.type === "page");
}

function attrs(node) {
  const out = {};
  const a = node.attributes || [];
  for (let i = 0; i < a.length; i += 2) out[a[i]] = a[i + 1];
  return out;
}

function walk(node, visit) {
  visit(node);
  for (const child of node.children || []) walk(child, visit);
  if (node.contentDocument) walk(node.contentDocument, visit);
}

async function state() {
  for (const page of await pages()) {
    const cdp = new Cdp(page.webSocketDebuggerUrl);
    await cdp.ready;
    const history = await cdp.send("Page.getNavigationHistory");
    const { root } = await cdp.send("DOM.getDocument", { depth: -1 });
    const found = { html: {}, policies: [], banners: [], probe: false, iframes: [], objects: 0, embeds: 0, scripts: 0, handlers: [] };
    walk(root, (node) => {
      const name = (node.nodeName || "").toLowerCase();
      const a = attrs(node);
      if (name === "html") found.html = a;
      if (name === "meta" && (a["http-equiv"] || "").toLowerCase() === "content-security-policy") {
        found.policies.push(a.content);
      }
      if (a.class === "cabal-probe-banner") found.banners.push(node.children?.[0]?.nodeValue || "");
      if (a.id === "cabal-probe") found.probe = true;
      if (name === "iframe") found.iframes.push(a.src || "");
      if (name === "object") found.objects += 1;
      if (name === "embed") found.embeds += 1;
      if (name === "script") found.scripts += 1;
      for (const key of Object.keys(a)) {
        if (key.startsWith("on") && (a.id || "").startsWith("cabal-probe") || (key === "onerror" && a.alt === "probe image")) {
          found.handlers.push(`${name}.${key}`);
        }
      }
    });
    console.log(JSON.stringify({
      title: page.title,
      url: page.url,
      historyIndex: history.currentIndex,
      history: history.entries.map((e) => `${e.id} ${e.url.slice(0, 90)} | ${e.title.slice(0, 40)} | ${e.transitionType}`),
      htmlAttributes: found.html,
      contentPolicies: found.policies,
      scriptRanBanners: found.banners,
      probeParagraphPresent: found.probe,
      probeHandlersInDom: found.handlers,
      iframes: found.iframes,
      objects: found.objects,
      embeds: found.embeds,
      scriptElements: found.scripts,
    }, null, 2));
    cdp.close();
  }
}

async function html() {
  const [page] = await pages();
  const cdp = new Cdp(page.webSocketDebuggerUrl);
  await cdp.ready;
  const { root } = await cdp.send("DOM.getDocument", { depth: 0 });
  const { outerHTML } = await cdp.send("DOM.getOuterHTML", { nodeId: root.nodeId });
  console.log(outerHTML);
  cdp.close();
}

async function reload() {
  const [page] = await pages();
  const cdp = new Cdp(page.webSocketDebuggerUrl);
  await cdp.ready;
  await cdp.send("Page.reload", { ignoreCache: true });
  cdp.close();
}

async function serve(substr) {
  const log = (...args) => console.log(new Date().toISOString().slice(11, 23), ...args);
  log(`serving probe markup into documents whose URL contains "${substr}"`);
  // The browser-level socket goes away with the app; keep coming back for the next one.
  for (;;) {
    try {
      await serveOnce(substr, log);
    } catch (e) {
      // The app is not running, or the forward is gone.
    }
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
}

// One connection to the WebView's browser-level endpoint. New pages are attached to
// before they load anything (waitForDebuggerOnStart), so the article's first request
// is already behind the interception.
async function serveOnce(substr, log) {
  const cdp = new Cdp(`ws://localhost:${PORT}/devtools/browser`);
  await cdp.ready;
  const closed = new Promise((resolve) => {
    cdp.ws.onclose = resolve;
  });
  log("connected");
  cdp.on(async (msg) => {
    const session = msg.sessionId;
    try {
      if (msg.method === "Target.attachedToTarget") {
        const s = msg.params.sessionId;
        if (msg.params.targetInfo.type === "page") {
          await cdp.send("Fetch.enable", {
            patterns: [{ urlPattern: "*", resourceType: "Document", requestStage: "Response" }],
          }, s);
          log("attached", msg.params.targetInfo.targetId.slice(0, 8), "waiting:", msg.params.waitingForDebugger,
            msg.params.targetInfo.url.slice(0, 70));
        }
        await cdp.send("Runtime.runIfWaitingForDebugger", {}, s);
        return;
      }
      if (msg.method !== "Fetch.requestPaused") return;
      const p = msg.params;
      const isDocument = p.resourceType === "Document" && p.request.url.includes(substr);
      if (!isDocument || p.responseStatusCode !== 200) {
        await cdp.send("Fetch.continueRequest", { requestId: p.requestId }, session);
        return;
      }
      const body = await cdp.send("Fetch.getResponseBody", { requestId: p.requestId }, session);
      const text = body.base64Encoded ? Buffer.from(body.body, "base64").toString("utf8") : body.body;
      const out = inject(text);
      if (out === null) {
        log("no paragraph to inject after", p.request.url);
        await cdp.send("Fetch.continueRequest", { requestId: p.requestId }, session);
        return;
      }
      const drop = new Set(["content-length", "content-encoding", "content-security-policy", "etag"]);
      const headers = (p.responseHeaders || []).filter((h) => !drop.has(h.name.toLowerCase()));
      await cdp.send("Fetch.fulfillRequest", {
        requestId: p.requestId,
        responseCode: 200,
        responseHeaders: headers,
        body: Buffer.from(out, "utf8").toString("base64"),
      }, session);
      log("served with probe:", p.request.url);
    } catch (e) {
      log("error", msg.method, e.message);
    }
  });
  await cdp.send("Target.setAutoAttach", { autoAttach: true, waitForDebuggerOnStart: true, flatten: true });
  await closed;
  log("disconnected");
}

const [command, arg] = process.argv.slice(2);
const commands = { state, html, reload, serve: () => serve(arg), pages: async () => {
  for (const p of await pages()) console.log(p.id.slice(0, 8), p.url, "|", p.title);
} };
if (!commands[command] || (command === "serve" && !arg)) {
  console.error("usage: reader-probe.mjs pages | state | html | reload | serve URL-SUBSTRING");
  process.exit(2);
}
await commands[command]();
