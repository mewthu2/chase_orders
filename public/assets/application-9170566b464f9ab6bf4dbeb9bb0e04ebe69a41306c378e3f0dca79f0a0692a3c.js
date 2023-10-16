import { createApp } from "importmap"
import { Turbo } from "@hotwired/turbo-rails"
import "@bootstrap"

const app = createApp()

document.addEventListener("turbo:load", () => {
  app.load()
  Turbo.connectStreamSource()
});
