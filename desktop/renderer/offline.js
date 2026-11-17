(function () {
  const api = window.vesperDesktop;
  if (!api) return;

  const params = new URLSearchParams(window.location.search);
  const mode = params.get("mode");
  const isSettingsMode = mode === "settings";
  const isImportMode = mode === "import";

  const pageTitle = document.getElementById("page-title");
  const targetUrlEl = document.getElementById("target-url");
  const statusPill = document.getElementById("status-pill");
  const statusDot = document.getElementById("status-dot");
  const statusLabel = document.getElementById("status-label");
  const statusDetail = document.getElementById("status-detail");
  const connectionActions = document.getElementById("connection-actions");
  const retryBtn = document.getElementById("retry-btn");
  const openBtn = document.getElementById("open-btn");
  const urlForm = document.getElementById("url-form");
  const serverUrlInput = document.getElementById("server-url-input");
  const saveUrlBtn = document.getElementById("save-url-btn");
  const formError = document.getElementById("form-error");

  const importSection = document.getElementById("import-section");
  const backupPathInput = document.getElementById("backup-path-input");
  const browseBackupBtn = document.getElementById("browse-backup-btn");
  const backupSummary = document.getElementById("backup-summary");
  const importKeyOk = document.getElementById("import-key-ok");
  const importKeyOkText = document.getElementById("import-key-ok-text");
  const importKeyGroup = document.getElementById("import-key-group");
  const importSecretsKeyInput = document.getElementById("import-secrets-key-input");
  const importKeyHint = document.getElementById("import-key-hint");
  const importDropSecrets = document.getElementById("import-drop-secrets");
  const importError = document.getElementById("import-error");
  const runImportBtn = document.getElementById("run-import-btn");

  const dockerSection = document.getElementById("docker-section");
  const dockerBadge = document.getElementById("docker-badge");
  const checkoutPathInput = document.getElementById("checkout-path-input");
  const browseCheckoutBtn = document.getElementById("browse-checkout-btn");
  const startStackBtn = document.getElementById("start-stack-btn");
  const stackError = document.getElementById("stack-error");
  const stackLog = document.getElementById("stack-log");

  let inputDirty = false;
  let checkoutDirty = false;
  let pollTimer = null;
  let selectedInspection = null;

  if (isSettingsMode) {
    document.title = "Vesper Settings";
    pageTitle.textContent = "Vesper Server Settings";
  } else if (isImportMode) {
    document.title = "Import Vesper Backup";
    pageTitle.textContent = "Import Vesper Backup";
    targetUrlEl.textContent = "Replace local Postgres database & blobs from an export .zip or folder";
    statusPill.classList.add("hidden");
    statusDetail.classList.add("hidden");
    connectionActions.classList.add("hidden");
    urlForm.classList.add("hidden");
    dockerSection.classList.add("hidden");
    importSection.classList.remove("hidden");
  }

  function renderDocker(state) {
    if (!state.isLocalhost) {
      dockerSection.classList.add("hidden");
      return;
    }
    dockerSection.classList.remove("hidden");

    if (!checkoutDirty && state.localCheckoutPath && checkoutPathInput.value !== state.localCheckoutPath) {
      checkoutPathInput.value = state.localCheckoutPath;
    }

    const docker = state.docker;
    if (!docker) {
      dockerBadge.textContent = "Checking Docker…";
      dockerBadge.className = "docker-badge";
      startStackBtn.disabled = true;
    } else if (docker.available) {
      dockerBadge.textContent = docker.runtime === "orbstack" ? "OrbStack ready" : "Docker ready";
      dockerBadge.className = "docker-badge ready";
      startStackBtn.disabled = Boolean(state.stackStarting);
    } else {
      dockerBadge.textContent = "Docker / OrbStack not running";
      dockerBadge.className = "docker-badge";
      startStackBtn.disabled = true;
    }

    startStackBtn.textContent = state.stackStarting ? "Starting Stack…" : "Start Vesper Stack";
  }

  function renderState(state) {
    targetUrlEl.textContent = state.serverUrl;
    if (!inputDirty && serverUrlInput.value !== state.serverUrl) {
      serverUrlInput.value = state.serverUrl;
    }

    statusDot.className = "dot " + state.phase;
    if (state.phase === "checking") {
      statusLabel.textContent = "Checking server…";
      statusDetail.textContent = "Trying " + state.targetUrl + "…";
      retryBtn.disabled = true;
      openBtn.classList.add("hidden");
    } else if (state.phase === "reachable") {
      statusLabel.textContent = "Connected";
      statusDetail.textContent = isSettingsMode
        ? "Server is reachable at " + state.serverUrl + "."
        : "Vesper is reachable. Opening now…";
      retryBtn.disabled = false;
      if (isSettingsMode) {
        openBtn.classList.remove("hidden");
      } else {
        openBtn.classList.add("hidden");
        void api.openTarget();
      }
    } else {
      statusLabel.textContent = "Server unreachable";
      const reason = state.errorMessage ? " (" + state.errorMessage + ")" : "";
      statusDetail.textContent =
        "Could not reach " +
        state.serverUrl +
        reason +
        ". Make sure OrbStack / Docker Compose is running, or update the server URL below. Retrying automatically every 4s.";
      retryBtn.disabled = false;
      openBtn.classList.add("hidden");
    }

    renderDocker(state);
  }

  serverUrlInput.addEventListener("input", function () {
    inputDirty = true;
    formError.textContent = "";
  });

  checkoutPathInput.addEventListener("input", function () {
    checkoutDirty = true;
    stackError.textContent = "";
  });

  retryBtn.addEventListener("click", function () {
    void api.retryConnection().then(renderState);
  });

  openBtn.addEventListener("click", function () {
    void api.openTarget();
  });

  browseCheckoutBtn.addEventListener("click", function () {
    void api.pickCheckoutFolder().then(function (chosen) {
      if (chosen) {
        checkoutPathInput.value = chosen;
        checkoutDirty = false;
        stackError.textContent = "";
      }
    });
  });

  startStackBtn.addEventListener("click", function () {
    stackError.textContent = "";
    stackLog.textContent = "";
    stackLog.classList.remove("hidden");
    startStackBtn.disabled = true;
    void api.startLocalStack(checkoutPathInput.value).then(function (res) {
      if (!res.ok) {
        stackError.textContent = res.error || "Failed to start local stack.";
      }
      void api.retryConnection().then(renderState);
    });
  });

  urlForm.addEventListener("submit", function (event) {
    event.preventDefault();
    formError.textContent = "";
    saveUrlBtn.disabled = true;
    void api
      .setServerUrl({
        serverUrl: serverUrlInput.value,
        localCheckoutPath: checkoutPathInput.value,
      })
      .then(function (result) {
        if (!result.ok) {
          formError.textContent = result.error || "Invalid server URL.";
          return;
        }
        inputDirty = false;
        checkoutDirty = false;
        renderState(result.state);
      })
      .finally(function () {
        saveUrlBtn.disabled = false;
      });
  });

  function updateImportControls() {
    if (!isImportMode) return;
    if (!selectedInspection || !backupPathInput.value) {
      runImportBtn.disabled = true;
      return;
    }
    const noKeyRequired = !selectedInspection.secretsKeyFingerprint && selectedInspection.encryptedSecretRows === 0;
    if (noKeyRequired || selectedInspection.matchesCurrentKey) {
      runImportBtn.disabled = false;
      return;
    }
    importSecretsKeyInput.disabled = importDropSecrets.checked;
    runImportBtn.disabled = !importDropSecrets.checked && importSecretsKeyInput.value.trim().length === 0;
  }

  function renderImportInspection(res) {
    importError.textContent = "";
    selectedInspection = null;
    backupSummary.classList.add("hidden");
    importKeyOk.classList.add("hidden");
    importKeyGroup.classList.add("hidden");

    if (!res) {
      updateImportControls();
      return;
    }
    backupPathInput.value = res.archivePath || "";
    if (res.error || !res.inspection) {
      importError.textContent = res.error || "Could not inspect backup archive.";
      updateImportControls();
      return;
    }

    const insp = res.inspection;
    selectedInspection = insp;
    const exportedLabel = insp.exportedAt ? new Date(insp.exportedAt).toLocaleString() : "unknown time";
    backupSummary.textContent =
      "Exported " +
      exportedLabel +
      " · Schema v" +
      insp.schemaVersion +
      " · " +
      insp.tableCount +
      " tables (" +
      insp.totalRows +
      " rows) · " +
      insp.objectCount +
      " objects";
    backupSummary.classList.remove("hidden");

    const noKeyRequired = !insp.secretsKeyFingerprint && insp.encryptedSecretRows === 0;
    if (noKeyRequired) {
      importKeyOkText.textContent = "No SECRETS_KEY needed for this backup";
      importKeyOk.classList.remove("hidden");
    } else if (insp.matchesCurrentKey) {
      importKeyOkText.textContent = "Backup SECRETS_KEY matches this Mac's Keychain key";
      importKeyOk.classList.remove("hidden");
    } else {
      importDropSecrets.checked = false;
      importSecretsKeyInput.disabled = false;
      importKeyHint.textContent =
        "This archive holds encrypted logins or tokens (" +
        insp.encryptedSecretRows +
        " secret row(s)). Paste the source SECRETS_KEY to preserve them, or check below to clear them.";
      importKeyGroup.classList.remove("hidden");
    }
    updateImportControls();
  }

  if (isImportMode) {
    browseBackupBtn.addEventListener("click", function () {
      importError.textContent = "";
      void api.pickBackupArchive().then(function (res) {
        if (res) {
          renderImportInspection(res);
        }
      });
    });

    importSecretsKeyInput.addEventListener("input", function () {
      importError.textContent = "";
      updateImportControls();
    });

    importDropSecrets.addEventListener("change", function () {
      importError.textContent = "";
      updateImportControls();
    });

    runImportBtn.addEventListener("click", function () {
      if (!backupPathInput.value) return;
      importError.textContent = "";
      runImportBtn.disabled = true;
      browseBackupBtn.disabled = true;
      runImportBtn.textContent = "Importing Backup…";
      void api
        .importBackup({
          archivePath: backupPathInput.value,
          secretsKey: importDropSecrets.checked ? "" : importSecretsKeyInput.value.trim(),
          dropSecrets: importDropSecrets.checked,
        })
        .then(function (res) {
          if (!res.ok) {
            importError.textContent = res.error || "Import failed.";
            browseBackupBtn.disabled = false;
            runImportBtn.textContent = "Import Backup";
            updateImportControls();
          }
        })
        .catch(function (err) {
          importError.textContent = err && err.message ? err.message : String(err);
          browseBackupBtn.disabled = false;
          runImportBtn.textContent = "Import Backup";
          updateImportControls();
        });
    });
  }

  api.onStackLog(function (chunk) {
    stackLog.classList.remove("hidden");
    stackLog.textContent += chunk;
    stackLog.scrollTop = stackLog.scrollHeight;
  });

  if (!isImportMode) {
    api.onStateChange(renderState);

    void api.getState().then(function (state) {
      renderState(state);
      if (!isSettingsMode && state.phase === "unreachable") {
        void api.retryConnection().then(renderState);
      }
    });
  }

  if (!isSettingsMode && !isImportMode) {
    pollTimer = window.setInterval(function () {
      void api.retryConnection().then(renderState);
    }, 4000);
    window.addEventListener("beforeunload", function () {
      if (pollTimer !== null) window.clearInterval(pollTimer);
    });
  }
})();
