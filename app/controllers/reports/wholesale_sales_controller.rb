module Reports
  # Adm › Dashboards e relatórios › Vendas Atacado: faturamento das NF-e de venda do atacado (Reports::WholesaleSales).
  class WholesaleSalesController < ApplicationController
    guard_screen :report_wholesale_sales

    def index
      @report = Reports::WholesaleSales.new(Reports::WholesaleSales.period(params[:periodo]))
    end
  end
end
