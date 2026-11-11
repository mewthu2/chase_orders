import { Controller } from "@hotwired/stimulus"

// Modal do Bootstrap controlado pelo Stimulus: <div class="modal" data-controller="modal">.
// Abre por modal#open (no próprio modal) ou por um botão de fora com modal-opener.
export default class extends Controller {
  connect() {
    // O .content tem z-index próprio e prende o modal abaixo do fundo escuro; o honey_shell.js move o
    // modal para o <body> ao abrir, o que desconecta e reconecta este controller no meio da abertura.
    // Movendo já aqui, a abertura acontece com o modal no lugar certo (dentro de formulário ele fica onde está).
    if (this.element.parentElement !== document.body && !this.element.closest("form")) {
      document.body.appendChild(this.element)
      return
    }

    this.modal = window.bootstrap?.Modal.getOrCreateInstance(this.element)
    this.element.addEventListener("shown.bs.modal", this.shown)
    this.element.addEventListener("hidden.bs.modal", this.hidden)
  }

  disconnect() {
    this.element.removeEventListener("shown.bs.modal", this.shown)
    this.element.removeEventListener("hidden.bs.modal", this.hidden)
    // Só descarta se o modal saiu da página; se foi apenas movido, a instância continua valendo.
    if (!this.element.isConnected) this.modal?.dispose()
    this.modal = null
  }

  open() {
    this.modal?.show()
  }

  close() {
    this.modal?.hide()
  }

  shown = () => this.dispatch("opened")
  hidden = () => this.dispatch("closed")
}
