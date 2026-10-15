# frozen_string_literal: true

module Cashback
  class Unify
    class Error < StandardError; end

    def initialize(unification, gateway: ShopifyGateway.new)
      @unification = unification
      @gateway = gateway
      @mutation_started = false
    end

    def call
      return @unification if @unification.reload.completed?

      claim!
      begin
        revalidate!
        @unification.source_snapshots.each_with_index do |source, index|
          # Persist BEFORE the request. A timeout or killed worker is never assumed to mean failure.
          @unification.update!(step: "deactivate_#{index + 1}")
          @mutation_started = true
          @gateway.deactivate(source.fetch('node_id'))
          verify_deactivated!(source)
          Discount.where(shopify_node_id: source['node_id']).update_all(
            is_active: false, is_expired: true, status: 'EXPIRED', ends_at: Time.current, last_synced_at: Time.current
          )
        end
        # Recheck both immediately before issuing the replacement.
        @unification.source_snapshots.each { |source| verify_deactivated!(source) }
        raise Error, 'A validade terminou durante a unificação.' if @unification.expires_at <= Time.current

        @unification.update!(step: 'create')
        node_id = @gateway.create(new_discount_input)
        @unification.update!(shopify_node_id: node_id, step: 'verify')
        verify_created!
        @unification.update!(status: :completed, completed_at: Time.current, step: 'completed', error_message: nil)
        log_result
      rescue StandardError => error
        fail_operation!(error)
        raise Error, @unification.error_message
      end
      @unification
    end

    private

    def claim!
      @unification.with_lock do
        raise Error, 'Esta operação já foi processada ou está em conferência. Consulte o histórico.' unless @unification.draft?
        raise Error, 'A conferência expirou. Consulte os cupons novamente.' if @unification.created_at < 10.minutes.ago

        @unification.source_snapshots.sort_by { |source| source['node_id'] }.each do |source|
          # Use the unique database index, not a check-then-insert validation, as the arbiter.
          @unification.sources.build(shopify_node_id: source.fetch('node_id')).save!(validate: false)
        end
        @unification.update!(status: :processing, step: 'validate')
      end
    rescue ActiveRecord::RecordNotUnique
      raise Error, 'Um dos cupons já está reservado ou foi unificado em outra operação. Consulte o histórico.'
    end

    def revalidate!
      current = Preview.new(gateway: @gateway).call(
        codes: @unification.source_codes, customer: @unification.customer,
        ownership_confirmed: @unification.ownership_confirmed
      )
      unless current[:source_snapshots] == @unification.source_snapshots && current[:customer_gid] == @unification.customer_gid
        raise Error, 'Os cupons ou a cliente mudaram desde a conferência. Consulte os cupons novamente.'
      end
      raise Error, 'O código reservado para o novo cupom já existe. Faça uma nova consulta.' if @gateway.lookup(@unification.code)
    end

    def verify_deactivated!(source)
      node = @gateway.lookup(source.fetch('code'))
      data = node&.fetch('codeDiscount', nil)
      unless node&.dig('id') == source['node_id'] && data && data['status'] == 'EXPIRED' &&
             Time.iso8601(data.fetch('endsAt')) <= Time.current && data['asyncUsageCount'] == 0 &&
             data.except('status', 'endsAt') == source.fetch('data').except('status', 'endsAt')
        raise Error, 'Não foi possível confirmar a desativação sem uso dos cupons originais.'
      end
    end

    def new_discount_input
      {
        title: @unification.code, code: @unification.code,
        startsAt: Time.current.iso8601, endsAt: @unification.expires_at.iso8601,
        usageLimit: 1, appliesOncePerCustomer: true,
        context: { customers: { add: [@unification.customer_gid] } },
        customerGets: {
          items: { all: true }, appliesOnOneTimePurchase: true, appliesOnSubscription: false,
          value: { discountAmount: { amount: @unification.amount.to_s('F'), appliesOnEachItem: false } }
        },
        minimumRequirement: { subtotal: { greaterThanOrEqualToSubtotal: @unification.minimum_purchase.to_s('F') } },
        combinesWith: @unification.source_snapshots.first.fetch('data').fetch('combinesWith')
      }
    end

    def verify_created!
      node = @gateway.lookup(@unification.code)
      data = node&.dig('codeDiscount')
      amount = data&.dig('customerGets', 'value', 'amount')
      minimum = data&.dig('minimumRequirement', 'greaterThanOrEqualToSubtotal')
      unless node&.dig('id') == @unification.shopify_node_id && data && data['__typename'] == 'DiscountCodeBasic' &&
             data['status'] == 'ACTIVE' && data['usageLimit'] == 1 && data['appliesOncePerCustomer'] == true &&
             data.dig('codes', 'nodes') == [{ 'code' => @unification.code }] && data.dig('codes', 'pageInfo', 'hasNextPage') == false &&
             data.dig('context', '__typename') == 'DiscountCustomers' &&
             data.dig('context', 'customers') == [{ 'id' => @unification.customer_gid }] &&
             amount&.dig('currencyCode') == 'BRL' && BigDecimal(amount.fetch('amount')) == @unification.amount &&
             minimum&.dig('currencyCode') == 'BRL' && BigDecimal(minimum.fetch('amount')) == @unification.minimum_purchase &&
             Time.iso8601(data.fetch('endsAt')) == @unification.expires_at &&
             data.dig('customerGets', 'items', '__typename') == 'AllDiscountItems' &&
             data.dig('customerGets', 'value', 'appliesOnEachItem') == false &&
             data.dig('customerGets', 'appliesOnSubscription') == false && data.dig('customerGets', 'appliesOnOneTimePurchase') == true &&
             data['combinesWith'] == @unification.source_snapshots.first.dig('data', 'combinesWith')
        raise Error, 'O novo cupom ainda não pôde ser conferido na Shopify.'
      end
    end

    def fail_operation!(error)
      message = if @mutation_started
                  'A Shopify não confirmou todas as etapas. Não utilize os cupons nem repita a operação; solicite conferência ao administrador.'
                else
                  error.is_a?(Preview::Error) || error.is_a?(Error) ? error.message : 'Não foi possível conferir os cupons na Shopify. Consulte novamente.'
                end
      @unification.with_lock do
        @unification.update!(status: @mutation_started ? :needs_review : :rejected, error_message: message)
        CashbackUnificationSource.where(cashback_unification_id: @unification.id).delete_all unless @mutation_started
      end
      # Do not log transport exception text: it can contain request headers/tokens.
      Rails.logger.error("CashbackUnification #{@unification.id}: #{@unification.step} (#{error.class})")
      log_result
    end

    def log_result
      LogService.create_log(
        user: @unification.user, resource_type: 'discount', action_type: 'unify',
        resource_name: @unification.code, resource_id: @unification.id,
        details: { source_codes: @unification.source_codes, customer_gid: @unification.customer_gid,
                   ownership_confirmed: @unification.ownership_confirmed, step: @unification.step },
        new_values: { cashback: @unification.amount.to_s('F'), minimum: @unification.minimum_purchase.to_s('F'),
                      expires_at: @unification.expires_at.iso8601 },
        success: @unification.completed?, error_message: @unification.error_message
      )
    end
  end
end
