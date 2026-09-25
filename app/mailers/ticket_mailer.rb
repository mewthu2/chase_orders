# E-mails do sistema de chamados. Sempre parametrizado com o chamado e o destinatário,
# para personalizar o texto conforme o papel da pessoa (solicitante, responsável, acompanhante).
class TicketMailer < ApplicationMailer
  layout 'ticket_mailer'
  helper TicketsHelper

  LOGO_PATH = Rails.root.join('app/assets/images/admin/chase-logo.png')
  TIPS = [
    '📸 Cole prints direto no chamado com Ctrl+V — não precisa salvar o arquivo antes.',
    '⚡ Quanto mais detalhes na primeira mensagem, mais rápido o chamado anda.',
    '👥 Precisa de mais alguém? Use "Chamar pessoa" dentro do chamado.',
    '✅ Ao resolver, descreva a solução: ela fica registrada para os próximos casos.',
    '⏱️ Cada resposta reinicia o prazo — responder dentro dele mantém tudo em dia.'
  ].freeze

  before_action :load_context

  def opened
    hero('🎫', 'Novo chamado aberto', TicketsHelper.status_color(@ticket.status))
    deliver_with(subject: "Novo: #{@ticket.title}")
  end

  def new_message
    @message = params[:message]
    @author = @message.user
    @recent = @ticket.messages.where.not(id: @message.id).includes(:user).last(3)
    status = @message.status_to_name
    case status
    when 'resolved' then hero('✅', 'Chamado resolvido!', TicketsHelper.status_color(status))
    when 'closed' then hero('🔒', 'Chamado fechado', TicketsHelper.status_color(status))
    when nil then hero('💬', "Nova interação de #{@author&.name}", TicketsHelper.status_color(@ticket.status))
    else hero('🔄', "Status: #{Ticket.status_label(status)}", TicketsHelper.status_color(status))
    end
    subject = status.in?(%w[resolved closed]) ? "#{Ticket.status_label(status)}: #{@ticket.title}" : "Nova interação de #{@author&.name}"
    deliver_with(subject: subject)
  end

  def follower_added
    @added_by = params[:added_by]
    hero('👀', 'Você foi chamado para acompanhar', TicketsHelper.status_color(@ticket.status))
    deliver_with(subject: "Você foi chamado para acompanhar: #{@ticket.title}")
  end

  def overdue
    hero('⏰', 'Prazo de resposta vencido', TicketsHelper::OVERDUE_COLOR)
    deliver_with(subject: "⚠ Prazo vencido: #{@ticket.title}")
  end

  private

  def load_context
    @ticket = params[:ticket]
    @recipient = params[:recipient]
    @role_label = (TicketParticipant::ROLE_LABELS[@ticket.role_of(@recipient)] || 'participante').downcase
    @tip = TIPS[@ticket.id.to_i % TIPS.size]
    attachments.inline['chase-logo.png'] = File.binread(LOGO_PATH)
  end

  def hero(emoji, title, color)
    @hero_emoji = emoji
    @hero_title = title
    @banner_color = color
  end

  def deliver_with(subject:)
    mail(to: @recipient.email, subject: "[Chamado ##{@ticket.id}] #{subject}")
  end
end
