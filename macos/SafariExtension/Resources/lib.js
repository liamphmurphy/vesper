// Vesper for Safari: logic shared by the background script and the popover,
// kept free of browser APIs so tests/lib.test.cjs can run it under Node.
// The server enforces the same rules again (server/internal/browserext); this
// copy is what lets the popover dim the button before anything is sent.
"use strict";

(function (root) {
  /** Lower case, no "www.", no port, no trailing dot; null for anything that isn't a host. */
  function normalizeHost(raw) {
    let host = String(raw || "").trim().toLowerCase();
    if (!host) return null;
    if (host.includes("://")) {
      try {
        host = new URL(host).hostname;
      } catch {
        return null;
      }
    } else {
      host = host.replace(/:\d+$/, "");
    }
    host = host.replace(/^www\./, "").replace(/\.$/, "");
    if (!host || host.length > 253 || /[\/?#@\s\\]/.test(host)) return null;
    return host;
  }

  /** Whether host is entry or one of its subdomains. */
  function covered(host, entry) {
    return host === entry || host.endsWith("." + entry);
  }

  /**
   * Whether a tab's page may be shared, clipped or asked about. reason is a
   * sentence for the popover when it may not.
   */
  function shareablePage(url, incognito, neverShare) {
    if (incognito) return { ok: false, reason: "Private windows are never shared." };
    let u;
    try {
      u = new URL(url);
    } catch {
      return { ok: false, reason: "This isn't a web page." };
    }
    if (u.protocol !== "http:" && u.protocol !== "https:") return { ok: false, reason: "Only web pages can be shared." };
    if (u.username || u.password) return { ok: false, reason: "Addresses with a password in them are never shared." };
    const host = normalizeHost(u.hostname);
    if (!host) return { ok: false, reason: "This isn't a web page." };
    const lists = neverShare || { builtin: [], mine: [] };
    if ((lists.builtin || []).some((e) => covered(host, e))) return { ok: false, host, reason: `${host} is on Vesper's never-share list (passwords, sign-in and payments).` };
    if ((lists.mine || []).some((e) => covered(host, e))) return { ok: false, host, mine: true, reason: `You set ${host} to never share.` };
    return { ok: true, host };
  }

  /** Same page for a share "until you leave the page": equal but for the fragment. */
  function samePage(a, b) {
    try {
      const ua = new URL(a);
      const ub = new URL(b);
      ua.hash = "";
      ub.hash = "";
      return ua.href === ub.href;
    } catch {
      return false;
    }
  }

  function luhn(digits) {
    let sum = 0;
    for (let i = 0; i < digits.length; i++) {
      let d = digits.charCodeAt(digits.length - 1 - i) - 48;
      if (i % 2 === 1) {
        d *= 2;
        if (d > 9) d -= 9;
      }
      sum += d;
    }
    return sum % 10 === 0;
  }

  /** Replaces anything that looks like a payment card number (13–19 digits passing Luhn). */
  function redactCardNumbers(text) {
    return String(text).replace(/(?<![\d-])\d(?:[ -]?\d){12,18}(?![\d-])/g, (match) => {
      const digits = match.replace(/[ -]/g, "");
      return luhn(digits) ? "[card number removed]" : match;
    });
  }

  function defaultPersona(personas) {
    return (personas || []).find((p) => p.is_default) || (personas || [])[0] || null;
  }

  function personaNamed(personas, name) {
    const want = name.toLowerCase();
    return (personas || []).find((p) => p.name.trim().toLowerCase() === want) || null;
  }

  /**
   * The one-click actions for the site a tab is on. Each starts a Vesper chat
   * with its prompt (the page itself goes along as untrusted content).
   */
  function siteActions(url, personas) {
    let u;
    try {
      u = new URL(url);
    } catch {
      return [];
    }
    const host = u.hostname.replace(/^www\./, "");
    const fallback = defaultPersona(personas);
    const out = [];
    if (host === "github.com") {
      const m = u.pathname.match(/^\/[^/]+\/[^/]+\/(pull|issues)\/\d+(?:\/|$)/);
      if (m && m[1] === "pull") {
        const reviewer = personaNamed(personas, "Code Reviewer");
        out.push({
          id: "review-pr",
          label: reviewer ? `Review with ${reviewer.name}` : "Review this pull request",
          persona: reviewer || fallback,
          prompt: "Review this pull request: read it on GitHub, then give me your findings, most severe first.",
        });
        out.push({
          id: "ticket-from-pr",
          label: "Make a ticket from this",
          persona: fallback,
          prompt: "Make a Vesper ticket from this pull request: a clear title, what it changes and acceptance criteria. Ask me which project if it isn't clear.",
        });
      } else if (m) {
        out.push({
          id: "ticket-from-issue",
          label: "Make a ticket from this",
          persona: fallback,
          prompt: "Make a Vesper ticket from this GitHub issue: a clear title, the problem and acceptance criteria. Ask me which project if it isn't clear.",
        });
      }
    }
    const video = (host === "youtube.com" || host === "m.youtube.com") && u.pathname === "/watch" && u.searchParams.get("v");
    if (video || (host === "youtu.be" && u.pathname.length > 1)) {
      out.push({
        id: "video-notes",
        label: "Take notes on this video",
        persona: fallback,
        prompt: "Take notes on this video: read its transcript with get_video_transcript, then save the notes as a Knowledge source note for it.",
      });
    }
    return out;
  }

  /**
   * Runs inside the page (scripting.executeScript serializes it, so it must
   * use nothing from outside). Returns the readable text: visible text nodes
   * only, never form fields, editable regions, scripts or hidden elements.
   */
  function extractPage() {
    const SKIP = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "INPUT", "TEXTAREA", "SELECT", "OPTION", "BUTTON", "SVG", "CANVAS", "IFRAME", "OBJECT", "EMBED"]);
    const BLOCK = /^(ADDRESS|ARTICLE|ASIDE|BLOCKQUOTE|DD|DIV|DL|DT|FIGCAPTION|FIGURE|FOOTER|FORM|H[1-6]|HEADER|HR|LI|MAIN|NAV|OL|P|PRE|SECTION|TABLE|TR|UL|BR)$/;
    const hidden = (el) => {
      if (el.hidden || el.getAttribute("aria-hidden") === "true" || el.isContentEditable) return true;
      if (typeof el.checkVisibility === "function") return !el.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true });
      const s = getComputedStyle(el);
      return s.display === "none" || s.visibility === "hidden";
    };
    const parts = [];
    const walk = (node) => {
      for (let child = node.firstChild; child; child = child.nextSibling) {
        if (child.nodeType === Node.TEXT_NODE) {
          const t = child.nodeValue.replace(/\s+/g, " ");
          if (t.trim()) parts.push(t);
        } else if (child.nodeType === Node.ELEMENT_NODE) {
          if (SKIP.has(child.tagName.toUpperCase()) || hidden(child)) continue;
          const block = BLOCK.test(child.tagName.toUpperCase());
          if (block) parts.push("\n");
          walk(child.shadowRoot || child);
          if (block) parts.push("\n");
        }
      }
    };
    if (document.body) walk(document.body);
    const text = parts.join("").replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
    return { url: location.href, title: document.title || "", text: text.slice(0, 200000), selection: String(getSelection() || "").slice(0, 20000) };
  }

  const api = { normalizeHost, shareablePage, samePage, redactCardNumbers, siteActions, defaultPersona, extractPage };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.VesperExt = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
