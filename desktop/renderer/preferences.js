(function () {
  const api = window.vesperDesktop;
  if (!api || !api.getPreferences) return;

  const KIND_LABELS = {
    approval: "Agent requests",
    question: "Agent questions",
    blocked: "Failed or blocked runs",
    stalled: "Stalled runs",
    mockup: "Mockups to review",
    planning: "Plans to approve",
    review: "Work ready for review",
    workflow_gate: "Workflow gates",
    connector_approval: "Connector tool calls",
    secret_approval: "Requests using a secret",
    merged: "Merged pull requests",
    pr_approved: "Approved pull requests",
    drive_backup: "Failed backups",
  };

  let state = null;
  const globalError = document.getElementById("global-error");

  function get(obj, key) {
    return key.split(".").reduce(function (o, k) {
      return o == null ? undefined : o[k];
    }, obj);
  }

  function patchFor(key, value) {
    const parts = key.split(".");
    const out = {};
    let cur = out;
    for (let i = 0; i < parts.length - 1; i++) {
      cur[parts[i]] = {};
      cur = cur[parts[i]];
    }
    cur[parts[parts.length - 1]] = value;
    return out;
  }

  function save(patch) {
    globalError.textContent = "";
    return api.setPreferences(patch).then(function (res) {
      if (res && res.state) {
        state = res.state;
        render();
      }
      if (res && !res.ok && res.error) {
        if (patch.quickCapture) {
          document.getElementById("shortcut-error").textContent = res.error;
        } else if (patch.screenshot) {
          document.getElementById("screenshot-error").textContent = res.error;
        } else if (patch.showHide) {
          document.getElementById("showhide-error").textContent = res.error;
        } else {
          globalError.textContent = res.error;
        }
      }
      return res;
    });
  }

  // Sections
  const navButtons = document.querySelectorAll("nav button[data-section]");
  navButtons.forEach(function (btn) {
    btn.addEventListener("click", function () {
      navButtons.forEach(function (b) {
        b.removeAttribute("aria-current");
      });
      btn.setAttribute("aria-current", "page");
      document.querySelectorAll("section[data-panel]").forEach(function (panel) {
        panel.classList.toggle("hidden", panel.getAttribute("data-panel") !== btn.getAttribute("data-section"));
      });
    });
  });

  // Notification kinds
  const kinds = document.getElementById("kinds");
  Object.keys(KIND_LABELS).forEach(function (kind) {
    const label = document.createElement("label");
    const input = document.createElement("input");
    input.type = "checkbox";
    input.setAttribute("data-key", "notifications.kinds." + kind);
    label.appendChild(input);
    label.appendChild(document.createTextNode(KIND_LABELS[kind]));
    kinds.appendChild(label);
  });

  // Switches and checkboxes
  document.querySelectorAll("input[type=checkbox][data-key]").forEach(function (input) {
    input.addEventListener("change", function () {
      void save(patchFor(input.getAttribute("data-key"), input.checked));
    });
  });

  // Segmented controls
  document.querySelectorAll(".segmented[data-key]").forEach(function (group) {
    group.querySelectorAll("button[data-value]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        void save(patchFor(group.getAttribute("data-key"), btn.getAttribute("data-value")));
      });
    });
  });

  // Quiet hours
  const quietStart = document.getElementById("quiet-start");
  const quietEnd = document.getElementById("quiet-end");
  function saveQuiet() {
    if (!quietStart.value || !quietEnd.value) return;
    void save({ notifications: { quietHours: { start: quietStart.value, end: quietEnd.value } } });
  }
  quietStart.addEventListener("change", saveQuiet);
  quietEnd.addEventListener("change", saveQuiet);

  // Disk threshold
  const minDisk = document.getElementById("min-disk");
  minDisk.addEventListener("change", function () {
    const n = Number(minDisk.value);
    if (Number.isFinite(n) && n >= 1 && n <= 1000) void save({ stack: { minFreeDiskGb: Math.round(n) } });
  });

  // Shortcut recorders (Quick Capture, Screenshot to Chat)
  const SYMBOLS = { Command: "⌘", Control: "⌃", Alt: "⌥", Shift: "⇧" };
  let recording = null;

  function keyName(e) {
    const code = e.code || "";
    if (/^Key[A-Z]$/.test(code)) return code.slice(3);
    if (/^Digit[0-9]$/.test(code)) return code.slice(5);
    if (/^F([1-9]|1[0-9]|2[0-4])$/.test(code)) return code;
    const named = {
      Space: "Space", Tab: "Tab", Backspace: "Backspace", Delete: "Delete", Enter: "Return", ArrowUp: "Up", ArrowDown: "Down",
      ArrowLeft: "Left", ArrowRight: "Right", Home: "Home", End: "End", PageUp: "PageUp", PageDown: "PageDown",
      Minus: "-", Equal: "=", BracketLeft: "[", BracketRight: "]", Semicolon: ";", Quote: "'", Comma: ",", Period: ".", Slash: "/", Backquote: "`",
    };
    return named[code] || null;
  }

  const ERROR_IDS = { quickCapture: "shortcut-error", screenshot: "screenshot-error", showHide: "showhide-error" };
  document.querySelectorAll("input.shortcut[data-shortcut]").forEach(function (input) {
    const key = input.getAttribute("data-shortcut");
    const errorEl = document.getElementById(ERROR_IDS[key]);
    input.addEventListener("focus", function () {
      recording = key;
      input.classList.add("recording");
      input.value = "Press keys…";
      errorEl.textContent = "";
    });
    input.addEventListener("blur", function () {
      recording = null;
      input.classList.remove("recording");
      render();
    });
    input.addEventListener("keydown", function (e) {
      if (recording !== key) return;
      e.preventDefault();
      if (e.key === "Escape") {
        input.blur();
        return;
      }
      const mods = [];
      if (e.metaKey) mods.push("Command");
      if (e.ctrlKey) mods.push("Control");
      if (e.altKey) mods.push("Alt");
      if (e.shiftKey) mods.push("Shift");
      const name = keyName(e);
      input.value =
        mods.map(function (m) {
          return SYMBOLS[m];
        }).join("") + (name || "…");
      if (!name) return;
      const patch = {};
      patch[key] = { shortcut: mods.concat([name]).join("+"), enabled: true };
      void save(patch).then(function (res) {
        if (res && res.ok) input.blur();
      });
    });
  });

  // Text settings: saved on change; the main process refuses invalid values, which then show as errors.
  const TEXT_ERRORS = {
    "workspaces.terminalApp": ["terminal-app-error", "Use an app name like Terminal or iTerm."],
    "workspaces.editor.command": ["editor-command-error", "Use plain words, like nvim or emacs -nw."],
    "workspaces.editor.app": ["editor-app-error", "Use an app name like Visual Studio Code."],
  };
  document.querySelectorAll("input[data-text-key]").forEach(function (input) {
    const key = input.getAttribute("data-text-key");
    input.addEventListener("change", function () {
      const typed = input.value.trim();
      const errorEl = document.getElementById(TEXT_ERRORS[key][0]);
      errorEl.textContent = "";
      void save(patchFor(key, typed)).then(function () {
        if (get(state.settings, key) !== typed) errorEl.textContent = TEXT_ERRORS[key][1];
      });
    });
  });

  // Backups
  document.getElementById("export-folder-btn").addEventListener("click", function () {
    void api.pickExportFolder().then(function (res) {
      if (res && res.state) {
        state = res.state;
        render();
      }
    });
  });
  document.getElementById("export-every").addEventListener("change", function (e) {
    void save({ backups: { export: { everyHours: Number(e.target.value) } } });
  });
  document.getElementById("export-keep").addEventListener("change", function (e) {
    const n = Number(e.target.value);
    if (Number.isInteger(n) && n >= 1 && n <= 100) void save({ backups: { export: { keep: n } } });
  });
  document.getElementById("export-now").addEventListener("click", function () {
    const btn = document.getElementById("export-now");
    const err = document.getElementById("export-error");
    btn.disabled = true;
    btn.textContent = "Exporting…";
    err.textContent = "";
    void api
      .exportNow()
      .then(function (res) {
        if (res && res.state) {
          state = res.state;
          render();
        }
        if (res && !res.ok) err.textContent = res.error || "The export failed.";
      })
      .finally(function () {
        btn.disabled = false;
        btn.textContent = "Export Now";
      });
  });

  // Buttons
  document.getElementById("server-btn").addEventListener("click", function () {
    void api.openServerSettings();
  });
  document.getElementById("test-notification").addEventListener("click", function () {
    void api.testNotification();
  });
  document.getElementById("logs-btn").addEventListener("click", function () {
    void api.openLogs();
  });
  document.getElementById("data-btn").addEventListener("click", function () {
    void api.openDataDir();
  });
  document.getElementById("services-btn").addEventListener("click", function () {
    const errEl = document.getElementById("services-error");
    errEl.textContent = "";
    void api.setQuickActionsInstalled(!state.status.servicesInstalled).then(function (res) {
      if (res && res.state) {
        state = res.state;
        render();
      }
      if (res && !res.ok) errEl.textContent = res.error || "Couldn't change the Quick Actions.";
    });
  });
  document.getElementById("touchid-test").addEventListener("click", function () {
    const el = document.getElementById("touchid-status");
    el.textContent = "";
    el.classList.remove("ok");
    void api.testTouchId().then(function (res) {
      el.textContent = res && res.ok ? "Touch ID works." : (res && res.error) || "Touch ID wasn't confirmed.";
      el.classList.toggle("ok", Boolean(res && res.ok));
    });
  });
  document.getElementById("update-check").addEventListener("click", function () {
    const el = document.getElementById("update-status");
    const btn = document.getElementById("update-check");
    btn.disabled = true;
    el.dataset.touched = "1";
    el.textContent = "Checking…";
    void api
      .checkForUpdates()
      .then(function (res) {
        if (!res) return;
        if (res.status === "available") el.textContent = "Vesper " + res.version + " is available. A notification has the download link.";
        else if (res.status === "error") el.textContent = "Couldn't check: " + (res.error || "unknown error");
        else el.textContent = "You have the newest version.";
      })
      .finally(function () {
        btn.disabled = false;
      });
  });

  function render() {
    if (!state) return;
    const s = state.settings;
    const st = state.status;
    document.getElementById("version").textContent = "Vesper " + st.appVersion;

    document.querySelectorAll("input[type=checkbox][data-key]").forEach(function (input) {
      input.checked = Boolean(get(s, input.getAttribute("data-key")));
    });
    document.querySelectorAll(".segmented[data-key]").forEach(function (group) {
      const value = get(s, group.getAttribute("data-key"));
      group.querySelectorAll("button[data-value]").forEach(function (btn) {
        btn.setAttribute("aria-pressed", String(btn.getAttribute("data-value") === value));
      });
    });
    document.querySelectorAll("[data-requires]").forEach(function (el) {
      const on = Boolean(get(s, el.getAttribute("data-requires")));
      el.classList.toggle("disabled", !on);
      el.querySelectorAll("input, button").forEach(function (c) {
        c.disabled = !on;
      });
    });
    document.querySelectorAll("[data-local-only]").forEach(function (el) {
      el.classList.toggle("hidden", !st.localStack);
    });

    const lastWindow = {
      dock: "Vesper stays in the Dock and keeps running, and so do your runs.",
      menuBar: "The Dock icon hides and Vesper keeps running in the menu bar.",
      quit: "Vesper quits and stops its stack (asking first if runs are working).",
    };
    document.getElementById("last-window-hint").textContent =
      lastWindow[s.tray.onLastWindowClose] + (s.tray.onLastWindowClose === "menuBar" && !s.tray.enabled ? " Needs the menu bar icon; stays in the Dock until it's on." : "");
    document.getElementById("login-status").textContent = st.login || "";
    document.getElementById("sleep-hint").textContent =
      s.power.onSleep === "pause"
        ? "Working ticket runs pause before sleep and pick up again after wake with “You were paused; continue.”"
        : "Runs are left as they are. A run working when the Mac sleeps may fail its turn if its network connection drops; retry it from the run page.";

    quietStart.value = s.notifications.quietHours.start;
    quietEnd.value = s.notifications.quietHours.end;
    quietStart.disabled = quietEnd.disabled = !s.notifications.enabled;
    minDisk.value = String(s.stack.minFreeDiskGb);
    document.getElementById("data-dir").textContent = st.dataDir;

    const shortcutInput = document.getElementById("shortcut-input");
    const screenshotInput = document.getElementById("screenshot-input");
    if (recording !== "quickCapture") shortcutInput.value = st.shortcutLabel;
    if (recording !== "screenshot") screenshotInput.value = st.screenshotLabel;
    if (recording !== "showHide") document.getElementById("showhide-input").value = st.showHideLabel;
    if (recording === null) {
      document.getElementById("shortcut-error").textContent = s.quickCapture.enabled && st.shortcut ? st.shortcut : "";
      document.getElementById("screenshot-error").textContent = s.screenshot.enabled && st.screenshot ? st.screenshot : "";
      document.getElementById("showhide-error").textContent = s.showHide.enabled && st.showHide ? st.showHide : "";
    }

    document.querySelectorAll("input[data-text-key]").forEach(function (input) {
      if (document.activeElement !== input) input.value = get(s, input.getAttribute("data-text-key"));
    });
    const appKind = s.workspaces.editor.kind === "app";
    document.getElementById("editor-command-row").classList.toggle("hidden", appKind);
    document.getElementById("editor-app-row").classList.toggle("hidden", !appKind);
    document.getElementById("editor-hint").textContent = appKind
      ? "Open in " + s.workspaces.editor.app + "."
      : "Open in " + s.workspaces.editor.command + " in Terminal.";

    document.getElementById("tm-status").textContent =
      st.timeMachineExcluded === true ? "Excluded now." : st.timeMachineExcluded === false ? "Not excluded yet (tmutil hasn't succeeded)." : "";
    document.getElementById("export-folder").textContent = s.backups.export.folder || "No folder chosen.";
    document.getElementById("export-every").value = String(s.backups.export.everyHours);
    document.getElementById("export-keep").value = String(s.backups.export.keep);
    document.getElementById("export-now").disabled = !s.backups.export.folder || st.exporting;
    document.getElementById("export-status").textContent = st.lastExportAt
      ? "Last export: " + new Date(st.lastExportAt).toLocaleString() + "."
      : "No export yet.";
    if (st.lastExportError) document.getElementById("export-error").textContent = "Last attempt failed: " + st.lastExportError;
    document.getElementById("easing-off").textContent = st.easingOff ? "Now: " + st.easingOff + "." : "";

    const servicesBtn = document.getElementById("services-btn");
    servicesBtn.textContent = st.servicesInstalled ? "Remove" : "Install";
    servicesBtn.disabled = !st.servicesAvailable;
    if (!st.servicesAvailable) document.getElementById("services-error").textContent = "Available in the packaged Vesper.app.";

    const touch = document.getElementById("touchid-status");
    if (!st.touchIdAvailable && !touch.classList.contains("ok")) {
      touch.textContent = "Touch ID isn't available on this Mac (no sensor, lid closed, or no fingerprints), so approvals work with a click as usual.";
    }
    document.getElementById("touchid-test").disabled = !st.touchIdAvailable;

    const last = st.lastUpdateCheckAt ? new Date(st.lastUpdateCheckAt).toLocaleString() : "never";
    const status = document.getElementById("update-status");
    if (!status.dataset.touched) status.textContent = "Last checked: " + last + ".";
  }

  void api.getPreferences().then(function (s) {
    state = s;
    render();
  });
})();
