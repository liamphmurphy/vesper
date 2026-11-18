// Vesper for Safari, background: shares tabs with a Vesper chat, keeps shared
// tabs' snapshots current, and runs the context-menu actions. Every call to
// Vesper goes through the native handler (SafariWebExtensionHandler), which
// holds the token and only knows a fixed set of operations.
"use strict";

// manifest.json loads lib.js first (Xcode's Safari template uses background scripts, not a service
// worker); importScripts covers a worker, should Safari run it as one.
if (!globalThis.VesperExt && typeof importScripts === "function") importScripts("lib.js");
const ext = globalThis.VesperExt;

// Safari ignores the application id; the handler is the containing app's.
const APP_ID = "com.vesper.mac";
const SNAPSHOT_DEBOUNCE_MS = 1500;
const SCREENSHOT_MAX_WIDTH = 1280;
const SCREENSHOT_MAX_BYTES = 1_400_000;

class VesperError extends Error {
  constructor(message, status) {
    super(message);
    this.status = status || 0;
  }
}

async function native(op, args) {
  let reply;
  try {
    reply = await browser.runtime.sendNativeMessage(APP_ID, { op, ...(args || {}) });
  } catch (e) {
    throw new VesperError("Couldn't reach Vesper. Open the Vesper app and try again.");
  }
  if (!reply || reply.ok !== true) throw new VesperError((reply && reply.error) || "Vesper didn't answer.", reply && reply.status);
  return reply.body;
}

// --- State: the tabs this browser shares, by tab id. Kept in storage because
// Safari may unload the background script between events.

async function loadShares() {
  const { shares } = await browser.storage.local.get("shares");
  return shares || {};
}

async function saveShares(shares) {
  await browser.storage.local.set({ shares });
}

async function config(refresh) {
  const { config: cached } = await browser.storage.local.get("config");
  if (cached && !refresh) return cached;
  const fresh = await native("config");
  await browser.storage.local.set({ config: fresh });
  await reconcile(fresh);
  await updateMenus(fresh);
  return fresh;
}

/** Brings local share state in line with the server's active shares. */
async function reconcile(cfg) {
  const local = await loadShares();
  const next = {};
  for (const s of cfg.shares || []) {
    const tabId = Number(s.tab_id);
    try {
      await browser.tabs.get(tabId);
    } catch {
      // The tab is gone (Safari restarted, or it closed while unloaded): end the share.
      native("share_stop", { share_id: s.id, body: { reason: "tab_closed" } }).catch(() => {});
      continue;
    }
    const prev = local[tabId];
    next[tabId] = { id: s.id, chat_id: s.chat_id, chat_title: s.chat_title, until: s.until, include_screenshot: s.include_screenshot, start_url: (prev && prev.start_url) || s.url };
  }
  await saveShares(next);
  for (const tabId of new Set([...Object.keys(local), ...Object.keys(next)])) await setBadge(Number(tabId), !!next[tabId]);
}

async function setBadge(tabId, shared) {
  try {
    await browser.action.setBadgeText({ tabId, text: shared ? "●" : "" });
    if (shared) await browser.action.setBadgeBackgroundColor({ tabId, color: "#d79921" });
  } catch {
    // The tab closed.
  }
}

// --- Reading a tab

function toBase64(buffer) {
  const bytes = new Uint8Array(buffer);
  let bin = "";
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  return btoa(bin);
}

/** A JPEG of the visible tab, scaled down to fit the server's limit; undefined when it can't be taken. */
async function screenshot(windowId) {
  try {
    const dataUrl = await browser.tabs.captureVisibleTab(windowId, { format: "jpeg", quality: 70 });
    const bitmap = await createImageBitmap(await (await fetch(dataUrl)).blob());
    const scale = Math.min(1, SCREENSHOT_MAX_WIDTH / bitmap.width);
    const canvas = new OffscreenCanvas(Math.round(bitmap.width * scale), Math.round(bitmap.height * scale));
    canvas.getContext("2d").drawImage(bitmap, 0, 0, canvas.width, canvas.height);
    for (const quality of [0.6, 0.4]) {
      const blob = await canvas.convertToBlob({ type: "image/jpeg", quality });
      if (blob.size <= SCREENSHOT_MAX_BYTES) return toBase64(await blob.arrayBuffer());
    }
  } catch {
    // No screenshot this time; the text still goes.
  }
  return undefined;
}

