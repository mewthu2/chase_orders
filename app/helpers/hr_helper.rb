module HrHelper
  def hr_hours(minutes, sign: false) = HrEmployee.hours(minutes, sign: sign)

  def hr_punch_url(employee) = punch_clock_url(employee.punch_token)

  # QR code do link do ponto (SVG), para imprimir ou mostrar na tela.
  def hr_qr_svg(url)
    RQRCode::QRCode.new(url).as_svg(module_size: 4, standalone: true, use_path: true, color: '0b0e13', shape_rendering: 'crispEdges', viewbox: true).html_safe
  end

  def hr_whatsapp_url(employee)
    text = "Oi, #{employee.first_name}! Este é o seu link para bater o ponto na Chase (abre a câmera do celular): #{hr_punch_url(employee)}"
    phone = employee.phone.to_s.gsub(/\D/, '')
    phone = "55#{phone}" if phone.size.between?(10, 11)
    "https://wa.me/#{phone}?text=#{ERB::Util.url_encode(text)}"
  end

  def hr_employees_table(employees, open_now:, week_alerts:)
    rows = employees.map do |e|
      { id: e.id, record: e, nome: e.name, cargo: e.role.to_s, empresa: e.company_name.to_s, uf: e.state, carga: hr_hours(e.weekly_minutes),
        dias: e.work_days.map { |d| HrEmployee::WEEKDAYS[d][0, 3] }.join(' '), cpf: e.cpf_formatted,
        agora: open_now.include?(e.id) ? 'trabalhando' : 'fora', alertas: week_alerts[e.id].to_i, st: e.active? ? 'ativo' : 'inativo' }
    end
    companies = employees.map { |e| e.company_name.to_s }.uniq.sort.map { |n| [n, n] }
    states = employees.map(&:state).uniq.sort.map { |s| [s, s] }
    HoneyTable.new(params, rows: rows, unit: 'funcionários', unit1: 'funcionário', page_size: 25, sort: { k: :nome, dir: 1 },
      cols: [
        { k: :nome, label: 'Funcionário', main: true, sub: :cargo, sort: true },
        { k: :cargo, label: 'Cargo', hide: true },
        { k: :cpf, label: 'CPF', hide: true },
        { k: :empresa, label: 'Empresa', sort: true },
        { k: :uf, label: 'Estado', t: :tag, sort: true },
        { k: :carga, label: 'Carga semanal', sub: :dias },
        { k: :dias, label: 'Dias', hide: true, nodetail: true },
        { k: :agora, label: 'Agora', t: :status, map: { 'trabalhando' => ['Trabalhando', 'green', 'Bateu a entrada e ainda não saiu.'], 'fora' => ['Fora', 'gray', 'Sem período aberto.'] } },
        { k: :alertas, label: 'Alertas na semana', t: :qty, sort: true },
        { k: :st, label: 'Cadastro', t: :status, map: { 'ativo' => ['Ativo', 'blue', 'O link do ponto funciona.'], 'inativo' => ['Inativo', 'gray', 'O link do ponto não funciona.'] } }
      ],
      filters: [
        { id: :q, type: :search, label: 'Buscar', ph: 'Nome, cargo ou CPF…', cols: %i[nome cargo cpf] },
        { id: :empresa, type: :select, label: 'Empresa', col: :empresa, all: 'Todas', options: companies },
        { id: :uf, type: :select, label: 'Estado', col: :uf, all: 'Todos', options: states },
        { id: :st, type: :select, label: 'Cadastro', col: :st, all: 'Todos' }
      ],
      kpis: [
        { label: 'Funcionários ativos', icon: 'fas fa-id-card', tone: 'blue', help: 'Com o link do ponto ligado.', col: :st, vals: ['ativo'] },
        { label: 'Trabalhando agora', icon: 'fas fa-person-running', tone: 'green', help: 'Bateram a entrada e não saíram.', col: :agora, vals: ['trabalhando'] },
        { label: 'Com alerta na semana', icon: 'fas fa-triangle-exclamation', tone: 'yellow', help: 'Acima da carga ou fora da CLT.', count: rows.count { |r| r[:alertas].positive? } },
        { label: 'Empresas', icon: 'fas fa-building', tone: 'brand', help: 'Com funcionários cadastrados.', count: companies.size }
      ])
  end

  def hr_alerts_table(alerts)
    rows = alerts.map do |a|
      { id: a.id, record: a, nome: a.employee.name, empresa: a.employee.company_name.to_s, uf: a.employee.state, tipo: a.kind,
        dia: a.work_date, periodo: a.period_text, msg: a.message, lei: a.law, aviso: a.notified_at }
    end
    HoneyTable.new(params, rows: rows, unit: 'alertas', unit1: 'alerta', page_size: 30, sort: { k: :dia, dir: -1 },
      cols: [
        { k: :nome, label: 'Funcionário', main: true, sub: :empresa, sort: true },
        { k: :empresa, label: 'Empresa', hide: true },
        { k: :uf, label: 'Estado', t: :tag },
        { k: :tipo, label: 'Alerta', t: :status, map: HrAlert::KINDS.transform_values { |v| [v[:label], v[:tone], v[:law]] } },
        { k: :dia, label: 'Dia', t: :d, sub: :periodo, sort: true },
        { k: :periodo, label: 'Período', hide: true, nodetail: true },
        { k: :msg, label: 'O que aconteceu' },
        { k: :lei, label: 'Regra', hide: true },
        { k: :aviso, label: 'E-mail enviado', t: :dt }
      ],
      filters: [
        { id: :q, type: :search, label: 'Buscar', ph: 'Funcionário ou empresa…', cols: %i[nome empresa] },
        { id: :tipo, type: :select, label: 'Alerta', col: :tipo, all: 'Todos' },
        { id: :uf, type: :select, label: 'Estado', col: :uf, all: 'Todos', options: rows.map { |r| r[:uf] }.uniq.sort.map { |s| [s, s] } },
        { id: :p, type: :period, label: 'Período', col: :dia }
      ],
      kpis: [
        { label: 'Alertas', icon: 'fas fa-bell', tone: 'blue', help: 'Todos os registrados.', count: rows.size },
        { label: 'Acima da carga', icon: 'fas fa-clock', tone: 'yellow', help: 'No dia, na semana ou na folga.', col: :tipo, vals: %w[daily_over weekly_over day_off] },
        { label: 'Limites da CLT', icon: 'fas fa-scale-balanced', tone: 'red', help: '2h extras, intervalo e descanso de 11h.', col: :tipo, vals: %w[daily_limit break_short rest_short] }
      ])
  end
end
