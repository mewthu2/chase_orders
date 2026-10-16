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
        const card = el("article", undefined, "wa-number-card");
        card.append(
          el("h2", c.name),
          el("p", c.phone || "Telefone ainda não confirmado pelo WhatsApp"),
          el("span", stateLabels[c.state] || c.state, "wa-state"),
        );
        if (c.qr && new Date(c.qr_expires_at) > new Date()) {
          const img = el("img");
          img.src = c.qr;
          img.alt = `QR para conectar ${c.name}`;
          card.append(
            img,
            el(
              "p",
              "No celular: WhatsApp Business → Aparelhos conectados → Conectar aparelho.",
            ),
          );
          const expiry = el(
            "small",
            "O QR é temporário. Um novo aparecerá quando o WhatsApp renovar.",
          );
          card.append(expiry);
          setTimeout(
            () => {
              img.remove();
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
          card.append(b);
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
          el("p", "Nenhum número conectado. Adicione o primeiro número acima."),
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
      page: listPage,
    });
    const result = await api(`/whatsapp/conversations.json?${p}`);
    numbers = result.connections;
    const selection = $("wa-number").value;
    $("wa-number").replaceChildren(new Option("Todos os meus números", ""));
    numbers.forEach((n) =>
      $("wa-number").add(
        new Option(`${n.name}${n.phone ? " · " + n.phone : ""}`, n.id),
      ),
    );
    $("wa-number").value = selection;
    if (!append) $("wa-threads").replaceChildren();
    result.conversations.forEach((c) => {
      const button = el(
        "button",
        undefined,
        `wa-thread ${selected?.id === c.id ? "selected" : ""}`,
      );
      button.type = "button";
      if (c.unread_count) button.append(el("span", c.unread_count, "wa-badge"));
      button.append(
        el("strong", c.name),
        el("small", `${c.connection_name} · ${date(c.last_message_at)}`),
        el("small", c.last_message_preview || c.phone || "Sem mensagens"),
      );
      button.onclick = safe(() => selectConversation(c.id));
      $("wa-threads").append(button);
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
    $("wa-company-number").textContent =
      `Pelo número ${c.connection_name}${c.connection_phone ? " · " + c.connection_phone : ""} · ${stateLabels[c.connection_state] || c.connection_state}`;
    $("wa-owner").textContent =
      `Responsável: ${c.assignee_name || "ninguém"} · ${c.state === "closed" ? "encerrada" : "aberta"}`;
    $("wa-close").textContent = c.state === "closed" ? "Reabrir" : "Encerrar";
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
    [...messages.values()]
      .sort((a, b) => new Date(a.sent_at) - new Date(b.sent_at) || a.id - b.id)
      .forEach((m, index) => {
        let node = document.getElementById(`wa-message-${m.id}`);
        const signature = JSON.stringify(m);
        if (!node || node.dataset.signature !== signature) {
          const next = el("article", undefined, `wa-message ${m.direction}`);
          next.id = `wa-message-${m.id}`;
          next.dataset.signature = signature;
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
          next.append(
            el(
              "small",
              `${m.author ? m.author + " · " : ""}${date(m.sent_at)} · ${messageLabels[m.state] || m.state}`,
            ),
          );
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
          if (node) node.replaceWith(next);
          node = next;
        }
        const current = container.children[index];
        if (current !== node) container.insertBefore(node, current || null);
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
    $("wa-text").value = draft?.text || "";
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
      setFiles(null);
      draftNonce = null;
      draftRequest = null;
      lockDraft(false);
      drafts.delete(id);
      error("");
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
      $("wa-record").textContent = "Gravar áudio";
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
    $("wa-record").textContent = "Parar gravação";
    setTimeout(stopRecording, 60000);
  });
  let debounce;
  ["wa-search", "wa-number", "wa-state", "wa-unread", "wa-mine"].forEach(
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
