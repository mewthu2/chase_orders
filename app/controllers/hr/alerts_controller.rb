module Hr
  # Recursos Humanos › Alertas de jornada: quem passou da carga horária ou de um limite da CLT (Hr::JourneyCheck).
  class AlertsController < ApplicationController
    guard_screen :hr_alerts

    def index
      @alerts = HrAlert.includes(employee: :company).recent.limit(2000).to_a
    end
  end
end
