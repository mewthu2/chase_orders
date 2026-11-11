import { Controller } from "@hotwired/stimulus"

// Botão que abre um modal de outro lugar da página:
// data-controller="modal-opener" data-modal-opener-modal-outlet="#idDoModal" data-action="modal-opener#open"
export default class extends Controller {
  static outlets = ["modal"]

  open(event) {
    event?.preventDefault()
    this.modalOutlets.forEach((modal) => modal.open())
  }
}
