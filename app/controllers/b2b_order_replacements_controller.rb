# Pedido de devolução do atacado: a partir de um pedido de venda, escolhe as peças devolvidas (ex.: com defeito)
# e cria um pedido novo vinculado, para o mesmo cliente e endereço, que repõe as peças sem cobrança. Ele segue o
# Log02 e o Correios como uma venda; a NF-e sai pela configuração de devolução (B2bSetting#return_issuer).
# A aba Nota fiscal de qualquer pedido de venda marca/desmarca a devolução e guarda as chaves (update).
class B2bOrderReplacementsController < ApplicationController
  guard_screen :b2b_orders, actions: { new: :create, create: :create, update: :edit }
  before_action :set_original, only: %i[new create]

  # Campos do pedido original que não passam para a devolução.
  SKIP = %w[id kind status created_at updated_at tiny_reference_id tiny_reference_number error_message tracking_code correios_order_id
            xml_sent_at log_ignored nf_additional_info nf_carrier_id nf_freight_mode order_discount order_discount_type payment_terms
            payment_method freight_value fixed_freight notes replacement replacement_of_id original_nfe_key return_nfe_key
            remessa_recipient user_id].freeze

  def new
    @items = @original.b2b_order_items.order(:id).to_a
    @original_key = original_key
  end

  def create
    quantities = params.fetch(:qty, {}).permit!.to_h.transform_keys(&:to_i).transform_values(&:to_i)
    items = @original.b2b_order_items.select { |i| quantities[i.id].to_i.positive? }
    return redirect_to(new_replacement_b2b_order_path(@original), alert: 'Escolha pelo menos uma peça para devolver.') if items.empty?

    over = items.find { |i| quantities[i.id] > i.quantity.to_i }
    return redirect_to(new_replacement_b2b_order_path(@original), alert: "#{over.sku}: o pedido original tem só #{over.quantity}.") if over

    order = B2bOrder.new(@original.attributes.except(*SKIP))
    order.assign_attributes(kind: :sale, status: :aberto, user: current_user, replacement: true, replacement_of: @original,
                            original_nfe_key: params[:original_nfe_key].presence || original_key, return_nfe_key: params[:return_nfe_key],
                            order_discount: 100, order_discount_type: 'percent', freight_value: 0, fixed_freight: true,
                            notes: ["Devolução do pedido ##{@original.id}: reposição das peças devolvidas, sem cobrança.", params[:notes].to_s.strip.presence].compact.join("\n"))
    items.each { |i| order.b2b_order_items.build(sku: i.sku, name: i.name, price: i.price, discount: i.discount, quantity: quantities[i.id]) }

    if order.save
      HoneyB2bLog.sync_reservations!
      redirect_to edit_b2b_order_path(order), notice: "Pedido de devolução ##{order.id} criado com #{order.b2b_order_items.sum(&:quantity)} peça(s). Ele segue no Log02 depois de aprovado; a nota sai pela configuração de devolução."
    else
      @items = @original.b2b_order_items.order(:id).to_a
      @original_key = original_key
      flash.now[:alert] = order.errors.full_messages.to_sentence
      render :new, status: :unprocessable_content
    end
  end

  # Aba Nota fiscal: marca o pedido como devolução e guarda as chaves (só enquanto a nota de produção não sai).
  def update
    order = B2bOrder.sale.find(params[:id])
    back = edit_b2b_order_path(order, tab: 'nota')
    if (lock = order.nf_details_lock)
      return redirect_to(back, alert: "A NF-e nº #{lock.number} está #{lock.status_label.downcase}: a devolução não muda mais.")
    end

    data = params.require(:replacement).permit(:replacement, :original_nfe_key, :return_nfe_key)
    order.assign_attributes(replacement: data[:replacement] == '1', original_nfe_key: data[:original_nfe_key], return_nfe_key: data[:return_nfe_key])
    order.valid?
    errors = order.errors.select { |e| e.attribute.to_s.end_with?('nfe_key') }
    return redirect_to(back, alert: errors.map(&:full_message).to_sentence) if errors.any?

    order.update_columns(replacement: order.replacement, original_nfe_key: order.original_nfe_key, return_nfe_key: order.return_nfe_key, updated_at: Time.current)
    redirect_to back, notice: order.replacement? ? 'Pedido de devolução: a nota sai pela configuração de devolução, com as chaves informadas.' : 'O pedido voltou a ser uma venda comum.'
  end

  private

  def set_original
    @original = B2bOrder.sale.includes(:b2b_order_items, :client).find(params[:id])
  end

  # Chave da NF-e de venda autorizada em produção do pedido original, quando ela saiu pelo Honey.
  def original_key
    @original.original_nfe_key.presence ||
      FiscalNote.principal.where(b2b_order_id: @original.id, environment: :producao, status: :autorizada).order(:authorized_at).last&.access_key
  end
end
