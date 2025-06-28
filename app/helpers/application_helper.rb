module ApplicationHelper
  def title(page_title)
    content_for(:title) { page_title }
  end

  def verify_comercial_hour?
    # dia_da_semana = Time.now.wday

    # hora_atual = Time.now.hour
    # minutos_atual = Time.now.min

    # dia_da_semana >= 1 && dia_da_semana <= 5 && (hora_atual > 8 || (hora_atual == 8 && minutos_atual >= 0)) && hora_atual < 15
    true
  end

  def within_schedule?
    now = Time.zone.now
    weekday = (1..5).include?(now.wday)      # Segunda (1) a sexta (5)
    work_hours = now.hour.between?(8, 21)    # Das 08h até 21:59 (pois 22:00 em diante já não é válido)
    weekday && work_hours
  end

  def client_shopify_graphql
    session = ShopifyAPI::Auth::Session.new(
      shop: 'chasebrasil.myshopify.com',
      access_token: ENV.fetch('BH_SHOPPING_TOKEN_APP')
    )
    ShopifyAPI::Clients::Graphql::Admin.new(session:)
  end

  def client_shopify_rest
    session = ShopifyAPI::Auth::Session.new(
      shop: 'chasebrasil.myshopify.com',
      access_token: ENV.fetch('BH_SHOPPING_TOKEN_APP')
    )
    ShopifyAPI::Clients::Rest::Admin.new(session:)
  end
end
