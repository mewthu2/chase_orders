class AddFreightServiceToB2bOrders < ActiveRecord::Migration[7.2]
  # Serviço de frete (forma_frete no Tiny), ex.: "SEDEX CORREIOS LOG+". Só é usado quando a
  # Forma de Envio é Correios Log; o fluxo dos Correios do Honey depende desse nome.
  def change
    add_column :b2b_orders, :freight_service, :string
  end
end
