require 'test_helper'

class InternalTransferTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(name: 'Solicitante', email: 'solicitante@example.com', password: 'password123')
    @destination = Location.create!(slug: 'lagoa_seca', name: 'Lagoa Seca', shopify_location_id: '1')
    @origin_a = Location.create!(slug: 'bh_shopping', name: 'BH Shopping', shopify_location_id: '2')
    @origin_b = Location.create!(slug: 'rj', name: 'RJ', shopify_location_id: '3')
    @product = Product.create!(sku: 'SKU-1', shopify_product_name: 'Camiseta', shopify_inventory_item_id: '9001')
  end

  def build_transfer(items: [[@origin_a, @product, 2]], **attrs)
    transfer = InternalTransfer.new({ destination_location: @destination, requested_by: @user, approval_status: :aprovada }.merge(attrs))
    items.group_by { |origin, _, _| origin }.each do |origin, group|
      shipment = transfer.shipments.build(origin_location: origin)
      group.each { |_, product, qty| shipment.items.build(product: product, quantity: qty) }
    end
    transfer
  end

  test 'is valid with a destination, a requester and at least one item' do
    transfer = build_transfer
    assert transfer.valid?, transfer.errors.full_messages.to_sentence
  end

  test 'requires at least one item across all shipments' do
    transfer = build_transfer(items: [])
    refute transfer.valid?
    assert_includes transfer.errors.full_messages.to_sentence, 'pelo menos um item'
  end

  test 'a shipment cannot have the same origin as the transfer destination' do
    transfer = build_transfer(items: [[@destination, @product, 1]])
    refute transfer.valid?
    assert_match(/mesma loja de destino/, transfer.errors.full_messages.to_sentence)
  end

  test 'grouping items by origin creates one shipment per origin store' do
    transfer = build_transfer(items: [[@origin_a, @product, 2], [@origin_b, @product, 3]])
    transfer.save!

    assert_equal 2, transfer.shipments.count
    assert_equal [@origin_a, @origin_b].map(&:id).sort, transfer.shipments.map(&:origin_location_id).sort
  end

  test 'total_quantity sums every item across shipments' do
    transfer = build_transfer(items: [[@origin_a, @product, 2], [@origin_b, @product, 3]])
    transfer.save!

    assert_equal 5, transfer.total_quantity
  end

  test 'overall_status is open while every shipment is open' do
    transfer = build_transfer
    transfer.save!

    assert_equal 'aberto', transfer.overall_status
  end

  test 'overall_status is in_progress while shipments are in different stages' do
    transfer = build_transfer(items: [[@origin_a, @product, 2], [@origin_b, @product, 3]])
    transfer.save!
    transfer.shipments.first.update!(status: :recebido)

    assert_equal 'em_andamento', transfer.overall_status
  end

  test 'overall_status is completed once every shipment is received or cancelled, with at least one received' do
    transfer = build_transfer(items: [[@origin_a, @product, 2], [@origin_b, @product, 3]])
    transfer.save!
    transfer.shipments.first.update!(status: :recebido)
    transfer.shipments.second.update!(status: :cancelado)

    assert_equal 'concluida', transfer.overall_status
  end

  test 'overall_status is cancelled when every shipment was cancelled' do
    transfer = build_transfer
    transfer.save!
    transfer.shipments.first.update!(status: :cancelado)

    assert_equal 'cancelada', transfer.overall_status
  end

  test 'editable? and deletable? are true only while every shipment is still open' do
    transfer = build_transfer
    transfer.save!

    assert transfer.editable?
    assert transfer.deletable?

    transfer.shipments.first.update!(status: :reservado)
    refute transfer.reload.editable?
    refute transfer.deletable?
  end

  test 'my_action_needed? flags a shipment waiting on the origin (reserve/ship) or the destination (receive)' do
    transfer = build_transfer(items: [[@origin_a, @product, 2], [@origin_b, @product, 3]])
    transfer.save!
    transfer.shipments.find_by(origin_location: @origin_a).update!(status: :enviado)
    transfer.reload

    origin_manager = User.create!(name: 'Gerente RJ', email: 'gerente_rj@example.com', password: 'password123', allowed_locations: ['rj'])
    destination_manager = User.create!(name: 'Gerente Lagoa', email: 'gerente_lagoa@example.com', password: 'password123', allowed_locations: ['lagoa_seca'])
    unrelated_manager = User.create!(name: 'Gerente RJ2', email: 'gerente_rj2@example.com', password: 'password123', allowed_locations: ['eldorado_sp'])

    assert transfer.my_action_needed?(origin_manager)   # reservar a de RJ
    assert transfer.my_action_needed?(destination_manager) # receber a de BH
    refute transfer.my_action_needed?(unrelated_manager)
  end

  test 'a new transfer waits for approval and its shipments cannot be reserved until approved' do
    transfer = InternalTransfer.new(destination_location: @destination, requested_by: @user)
    transfer.shipments.build(origin_location: @origin_a).items.build(product: @product, quantity: 2)
    transfer.save!

    assert transfer.approval_pendente?
    assert_equal 'aguardando_aprovacao', transfer.overall_status
    assert transfer.editable?
    refute transfer.shipments.first.reservable?

    approver = User.create!(name: 'Aprovador', email: 'aprovador_m@example.com', password: 'password123')
    transfer.approve!(approver)

    assert transfer.reload.approval_aprovada?
    assert_equal approver, transfer.reviewed_by
    assert transfer.shipments.first.reservable?
    assert_equal 'approved', transfer.events.last.action
  end

  test 'reject! cancels every shipment and item and blocks edits' do
    transfer = build_transfer(items: [[@origin_a, @product, 2], [@origin_b, @product, 3]], approval_status: :pendente)
    transfer.save!
    approver = User.create!(name: 'Aprovador', email: 'aprovador_r@example.com', password: 'password123')

    transfer.reject!(approver, reason: 'Sem necessidade')
    transfer.reload

    assert transfer.approval_reprovada?
    assert_equal 'Sem necessidade', transfer.rejection_reason
    assert_equal 'reprovada', transfer.overall_status
    assert transfer.shipments.all?(&:cancelado?)
    assert transfer.shipments.flat_map(&:items).all?(&:cancelled?)
    refute transfer.editable?
    assert_raises(InternalTransfer::NotPending) { transfer.approve!(approver) }
  end

  test 'my_action_needed? while pending flags the approvers and the admins only' do
    transfer = build_transfer(approval_status: :pendente)
    transfer.save!
    approver = User.create!(name: 'Aprovador', email: 'aprovador_a@example.com', password: 'password123')
    other_approver = User.create!(name: 'Outro Aprovador', email: 'aprovador_b@example.com', password: 'password123')
    admin = User.create!(name: 'Admin', email: 'admin_a@example.com', password: 'password123')
    admin.profiles << Profile.find(Profile::ADMIN)
    origin_manager = User.create!(name: 'Gerente BH', email: 'gerente_bh_a@example.com', password: 'password123', allowed_locations: ['bh_shopping'])
    approver_ids = [approver.id, other_approver.id]

    assert transfer.my_action_needed?(approver, approver_ids: approver_ids)
    assert transfer.my_action_needed?(other_approver, approver_ids: approver_ids)
    assert transfer.my_action_needed?(admin, approver_ids: approver_ids)
    refute transfer.my_action_needed?(origin_manager, approver_ids: approver_ids)
  end
end
