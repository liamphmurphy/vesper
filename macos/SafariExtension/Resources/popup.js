// Vesper for Safari, the toolbar popover. It renders from the background's
// state and sends every action back to it; it never talks to Vesper itself.
// Built with textContent only: page titles and chat names are never parsed as HTML.
"use strict";

const root = document.getElementById("root");
const statusLine = document.getElementById("status");
let tabId = null;

function h(tag, attrs, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === undefined || v === null || v === false) continue;
    if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else if (k === "className") el.className = v;
    else el.setAttribute(k, v === true ? "" : v);
  }
  for (const c of children.flat()) if (c !== null && c !== undefined && c !== false) el.append(c instanceof Node ? c : String(c));
  return el;
}

async function call(type, extra) {
  const reply = await browser.runtime.sendMessage({ type, tabId, ...(extra || {}) });
  if (!reply || !reply.ok) throw new Error((reply && reply.error) || "Something went wrong.");
  return reply.value;
}

function ago(iso) {
  const s = Math.max(0, (Date.now() - Date.parse(iso)) / 1000);
  if (s < 60) return "just now";
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
  return `${Math.floor(s / 86400)}d ago`;
}

/** A button that shows progress and errors in place, then re-renders. */
function action(label, run, opts) {
  const err = h("div", { className: "error", role: "alert" });
  const btn = h("button", {
    className: opts && opts.primary ? "primary" : undefined,
    disabled: opts && opts.disabled,
    onclick: async () => {
      btn.disabled = true;
      err.textContent = "";
      try {
        const keepOpen = await run();
        if (keepOpen !== false) await render();
      } catch (e) {
        err.textContent = e.message;
        btn.disabled = false;
      }
    },
  }, label);
  return [btn, err];
}

function personaOptions(personas, selectedId) {
  return personas.map((p) => h("option", { value: p.id, selected: p.id === selectedId }, p.name));
}

function shareSection(state) {
  const { config, check, share } = state;
  if (share) {
    const reads = share.reads || [];
    return h("section", { className: "shared" },
      h("div", { className: "row" }, h("span", { className: "dot", "aria-hidden": "true" }), h("strong", {}, "Sharing this tab")),
      h("div", { className: "muted" }, `With “${share.chat_title || "a chat"}”, ${share.until === "page" ? "until you leave this page" : "until you press Stop"}. ${share.include_screenshot ? "Text and a screenshot." : "Text only."}`),
      h("h2", {}, "Read log"),
      reads.length
        ? h("ul", { className: "log" }, reads.map((r) => h("li", {}, h("span", {}, `${r.persona || "A persona"} read it`), h("span", { className: "muted" }, ago(r.read_at)))))
        : h("div", { className: "muted" }, "Not read yet."),
      h("div", { className: "row" },
        ...action("Send snapshot now", () => call("snapshot")),
        ...action("Stop", () => call("stop"), { primary: true }),
        h("button", { className: "link", onclick: () => call("openChat", { chatId: share.chat_id }) }, "Open chat"),
      ),
    );
  }
  if (!check.ok) {
    return h("section", {},
      h("h2", {}, "Share this tab"),
      h("div", { className: "muted" }, check.reason),
      check.mine ? h("div", {}, ...action(`Allow sharing ${check.host} again`, () => call("neverRemove", { host: check.host }))) : null,
    );
  }
  const personas = config.personas || [];
  const def = personas.find((p) => p.is_default) || personas[0];
  const target = h("select", { "aria-label": "Share with" },
    h("optgroup", { label: "New chat with" }, personas.map((p) => h("option", { value: `persona:${p.id}`, selected: p === def }, p.name))),
    (config.chats || []).length ? h("optgroup", { label: "Recent chats" }, config.chats.map((c) => h("option", { value: `chat:${c.id}` }, c.title || "Untitled chat"))) : null,
  );
  if (!personas.length) target.prepend(h("option", { value: "persona:", selected: true }, "New chat"));
  const shot = h("input", { type: "checkbox" });
  const untilPage = h("input", { type: "radio", name: "until", value: "page", checked: true });
  const untilStop = h("input", { type: "radio", name: "until", value: "stop" });
  return h("section", {},
    h("h2", {}, "Share this tab"),
    target,
    h("label", {}, h("input", { type: "checkbox", checked: true, disabled: true }), "Page text"),
    h("label", {}, shot, "A screenshot of what's visible"),
    h("label", {}, untilPage, "Until I leave this page"),
    h("label", {}, untilStop, "Until I press Stop"),
    h("div", { className: "muted" }, "Form fields, passwords and card numbers are never sent. The persona can read the page, not click or type in it."),
    h("div", { className: "row" }, ...action("Share", () => {
      const [kind, id] = target.value.split(":");
      const t = kind === "chat" ? { chat_id: id } : id ? { persona_id: id } : {};
      return call("share", { target: t, until: untilStop.checked ? "stop" : "page", includeScreenshot: shot.checked });
    }, { primary: true })),
  );
}

