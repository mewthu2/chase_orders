module Reports
  # Adm › Dashboards e relatórios › Análise de produtos do atacado (Reports::WholesaleProducts): curva ABC,
  # produtos parados, tendência, margem, giro das entradas no Log02 e candidatos a outlet.
  class WholesaleProductsController < ApplicationController
    guard_screen :report_wholesale_products

    def index
      @report = Reports::WholesaleProducts.new(Reports::WholesaleSales.period(params[:periodo].presence || '12m'), basis: params[:base])
    end
  end
end
