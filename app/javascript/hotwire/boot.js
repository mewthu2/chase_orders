import { Turbo } from "@hotwired/turbo-rails"
import "controllers"

// Turbo Drive fica desligado: as telas antigas usam $(document).ready e scripts na própria página,
// que não sobrevivem à troca de página sem recarregar. Turbo Frames e Streams funcionam assim mesmo.
// Uma tela pode ligar o Drive num trecho com data-turbo="true".
Turbo.config.drive.enabled = false
