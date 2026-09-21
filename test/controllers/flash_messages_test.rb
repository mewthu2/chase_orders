require 'test_helper'

class FlashMessagesTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(name: 'Admin Flash', email: 'admin_flash@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @client = Client.create!(responsible_name: 'Cliente Flash', registration: '25.405.327/0001-74')
    sign_in @admin
  end

  def cancelled_order
    order = B2bOrder.new(kind: :sale, user: @admin, client: @client, status: :cancelado)
    order.b2b_order_items.build(sku: 'SKU1', quantity: 1, price: 1)
    order.save!
    order
  end

  test 'flash messages are rendered by the layout on any page, exactly once' do
    post transmit_b2b_order_path(cancelled_order)
    follow_redirect!

    assert_response :success
    assert_select '.flash-messages-container .alert', count: 1
    assert_select '.flash-messages-container .alert', text: /não pode ser reenviado/
  end

  test 'the flash container is anchored to the bottom right corner' do
    css = Rails.root.join('app/assets/stylesheets/admin/_layout.scss').read
    block = css[/\.flash-messages-container \{[^}]*\}/m]

    assert_match(/position:\s*fixed/, block)
    assert_match(/bottom:/, block)
    assert_match(/right:/, block)
  end

  test 'pages no longer render the messages partial themselves' do
    offenders = Dir[Rails.root.join('app/views/**/*.erb')].select do |path|
      next false if path.end_with?('layouts/partials/_messages.html.erb', 'layouts/application.html.erb')

      File.read(path).include?("layouts/partials/messages")
    end

    assert_empty offenders.map { |p| p.sub(Rails.root.to_s + '/', '') }
  end
end
