module AttemptsHelper
  def kind_icon(kind)
    case kind
    when 'emission_invoice_tiny2'
      'fas fa-file-invoice-dollar'
    when 'create_note_tiny2'
      'fas fa-sticky-note'
    when 'transfer_tiny_to_shopify_order'
      'fas fa-exchange-alt'
    else
      'fas fa-question'
    end
  end
end
