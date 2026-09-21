module CompaniesHelper
  ICMS_SITUATIONS = [
    ['102 - Simples: tributada sem permissão de crédito', '102'],
    ['103 - Simples: isenção do ICMS para faixa de receita bruta', '103'],
    ['300 - Simples: imune', '300'],
    ['400 - Simples: não tributada', '400'],
    ['40 - Normal: isenta', '40'],
    ['41 - Normal: não tributada', '41'],
    ['50 - Normal: suspensão', '50']
  ].freeze

  PIS_COFINS_CSTS = [
    ['04 - Monofásica (alíquota zero)', '04'],
    ['05 - Substituição tributária', '05'],
    ['06 - Alíquota zero', '06'],
    ['07 - Isenta', '07'],
    ['08 - Sem incidência', '08'],
    ['09 - Com suspensão', '09'],
    ['49 - Outras operações de saída', '49'],
    ['99 - Outras operações', '99']
  ].freeze

  CERTIFICATE_BADGES = {
    missing: ['Sem certificado', 'status-pill--inactive'],
    expired: ['Vencido', 'status-pill--inactive'],
    expiring: ['Vence em breve', ''],
    valid: ['Válido', 'status-pill--active']
  }.freeze

  def certificate_badge(company)
    label, css = CERTIFICATE_BADGES.fetch(company.certificate_status)
    if company.certificate_status == :expiring
      days = ((company.certificate_expires_at - Time.current) / 1.day).ceil
      label = "Vence em #{days} dia(s)"
    end
    content_tag(:span, label, class: "status-pill #{css}".strip)
  end
end
