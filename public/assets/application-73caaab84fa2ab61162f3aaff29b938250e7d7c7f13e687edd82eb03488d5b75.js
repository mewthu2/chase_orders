const app = createApp()

document.addEventListener("turbo:load", () => {
  app.load()
  Turbo.connectStreamSource()
});
