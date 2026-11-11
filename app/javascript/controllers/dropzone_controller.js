import { Controller } from "@hotwired/stimulus"

// Área que aceita arrastar um arquivo: o arquivo entra no <input type=file> (target "input")
// e o controller avisa com o evento "dropzone:dropped". Arquivo de outro tipo dispara "dropzone:rejected".
export default class extends Controller {
  static targets = ["input"]
  static values = { accept: String, activeClass: { type: String, default: "is-dragging" } }

  connect() {
    this.depth = 0
  }

  enter(event) {
    if (!this.hasFiles(event)) return
    event.preventDefault()
    this.depth++
    this.element.classList.add(this.activeClassValue)
  }

  over(event) {
    if (!this.hasFiles(event)) return
    event.preventDefault()
    event.dataTransfer.dropEffect = "copy"
  }

  leave() {
    if (--this.depth <= 0) this.reset()
  }

  drop(event) {
    if (!this.hasFiles(event)) return
    event.preventDefault()
    this.reset()

    const file = event.dataTransfer.files[0]
    if (!file || (this.acceptValue && !new RegExp(this.acceptValue, "i").test(file.name))) {
      this.dispatch("rejected", { detail: { file } })
      return
    }

    const transfer = new DataTransfer()
    transfer.items.add(file)
    this.inputTarget.files = transfer.files
    this.dispatch("dropped", { detail: { file } })
  }

  reset() {
    this.depth = 0
    this.element.classList.remove(this.activeClassValue)
  }

  hasFiles(event) {
    return event.dataTransfer && Array.from(event.dataTransfer.types).includes("Files")
  }
}
