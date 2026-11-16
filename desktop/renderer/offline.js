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

  if (isSettingsMode) {
    document.title = "Vesper Settings";
    pageTitle.textContent = "Vesper Server Settings";
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

  api.onStackLog(function (chunk) {
    stackLog.classList.remove("hidden");
    stackLog.textContent += chunk;
    stackLog.scrollTop = stackLog.scrollHeight;
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
