import { Controller } from "@hotwired/stimulus"

// Calendário "de tal dia a tal dia" dos filtros de data (HoneyPageHelper#hc_pg_month_field e o filtro de período).
// O primeiro clique marca o início, o segundo o fim (passar o mouse mostra o intervalo); Aplicar grava
// "AAAA-MM-DD..AAAA-MM-DD" no select do filtro e envia o formulário, como escolher uma opção da lista.
//   data-controller="date-range" data-date-range-from-value data-date-range-to-value data-date-range-month-value
const MONTHS = ["Janeiro", "Fevereiro", "Março", "Abril", "Maio", "Junho", "Julho", "Agosto", "Setembro", "Outubro", "Novembro", "Dezembro"]
const WEEKDAYS = ["D", "S", "T", "Q", "Q", "S", "S"]

const iso = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`
const parse = (s) => {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s || "")
  return m ? new Date(+m[1], +m[2] - 1, +m[3]) : null
}
const br = (d) => d.toLocaleDateString("pt-BR")
const addDays = (d, n) => new Date(d.getFullYear(), d.getMonth(), d.getDate() + n)
const today = () => { const t = new Date(); return new Date(t.getFullYear(), t.getMonth(), t.getDate()) }

export default class extends Controller {
  static targets = ["select", "button"]
  static values = { from: String, to: String, month: String }

  connect() {
    // O caminho do clique é guardado antes do redesenho: o dia clicado sai do DOM, mas o clique foi dentro.
    this.onDocClick = (e) => {
      const path = e.composedPath()
      if (this.pop && !path.includes(this.pop) && !path.includes(this.buttonTarget)) this.close()
    }
    this.onKey = (e) => { if (e.key === "Escape") { this.close(); this.buttonTarget.focus() } }
    this.onMove = () => this.place()
  }

  disconnect() { this.close() }

  toggle(event) {
    event.preventDefault()
    this.pop ? this.close() : this.open()
  }

  open() {
    this.start = parse(this.fromValue)
    this.end = parse(this.toValue)
    this.hover = null
    const base = this.start || parse(this.monthValue) || today()
    this.view = new Date(base.getFullYear(), base.getMonth(), 1)

    this.pop = document.createElement("div")
    this.pop.className = "dr-pop"
    this.pop.setAttribute("role", "dialog")
    this.pop.setAttribute("aria-label", "Escolher o período no calendário")
    this.pop.addEventListener("click", (e) => this.click(e))
    this.pop.addEventListener("mouseover", (e) => this.preview(e))
    document.body.appendChild(this.pop)
    this.render()
    this.place()
    this.buttonTarget.classList.add("is-open")
    requestAnimationFrame(() => this.pop?.classList.add("is-in"))
    setTimeout(() => document.addEventListener("click", this.onDocClick), 0)
    document.addEventListener("keydown", this.onKey)
    window.addEventListener("resize", this.onMove)
    window.addEventListener("scroll", this.onMove, true)
  }

  close() {
    if (!this.pop) return
    this.pop.remove()
    this.pop = null
    this.buttonTarget.classList.remove("is-open")
    document.removeEventListener("click", this.onDocClick)
    document.removeEventListener("keydown", this.onKey)
    window.removeEventListener("resize", this.onMove)
    window.removeEventListener("scroll", this.onMove, true)
  }

  place() {
    if (!this.pop) return
    const r = this.buttonTarget.getBoundingClientRect()
    const w = this.pop.offsetWidth
    const h = this.pop.offsetHeight
    const left = Math.max(8, Math.min(r.left, window.innerWidth - w - 8))
    let top = r.bottom + 8
    if (top + h > window.innerHeight - 8 && r.top - h - 8 > 8) top = r.top - h - 8
    this.pop.style.left = `${left}px`
    this.pop.style.top = `${top}px`
  }

  // ---- interação ----
  click(event) {
    const el = event.target.closest("[data-dr]")
    if (!el) return
    event.preventDefault()
    const action = el.dataset.dr
    if (action === "day") this.pick(parse(el.dataset.date))
    else if (action === "prev") this.shift(-1)
    else if (action === "next") this.shift(1)
    else if (action === "preset") this.preset(el.dataset.preset)
    else if (action === "clear") { this.start = this.end = null; this.render() }
    else if (action === "apply") this.apply()
  }

  pick(date) {
    if (!this.start || this.end) {
      this.start = date
      this.end = null
    } else if (date < this.start) {
      this.end = this.start
      this.start = date
    } else {
      this.end = date
    }
    this.hover = null
    this.render()
  }

  preview(event) {
    if (!this.start || this.end) return
    const el = event.target.closest("[data-dr='day']")
    const date = el && parse(el.dataset.date)
    if (!date || (this.hover && +this.hover === +date)) return
    this.hover = date
    this.paint()
  }

  shift(n) {
    this.view = new Date(this.view.getFullYear(), this.view.getMonth() + n, 1)
    this.render()
  }

  preset(key) {
    const t = today()
    const ranges = {
      today: [t, t],
      yesterday: [addDays(t, -1), addDays(t, -1)],
      d7: [addDays(t, -6), t],
      d30: [addDays(t, -29), t],
      month: [new Date(t.getFullYear(), t.getMonth(), 1), t],
      last: [new Date(t.getFullYear(), t.getMonth() - 1, 1), new Date(t.getFullYear(), t.getMonth(), 0)]
    }
    ;[this.start, this.end] = ranges[key]
    this.view = new Date(this.start.getFullYear(), this.start.getMonth(), 1)
    this.render()
  }

  apply() {
    if (!this.start) return
    const end = this.end || this.start
    const value = `${iso(this.start)}..${iso(end)}`
    const select = this.selectTarget
    let option = Array.from(select.options).find((o) => o.value === value)
    if (!option) {
      option = new Option(+end === +this.start ? br(this.start) : `${br(this.start)} a ${br(end)}`, value)
      select.add(option, 0)
    }
    select.value = value
    this.close()
    this.element.classList.add("is-range")
    select.form.requestSubmit()
  }

  // ---- desenho ----
  render() {
    const second = new Date(this.view.getFullYear(), this.view.getMonth() + 1, 1)
    const presets = [["today", "Hoje"], ["yesterday", "Ontem"], ["d7", "Últimos 7 dias"], ["d30", "Últimos 30 dias"], ["month", "Este mês"], ["last", "Mês passado"]]
    this.pop.innerHTML = `
      <div class="dr-presets">${presets.map(([k, l]) => `<button type="button" class="dr-chip" data-dr="preset" data-preset="${k}">${l}</button>`).join("")}</div>
      <div class="dr-body">
        <button type="button" class="dr-arrow is-prev" data-dr="prev" aria-label="Mês anterior"><i class="fas fa-chevron-left"></i></button>
        ${this.monthHtml(this.view)}
        ${this.monthHtml(second, "is-second")}
        <button type="button" class="dr-arrow is-next" data-dr="next" aria-label="Próximo mês"><i class="fas fa-chevron-right"></i></button>
      </div>
      <div class="dr-foot">
        <div class="dr-summary"></div>
        <button type="button" class="btn btn-ghost btn-sm" data-dr="clear">Limpar</button>
        <button type="button" class="btn btn-primary btn-sm dr-apply" data-dr="apply"><i class="fas fa-check"></i>Aplicar</button>
      </div>`
    this.paint()
  }

  monthHtml(first, extra = "") {
    const lead = first.getDay()
    const days = new Date(first.getFullYear(), first.getMonth() + 1, 0).getDate()
    const t = +today()
    let cells = ""
    for (let i = 0; i < lead; i++) cells += `<span class="dr-gap"></span>`
    for (let d = 1; d <= days; d++) {
      const date = new Date(first.getFullYear(), first.getMonth(), d)
      const cls = ["dr-day", +date === t ? "is-today" : "", +date > t ? "is-future" : ""].join(" ")
      cells += `<button type="button" class="${cls}" data-dr="day" data-date="${iso(date)}" aria-label="${br(date)}">${d}</button>`
    }
    return `<div class="dr-month ${extra}">
      <div class="dr-title">${MONTHS[first.getMonth()]} <span>${first.getFullYear()}</span></div>
      <div class="dr-grid">${WEEKDAYS.map((w) => `<span class="dr-wd">${w}</span>`).join("")}${cells}</div>
    </div>`
  }

  // Marca início, fim e o meio do intervalo (com a prévia do mouse) sem redesenhar os meses.
  paint() {
    const a = this.start
    let b = this.end || this.hover
    let lo = a, hi = b
    if (a && b && b < a) { lo = b; hi = a }
    if (a && !b) hi = a
    this.pop.querySelectorAll(".dr-day").forEach((el) => {
      const d = +parse(el.dataset.date)
      const on = lo && d >= +lo && d <= +hi
      el.classList.toggle("is-in", !!on)
      el.classList.toggle("is-start", !!lo && d === +lo)
      el.classList.toggle("is-end", !!hi && d === +hi)
      el.classList.toggle("is-preview", !!on && !this.end)
    })
    const summary = this.pop.querySelector(".dr-summary")
    const apply = this.pop.querySelector(".dr-apply")
    if (!a) summary.innerHTML = `<i class="fas fa-hand-pointer"></i> Clique no primeiro dia`
    else if (!this.end) summary.innerHTML = `<b>${br(a)}</b> <i class="fas fa-arrow-right"></i> <span class="dr-wait">clique no último dia</span>`
    else {
      const n = Math.round((+this.end - +a) / 86400000) + 1
      summary.innerHTML = `<b>${br(a)}</b> <i class="fas fa-arrow-right"></i> <b>${br(this.end)}</b> <span class="dr-count">${n} ${n === 1 ? "dia" : "dias"}</span>`
    }
    apply.disabled = !a
  }
}
