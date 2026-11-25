require 'csv'

module Finance
  # Comissões do mês (Finance::Commissions) e os percentuais de cada pessoa no mês.
  class CommissionsController < ApplicationController
    guard_screen :commissions, actions: { rates: :edit, copy_previous: :edit }
    before_action :set_month

    def index
      @result = Finance::Commissions.new(month: @month)
      respond_to do |format|
        format.html
        format.csv { send_data csv(@result), filename: "comissoes-#{@month.strftime('%Y-%m')}.csv", type: 'text/csv; charset=utf-8' }
      end
    end

    def show
      @result = Finance::Commissions.new(month: @month)
      @row = @result.find(params[:key]) or redirect_to(finance_commissions_path(mes: month_param), alert: 'Ninguém com comissão neste mês com essa chave.')
    end

    # percents: { "User-1" => "2,5", "Consultant-3" => "" } — vazio apaga o percentual do mês.
    def rates
      (params[:percents]&.to_unsafe_h || {}).each do |key, value|
        type, id = key.to_s.split('-', 2)
        next unless %w[User Consultant].include?(type) && id.to_i.positive?

        scope = CommissionRate.where(month: @month, beneficiary_type: type, beneficiary_id: id.to_i)
        text = value.to_s.strip.tr(',', '.')
        if text.empty?
          scope.delete_all
        else
          rate = scope.first_or_initialize
          rate.percent = BigDecimal(text, exception: false) || rate.percent
          rate.save
        end
      end
      redirect_to finance_commissions_path(mes: month_param), notice: 'Percentuais do mês salvos.'
    end

    def copy_previous
      count = CommissionRate.copy_previous!(@month)
      redirect_to finance_commissions_path(mes: month_param),
                  notice: count.zero? ? 'Nada para copiar: todos já têm percentual ou não há mês anterior com percentuais.' : "#{count} #{count == 1 ? 'percentual copiado' : 'percentuais copiados'} do mês anterior."
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
