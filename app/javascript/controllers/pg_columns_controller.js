import { Controller } from "@hotwired/stimulus"

// Botão "Colunas" das tabelas (HoneyPageHelper#hc_pg_columns_button): arrastar (ou as setas) muda a ordem, a caixa
// mostra ou esconde a coluna. Salvar grava para o usuário (PATCH /preferencias/colunas) e recarrega a tela;
// "Voltar ao padrão" apaga a arrumação. A coluna principal (a do link) fica sempre visível.
// Também dá para arrastar o título da coluna no cabeçalho da tabela e soltar em outra: salva na hora.
//   data-controller="pg-columns" data-pg-columns-key-value data-pg-columns-url-value data-pg-columns-items-value
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]))

export default class extends Controller {
  static targets = ["button"]
  static values = { key: String, url: String, items: Array, custom: Boolean }

  connect() {
    this.onDocClick = (e) => {
      const path = e.composedPath()
      if (this.pop && !path.includes(this.pop) && !path.includes(this.buttonTarget)) this.close()
    }
    this.onKey = (e) => { if (e.key === "Escape" && this.pop) { this.close(); this.buttonTarget.focus() } }
    this.bindHeader()
  }

  // Arrastar direto no cabeçalho: solta antes ou depois da coluna de destino (pela metade em que o mouse está).
  bindHeader() {
    const card = this.element.closest(".pg-card")
    const ths = card ? [...card.querySelectorAll("table.pg-tbl thead th[data-col-key]")] : []
    if (ths.length < 2) return
    let from = null
    const clear = () => ths.forEach((th) => th.classList.remove("is-drop-before", "is-drop-after", "is-dragging"))
    ths.forEach((th) => {
      th.draggable = true
      th.classList.add("pg-th-drag")
      th.title = "Arraste para mudar a ordem da coluna"
      th.addEventListener("dragstart", (e) => {
        from = th.dataset.colKey
        th.classList.add("is-dragging")
        e.dataTransfer.effectAllowed = "move"
        e.dataTransfer.setData("text/plain", from)
      })
      th.addEventListener("dragend", () => { from = null; clear() })
      th.addEventListener("dragover", (e) => {
        if (!from || from === th.dataset.colKey) return
        e.preventDefault()
        const r = th.getBoundingClientRect()
        const after = e.clientX > r.left + r.width / 2
        clear()
        th.classList.add(after ? "is-drop-after" : "is-drop-before")
      })
      th.addEventListener("dragleave", () => th.classList.remove("is-drop-before", "is-drop-after"))
      th.addEventListener("drop", (e) => {
        e.preventDefault()
        const to = th.dataset.colKey
        const after = th.classList.contains("is-drop-after")
        clear()
        if (!from || from === to) return
        const items = this.itemsValue.map((i) => ({ ...i }))
        const fromIdx = items.findIndex((i) => i.k === from)
        if (fromIdx < 0) return
        const [moved] = items.splice(fromIdx, 1)
        let toIdx = items.findIndex((i) => i.k === to)
        if (toIdx < 0) return
        items.splice(after ? toIdx + 1 : toIdx, 0, moved)
        card.classList.add("is-saving")
        this.send("PATCH", { key: this.keyValue, columns: items.map((i) => ({ k: i.k, on: i.on })) })
      })
    })
  }

  disconnect() { this.close() }

  toggle(event) {
    event.preventDefault()
    this.pop ? this.close() : this.open()
  }

  open() {
    this.items = this.itemsValue.map((i) => ({ ...i }))
    this.pop = document.createElement("div")
    this.pop.className = "pg-cols-pop"
    this.pop.setAttribute("role", "dialog")
    this.pop.setAttribute("aria-label", "Colunas da tabela")
    this.element.appendChild(this.pop)
    this.render()
    this.buttonTarget.setAttribute("aria-expanded", "true")
    document.addEventListener("click", this.onDocClick, true)
    document.addEventListener("keydown", this.onKey)
  }

  close() {
    if (!this.pop) return
    this.pop.remove()
    this.pop = null
    this.buttonTarget?.setAttribute("aria-expanded", "false")
    document.removeEventListener("click", this.onDocClick, true)
    document.removeEventListener("keydown", this.onKey)
  }

