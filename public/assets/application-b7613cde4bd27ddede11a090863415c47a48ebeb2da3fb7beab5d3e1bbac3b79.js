import "bootstrap/dist/js/bootstrap.bundle"

const app = createApp()

document.addEventListener("turbo:load", () => {
  app.load()
  Turbo.connectStreamSource()
});
