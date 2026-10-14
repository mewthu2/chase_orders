module CashbackFactory
  def setup_cashback
    travel_to Time.utc(2026, 10, 14, 18)
    [Profile::ADMIN, Profile::MANAGER, Profile::USER].each do |id|
      Profile.find_or_create_by!(id: id) { |profile| profile.name = "Perfil #{id}" }
    end
    @user = User.create!(name: 'Gerente Cashback', email: 'cashback@example.com', password: 'password123', profiles: [Profile.find(Profile::MANAGER)])
    @user.profiles.first.screen_keys = ['cashback_unifications']
    @user.profiles.first.save!
    @customer = Customer.create!(shopify_customer_id: '123', first_name: 'Ana', last_name: 'Teste', email: 'ana@example.com')
    @gateway = FakeCashbackGateway.new
    @gateway.nodes['MTZA'] = cashback_node('MTZA', '1', amount: '20.10', minimum: '100.01', ends_at: 2.days.from_now)
    @gateway.nodes['MTZB'] = cashback_node('MTZB', '2', amount: '30.20', minimum: '150.02', ends_at: 1.day.from_now)
  end

  def cashback_node(code, id, amount: '20.10', minimum: '100.01', ends_at: 2.days.from_now)
    {
      'id' => "gid://shopify/DiscountCodeNode/#{id}",
      'codeDiscount' => {
        '__typename' => 'DiscountCodeBasic', 'title' => code, 'status' => 'ACTIVE',
        'startsAt' => 1.day.ago.iso8601, 'endsAt' => ends_at.iso8601,
        'asyncUsageCount' => 0, 'usageLimit' => 1, 'appliesOncePerCustomer' => true,
        'codes' => { 'nodes' => [{ 'code' => code }], 'pageInfo' => { 'hasNextPage' => false } },
        'context' => { '__typename' => 'DiscountCustomers', 'customers' => [{ 'id' => 'gid://shopify/Customer/123' }] },
        'combinesWith' => { 'orderDiscounts' => false, 'productDiscounts' => false, 'shippingDiscounts' => false },
        'customerGets' => {
          'appliesOnOneTimePurchase' => true, 'appliesOnSubscription' => false,
          'items' => { '__typename' => 'AllDiscountItems' },
          'value' => { '__typename' => 'DiscountAmount', 'amount' => { 'amount' => amount, 'currencyCode' => 'BRL' }, 'appliesOnEachItem' => false }
        },
        'minimumRequirement' => { '__typename' => 'DiscountMinimumSubtotal', 'greaterThanOrEqualToSubtotal' => { 'amount' => minimum, 'currencyCode' => 'BRL' } }
      }
    }
  end

  def preview(ownership_confirmed: false, codes: %w[MTZA MTZB])
    Cashback::Preview.new(gateway: @gateway).call(codes: codes, customer: @customer, ownership_confirmed: ownership_confirmed)
  end

  def draft_unification
    CashbackUnification.create!(preview.merge(user: @user, code: "UNF#{SecureRandom.hex(8).upcase}"))
  end

  def unify(record)
    Cashback::Unify.new(record, gateway: @gateway).call
  end

  class FakeCashbackGateway
    attr_accessor :before_deactivate, :after_deactivate, :after_create
    attr_reader :nodes, :writes, :inputs

    def initialize
      @nodes = {}
      @writes = []
      @inputs = []
    end

    def lookup(code) = nodes[code]&.deep_dup

    def deactivate(id)
      @writes << [:deactivate, id]
      before_deactivate&.call(id)
      node = nodes.values.find { |value| value['id'] == id }
      node['codeDiscount']['status'] = 'EXPIRED'
      node['codeDiscount']['endsAt'] = Time.current.iso8601
      after_deactivate&.call(id)
      id
    end

    def create(input)
      @writes << [:create, input[:code]]
      @inputs << input
      data = nodes.values.first.fetch('codeDiscount').deep_dup
      data.merge!(
        'title' => input[:title], 'status' => 'ACTIVE', 'startsAt' => input[:startsAt], 'endsAt' => input[:endsAt],
        'usageLimit' => input[:usageLimit], 'appliesOncePerCustomer' => input[:appliesOncePerCustomer],
        'codes' => { 'nodes' => [{ 'code' => input[:code] }], 'pageInfo' => { 'hasNextPage' => false } },
        'context' => { '__typename' => 'DiscountCustomers', 'customers' => input.dig(:context, :customers, :add).map { |id| { 'id' => id } } }
      )
      data['customerGets']['value']['amount']['amount'] = input.dig(:customerGets, :value, :discountAmount, :amount)
      data['minimumRequirement']['greaterThanOrEqualToSubtotal']['amount'] = input.dig(:minimumRequirement, :subtotal, :greaterThanOrEqualToSubtotal)
      nodes[input[:code]] = { 'id' => 'gid://shopify/DiscountCodeNode/new', 'codeDiscount' => data }
      after_create&.call
      nodes[input[:code]]['id']
    end
  end
end
