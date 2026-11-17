(function () {
  const api = window.vesperDesktop;
  if (!api || !api.getLogs) return;

  const MAX_CHARS = 400000;
  const log = document.getElementById("log");
  const follow = document.getElementById("follow");
  const restart = document.getElementById("restart");

  function append(text) {
    log.textContent = (log.textContent + text).slice(-MAX_CHARS);
    if (follow.checked) log.scrollTop = log.scrollHeight;
  }

  function renderHealth(h) {
    if (!h) return;
    const dot = document.getElementById("health-dot");
    dot.className = "dot" + (h.phase === "running" || h.phase === "remote" ? " green" : h.phase === "error" || h.phase === "degraded" ? " red" : "");
    document.getElementById("health-title").textContent = h.title;
    const box = document.getElementById("health");
    const hasDetail = Boolean(h.message || h.nextStep);
    box.classList.toggle("hidden", !hasDetail);
    document.getElementById("health-message").textContent = h.message || "";
    document.getElementById("health-step").textContent = h.nextStep || "";
    restart.disabled = h.phase === "starting";
  }

  document.getElementById("copy").addEventListener("click", function () {
    void api.copyLogs();
  });
  document.getElementById("reveal").addEventListener("click", function () {
    void api.revealLogs();
  });
  restart.addEventListener("click", function () {
    restart.disabled = true;
    append("\n— Restarting the stack —\n");
    void api.restartStack();
  });

  void api.getLogs().then(function (res) {
    log.textContent = res.text || "No logs yet.\n";
    log.scrollTop = log.scrollHeight;
  });
  api.onStackLog(append);
  void api.getHealth().then(renderHealth);
  api.onHealth(renderHealth);
})();
