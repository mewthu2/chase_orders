import { Controller } from "@hotwired/stimulus"
import { getJSON } from "lib/http"
import { downloadCsv, today } from "lib/csv"

// Consulta de estoque de um item (API Correios): busca por SKU ou nome, estoque no armazém,
// pedidos travados por falta do SKU e a lista de itens para exportar.
export default class extends Controller {
  static targets = [
    "input", "results", "button", "icon", "panel", "image", "result",
    "addButton", "crossLink", "exportSection", "exportCount", "exportBody"
  ]

  static values = {
    b2b: Boolean,
    stockUrl: String,
    searchUrl: String,
    stuckUrl: String,
    crossUrl: String,
    exportFilename: String
  }

  connect() {
    this.currentItem = null
    this.exportList = []

    // Veio de um link "Pesquisar item no outro Log".
    const sku = new URLSearchParams(window.location.search).get("sku")
    if (sku) {
      this.inputTarget.value = sku
      this.search()
    }
  }

  disconnect() {
    clearTimeout(this.suggestTimer)
  }

  // ===== Sugestões enquanto digita =====
  suggest() {
    clearTimeout(this.suggestTimer)
    const query = this.inputTarget.value.trim()
    this.currentItem = null
    this.addButtonTarget.hidden = true

    if (!query) {
      this.resultsTarget.replaceChildren()
      return
    }

    this.resultsTarget.innerHTML = '<div class="list-group-item bg-dark text-white-50"><i class="fas fa-spinner fa-spin me-2"></i>Buscando...</div>'
    this.suggestTimer = setTimeout(async () => {
      try {
        const data = await getJSON(this.searchUrlValue, { query })
        if (this.inputTarget.value.trim() !== query) return
        this.renderSuggestions((data && data.products) || [])
      } catch {
        this.resultsTarget.replaceChildren()
      }
    }, 300)
  }

  renderSuggestions(products) {
    const items = products.map((product, index) => {
      const item = document.createElement("button")
      item.type = "button"
      item.className = "list-group-item list-group-item-action d-flex align-items-center gap-2 hc-pop-in"
      item.style.setProperty("--i", index)
      item.append(this.thumbnail(product.image_url, 44))
      const label = document.createElement("span")
      label.textContent = `${product.sku} - ${product.name || "Sem nome"}`
      item.append(label)
      item.addEventListener("click", () => {
        this.currentItem = { sku: product.sku, name: product.name, image_url: product.image_url }
        this.inputTarget.value = product.sku
        this.search()
      })
      return item
    })
    this.resultsTarget.replaceChildren(...items)
  }

  keydown(event) {
    if (event.key !== "Enter") return
    event.preventDefault()
    this.search()
  }

  // ===== Consulta do estoque =====
  async search() {
    clearTimeout(this.suggestTimer)
    const sku = this.inputTarget.value.trim()
    this.resultsTarget.replaceChildren()

    if (!sku) {
      this.panelTarget.hidden = false
      this.setResult("exclamation-triangle", "Digite um código de estoque")
      return
    }

    if (!this.currentItem || this.currentItem.sku !== sku) this.currentItem = { sku, name: null, image_url: null }

    this.addButtonTarget.hidden = true
    this.crossLinkTarget.hidden = true
    this.imageTarget.hidden = true
    this.imageTarget.removeAttribute("src")
    this.panelTarget.hidden = false
    this.setPanelState(null)
    this.setBusy(true)
    this.result.innerHTML = '<i class="fas fa-spinner fa-spin me-2"></i>Buscando...'
    this.restartAnimation(this.panelTarget)

    try {
      const [stock, productData] = await Promise.all([
        getJSON(this.stockUrlValue, { item_code: sku, b2b: this.b2bValue ? 1 : 0 }),
        getJSON(this.searchUrlValue, { query: sku })
      ])

      const matched = ((productData && productData.products) || []).find((p) => p.sku.toUpperCase() === sku.toUpperCase())
      if (matched) {
        this.currentItem = { sku: matched.sku, name: matched.name, image_url: matched.image_url }
        if (matched.image_url) {
          this.imageTarget.src = matched.image_url
          this.imageTarget.hidden = false
        }
      }

      this.crossLinkTarget.href = `${this.crossUrlValue}?sku=${encodeURIComponent(sku)}`
      this.crossLinkTarget.hidden = false

      if (stock && Object.keys(stock).length > 0) {
        this.renderStock(stock)
        this.setPanelState("success")
        this.addButtonTarget.hidden = false
        this.checkStuckOrders(sku)
      } else {
        this.setResult("times-circle", "Nenhum resultado encontrado")
        this.setPanelState("error")
      }
    } catch {
      this.setResult("exclamation-triangle", "Erro ao buscar informações")
      this.setPanelState("error")
    } finally {
      this.setBusy(false)
    }
  }

  renderStock(stock) {
    const available = stock.disponivel !== undefined ? stock.disponivel : "-"
    const reserved = stock.reservado !== undefined ? stock.reservado : 0
    const fragment = document.createDocumentFragment()

    if (this.currentItem.name) {
      const name = document.createElement("div")
      name.className = "text-main fw-bold"
      name.textContent = this.currentItem.name
      const badge = document.createElement("div")
      badge.className = "cnpj-badge mb-2"
      badge.textContent = `SKU: ${this.currentItem.sku}`
      fragment.append(name, badge)
    }

    const line = document.createElement("div")
    line.innerHTML = '<i class="fas fa-check-circle me-2 text-success"></i>Disponível: <strong></strong>&nbsp;|&nbsp;Reservado: <strong></strong>'
    const [availableEl, reservedEl] = line.querySelectorAll("strong")
    availableEl.textContent = available
    reservedEl.textContent = reserved
    fragment.append(line)

    this.result.replaceChildren(fragment)
  }