async function readTab(tab, includeScreenshot) {
  const [result] = await browser.scripting.executeScript({ target: { tabId: tab.id }, func: ext.extractPage });
  const page = (result && result.result) || { text: "", title: "", selection: "" };
  const snap = { url: tab.url, title: page.title || tab.title || "", text: ext.redactCardNumbers(page.text), incognito: !!tab.incognito };
  // Safari only captures the tab showing in its window.
  if (includeScreenshot && tab.active) snap.screenshot = await screenshot(tab.windowId);
  return { snap, selection: ext.redactCardNumbers(page.selection) };
}

async function readSelection(tab) {
  try {
    const [result] = await browser.scripting.executeScript({ target: { tabId: tab.id }, func: () => String(getSelection() || "").slice(0, 20000) });
    return ext.redactCardNumbers((result && result.result) || "");
  } catch {
    return "";
  }
}

function pageCheck(cfg, tab) {
  return ext.shareablePage(tab.url, !!tab.incognito, cfg.never_share);
}

// --- Sharing

async function startShare(tabId, target, until, includeScreenshot) {
  const cfg = await config(false);
  const tab = await browser.tabs.get(tabId);
  const check = pageCheck(cfg, tab);
  if (!check.ok) throw new VesperError(check.reason);
  const { snap } = await readTab(tab, includeScreenshot);
  const body = { ...snap, tab_id: String(tab.id), until, include_screenshot: includeScreenshot };
  if (target.chat_id) body.chat_id = target.chat_id;
  else if (target.persona_id) body.persona_id = target.persona_id;
  const share = await native("share_start", { body });
  const shares = await loadShares();
  shares[tab.id] = { id: share.id, chat_id: share.chat_id, chat_title: share.chat_title, until, include_screenshot: includeScreenshot, start_url: tab.url };
  await saveShares(shares);
  await setBadge(tab.id, true);
  // A new chat opens in Vesper so the person sees where the tab went; an existing one is left alone.
  if (!target.chat_id) native("open_chat", { chat_id: share.chat_id }).catch(() => {});
  return share;
}

async function stopShare(tabId, reason) {
  const shares = await loadShares();
  const s = shares[tabId];
  if (!s) return null;
  delete shares[tabId];
  await saveShares(shares);
  await setBadge(tabId, false);
  try {
    return await native("share_stop", { share_id: s.id, body: { reason } });
  } catch {
    return null; // Ended locally either way; the server ends it on the next refused snapshot.
  }
}

async function sendSnapshot(tabId) {
  const shares = await loadShares();
  const s = shares[tabId];
  if (!s) return null;
  const cfg = await config(false);
  let tab;
  try {
    tab = await browser.tabs.get(tabId);
  } catch {
    return stopShare(tabId, "tab_closed");
  }
  // Never send a page the share doesn't cover: stop instead.
  if (!pageCheck(cfg, tab).ok) return stopShare(tabId, "never_share");
  if (s.until === "page" && !ext.samePage(s.start_url, tab.url)) return stopShare(tabId, "left_page");
  const { snap } = await readTab(tab, s.include_screenshot);
  try {
    return await native("snapshot", { share_id: s.id, body: snap });
  } catch (e) {
    if (e.status === 409 || e.status === 404) {
      delete shares[tabId];
      await saveShares(shares);
      await setBadge(tabId, false);
    }
    throw e;
  }
}

const pending = new Map();
function scheduleSnapshot(tabId) {
  clearTimeout(pending.get(tabId));
  pending.set(tabId, setTimeout(() => {
    pending.delete(tabId);
    sendSnapshot(tabId).catch(() => {});
  }, SNAPSHOT_DEBOUNCE_MS));
}

browser.tabs.onUpdated.addListener(async (tabId, change, tab) => {
  const shares = await loadShares();
  const s = shares[tabId];
  if (!s) return;
  if (change.url) {
    const cfg = await config(false).catch(() => null);
    if (s.until === "page" && !ext.samePage(s.start_url, change.url)) return void stopShare(tabId, "left_page");
    if (cfg && !ext.shareablePage(change.url, !!tab.incognito, cfg.never_share).ok) return void stopShare(tabId, "never_share");
  }
  if (change.status === "complete") scheduleSnapshot(tabId);
});

browser.tabs.onRemoved.addListener((tabId) => {
  stopShare(tabId, "tab_closed").catch(() => {});
});

// --- Ask and clip

async function ask(tab, prompt, personaId, selection) {
  const cfg = await config(false);
  const check = pageCheck(cfg, tab);
  if (!check.ok) throw new VesperError(check.reason);
  const persona = personaId || (ext.defaultPersona(cfg.personas) || {}).id;
  const body = { prompt, url: tab.url, title: tab.title || "", selection: selection || "", incognito: !!tab.incognito };
  if (persona) body.persona_id = persona;
  const out = await native("ask", { body });
  native("open_chat", { chat_id: out.chat_id }).catch(() => {});
  return out;
}

