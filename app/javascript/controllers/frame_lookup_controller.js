import { Controller } from "@hotwired/stimulus"

// Formulário que responde dentro de um <turbo-frame>: mostra o spinner no botão enquanto o
// servidor responde e, se a resposta não trouxer o frame (erro 500, sessão caída), mostra um aviso no lugar.
export default class extends Controller {
  static targets = ["button", "icon", "frame"]
  static values = { errorMessage: { type: String, default: "Erro ao buscar informações" } }

  start() {
    this.buttonTarget.disabled = true
    this.iconTarget.classList.add("fa-spinner", "fa-spin")
    this.iconTarget.classList.remove("fa-magnifying-glass")
    this.frameTarget.setAttribute("aria-busy", "true")
  }

  finish() {
    this.buttonTarget.disabled = false
    this.iconTarget.classList.remove("fa-spinner", "fa-spin")
    this.iconTarget.classList.add("fa-magnifying-glass")
    this.frameTarget.removeAttribute("aria-busy")
  }

  missing(event) {
    event.preventDefault()
    this.finish()
    const panel = document.createElement("div")
    panel.className = "pg-answer hc-pop-in"
    panel.style.borderColor = "#da3633"
    panel.innerHTML = '<div class="text-main"><i class="fas fa-exclamation-triangle me-2"></i></div>'
    panel.firstChild.append(this.errorMessageValue)
    this.frameTarget.replaceChildren(panel)
  }
}
