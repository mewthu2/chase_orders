module HomeHelper
  def kind_display_name(kind)
    case kind
    when 'rj'
      'Rio de Janeiro'
    when 'bh_shopping'
      'BH Shopping'
    when 'lagoa_seca'
      'Lagoa Seca'
    else
      kind.titleize
    end
  end
end
