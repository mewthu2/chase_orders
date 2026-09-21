module AddressCorrectionsHelper
  # Selo do pedido com correção de endereço no Honey (ou aguardando a correção da nota no Tiny).
  def address_correction_badge(correction)
    return if correction.nil?

    if correction.awaiting_tiny_fix?
      content_tag(:span, 'Aguardando correção da nota no Tiny', class: 'badge bg-warning text-dark address-correction-badge',
                  title: "Correção do Honey: #{correction.summary}. O Tiny recusou o endereço da nota.")
    else
      content_tag(:span, 'Endereço corrigido', class: 'badge bg-info text-dark address-correction-badge',
                  title: "Correção do Honey: #{correction.summary}")
    end
  end

  def nota_fiscal_edit_url(invoice_id)
    "#{ENV.fetch('TINY_NOTA_FISCAL_URL', 'https://erp.tiny.com.br/notas_fiscais#edit/')}#{invoice_id}"
  end
end
