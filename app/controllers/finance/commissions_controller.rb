require 'csv'

module Finance
  # Comissões do mês (Finance::Commissions) e o percentual geral de cada pessoa.
  class CommissionsController < ApplicationController
    guard_screen :commissions, actions: { rates: :edit }
    before_action :set_month

    def index
      @result = Finance::Commissions.new(month: @month)
      @rates = CommissionRate.percents
      @sellers = User.where(id: B2bOrder.sale.select(:user_id)).or(User.where(id: CommissionRate.where(beneficiary_type: 'User').select(:beneficiary_id))).order(:name)
      @consultants = Consultant.where(active: true).or(Consultant.where(id: CommissionRate.where(beneficiary_type: 'Consultant').select(:beneficiary_id))).ordered
      respond_to do |format|
        format.html
        format.csv { send_data csv(@result), filename: "comissoes-#{@month.strftime('%Y-%m')}.csv", type: 'text/csv; charset=utf-8' }
      end
    end

    def show
      @result = Finance::Commissions.new(month: @month)
      @row = @result.find(params[:key]) or redirect_to(finance_commissions_path(mes: month_param), alert: 'Ninguém com comissão neste mês com essa chave.')
    end

    # percents: { "User-1" => "2,5", "Consultant-3" => "" } — percentual geral de cada pessoa; vazio apaga.
    def rates
      invalid = []
      (params[:percents]&.to_unsafe_h || {}).each do |key, value|
        type, id = key.to_s.split('-', 2)
        next unless %w[User Consultant].include?(type) && id.to_i.positive?

        scope = CommissionRate.where(beneficiary_type: type, beneficiary_id: id.to_i)
        text = value.to_s.strip.tr(',', '.')
        next scope.delete_all if text.empty?

        rate = scope.first_or_initialize
        rate.percent = BigDecimal(text, exception: false)
        invalid << (rate.beneficiary&.name || key) unless rate.percent && rate.save
      end
      if invalid.any?
        redirect_to finance_commissions_path(mes: month_param), alert: "Percentual de #{invalid.to_sentence} não foi salvo: use um número de 0 a 100."
      else
        redirect_to finance_commissions_path(mes: month_param), notice: 'Percentuais salvos. Valem para todos os meses.'
      end
    end

    private

    def set_month
      @month = HoneyTable.parse_month(params[:mes]) || Date.current.beginning_of_month
    end

    def month_param = @month.strftime('%Y-%m')

    def csv(result)
      money = ->(v) { format('%.2f', v).tr('.', ',') }
      "﻿" + CSV.generate(col_sep: ';') do |out|
        out << %w[Papel Nome Percentual Base Comissão]
        result.rows.each do |r|
          out << [r.role == :typist ? 'Vendedor' : 'Consultor', r.name, r.percent ? money.call(r.percent) : '', money.call(r.base), money.call(r.commission)]
        end
      end
    end
  end
end
