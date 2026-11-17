(function () {
  const api = window.vesperDesktop;
  if (!api || !api.getCaptureOptions) return;

  const PLACEHOLDERS = {
    note: "Capture a note to your Knowledge inbox…",
    message: "Message a persona; it starts a new chat…",
    ticket: "Ticket title on the first line, details below…",
  };
  const SUBMIT = { note: "Save", message: "Send", ticket: "Create Ticket" };

  let kind = "note";
  let busy = false;
  const text = document.getElementById("text");
  const persona = document.getElementById("persona");
  const project = document.getElementById("project");
  const error = document.getElementById("error");
  const submit = document.getElementById("submit");
  const openAfter = document.getElementById("open-after");

  function setKind(next) {
    kind = next;
    document.querySelectorAll("#kinds button").forEach(function (b) {
      b.setAttribute("aria-pressed", String(b.getAttribute("data-kind") === kind));
    });
    persona.classList.toggle("hidden", kind !== "message");
    project.classList.toggle("hidden", kind !== "ticket");
    text.placeholder = PLACEHOLDERS[kind];
    submit.firstChild.textContent = SUBMIT[kind] + " ";
    error.textContent = "";
    text.focus();
  }

  document.querySelectorAll("#kinds button").forEach(function (b) {
    b.addEventListener("click", function () {
      setKind(b.getAttribute("data-kind"));
    });
  });

  function option(select, value, label) {
    const o = document.createElement("option");
    o.value = value;
    o.textContent = label;
    select.appendChild(o);
  }

  function close() {
    // Esc closes without sending anything.
    void api.closeWindow();
  }

  function send() {
    if (busy) return;
    error.textContent = "";
    busy = true;
    submit.disabled = true;
    void api
      .submitCapture({ kind: kind, text: text.value, personaId: persona.value, projectKey: project.value, open: openAfter.checked })
      .then(function (res) {
        if (!res || !res.ok) error.textContent = (res && res.error) || "Couldn't save it.";
      })
      .catch(function () {
        error.textContent = "Couldn't reach Vesper.";
      })
      .finally(function () {
        busy = false;
        submit.disabled = false;
      });
  }

  submit.addEventListener("click", send);
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape") {
      e.preventDefault();
      close();
    } else if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
      e.preventDefault();
      send();
    } else if (e.metaKey && ["1", "2", "3"].includes(e.key)) {
      e.preventDefault();
      setKind(["note", "message", "ticket"][Number(e.key) - 1]);
    }
  });

  void api.getCaptureOptions().then(function (opts) {
    if (!opts.reachable) error.textContent = "Vesper isn't reachable right now; saving will fail until it is.";
    option(persona, "", "Default persona");
    (opts.personas || []).forEach(function (p) {
      option(persona, p.id, p.name);
    });
    if (opts.defaultPersonaId) persona.value = opts.defaultPersonaId;
    (opts.projects || []).forEach(function (p) {
      option(project, p.key, p.key + " · " + p.name);
    });
    if ((opts.projects || []).length === 0) option(project, "", "No projects");
  });

  setKind("note");
})();
