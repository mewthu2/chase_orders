import { Controller } from "@hotwired/stimulus"
import { getJSON } from "lib/http"
import { parseSkus, downloadCsv, today } from "lib/csv"

// Consulta de estoque em lote: lê os SKUs da planilha, consulta um por vez (estoque deste armazém,
// do outro armazém e pedidos travados), monta a tabela e exporta o resultado.
export default class extends Controller {
  static targets = ["file", "button", "progress", "progressText", "progressBar", "body", "exportButton", "message"]

  static values = {
    b2b: Boolean,
    stockUrl: String,
    stuckUrl: String,
    otherLabel: String,
    exportFilename: String
  }

  connect() {
    this.results = []
    this.running = false
  }

  disconnect() {
    this.cancelled = true
  }

  // Arquivo arrastado para o modal: a consulta começa sozinha.
  dropped() {
    if (!this.running) this.run()
  }

  rejected() {
    this.showMessage("Arraste uma planilha .csv.")
  }

  async run() {
    this.hideMessage()
    const file = this.fileTarget.files[0]
    if (!file) {
      this.showMessage("Selecione uma planilha .csv antes de consultar.")
      return
    }

    const skus = parseSkus(await file.text())
    if (skus.length === 0) {
      this.showMessage('Nenhum SKU encontrado na planilha. Verifique se existe uma coluna "SKU".')
      return
    }

    this.running = true
    this.cancelled = false
    this.results = []
    this.bodyTarget.replaceChildren()
    this.buttonTarget.disabled = true
    this.exportButtonTarget.hidden = false
    this.exportButtonTarget.disabled = true
    this.progressTarget.hidden = false

    for (let index = 0; index < skus.length; index++) {
      if (this.cancelled) return
      const sku = skus[index]
      this.setProgress(index, skus.length, `<i class="fas fa-spinner fa-spin me-1"></i>Consultando ${index + 1}/${skus.length}: `, sku)
      this.addRow(await this.lookup(sku))
    }

    this.setProgress(skus.length, skus.length, '<i class="fas fa-check-circle me-1 text-success"></i>', `Consulta concluída: ${skus.length} SKU(s).`)
    this.buttonTarget.disabled = false
    this.exportButtonTarget.disabled = this.results.length === 0
    this.running = false
    this.celebrate(this.exportButtonTarget)
  }

  async lookup(sku) {
    const b2b = this.b2bValue ? 1 : 0
    const [stock, stuck, other] = await Promise.allSettled([
      getJSON(this.stockUrlValue, { item_code: sku, b2b }),
      getJSON(this.stuckUrlValue, { sku, b2b }),
      getJSON(this.stockUrlValue, { item_code: sku, b2b: b2b ? 0 : 1 })
    ])

    // O estoque do outro armazém é só informativo: se falhar, a linha sai com "-".
    const otherStock = other.status === "fulfilled" && other.value && other.value.disponivel != null ? other.value.disponivel : "-"

    if (stock.status === "rejected") {
      return { sku, quantity: "-", other: "-", reserved: "-", stuckOrders: 0, stuckQuantity: 0, status: "error" }
    }

    const stuckData = (stuck.status === "fulfilled" && stuck.value) || { orders_count: 0, total_quantity: 0 }
    const found = stock.value && stock.value.disponivel !== undefined && stock.value.disponivel !== null
    return {
      sku,
      quantity: found ? stock.value.disponivel : "-",
      other: otherStock,
      reserved: found ? (stock.value.reservado !== undefined ? stock.value.reservado : 0) : "-",
      stuckOrders: Number(stuckData.orders_count) || 0,
      stuckQuantity: Number(stuckData.total_quantity) || 0,
      status: found ? "ok" : "missing"
    }
  }

  static statuses = {
    ok: ["text-success", "check-circle", "OK"],
    missing: ["text-warning", "exclamation-triangle", "Não encontrado"],
    error: ["text-danger", "times-circle", "Erro"]
  }

  addRow(result) {
    this.results.push(result)
    const hasReserved = result.reserved !== "-" && Number(result.reserved) > 0
    const hasStuck = result.stuckOrders > 0

    const row = document.createElement("tr")
    row.className = "hc-row-in"
    if (hasStuck) row.style.backgroundColor = "rgba(220,53,69,0.15)"
    else if (hasReserved) row.style.backgroundColor = "rgba(255,193,7,0.12)"

    const cell = (content) => {
      const td = document.createElement("td")
      if (content instanceof Node) td.append(content)
      else td.textContent = content
      row.append(td)
    }
    const span = (className, iconName, text, title) => {
      const el = document.createElement("span")
      el.className = className
      if (title) el.title = title
      el.innerHTML = `<i class="fas fa-${iconName} me-1"></i>`
      el.append(text)
      return el
    }

    cell(result.sku)
    cell(String(result.quantity))
    cell(String(result.other))
    if (hasReserved) {
      const reserved = document.createElement("span")
      reserved.className = "text-warning"
      reserved.textContent = result.reserved
      cell(reserved)
    } else {
      cell(String(result.reserved))
    }
    cell(hasStuck
      ? span("text-danger", "triangle-exclamation", `${result.stuckOrders} pedido(s) (${result.stuckQuantity} un.)`, "Pedidos que falharam no Correios por falta desse SKU")
      : "-")
    const [className, iconName, label] = this.constructor.statuses[result.status]
    cell(span(className, iconName, label))

    this.bodyTarget.append(row)
  }

  download() {
    if (this.results.length === 0) return
    const labels = this.constructor.statuses
    const rows = [
      ["SKU", "Estoque Disponível", this.otherLabelValue, "Reservado", "Pedidos Travados", "Unidades Travadas", "Status"],
      ...this.results.map((r) => [r.sku, r.quantity, r.other, r.reserved, r.stuckOrders, r.stuckQuantity, labels[r.status][2]])
    ]
    downloadCsv(`${this.exportFilenameValue}_${today()}.csv`, rows)
  }

  setProgress(done, total, iconHtml, text) {
    this.progressTextTarget.innerHTML = iconHtml
    this.progressTextTarget.append(text)
    this.progressBarTarget.style.width = `${total ? Math.round((done / total) * 100) : 0}%`
    this.progressBarTarget.classList.toggle("is-done", done === total)
  }

  showMessage(text) {
    this.messageTarget.textContent = text
    this.messageTarget.hidden = false
    this.messageTarget.classList.remove("hc-shake")
    void this.messageTarget.offsetWidth
    this.messageTarget.classList.add("hc-shake")
  }

  hideMessage() {
    this.messageTarget.hidden = true
  }

  celebrate(element) {
    element.classList.remove("hc-flash")
    void element.offsetWidth
    element.classList.add("hc-flash")
  }
}
