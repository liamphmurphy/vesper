(function () {
  const api = window.vesperDesktop;
  if (!api) return;

  const params = new URLSearchParams(window.location.search);
  const isSettingsMode = params.get("mode") === "settings";

  const pageTitle = document.getElementById("page-title");
  const targetUrlEl = document.getElementById("target-url");
  const statusDot = document.getElementById("status-dot");
  const statusLabel = document.getElementById("status-label");
  const statusDetail = document.getElementById("status-detail");
  const retryBtn = document.getElementById("retry-btn");
  const openBtn = document.getElementById("open-btn");
  const urlForm = document.getElementById("url-form");
  const serverUrlInput = document.getElementById("server-url-input");
  const saveUrlBtn = document.getElementById("save-url-btn");
  const formError = document.getElementById("form-error");

  let inputDirty = false;
  let pollTimer = null;

  if (isSettingsMode) {
    document.title = "Vesper Settings";
    pageTitle.textContent = "Vesper Server Settings";
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
  }

  serverUrlInput.addEventListener("input", function () {
    inputDirty = true;
    formError.textContent = "";
  });

  retryBtn.addEventListener("click", function () {
    void api.retryConnection().then(renderState);
  });

  openBtn.addEventListener("click", function () {
    void api.openTarget();
  });

  urlForm.addEventListener("submit", function (event) {
    event.preventDefault();
    formError.textContent = "";
    saveUrlBtn.disabled = true;
    void api
      .setServerUrl({ serverUrl: serverUrlInput.value })
      .then(function (result) {
        if (!result.ok) {
          formError.textContent = result.error || "Invalid server URL.";
          return;
        }
        inputDirty = false;
        renderState(result.state);
      })
      .finally(function () {
        saveUrlBtn.disabled = false;
      });
  });

  api.onStateChange(renderState);

  void api.getState().then(function (state) {
    renderState(state);
    if (!isSettingsMode && state.phase === "unreachable") {
      void api.retryConnection().then(renderState);
    }
  });

  if (!isSettingsMode) {
    pollTimer = window.setInterval(function () {
      void api.retryConnection().then(renderState);
    }, 4000);
    window.addEventListener("beforeunload", function () {
      if (pollTimer !== null) window.clearInterval(pollTimer);
    });
  }
})();
