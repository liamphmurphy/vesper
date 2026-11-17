(function () {
  const api = window.vesperDesktop;
  if (!api || !api.getSendFiles) return;

  const files = document.getElementById("files");
  const target = document.getElementById("target");
  const persona = document.getElementById("persona");
  const personaField = document.getElementById("persona-field");
  const message = document.getElementById("message");
  const error = document.getElementById("error");
  const send = document.getElementById("send");

  function size(n) {
    if (n >= 1024 * 1024) return (n / 1024 / 1024).toFixed(1) + " MB";
    return Math.max(1, Math.round(n / 1024)) + " KB";
  }

  function row(name, detail, rejected) {
    const li = document.createElement("li");
    if (rejected) li.className = "rejected";
    const n = document.createElement("span");
    n.className = "name";
    n.textContent = name;
    const d = document.createElement("span");
    d.className = "muted small";
    d.textContent = detail;
    li.appendChild(n);
    li.appendChild(d);
    files.appendChild(li);
  }

  function option(select, value, label) {
    const o = document.createElement("option");
    o.value = value;
    o.textContent = label;
    select.appendChild(o);
  }

  target.addEventListener("change", function () {
    personaField.classList.toggle("hidden", target.value !== "new");
  });

  document.getElementById("cancel").addEventListener("click", function () {
    void api.closeWindow();
  });
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape") void api.closeWindow();
  });

  send.addEventListener("click", function () {
    error.textContent = "";
    send.disabled = true;
    send.textContent = "Uploading…";
    void api
      .submitSendFiles({ target: target.value, personaId: persona.value, message: message.value })
      .then(function (res) {
        if (!res || !res.ok) error.textContent = (res && res.error) || "Couldn't send the files.";
      })
      .finally(function () {
        send.disabled = false;
        send.textContent = "Send";
      });
  });

  void api.getSendFiles().then(function (data) {
    const accepted = data.files || [];
    accepted.forEach(function (f) {
      row(f.name, size(f.size), false);
    });
    (data.rejected || []).forEach(function (r) {
      row(r.name, r.reason, true);
    });
    document.getElementById("title").textContent =
      accepted.length === 1 ? "Send 1 file to a chat" : "Send " + accepted.length + " files to a chat";
    if (accepted.length === 0) {
      send.disabled = true;
      error.textContent = "None of these can be attached.";
    }
    option(target, "new", "New chat");
    (data.chats || []).forEach(function (c) {
      option(target, c.id, c.title || "Untitled chat");
    });
    option(persona, "", "Default persona");
    (data.personas || []).forEach(function (p) {
      option(persona, p.id, p.name);
    });
    if (data.defaultPersonaId) persona.value = data.defaultPersonaId;
  });
})();
