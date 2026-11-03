(() => {
  const $ = (id) => document.getElementById(id);
  const inbox = $("wa-inbox"),
    connectionsRoot = $("wa-connections");
  if (!inbox && !connectionsRoot) return;
  const stateLabels = {
    connected: "Conectado",
    qr: "Escaneie o QR",
    connecting: "Conectando…",
    disconnected: "Desconectado",
    disconnecting: "Desconectando…",
    unavailable: "Sem comunicação com o provedor",
  };
  const messageLabels = {
    queued: "Na fila",
    sending: "Enviando…",
    uncertain: "Envio sem confirmação",
    failed: "Não enviada",
    sent: "Enviada",
    delivered: "Entregue",
    read: "Lida",
    received: "Recebida",
  };
  const el = (tag, text, cls) => {
    const n = document.createElement(tag);
    if (text !== undefined) n.textContent = text;
    if (cls) n.className = cls;
    return n;
  };
  const palette = ["#00a884", "#53bdeb", "#ff7c5c", "#a78bfa", "#f59e0b", "#ef4f8a", "#25a3a3", "#7c9cff"];
  const initials = (name) =>
    (name || "?")
      .replace(/[^\p{L}\p{N} ]/gu, "")
      .trim()
      .split(/\s+/)
      .slice(0, 2)
      .map((w) => w[0])
      .join("")
      .toUpperCase() || "#";
  const paintAvatar = (node, name) => {
    let h = 0;
    for (const ch of name || "") h = (h * 31 + ch.codePointAt(0)) >>> 0;
    node.textContent = initials(name);
    node.style.setProperty("--wa-avatar", palette[h % palette.length]);
    return node;
  };
  const sameDay = (a, b) => a.toDateString() === b.toDateString();
  const hour = (value) =>
    value
      ? new Date(value).toLocaleTimeString("pt-BR", { hour: "2-digit", minute: "2-digit" })
      : "";
  const dayLabel = (value) => {
    const d = new Date(value),
      today = new Date(),
      yesterday = new Date(Date.now() - 864e5);
    if (sameDay(d, today)) return "Hoje";
    if (sameDay(d, yesterday)) return "Ontem";
    return d.toLocaleDateString("pt-BR", { day: "2-digit", month: "2-digit", year: "numeric" });
  };
  const listTime = (value) => {
    if (!value) return "";
    const label = dayLabel(value);
    return label === "Hoje" ? hour(value) : label;
  };
  const ticks = {
    queued: "fas fa-clock",
    sending: "fas fa-clock",
    sent: "fas fa-check",
    delivered: "fas fa-check-double",
    read: "fas fa-check-double",
    uncertain: "fas fa-circle-question",
    failed: "fas fa-circle-exclamation",
  };
  const error = (msg) => {
    $("wa-error").textContent = msg;
    $("wa-error").hidden = !msg;
  };
  const date = (value) =>
    value
      ? new Date(value).toLocaleString("pt-BR", {
          day: "2-digit",
          month: "2-digit",
          hour: "2-digit",
          minute: "2-digit",
        })
      : "";
  async function api(path, options = {}) {
    const headers = {
      Accept: "application/json",
      "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')
        ?.content,
      ...options.headers,
    };
    let response;
    try {
      response = await fetch(path, {
        credentials: "same-origin",
        ...options,
        headers,
      });
    } catch (_) {
      throw new Error(
        "Sem comunicação com o Honey. Confira sua conexão e tente novamente.",
      );
    }
    if (response.redirected || [401, 403, 404].includes(response.status)) {
      if (inbox) {
        $("wa-messages").replaceChildren();
        $("wa-threads").replaceChildren();
        $("wa-contact-panel").hidden = true;
        $("wa-selected").hidden = true;
      }
      const failure = new Error(
        "Seu acesso mudou ou a sessão terminou. Entre novamente no Honey.",
      );
      failure.status = response.redirected ? 401 : response.status;
      throw failure;
    }
    const data = response.headers
      .get("content-type")
      ?.includes("application/json")
      ? await response.json()
      : {};
    if (!response.ok) {
      const failure = new Error(
        data.error ||
          "Não foi possível concluir. O conteúdo digitado foi preservado.",
      );
      failure.status = response.status;
      throw failure;
    }
    return data;
  }
  const json = (method, body) => ({
    method,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const safe =
    (fn) =>
    async (...args) => {
      try {
        await fn(...args);
      } catch (e) {
        error(e.message);
      }
    };
  let stopped = false;
  window.addEventListener("pagehide", () => {
    stopped = true;
    stopRecording();
  });
  function poll(fn, interval = 4000) {
    const tick = async () => {
      if (stopped) return;
      if (!document.hidden) await safe(fn)();
      setTimeout(tick, interval);
    };
    setTimeout(tick, interval);
  }
  let mediaRecorder, audioStream, recordedFile;
  function stopRecording() {
    if (mediaRecorder?.state === "recording") mediaRecorder.stop();
    audioStream?.getTracks().forEach((t) => t.stop());
  }

  if (connectionsRoot) {
    let cached = [];
    async function refresh() {
      const result = await api("/whatsapp/connections.json");
      cached = result.connections;
      const root = $("wa-number-cards");
      // Preserve edits and focus while an administrator changes the access list.
      if (root.querySelector("details[open]")) return;
      root.replaceChildren();
      cached.forEach((c) => {
        const card = el("article", undefined, `wa-number-card is-${c.state}`);
        const head = el("header", undefined, "wa-card-head");
        head.append(
          el("h3", c.name),
          el("span", stateLabels[c.state] || c.state, "wa-state"),
        );
        card.append(
          head,
          el(
            "p",
            c.phone || "Telefone ainda não confirmado pelo WhatsApp",
            "wa-card-phone",
          ),
        );
        if (c.qr && new Date(c.qr_expires_at) > new Date()) {
          const frame = el("div", undefined, "wa-qr-frame");
          const img = el("img");
          img.src = c.qr;
          img.alt = `QR para conectar ${c.name}`;
          frame.append(img, el("span", undefined, "wa-qr-scan"));
          card.append(
            frame,
            el(
              "p",
              "No celular: WhatsApp Business → Aparelhos conectados → Conectar aparelho.",
              "wa-qr-help",
            ),
          );
          const expiry = el(
            "small",
            "O QR é temporário. Um novo aparecerá quando o WhatsApp renovar.",
          );
          card.append(expiry);
          setTimeout(
            () => {
              frame.remove();
              expiry.textContent =
                "QR expirado. Aguardando renovação; se necessário, clique em Conectar.";
            },
            Math.max(0, new Date(c.qr_expires_at) - Date.now()),
          );
        }
        if (c.error_code)
          card.append(
            el(
              "p",
              "Não foi possível concluir a comunicação. Verifique o serviço e tente conectar novamente.",
              "wa-send-warning",
            ),
          );
        card.append(
          el(
            "small",
            `Última atualização: ${date(c.provider_updated_at) || "aguardando"} · Sincronização: ${date(c.last_synced_at) || "aguardando"}`,
          ),
        );
        const actions = el("div", undefined, "wa-card-actions");
        card.append(actions);
        ["connect", "sync", "disconnect"].forEach((action) => {
          const labels = {
            connect:
              c.state === "connected" ? "Reconectar" : "Conectar / renovar QR",
            sync: "Sincronizar",
            disconnect: "Desconectar",
          };
          const b = el(
            "button",
            labels[action],
            "btn btn-sm btn-outline-secondary",
          );
          b.type = "button";
          b.onclick = safe(async () => {
            if (
              action === "disconnect" &&
              !confirm(`Desconectar ${c.name}? O histórico será mantido.`)
            )
              return;
            b.disabled = true;
            await api(
              `/whatsapp/connections/${c.id}/${action}`,
              json("POST", {}),
            );
            await refresh();
          });
          actions.append(b);
        });
        const settings = el("details");
        settings.append(el("summary", "Nome e pessoas autorizadas"));
        const form = el("form"),
          name = el("input", undefined, "form-control");
        name.value = c.name;
        name.maxLength = 80;
        name.required = true;
        name.setAttribute("aria-label", "Nome do número");
        const people = el("fieldset");
        people.append($("wa-user-options").content.cloneNode(true));
        people.querySelectorAll("input").forEach((input) => {
          input.checked = c.user_ids.includes(Number(input.value));
        });
        const save = el("button", "Salvar acesso", "btn btn-sm btn-success");
        form.append(name, people, save);
        form.onsubmit = safe(async (e) => {
          e.preventDefault();
          await api(
            `/whatsapp/connections/${c.id}`,
            json("PATCH", {
              name: name.value,
              user_ids: Array.from(
                people.querySelectorAll("input:checked"),
              ).map((x) => x.value),
            }),
          );
          await refresh();
        });
        settings.append(form);
        card.append(settings);
        root.append(card);
      });
      if (!cached.length)
        root.append(
          el(
            "p",
            "Nenhum número conectado ainda. Siga os 3 passos acima para adicionar o primeiro.",
            "wa-empty",
          ),
        );
    }
    $("wa-add-number").onsubmit = safe(async (e) => {
      e.preventDefault();
      const b = e.target.querySelector("button");
      b.disabled = true;
      try {
        await api("/whatsapp/connections", {
          method: "POST",
          body: new FormData(e.target),
        });
        e.target.reset();
        await refresh();
      } finally {
        b.disabled = false;
      }
    });
    safe(refresh)();
    poll(refresh);
    return;
  }

  let selected,
    generation = 0,
    messages = new Map(),
    before,
    afterId = 0,
    numbers = [],
    listPage = 1,
    draftNonce,
    draftRequest,
    busy = false;
  const drafts = new Map(); // Memory only: never store customer text in localStorage.
  const history = $("wa-history");
  const nearBottom = () =>
    history.scrollHeight - history.scrollTop - history.clientHeight < 100;
  const scrollBottom = () => {
    history.scrollTop = history.scrollHeight;
    $("wa-new-indicator").hidden = true;
  };
  function saveDraft() {
    if (selected)
      drafts.set(selected.id, {
        text: $("wa-text").value,
        file: recordedFile || $("wa-file").files[0],
        nonce: draftNonce,
        request: draftRequest,
      });
  }
  function setFiles(file) {
    recordedFile = file;
    $("wa-file").value = "";
    $("wa-file-name").textContent = file?.name || "";
    $("wa-clear-file").hidden = !file;
  }
  function lockDraft(locked) {
    $("wa-text").readOnly = locked;
    ["wa-file", "wa-clear-file", "wa-record"].forEach((id) => {
      $(id).disabled = locked;
    });
  }
  async function refreshList(append = false) {
    const p = new URLSearchParams({
      q: $("wa-search").value,
      connection_id: $("wa-number").value,
      state: $("wa-state").value,
      mine: $("wa-mine").checked ? "1" : "",
      unread: $("wa-unread").checked ? "1" : "",
      human: $("wa-human").checked ? "1" : "",
      page: listPage,
    });
    const result = await api(`/whatsapp/conversations.json?${p}`);
    numbers = result.connections;
    renderTabs();
    if (!append) $("wa-threads").replaceChildren();
    result.conversations.forEach((c) => {
      const button = el(
        "button",
        undefined,
        `wa-thread ${selected?.id === c.id ? "selected" : ""}`,
      );
      button.type = "button";
      if (c.unread_count) button.classList.add("has-unread");
      const body = el("span", undefined, "wa-thread-body"),
        top = el("span", undefined, "wa-thread-top"),
        bottom = el("span", undefined, "wa-thread-bottom");
      top.append(el("strong", c.name), el("time", listTime(c.last_message_at)));
      bottom.append(el("small", c.last_message_preview || c.phone || "Sem mensagens"));
      if (c.unread_count) bottom.append(el("span", c.unread_count, "wa-badge"));
      const foot = el("em", undefined, "wa-thread-number");
      foot.append(el("span", c.stage_label, `wa-stage is-${c.stage}`), document.createTextNode(c.connection_name));
      if (c.needs_human) {
        const h = el("span", " Precisa de você", "wa-human-flag");
        h.prepend(el("i", undefined, "fas fa-robot"));
        foot.append(h);
      } else if (c.has_draft) {
        const d = el("span", " Sugestão pronta", "wa-draft-flag");
        d.prepend(el("i", undefined, "fas fa-wand-magic-sparkles"));
        foot.append(d);
      }
      body.append(top, bottom, foot);
      button.append(paintAvatar(el("span", undefined, "wa-avatar"), c.name), body);
      button.onclick = safe(() => selectConversation(c.id));
      // Finalizar (ou reabrir) direto da lista, sem abrir a conversa.
      const row = el("div", undefined, "wa-thread-row");
      const closed = c.state === "closed";
      const quick = el("button", undefined, `wa-thread-finish${closed ? " is-closed" : ""}`);
      quick.type = "button";
      quick.title = closed ? "Reabrir conversa" : "Marcar como finalizada";
      quick.setAttribute("aria-label", `${quick.title}: ${c.name}`);
      quick.append(el("i", undefined, closed ? "fas fa-rotate-left" : "fas fa-check"));
      quick.onclick = safe(async (e) => {
        e.stopPropagation();
        quick.disabled = true;
        await api(`/whatsapp/conversations/${c.id}`, json("PATCH", { operation: closed ? "reopen" : "close" }));
        row.classList.add("is-leaving");
        if (selected?.id === c.id) await refreshSelected();
        await refreshList();
      });
      row.append(button, quick);
      $("wa-threads").append(row);
    });
    if (!result.conversations.length && !append)
      $("wa-threads").append(
        el(
          "p",
          numbers.length
            ? "Nenhuma conversa para este filtro."
            : "Nenhum número autorizado. Peça acesso à administração.",
          "wa-empty",
        ),
      );
    $("wa-more-conversations").hidden = !result.more;
  }
  function renderHeader(c) {
    selected = c;
    $("wa-contact-name").textContent = c.name;
    paintAvatar($("wa-contact-avatar"), c.name);
    paintAvatar($("wa-contact-avatar-lg"), c.name);
    $("wa-company-number").textContent =
      `Pelo número ${c.connection_name}${c.connection_phone ? " · " + c.connection_phone : ""} · ${stateLabels[c.connection_state] || c.connection_state}`;
    $("wa-owner").textContent =
      `${c.stage_label} · Responsável: ${c.assignee_name || "ninguém"}`;
    $("wa-close").replaceChildren(
      el("i", undefined, c.state === "closed" ? "fas fa-rotate-left" : "fas fa-circle-check"),
      document.createTextNode(c.state === "closed" ? " Reabrir" : " Finalizar"),
    );
    $("wa-close").classList.toggle("is-finish", c.state !== "closed");
    // Modo conversa: a equipe conversa com a cliente e o agente não lê nem responde.
    const mode = $("wa-mode");
    mode.hidden = !c.automation || c.state === "closed";
    mode.classList.toggle("is-on", !!c.agent_paused);
    mode.setAttribute("aria-pressed", c.agent_paused ? "true" : "false");
    mode.title = c.agent_paused ? "Voltar a deixar o agente responder" : "Conversar você mesmo, sem o agente";
    mode.replaceChildren(
      el("i", undefined, c.agent_paused ? "fas fa-comments" : "fas fa-robot"),
      document.createTextNode(c.agent_paused ? " Modo conversa ligado" : " Modo conversa"),
    );
    renderAgent(c);
    const oldAssignee = $("wa-assignee").value;
    $("wa-assignee").replaceChildren(new Option("Transferir para…", ""));
    c.assignees?.forEach((u) => $("wa-assignee").add(new Option(u.name, u.id)));
    $("wa-assignee").value = oldAssignee;
    $("wa-contact-phone").textContent =
      c.phone || "Telefone ainda não informado pelo WhatsApp";
    $("wa-linked").replaceChildren();
    if (c.customer) {
      $("wa-linked").append(
        el("strong", c.customer.name),
        el("p", c.customer.phone || ""),
      );
      if (c.orders_url) {
        const a = el("a", "Ver pedidos no Honey");
        a.href = c.orders_url;
        a.target = "_blank";
        a.rel = "noopener";
        $("wa-linked").append(a);
      }
    }
    $("wa-customer-picker").hidden = !c.can_link_customer;
    $("wa-send").disabled = busy || c.connection_state !== "connected";
  }
  function renderMessages(rows, { older = false } = {}) {
    const wasBottom = nearBottom(),
      oldHeight = history.scrollHeight,
      oldTop = history.scrollTop;
    rows.forEach((m) => {
      messages.set(m.id, m);
    });
    // Existing elements are retained unless their message changed; audio playback isn't reset by polling.
    const container = $("wa-messages");
    let lastDay = null,
      lastDirection = null;
    [...messages.values()]
      .sort((a, b) => new Date(a.sent_at) - new Date(b.sent_at) || a.id - b.id)
      .forEach((m, index) => {
        let node = document.getElementById(`wa-message-${m.id}`);
        const signature = JSON.stringify(m);
        if (!node || node.dataset.signature !== signature) {
          const row = el("article", undefined, `wa-message ${m.direction}`);
          row.id = `wa-message-${m.id}`;
          row.dataset.signature = signature;
          const next = el("div", undefined, `wa-bubble is-${m.state}`);
          row.append(next);
          if (m.by_agent) next.classList.add("by-agent");
          if (m.author && m.direction === "outgoing")
            next.append(el("span", m.by_agent ? `🤖 ${m.author}` : m.author, "wa-author"));
          if (m.body) next.append(el("p", m.body));
          if (m.media_url) {
            if (m.kind === "image") {
              const image = el("img");
              image.src = m.media_url;
              image.alt = m.filename || "Imagem recebida";
              image.loading = "lazy";
              next.append(image);
            } else if (m.kind === "audio") {
              const audio = el("audio");
              audio.src = m.media_url;
              audio.controls = true;
              audio.preload = "none";
              next.append(audio);
            }
            const link = el("a", m.filename || "Baixar arquivo");
            link.href = m.media_url;
            link.download = m.filename || "";
            next.append(link);
          } else if (m.media_state)
            next.append(
              el(
                "p",
                {
                  pending: "Carregando arquivo…",
                  rejected: "Arquivo não permitido ou acima de 10 MB.",
                  unavailable: "Arquivo indisponível no provedor.",
                }[m.media_state] || "Arquivo indisponível.",
              ),
            );
          if (m.kind === "unsupported")
            next.append(
              el("p", "Este tipo de mensagem pode ser consultado no celular."),
            );
          const meta = el("small", undefined, "wa-meta");
          meta.title = `${date(m.sent_at)} · ${messageLabels[m.state] || m.state}`;
          meta.append(el("time", hour(m.sent_at)));
          if (m.direction === "outgoing" && ticks[m.state]) {
            const tick = el("i", undefined, `${ticks[m.state]} wa-tick is-${m.state}`);
            tick.setAttribute("aria-hidden", "true");
            meta.append(tick);
          }
          meta.append(el("span", messageLabels[m.state] || m.state, "visually-hidden"));
          next.append(meta);
          if (["failed", "uncertain"].includes(m.state)) {
            next.append(
              el(
                "p",
                m.state === "uncertain"
                  ? "O WhatsApp pode ter recebido este envio. Confira no celular antes de enviar novamente. Não houve repetição automática."
                  : "O envio não começou. O texto e o arquivo continuam disponíveis abaixo.",
                "wa-send-warning",
              ),
            );
            const restore = el(
              "button",
              "Copiar texto para o campo",
              "btn btn-sm btn-light",
            );
            restore.onclick = () => {
              if (draftRequest) {
                error(
                  "Consulte o envio pendente clicando em Enviar antes de alterar o rascunho.",
                );
                return;
              }
              if (
                !$("wa-text").value ||
                confirm("Substituir o texto atual pelo desta mensagem?")
              ) {
                $("wa-text").value = m.body || "";
                grow();
                draftNonce = null;
              }
            };
            next.append(restore);
            if (m.state === "failed") {
              const retry = el(
                "button",
                "Tentar enviar",
                "btn btn-sm btn-outline-secondary",
              );
              retry.onclick = safe(async () => {
                await api(
                  `/whatsapp/conversations/${selected.id}/messages/${m.id}/retry_send`,
                  json("POST", {}),
                );
                await refreshSelected();
              });
              next.append(retry);
            }
          }
          if (node) node.replaceWith(row);
          node = row;
        }
        const current = container.children[index];
        if (current !== node) container.insertBefore(node, current || null);
        // Separador de dia, como no WhatsApp: só na primeira mensagem de cada dia.
        const label = dayLabel(m.sent_at);
        if (label === lastDay) delete node.dataset.day;
        else node.dataset.day = label;
        // A "pontinha" do balão só aparece na primeira mensagem de uma sequência.
        node.classList.toggle("wa-first", label !== lastDay || m.direction !== lastDirection);
        lastDay = label;
        lastDirection = m.direction;
      });
    if (older) history.scrollTop = oldTop + (history.scrollHeight - oldHeight);
    else if (wasBottom) scrollBottom();
    else if (rows.some((m) => m.id > afterId))
      $("wa-new-indicator").hidden = false;
  }
  async function selectConversation(id) {
    if (busy) return;
    saveDraft();
    stopRecording();
    const ticket = ++generation;
    const c = await api(`/whatsapp/conversations/${id}.json`);
    if (ticket !== generation) return;
    messages = new Map();
    $("wa-messages").replaceChildren();
    renderHeader(c);
    $("wa-empty").hidden = true;
    $("wa-selected").hidden = false;
    $("wa-contact-panel").hidden = true;
    document.querySelector(".wa-workspace").classList.add("chat-open");
    const draft = drafts.get(id);
    fromDraft = false;
    agentSignature = "";
    $("wa-text").value = draft?.text || "";
    grow();
    setFiles(draft?.file);
    draftNonce = draft?.nonce;
    draftRequest = draft?.request || null;
    lockDraft(!!draftRequest);
    const result = await api(`/whatsapp/conversations/${id}/messages.json`);
    if (ticket !== generation) return;
    before = result.before;
    afterId = result.after_id;
    renderMessages(result.messages);
    $("wa-older").hidden = !before;
    scrollBottom();
    await markRead();
  }
  async function markRead() {
    if (selected && !document.hidden && nearBottom())
      await api(
        `/whatsapp/conversations/${selected.id}/read`,
        json("POST", { last_message_id: afterId }),
      );
  }
  async function refreshSelected() {
    if (!selected) return;
    const id = selected.id,
      ticket = generation;
    const ids = [...messages.keys()].slice(-200);
    const p = new URLSearchParams({ after_id: afterId });
    ids.forEach((i) => p.append("ids[]", i));
    const result = await api(
      `/whatsapp/conversations/${id}/messages.json?${p}`,
    );
    if (ticket !== generation) return;
    renderMessages(result.messages);
    afterId = result.after_id;
    const c = await api(`/whatsapp/conversations/${id}.json`);
    if (ticket !== generation) return;
    renderHeader(c);
    await markRead();
  }
  $("wa-older").onclick = safe(async () => {
    if (!before || !selected) return;
    const ticket = generation;
    const result = await api(
      `/whatsapp/conversations/${selected.id}/messages.json?before=${encodeURIComponent(before)}`,
    );
    if (ticket !== generation) return;
    renderMessages(result.messages, { older: true });
    before = result.before;
    $("wa-older").hidden = !before;
  });
  $("wa-new-indicator").onclick = safe(async () => {
    scrollBottom();
    await markRead();
  });
  $("wa-back").onclick = () => {
    document.querySelector(".wa-workspace").classList.remove("chat-open");
  };
  $("wa-contact-toggle").onclick = safe(async () => {
    $("wa-contact-panel").hidden = !$("wa-contact-panel").hidden;
    $("wa-contact-toggle").setAttribute(
      "aria-expanded",
      !$("wa-contact-panel").hidden,
    );
    if (!$("wa-contact-panel").hidden && selected.can_link_customer)
      await findCustomers();
  });
  $("wa-contact-hide").onclick = () => {
    $("wa-contact-panel").hidden = true;
    $("wa-contact-toggle").setAttribute("aria-expanded", "false");
  };
  async function action(operation, extra = {}) {
    if (!selected) return;
    const c = await api(
      `/whatsapp/conversations/${selected.id}`,
      json("PATCH", { operation, ...extra }),
    );
    renderHeader(c);
    await refreshList();
  }
  $("wa-take").onclick = safe(() => action("take"));
  $("wa-mode").onclick = safe(() => action(selected?.agent_paused ? "resume_agent" : "pause_agent"));
  $("wa-transfer").onclick = safe(() => {
    if (!$("wa-assignee").value)
      throw new Error("Escolha uma pessoa para transferir.");
    return action("transfer", { assignee_id: $("wa-assignee").value });
  });
  $("wa-close").onclick = safe(() =>
    action(selected.state === "closed" ? "reopen" : "close"),
  );
  async function findCustomers() {
    const id = selected.id;
    const result = await api(
      `/whatsapp/conversations/${id}/customers?q=${encodeURIComponent($("wa-customer-search").value)}`,
    );
    if (selected.id !== id) return;
    $("wa-customer-results").replaceChildren();
    result.customers.forEach((c) => {
      const b = el(
        "button",
        `${c.name} · ${c.phone || "Sem telefone"}`,
        "btn btn-light wa-customer-option",
      );
      b.onclick = safe(async () => {
        const data = await api(
          `/whatsapp/conversations/${id}/link_customer`,
          json("PATCH", { customer_id: c.id }),
        );
        renderHeader(data);
      });
      $("wa-customer-results").append(b);
    });
    if (!result.customers.length)
      $("wa-customer-results").append(
        el(
          "p",
          "Nenhum cadastro encontrado. A conversa pode continuar normalmente.",
        ),
      );
  }
  $("wa-customer-find").onclick = safe(findCustomers);
  $("wa-file").onchange = () => {
    recordedFile = null;
    const file = $("wa-file").files[0];
    $("wa-file-name").textContent = file?.name || "";
    $("wa-clear-file").hidden = !file;
    draftNonce = null;
  };
  $("wa-clear-file").onclick = () => {
    setFiles(null);
    draftNonce = null;
  };
  $("wa-text").oninput = () => {
    if (!draftRequest) draftNonce = null;
  };
  $("wa-compose").onsubmit = safe(async (e) => {
    e.preventDefault();
    if (busy || !selected) return;
    if (mediaRecorder?.state === "recording")
      throw new Error("Pare a gravação antes de enviar.");
    const file = recordedFile || $("wa-file").files[0];
    if (file?.size > 10 * 1024 * 1024)
      throw new Error("O arquivo deve ter até 10 MB.");
    if (!$("wa-text").value.trim() && !file) return;
    const id = selected.id;
    // Keep the exact request and nonce if the browser loses the response. No duplicate submit.
    if (!draftRequest) {
      draftNonce ||= crypto.randomUUID();
      const form = new FormData();
      form.set("client_nonce", draftNonce);
      form.set("body", $("wa-text").value);
      form.set("from_draft", fromDraft ? "1" : "0");
      if (file) form.set("file", file);
      draftRequest = form;
    }
    busy = true;
    $("wa-send").disabled = true;
    lockDraft(true);
    try {
      const message = await api(`/whatsapp/conversations/${id}/messages`, {
        method: "POST",
        body: draftRequest,
      });
      renderMessages([message]);
      $("wa-text").value = "";
    grow();
      setFiles(null);
      draftNonce = null;
      draftRequest = null;
      lockDraft(false);
      drafts.delete(id);
      fromDraft = false;
      error("");
      refreshSelected().catch(() => {});
      scrollBottom();
    } catch (failure) {
      if (failure.status && failure.status < 500) {
        draftRequest = null;
        draftNonce = null;
        lockDraft(false);
      } else {
        failure = new Error(
          "A resposta do Honey não chegou. Clique em Enviar novamente para consultar o mesmo envio, sem duplicar.",
        );
      }
      throw failure;
    } finally {
      busy = false;
      $("wa-send").disabled = selected?.connection_state !== "connected";
    }
  });
  const mime =
    window.MediaRecorder &&
    ["audio/webm;codecs=opus", "audio/ogg;codecs=opus", "audio/mp4"].find((t) =>
      MediaRecorder.isTypeSupported(t),
    );
  $("wa-record").hidden = !mime || !navigator.mediaDevices?.getUserMedia;
  $("wa-record").onclick = safe(async () => {
    if (mediaRecorder?.state === "recording") {
      stopRecording();
      return;
    }
    audioStream = await navigator.mediaDevices.getUserMedia({ audio: true });
    const chunks = [],
      id = selected?.id;
    mediaRecorder = new MediaRecorder(audioStream, { mimeType: mime });
    mediaRecorder.ondataavailable = (e) => {
      if (e.data.size) chunks.push(e.data);
    };
    mediaRecorder.onstop = () => {
      audioStream.getTracks().forEach((t) => t.stop());
      setRecording(false);
      if (selected?.id === id) {
        setFiles(
          new File(
            chunks,
            `audio.${mime.includes("ogg") ? "ogg" : mime.includes("mp4") ? "m4a" : "webm"}`,
            { type: mime },
          ),
        );
        draftNonce = null;
      }
    };
    mediaRecorder.start();
    setRecording(true);
    setTimeout(stopRecording, 60000);
  });
  // Barra do agente: sugestão para aprovar, "não sei o que fazer", pausa e pedido de sugestão.
  let fromDraft = false,
    agentSignature = "";
  function renderAgent(c) {
    const box = $("wa-agent");
    const signature = JSON.stringify([c.id, c.automation, c.agent_draft, c.agent_draft_finish, c.needs_human, c.agent_paused, c.agent_note, c.state]);
    if (signature === agentSignature) return;
    agentSignature = signature;
    box.replaceChildren();
    box.className = "wa-agent";
    if (!c.automation || c.state === "closed") {
      box.hidden = true;
      return;
    }
    box.hidden = false;
    const head = el("div", undefined, "wa-agent-head");
    const bot = el("span", undefined, "wa-agent-bot");
    bot.append(el("i", undefined, "fas fa-robot"));
    head.append(bot, el("strong", c.automation.name), el("small", c.automation.mode_label));
    box.append(head);
    const actions = el("div", undefined, "wa-agent-actions");
    const btn = (label, icon, cls, fn) => {
      const b = el("button", undefined, cls);
      b.type = "button";
      if (icon) b.append(el("i", undefined, icon));
      b.append(document.createTextNode(label));
      b.onclick = safe(fn);
      actions.append(b);
      return b;
    };
    const act = (operation) => action(operation).then(() => refreshSelected());
    if (c.agent_draft !== null && c.agent_draft !== undefined) {
      box.classList.add("is-draft");
      if (c.agent_draft) {
        box.append(el("p", c.agent_draft, "wa-agent-text"));
        btn(c.agent_draft_finish ? " Enviar e finalizar" : " Enviar", "fas fa-paper-plane", "wa-agent-send", () => {
          $("wa-text").value = c.agent_draft;
          fromDraft = true;
          grow();
          $("wa-compose").requestSubmit();
        });
        btn(" Editar", "fas fa-pen", "wa-pill", () => {
          $("wa-text").value = c.agent_draft;
          fromDraft = true;
          grow();
          $("wa-text").focus();
        });
      } else {
        box.append(el("p", "O agente sugere finalizar esta conversa.", "wa-agent-text"));
        btn(" Finalizar", "fas fa-check", "wa-agent-send", () => act("close"));
      }
      btn(" Descartar", "fas fa-xmark", "wa-pill", () => act("discard_draft"));
    } else if (c.needs_human) {
      box.classList.add("is-unsure");
      box.append(el("p", c.agent_note || "Não sei o que fazer neste caso.", "wa-agent-text"));
      if (c.automation.url) {
        const a = el("a", undefined, "wa-agent-send");
        a.href = `${c.automation.url}#falta-ensinar`;
        a.append(el("i", undefined, "fas fa-graduation-cap"), document.createTextNode(" Ensinar o agente"));
        actions.append(a);
      }
      btn(" Já resolvi", "fas fa-check", "wa-pill", () => act("resolve_human"));
      btn(" Tentar de novo", "fas fa-rotate", "wa-pill", () => act("ask_agent"));
    } else if (c.agent_paused) {
      box.classList.add("is-paused");
      box.append(el("p", "Modo conversa ligado: o agente não lê nem responde esta conversa enquanto você atende.", "wa-agent-text"));
      btn(" Voltar para o agente", "fas fa-robot", "wa-pill", () => act("resume_agent"));
      btn(" Pedir sugestão", "fas fa-wand-magic-sparkles", "wa-pill", () => act("ask_agent"));
    } else {
      box.classList.add("is-idle");
      box.append(
        el("p", c.agent_note || (c.automation.mode === "auto" ? "O agente responde sozinho nesta conversa." : "O agente sugere uma resposta quando a cliente escrever."), "wa-agent-text"),
      );
      if (c.agent_note === "Pensando numa resposta…") box.classList.add("is-thinking");
      btn(" Pedir sugestão", "fas fa-wand-magic-sparkles", "wa-pill", () => act("ask_agent"));
      btn(" Modo conversa", "fas fa-comments", "wa-pill", () => act("pause_agent"));
    }
    box.append(actions);
  }
  // Uma aba para cada número conectado: a lista carrega só as conversas do número aberto.
  const tabsRoot = $("wa-number-tabs");
  const tabButtons = () => [...tabsRoot.querySelectorAll(".wa-number-tab")];
  function setNumber(id) {
    $("wa-number").value = id ? String(id) : "";
    tabButtons().forEach((b) => {
      const on = b.dataset.id === String(id);
      b.classList.toggle("is-active", on);
      b.setAttribute("aria-selected", on ? "true" : "false");
    });
    try {
      localStorage.setItem("honey:wa-number", String(id));
    } catch (_) {}
  }
  function renderTabs() {
    numbers.forEach((n) => {
      const b = tabsRoot.querySelector(`[data-id="${n.id}"]`);
      if (!b) return;
      b.querySelector(".wa-number-dot").classList.toggle("is-on", !!n.connected);
      const count = b.querySelector(".wa-number-count");
      count.hidden = !n.pending_count && !n.human_count;
      count.textContent = n.pending_count || n.human_count;
      count.classList.toggle("is-human", n.human_count > 0);
      count.title = `${n.pending_count} pendente(s)${n.human_count ? ` · ${n.human_count} precisa(m) de você` : ""}`;
    });
  }
  tabButtons().forEach((b) => {
    b.onclick = safe(async () => {
      if (b.dataset.id === $("wa-number").value) return;
      setNumber(b.dataset.id);
      listPage = 1;
      $("wa-threads").replaceChildren();
      await refreshList();
    });
  });
  {
    let stored = null;
    try {
      stored = localStorage.getItem("honey:wa-number");
    } catch (_) {}
    const first = tabButtons().find((b) => b.dataset.id === stored) || tabButtons()[0];
    if (first) setNumber(first.dataset.id);
  }
  // Link direto para uma conversa (?c=ID), usado pela tela de Automações.
  const deepLink = Number(new URLSearchParams(location.search).get("c"));
  if (deepLink) {
    $("wa-state").value = "";
    setTimeout(
      safe(async () => {
        await selectConversation(deepLink);
        if (selected && String(selected.connection_id) !== $("wa-number").value) {
          setNumber(selected.connection_id);
          await refreshList();
        }
      }),
      300,
    );
  }
  function setRecording(on) {
    const b = $("wa-record");
    b.classList.toggle("is-recording", on);
    b.title = on ? "Parar gravação" : "Gravar áudio";
    b.setAttribute("aria-label", b.title);
    b.firstElementChild.className = on ? "fas fa-stop" : "fas fa-microphone";
  }
  // Tema claro/escuro do atendimento (preferência só deste navegador).
  const applyTheme = (theme) => {
    inbox.dataset.waTheme = theme;
    const next = theme === "dark" ? "claro" : "escuro";
    $("wa-theme-toggle").title = `Usar tema ${next}`;
    $("wa-theme-toggle").setAttribute("aria-label", `Usar tema ${next}`);
    $("wa-theme-toggle").firstElementChild.className =
      theme === "dark" ? "fas fa-sun" : "fas fa-moon";
  };
  try {
    applyTheme(localStorage.getItem("honey:wa-theme") === "light" ? "light" : "dark");
  } catch (_) {
    applyTheme("dark");
  }
  $("wa-theme-toggle").onclick = () => {
    const theme = inbox.dataset.waTheme === "dark" ? "light" : "dark";
    applyTheme(theme);
    try {
      localStorage.setItem("honey:wa-theme", theme);
    } catch (_) {}
  };
  // A caixa de texto cresce com a mensagem, até 6 linhas.
  function grow() {
    const t = $("wa-text");
    t.style.height = "auto";
    t.style.height = `${Math.min(t.scrollHeight, 140)}px`;
  }
  $("wa-text").addEventListener("input", grow);
  $("wa-new-side").onclick = () => $("wa-new").click();
  let debounce;
  ["wa-search", "wa-number", "wa-state", "wa-unread", "wa-mine", "wa-human"].forEach(
    (id) => {
      $(id).addEventListener(id === "wa-search" ? "input" : "change", () => {
        clearTimeout(debounce);
        debounce = setTimeout(
          safe(async () => {
            listPage = 1;
            await refreshList();
          }),
          250,
        );
      });
    },
  );
  $("wa-more-conversations").onclick = safe(async () => {
    listPage += 1;
    await refreshList(true);
  });
  $("wa-new").onclick = () => {
    $("wa-start-number").replaceChildren(new Option("Escolha um número", ""));
    numbers.forEach((n) =>
      $("wa-start-number").add(
        new Option(`${n.name} · ${n.phone || "não conectado"}`, n.id),
      ),
    );
    $("wa-start-number").value = $("wa-number").value;
    $("wa-new-dialog").showModal();
  };
  $("wa-cancel-new").onclick = () => $("wa-new-dialog").close();
  $("wa-start").onsubmit = safe(async (e) => {
    e.preventDefault();
    const c = await api(
      "/whatsapp/conversations",
      json("POST", {
        connection_id: $("wa-start-number").value,
        phone: $("wa-start-phone").value,
      }),
    );
    $("wa-new-dialog").close();
    await selectConversation(c.id);
    listPage = 1;
    await refreshList();
  });
  safe(refreshList)();
  poll(async () => {
    if (listPage === 1) await refreshList();
    await refreshSelected();
  });
})();