  async checkStuckOrders(sku) {
    try {
      const data = await getJSON(this.stuckUrlValue, { sku, b2b: this.b2bValue ? 1 : 0 })
      if (!data || !(data.orders_count > 0) || this.inputTarget.value.trim() !== sku) return
      const alert = document.createElement("div")
      alert.className = "alert alert-danger border-0 mt-2 mb-0 py-2 px-3 text-start hc-pop-in"
      alert.innerHTML = '<i class="fas fa-lock me-1"></i>'
      alert.append(`${data.orders_count} pedido(s) travado(s) aguardando esse SKU (necessário: ${data.total_quantity} un.)`)
      this.result.append(alert)
    } catch {
      // Sem o aviso de travados, o resultado do estoque continua valendo.
    }
  }

  // ===== Lista para exportar =====
  addToList() {
    const item = this.currentItem
    if (!item || !item.sku) return
    if (this.exportList.some((i) => i.sku === item.sku)) {
      this.flash(this.exportBodyTarget.querySelector(`tr[data-sku="${CSS.escape(item.sku)}"]`))
      return
    }
    this.exportList.push({ sku: item.sku, name: item.name, image_url: item.image_url, quantity: "" })
    this.renderList()
    this.flash(this.exportBodyTarget.lastElementChild)
  }

  renderList() {
    const rows = this.exportList.map((item, index) => {
      const row = document.createElement("tr")
      row.dataset.sku = item.sku

      const imageCell = document.createElement("td")
      if (item.image_url) imageCell.append(this.thumbnail(item.image_url, 32))
      const skuCell = document.createElement("td")
      skuCell.textContent = item.sku
      const nameCell = document.createElement("td")
      nameCell.textContent = item.name || "-"

      const quantity = document.createElement("input")
      quantity.type = "number"
      quantity.min = "0"
      quantity.className = "field-input"
      quantity.style.cssText = "padding: 0.35rem 0.6rem; font-size: 0.85rem"
      quantity.placeholder = "Marcar qtd."
      quantity.value = item.quantity || ""
      quantity.addEventListener("input", () => { this.exportList[index].quantity = quantity.value })
      const quantityCell = document.createElement("td")
      quantityCell.append(quantity)

      const remove = document.createElement("button")
      remove.type = "button"
      remove.className = "btn btn-ghost btn-sm"
      remove.title = "Remover da lista"
      remove.innerHTML = '<i class="fas fa-trash"></i>'
      remove.addEventListener("click", () => {
        const drop = () => {
          this.exportList.splice(index, 1)
          this.renderList()
        }
        row.classList.add("hc-row-out")
        // Sem animação (movimento reduzido), o animationend não chega: tira na hora.
        if (getComputedStyle(row).animationName === "none") drop()
        else row.addEventListener("animationend", drop, { once: true })
      })
      const removeCell = document.createElement("td")
      removeCell.append(remove)

      row.append(imageCell, skuCell, nameCell, quantityCell, removeCell)
      return row
    })

    this.exportBodyTarget.replaceChildren(...rows)
    this.exportCountTarget.textContent = this.exportList.length
    this.exportSectionTarget.hidden = this.exportList.length === 0
  }

  downloadList() {
    if (this.exportList.length === 0) return
    const rows = [["SKU", "Quantidade"], ...this.exportList.map((item) => [item.sku.replace(/,/g, " "), item.quantity || ""])]
    downloadCsv(`${this.exportFilenameValue}_${today()}.csv`, rows, { separator: ",", bom: false })
  }

  // ===== Ajudantes =====
  get result() {
    return this.resultTarget
  }

  setResult(icon, message) {
    this.result.innerHTML = `<i class="fas fa-${icon} me-2"></i>`
    this.result.append(message)
  }

  setBusy(busy) {
    this.buttonTarget.disabled = busy
    this.iconTarget.classList.toggle("fa-spinner", busy)
    this.iconTarget.classList.toggle("fa-spin", busy)
    this.iconTarget.classList.toggle("fa-magnifying-glass", !busy)
  }

  setPanelState(state) {
    const colors = { success: "#238636", error: "#da3633" }
    this.panelTarget.style.borderColor = colors[state] || ""
  }

  thumbnail(src, size) {
    if (src) {
      const img = document.createElement("img")
      img.src = src
      img.loading = "lazy"
      img.alt = ""
      img.className = "rounded border border-secondary flex-shrink-0"
      img.style.cssText = `width: ${size}px; height: ${size}px; object-fit: cover`
      return img
    }
    const placeholder = document.createElement("span")
    placeholder.className = "rounded border border-secondary d-flex align-items-center justify-content-center text-white-50 flex-shrink-0"
    placeholder.style.cssText = `width: ${size}px; height: ${size}px`
    placeholder.innerHTML = '<i class="fas fa-image"></i>'
    return placeholder
  }

  restartAnimation(element) {
    element.classList.remove("hc-pop-in")
    void element.offsetWidth
    element.classList.add("hc-pop-in")
  }

  flash(element) {
    if (!element) return
    element.classList.remove("hc-flash")
    void element.offsetWidth
    element.classList.add("hc-flash")
  }
}
