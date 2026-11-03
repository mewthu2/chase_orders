# Casca do painel: menu por área, trilha do topo, busca rápida, mapa e ajuda (Navigation).
module NavigationHelper
  SUPPORT_WHATSAPP = 'https://wa.me/5516992375432'.freeze
  TONES = { 'gray' => '#8b949e', 'yellow' => '#e3b341', 'blue' => '#58a6ff', 'green' => '#3fb950',
            'red' => '#f85149', 'purple' => '#b58cff', 'orange' => '#f0883e' }.freeze

  def nav_menu
    @nav_menu ||= Navigation.for(current_user)
  end

  def nav_entries
    @nav_entries ||= Navigation.flatten(nav_menu)
  end

  # Tela atual: { item:, area:, group: } ou nil (telas que não estão no menu).
  def nav_current
    return @nav_current if defined?(@nav_current)

    candidates = nav_entries + Navigation.extras.select { |e| Navigation.allowed?(e, current_user) }.map { |e| { item: e, area: nil, group: nil } }
    @nav_current = candidates.find { |entry| entry[:item][:active]&.call(self) }
  end

  def nav_path(item)
    item[:path].call(self)
  end

  # Trilha do topo: a área e o grupo levam à primeira tela que o usuário abre neles.
  def nav_group_path(group)
    link = group[:children].find { |c| c[:type] == :link }
    link ? nav_path(link) : root_path
  end

  def nav_area_path(area)
    first = area[:items].first
    first[:type] == :group ? nav_group_path(first) : nav_path(first)
  end

  def nav_active?(item)
    nav_current && nav_current[:item].equal?(item)
  end

  def nav_area_active?(area)
    nav_current && nav_current[:area] && nav_current[:area][:id] == area[:id]
  end

  def nav_group_active?(group)
    nav_current && nav_current[:group] && nav_current[:group][:id] == group[:id]
  end

  def nav_area_style(area)
    "--area: #{area[:color]}"
  end

  def nav_badge_count(key)
    @nav_badges ||= {}
    @nav_badges[key] ||= case key
                         when :waiting_me then Ticket.waiting_on_user(current_user).count
                         when :catalogs then B2bCatalogOrder.pending.count
                         else 0
                         end
  end

  def nav_badge(key, extra_class = nil)
    return unless key

    count = nav_badge_count(key)
    return unless count.positive?

    tip = key == :waiting_me ? 'Chamados em que a próxima ação é sua' : 'Encomendas novas, que ninguém viu ainda'
    content_tag(:span, count, class: ['sb-badge', extra_class].compact.join(' '), data: { tip: tip })
  end

  def user_initials(user)
    user.name.to_s.split.values_at(0, -1).compact.uniq.map { |part| part[0] }.join.upcase.presence || '?'
  end

  # Ajuda da tela atual (config/honey/help.json), com o que o perfil pode fazer nela.
  def nav_help
    entry = nav_current
    id = entry ? entry[:item][:id] : nil
    return tickets_help if id.nil? || %w[inicio chamados-setores chamados-todos].include?(id)

    screen = Navigation.help['screens'][id] || {}
    item = entry[:item]
    {
      title: "Ajuda: #{screen['title'] || item[:label]}",
      sub: [entry[:area]&.dig(:title), entry[:group]&.dig(:label)].compact.join(' › '),
      icon: item[:icon], id: id, screen: screen, item: item, group: entry[:group],
      perm: item[:perm]
    }
  end

  def tickets_help
    { title: 'Ajuda: Chamados', sub: 'Pedidos de ajuda entre setores', icon: 'fas fa-ticket-alt', id: 'inicio', tickets: true, perm: 'tickets' }
  end

  def help_tone(name)
    TONES.fetch(name.to_s, TONES['gray'])
  end

  # Dados da busca rápida e do mapa, já filtrados pelo perfil (JSON lido por honey_shell.js).
  def nav_search_data
    keywords = Navigation.help['keywords']
    screens = Navigation.help['screens']
    rows = nav_entries.map do |entry|
      item = entry[:item]
      path = [entry[:area][:title], entry[:group]&.dig(:label)].compact.join(' › ')
      label = entry[:group]&.dig(:aka) ? "#{item[:label]} (#{entry[:group][:label]})" : item[:label]
      { id: item[:id], label: label, icon: item[:icon], desc: item[:desc], path: path, url: nav_path(item), area: entry[:area][:id],
        keys: [keywords[item[:id]], screens.dig(item[:id], 'title'), entry[:group]&.dig(:aka)].compact.join(' ') }
    end
    extras = Navigation.extras.select { |e| Navigation.allowed?(e, current_user) }.map do |item|
      { id: item[:id], label: item[:label], icon: item[:icon], desc: item[:desc], path: item[:section], url: nav_path(item), keys: item[:keys].to_s }
    end
    glossary = Navigation.help['glossary'].map { |term, text| { term: term, text: text } }
    { screens: rows, extras: extras, glossary: glossary }
  end

  def nav_map
    nav_menu.map do |area|
      groups = area[:items].map do |item|
        if item[:type] == :group
          { label: item[:label], icon: item[:icon], desc: item[:desc], aka: item[:aka], links: item[:children].select { |c| c[:type] == :link } }
        else
          { label: nil, links: [item] }
        end
      end
      { area: area, groups: groups }
    end
  end
end
