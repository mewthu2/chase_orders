module Whatsapp
  # Automações de conversa de cada número: comandos do agente, perguntas que ele
  # não soube responder ("falta ensinar") e um simulador para testar antes de ligar.
  class AutomationsController < BaseController
    before_action :require_management
    before_action :set_automation, except: %i[index create]
    rescue_from ActiveRecord::RecordInvalid, with: :invalid_html

    def index
      @connections = Connection.order(:name)
      @automations = Automation.includes(:connection, :rules).order(:name).group_by(&:connection_id)
      @open_gaps = AutomationGap.open.group(:automation_id).count
    end

    def show
      @rules = @automation.rules.to_a
      @gaps = @automation.gaps.open.includes(conversation: :contact).order(created_at: :desc).limit(100)
      @taught = @automation.gaps.where(state: 'taught').count
    end

    def create
      connection = Connection.find(params.require(:connection_id))
      automation = connection.automations.new(name: params[:name].presence || 'Resposta automática', created_by: current_user, mode: 'approve')
      Automation.transaction do
        if params[:template] == '1'
          automation.instructions = LearnedTemplate::INSTRUCTIONS
          automation.save!
          LearnedTemplate::RULES.each { |trigger, response| automation.rules.create!(trigger: trigger, response: response) }
        else
          automation.save!
        end
      end
      redirect_to whatsapp_automation_path(automation), notice: 'Automação criada. Revise os comandos e ligue quando estiver pronta.'
    end

    def update
      @automation.update!(params.require(:automation).permit(:name, :mode, :enabled, :instructions))
      redirect_back fallback_location: whatsapp_automation_path(@automation), notice: 'Automação salva.'
    end

    def destroy
      @automation.destroy!
      redirect_to whatsapp_automations_path, notice: 'Automação excluída.'
    end

    def create_rule
      @automation.rules.create!(params.require(:rule).permit(:trigger, :response))
      redirect_to whatsapp_automation_path(@automation, anchor: 'comandos'), notice: 'Comando adicionado. O agente já usa a partir da próxima mensagem.'
    end

    def update_rule
      rule = @automation.rules.find(params[:rule_id])
      rule.update!(params.require(:rule).permit(:trigger, :response, :active))
      redirect_to whatsapp_automation_path(@automation, anchor: "comando-#{rule.id}"), notice: 'Comando salvo.'
    end

    def destroy_rule
      @automation.rules.find(params[:rule_id]).destroy!
      redirect_to whatsapp_automation_path(@automation, anchor: 'comandos'), notice: 'Comando excluído.'
    end

    # Ensinar: a pergunta pendente vira um comando novo.
    def teach_gap
      gap = @automation.gaps.find(params[:gap_id])
      AutomationGap.transaction do
        rule = @automation.rules.create!(params.require(:rule).permit(:trigger, :response))
        gap.update!(state: 'taught', rule: rule)
        @automation.gaps.open.where(question: gap.question).update_all(state: 'taught', rule_id: rule.id)
      end
      redirect_to whatsapp_automation_path(@automation, anchor: 'falta-ensinar'), notice: 'Aprendido! Virou um comando novo.'
    end

    def dismiss_gap
      @automation.gaps.find(params[:gap_id]).update!(state: 'dismissed')
      redirect_to whatsapp_automation_path(@automation, anchor: 'falta-ensinar'), notice: 'Pergunta descartada.'
    end

    # Testa o agente com uma mensagem de cliente, sem enviar nada.
    def simulate
      text = params.require(:message).to_s.truncate(2_000)
      history = Array(params[:history]).last(10).filter_map do |row|
        row = row.respond_to?(:permit) ? row.permit(:from, :text) : row
        { from: row[:from] == 'loja' ? 'loja' : 'cliente', text: row[:text].to_s.truncate(1_500), at: Time.current } if row[:text].present?
      end
      decision = Agent.new(@automation).decide(history + [{ from: 'cliente', text: text, at: Time.current }])
      render json: decision.to_h
    rescue Agent::NotConfigured, Agent::Failure => e
      render json: { error: e.message }, status: :service_unavailable
    end

    private

    def set_automation = @automation = Automation.find(params[:id])

    def invalid_html(error)
      return render(json: { error: error.record.errors.full_messages.join(', ') }, status: :unprocessable_entity) if request.format.json?
      redirect_back fallback_location: whatsapp_automations_path, alert: error.record.errors.full_messages.join(', ')
    end
  end
end