  render() {
    const shown = this.items.filter((i) => i.on).length
    const rows = this.items.map((item, idx) => `
      <li class="pg-cols-item${item.on ? "" : " is-off"}" draggable="true" data-idx="${idx}">
        <i class="fas fa-grip-vertical pg-cols-grip" aria-hidden="true"></i>
        <label>
          <input type="checkbox" data-idx="${idx}" ${item.on ? "checked" : ""} ${item.locked ? "disabled" : ""}>
          <span>${esc(item.label || item.k)}</span>
          ${item.locked ? '<i class="fas fa-lock pg-cols-lock" data-tip="Coluna principal: sempre aparece."></i>' : ""}
        </label>
        <span class="pg-cols-move">
          <button type="button" class="action-btn" data-move="-1" data-idx="${idx}" ${idx === 0 ? "disabled" : ""} aria-label="Subir"><i class="fas fa-chevron-up"></i></button>
          <button type="button" class="action-btn" data-move="1" data-idx="${idx}" ${idx === this.items.length - 1 ? "disabled" : ""} aria-label="Descer"><i class="fas fa-chevron-down"></i></button>
        </span>
      </li>`).join("")
    this.pop.innerHTML = `
      <div class="pg-cols-head"><b>Colunas</b><span>${shown} de ${this.items.length} visíveis · arraste para mudar a ordem</span></div>
      <ul class="pg-cols-list">${rows}</ul>
      <div class="pg-cols-foot">
        <button type="button" class="btn btn-ghost btn-sm" data-act="reset" ${this.customValue ? "" : "disabled"}><i class="fas fa-rotate-left"></i>Voltar ao padrão</button>
        <span class="pg-cols-sp"></span>
        <button type="button" class="btn btn-secondary btn-sm" data-act="cancel">Cancelar</button>
        <button type="button" class="btn btn-primary btn-sm" data-act="save"><i class="fas fa-check"></i>Salvar</button>
      </div>`
    this.bind()
  }

  bind() {
    const pop = this.pop
    pop.querySelectorAll('input[type="checkbox"]').forEach((cb) => cb.addEventListener("change", () => {
      this.items[+cb.dataset.idx].on = cb.checked
      this.render()
    }))
    pop.querySelectorAll("[data-move]").forEach((b) => b.addEventListener("click", () => {
      const from = +b.dataset.idx
      this.move(from, from + +b.dataset.move)
      this.render()
      this.pop.querySelector(`[data-move="${b.dataset.move}"][data-idx="${from + +b.dataset.move}"]`)?.focus()
    }))
    pop.querySelector('[data-act="cancel"]').addEventListener("click", () => this.close())
    pop.querySelector('[data-act="save"]').addEventListener("click", () => this.save())
    pop.querySelector('[data-act="reset"]').addEventListener("click", () => this.reset())

    let dragFrom = null
    pop.querySelectorAll(".pg-cols-item").forEach((li) => {
      li.addEventListener("dragstart", (e) => { dragFrom = +li.dataset.idx; li.classList.add("is-drag"); e.dataTransfer.effectAllowed = "move"; e.dataTransfer.setData("text/plain", li.dataset.idx) })
      li.addEventListener("dragend", () => { li.classList.remove("is-drag"); pop.querySelectorAll(".is-over").forEach((x) => x.classList.remove("is-over")) })
      li.addEventListener("dragover", (e) => { e.preventDefault(); li.classList.add("is-over") })
      li.addEventListener("dragleave", () => li.classList.remove("is-over"))
      li.addEventListener("drop", (e) => {
        e.preventDefault()
        const to = +li.dataset.idx
        if (dragFrom !== null && dragFrom !== to) { this.move(dragFrom, to); this.render() }
        dragFrom = null
      })
    })
  }

  move(from, to) {
    if (to < 0 || to >= this.items.length) return
    const [item] = this.items.splice(from, 1)
    this.items.splice(to, 0, item)
  }

  async save() {
    await this.send("PATCH", { key: this.keyValue, columns: this.items.map((i) => ({ k: i.k, on: i.on })) })
  }

  async reset() {
    await this.send("DELETE", { key: this.keyValue })
  }

  async send(method, body) {
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    this.pop?.querySelectorAll("button").forEach((b) => { b.disabled = true })
    try {
      const res = await fetch(this.urlValue, {
        method,
        headers: { "Content-Type": "application/json", "X-CSRF-Token": token || "", Accept: "application/json" },
        credentials: "same-origin",
        body: JSON.stringify(body)
      })
      if (!res.ok) throw new Error(res.status)
      window.location.reload()
    } catch (e) {
      this.element.closest(".pg-card")?.classList.remove("is-saving")
      if (!this.pop) { this.buttonTarget.dataset.tip = "Não deu para salvar a ordem. Tente de novo."; return }
      this.pop.querySelectorAll("button").forEach((b) => { b.disabled = false })
      this.pop.querySelector(".pg-cols-head span").textContent = "Não deu para salvar. Tente de novo."
    }
  }
}
