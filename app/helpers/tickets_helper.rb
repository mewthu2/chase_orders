module TicketsHelper
  STATUS_COLORS = {
    'awaiting_responsible' => '#d29922',
    'awaiting_requester' => '#1f6feb',
    'in_progress' => '#8957e5',
    'resolved' => '#238636',
    'closed' => '#6e7681'
  }.freeze
  OVERDUE_COLOR = '#da3633'

  def self.status_color(status) = STATUS_COLORS.fetch(status.to_s, '#6e7681')

  def ticket_status_color(status) = TicketsHelper.status_color(status)

  def ticket_status_badge(ticket_or_status)
    status = ticket_or_status.is_a?(Ticket) ? ticket_or_status.status : ticket_or_status.to_s
    content_tag(:span, Ticket.status_label(status), class: "ticket-status ticket-status--#{status}")
  end

  def ticket_datetime(time) = time.in_time_zone.strftime('%d/%m/%Y às %H:%M')

  # "45 min", "3h", "5h20", "2 dias"
  def ticket_duration_words(seconds)
    minutes = (seconds.abs / 60).round
    return "#{minutes} min" if minutes < 60

    hours = minutes / 60
    return "#{hours / 24} dias" if hours >= 48

    rest = minutes % 60
    rest.zero? ? "#{hours}h" : format('%dh%02d', hours, rest)
  end

  def ticket_due_text(ticket)
    return 'Sem prazo (chamado encerrado)' unless ticket.open? && ticket.due_at

    remaining = ticket.due_at - Time.current
    words = ticket_duration_words(remaining)
    suffix = remaining.negative? ? "vencido há #{words}" : "em #{words}"
    "#{ticket_datetime(ticket.due_at)} (#{suffix})"
  end

  def ticket_due_class(ticket)
    return 'ticket-due--overdue' if ticket.overdue?
    return 'ticket-due--soon' if ticket.due_soon?

    ''
  end
end
