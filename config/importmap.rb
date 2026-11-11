# Hotwire (Turbo + Stimulus) carregado como módulo, ao lado do application.js do Sprockets (jQuery etc.).
# A entrada fica numa subpasta de app/javascript porque o build do esbuild pega só os arquivos do topo da pasta.
pin "hotwire", to: "hotwire/boot.js"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"
pin_all_from "app/javascript/hotwire/lib", under: "lib", to: "hotwire/lib"
