// Registra todos os controllers de app/javascript/controllers (pinados no importmap).
import { application } from "controllers/application"
import { eagerLoadControllersFrom } from "@hotwired/stimulus-loading"

eagerLoadControllersFrom("controllers", application)