async function clip(tab, as, selection) {
  const cfg = await config(false);
  const check = pageCheck(cfg, tab);
  if (!check.ok) throw new VesperError(check.reason);
  return native("clip", { body: { as, url: tab.url, title: tab.title || "", selection: selection || "", incognito: !!tab.incognito } });
}

async function flash(tabId, text) {
  try {
    await browser.action.setBadgeText({ tabId, text });
    setTimeout(async () => {
      const shares = await loadShares();
      setBadge(tabId, !!shares[tabId]);
    }, 2000);
  } catch {
    // The tab closed.
  }
}

// --- Context menu

const MENU = { ask: "vesper-ask", clipSelection: "vesper-clip-selection", clipPage: "vesper-clip-page" };

async function updateMenus(cfg) {
  const persona = ext.defaultPersona(cfg && cfg.personas);
  const who = persona ? persona.name : "Vesper";
  try {
    await browser.contextMenus.update(MENU.ask, { title: `Ask ${who} about “%s”` });
  } catch {
    // Menus not created yet; installMenus names them next time.
  }
}

async function installMenus() {
  await browser.contextMenus.removeAll();
  browser.contextMenus.create({ id: MENU.ask, title: "Ask Vesper about “%s”", contexts: ["selection"] });
  browser.contextMenus.create({ id: MENU.clipSelection, title: "Save Selection to Vesper Knowledge", contexts: ["selection"] });
  browser.contextMenus.create({ id: MENU.clipPage, title: "Save Page to Vesper Knowledge", contexts: ["page"] });
  const { config: cached } = await browser.storage.local.get("config");
  if (cached) await updateMenus(cached);
}

browser.runtime.onInstalled.addListener(() => installMenus().catch(() => {}));
browser.runtime.onStartup.addListener(() => {
  installMenus().catch(() => {});
  config(true).catch(() => {});
});

browser.contextMenus.onClicked.addListener(async (info, tab) => {
  if (!tab) return;
  const selection = ext.redactCardNumbers(info.selectionText || "");
  try {
    if (info.menuItemId === MENU.ask) await ask(tab, "Explain this.", null, selection);
    else if (info.menuItemId === MENU.clipSelection) await clip(tab, "note", selection);
    else if (info.menuItemId === MENU.clipPage) await clip(tab, "note", "");
    else return;
    if (info.menuItemId !== MENU.ask) flash(tab.id, "✓");
  } catch {
    flash(tab.id, "!");
  }
});

// --- The popover's requests

async function popupState(tabId) {
  const cfg = await config(true);
  const tab = await browser.tabs.get(tabId);
  const shares = await loadShares();
  const local = shares[tabId];
  let share = null;
  if (local) share = await native("share_get", { share_id: local.id }).catch(() => null);
  const check = pageCheck(cfg, tab);
  return {
    config: cfg,
    tab: { id: tab.id, url: tab.url, title: tab.title, incognito: !!tab.incognito },
    check,
    share: share && !share.stopped_at ? share : null,
    actions: check.ok ? ext.siteActions(tab.url, cfg.personas) : [],
    selection: check.ok ? await readSelection(tab) : "",
  };
}

const handlers = {
  state: (m) => popupState(m.tabId),
  share: (m) => startShare(m.tabId, m.target, m.until, !!m.includeScreenshot),
  snapshot: (m) => sendSnapshot(m.tabId),
  stop: (m) => stopShare(m.tabId, "stopped"),
  ask: async (m) => ask(await browser.tabs.get(m.tabId), m.prompt, m.personaId, m.selection),
  clip: async (m) => clip(await browser.tabs.get(m.tabId), m.as, m.selection),
  neverAdd: async (m) => {
    const cfg = await native("never_add", { body: { host: m.host } });
    await browser.storage.local.set({ config: cfg });
    await reconcile(cfg);
    return cfg;
  },
  neverRemove: async (m) => {
    const cfg = await native("never_remove", { host: m.host });
    await browser.storage.local.set({ config: cfg });
    return cfg;
  },
  openChat: (m) => native("open_chat", { chat_id: m.chatId }),
  openPage: (m) => native("open_page", { page_id: m.pageId }),
};

browser.runtime.onMessage.addListener((message, sender) => {
  // Only this extension's own pages (the popover) may ask; content scripts and web pages can't.
  if (!sender || sender.id !== browser.runtime.id || sender.tab) return undefined;
  const handler = handlers[message && message.type];
  if (!handler) return undefined;
  return handler(message).then(
    (value) => ({ ok: true, value }),
    (e) => ({ ok: false, error: e.message || String(e), status: e.status || 0 }),
  );
});