function askSection(state) {
  const { config, selection, actions } = state;
  const personas = config.personas || [];
  const def = personas.find((p) => p.is_default) || personas[0];
  const who = h("select", { "aria-label": "Ask" }, personaOptions(personas, def && def.id));
  const question = h("textarea", { placeholder: selection ? "What do you want to know about the selection?" : "Ask about this page…", rows: "2" });
  const personaId = () => who.value || undefined;
  return h("section", {},
    h("h2", {}, "Ask"),
    selection ? h("div", { className: "quote" }, selection) : null,
    personas.length > 1 ? who : null,
    question,
    h("div", { className: "row" }, ...action("Ask", async () => {
      await call("ask", { prompt: question.value.trim() || "Explain this.", personaId: personaId(), selection });
      window.close();
      return false;
    }, { primary: true })),
    actions.length ? h("h2", {}, "For this page") : null,
    actions.length
      ? h("div", { className: "row" }, actions.map((a) => action(a.label, async () => {
          await call("ask", { prompt: a.prompt, personaId: a.persona && a.persona.id, selection });
          window.close();
          return false;
        })).flat())
      : null,
  );
}

function clipSection(state) {
  const { selection } = state;
  const done = h("div", { className: "muted" });
  const savedNote = (out) =>
    done.replaceChildren("Saved to Knowledge › Clippings. ", h("button", { className: "link", onclick: () => call("openPage", { pageId: out.id }) }, "Open"));
  return h("section", {},
    h("h2", {}, "Save"),
    h("div", { className: "row" },
      ...action(selection ? "Save selection to Knowledge" : "Save page to Knowledge", async () => {
        savedNote(await call("clip", { as: "note", selection }));
        return false;
      }),
      ...action("Save link", async () => {
        const out = await call("clip", { as: "link", selection });
        done.textContent = out.state === "already_saved" ? "Already in your reading list." : "Saved to your reading list.";
        return false;
      }),
    ),
    done,
  );
}

function neverShareSection(state) {
  const { config, check } = state;
  const mine = (config.never_share && config.never_share.mine) || [];
  return h("details", {},
    h("summary", {}, `Never-share sites (${mine.length} of yours, plus Vesper's)`),
    h("div", { className: "muted" }, "Vesper never shares, clips or asks about these sites, or their subdomains."),
    check.ok && check.host ? h("div", {}, ...action(`Never share ${check.host}`, () => call("neverAdd", { host: check.host }))) : null,
    mine.length
      ? h("ul", { className: "log" }, mine.map((host) => h("li", {}, host, h("button", { className: "link", onclick: async () => { await call("neverRemove", { host }); await render(); } }, "Remove"))))
      : null,
    h("div", { className: "muted" }, `Always: ${(config.never_share && config.never_share.builtin || []).join(", ")}.`),
  );
}

async function render() {
  let state;
  try {
    state = await call("state");
  } catch (e) {
    statusLine.textContent = "Not connected";
    root.replaceChildren(h("section", {}, h("div", { className: "error" }, e.message), h("div", { className: "muted" }, "Vesper for Safari works while the Vesper app is open.")));
    return;
  }
  statusLine.textContent = "Connected";
  const parts = [shareSection(state)];
  if (state.check.ok) parts.push(askSection(state), clipSection(state));
  parts.push(neverShareSection(state));
  root.replaceChildren(...parts);
}

(async () => {
  const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
  tabId = tab ? tab.id : null;
  if (tabId === null) {
    root.replaceChildren(h("div", { className: "muted" }, "Open a page to share it."));
    return;
  }
  await render();
})();
