module Whatsapp
  class ConversationsController < BaseController
    before_action :require_attendance
    def index
      @connections = authorized_connections.order(:name)
      respond_to do |format|
        format.html
        format.json do
          scope = authorized_conversations.includes(:connection, :contact, :assignee)
          scope = scope.where(connection_id: params[:connection_id]) if params[:connection_id].present?
          scope = scope.where(state: params[:state]) if %w[open closed].include?(params[:state])
          scope = scope.where(assignee_id: current_user.id) if params[:mine] == '1'
          if params[:q].present?
            q = ActiveRecord::Base.sanitize_sql_like(params[:q].to_s.truncate(100))
            scope = scope.joins(:contact).where('whatsapp_contacts.name LIKE :q OR whatsapp_contacts.phone LIKE :q', q: "%#{q}%")
          end
          if params[:unread] == '1'
            scope = scope.where(<<~SQL.squish, uid: current_user.id)
              EXISTS (SELECT 1 FROM whatsapp_messages m WHERE m.conversation_id = whatsapp_conversations.id
                AND m.direction = 'incoming' AND m.historical = 0 AND m.id > COALESCE(
                  (SELECT r.last_message_id FROM whatsapp_reads r WHERE r.conversation_id = whatsapp_conversations.id AND r.user_id = :uid), 0))
            SQL
          end
          page = params[:page].to_i.clamp(1, 1000)
          rows = scope.order(last_message_at: :desc, id: :desc).limit(51).offset((page - 1) * 50).to_a
          render json: { conversations: rows.first(50).map { |c| summary(c) }, more: rows.length > 50,
            connections: @connections.map { |c| c.slice(:id, :name, :phone, :state) } }
        end
      end
    end

    def show
      conversation = authorized_conversations.find(params[:id])
      render json: details(conversation)
    end

    def create
      connection = authorized_connections.find(params.require(:connection_id))
      phone = Phone.normalize(params.require(:phone))
      raise ArgumentError, 'Informe o telefone com DDI e DDD.' unless phone
      connection.with_lock do
        contact = Contact.resolve!(connection, { 'remoteJid' => "#{phone.delete_prefix('+')}@s.whatsapp.net" })
        conversation = connection.conversations.find_or_create_by!(contact: contact)
        render json: summary(conversation), status: :created
      end
    end

    def update
      conversation = authorized_conversations.find(params[:id])
      conversation.with_lock do
        action = params.require(:operation)
        case action
        when 'take'
          if conversation.assignee_id && conversation.assignee_id != current_user.id
            return render json: { error: 'Esta conversa já está com outra pessoa. Use Transferir.' }, status: :conflict
          end
          conversation.assignee = current_user
        when 'transfer'
          target = User.active.find(params.require(:assignee_id))
          raise ArgumentError, 'Essa pessoa não tem acesso a este número.' unless Connection.visible_to(target).where(id: conversation.connection_id).exists?
          conversation.assignee = target
        when 'close' then conversation.state = 'closed'
        when 'reopen' then conversation.state = 'open'
        else raise ArgumentError, 'Ação inválida.'
        end
        conversation.save!
        conversation.activities.create!(user: current_user, action: action, assignee: conversation.assignee)
      end
      render json: details(conversation)
    end

    def read
      conversation = authorized_conversations.find(params[:id])
      conversation.mark_read!(current_user, params.require(:last_message_id))
      head :no_content
    end

    def link_customer
      return head :forbidden unless current_user.can_access_screen?('customers')
      conversation = authorized_conversations.find(params[:id])
      customer = params[:customer_id].present? ? Customer.find(params[:customer_id]) : nil
      conversation.contact.update!(customer: customer)
      render json: details(conversation)
    end

    def customers
      return head :forbidden unless current_user.can_access_screen?('customers')
      conversation = authorized_conversations.find(params[:id])
      q = params[:q].to_s.truncate(80)
      if q.present?
        term = "%#{ActiveRecord::Base.sanitize_sql_like(q)}%"
        matches = Customer.where('name LIKE :q OR first_name LIKE :q OR last_name LIKE :q OR phone LIKE :q', q: term).limit(20)
      else
        # MySQL 8 normalization handles formatting without changing the customer registry.
        digits = conversation.contact.phone.to_s.delete_prefix('+')
        candidates = [digits, digits.start_with?('55') ? digits[2..] : digits].reject(&:blank?)
        matches = Customer.where("REGEXP_REPLACE(phone, '[^0-9]', '') IN (?)", candidates).limit(20)
      end
      render json: { customers: matches.map { |c| customer_payload(c) } }
    end

    private
    def summary(c)
      c.slice(:id, :state, :last_message_at, :last_message_preview, :assignee_id).merge(
        name: c.contact.display_name, phone: c.contact.phone, connection_id: c.connection_id,
        connection_name: c.connection.name, connection_phone: c.connection.phone, connection_state: c.connection.state,
        assignee_name: c.assignee&.name, unread_count: c.unread_count(current_user))
    end
    def details(c)
      people = User.active.order(:name).select { |u| Connection.visible_to(u).where(id: c.connection_id).exists? }
      result = summary(c).merge(assignees: people.map { |u| u.slice(:id, :name) },
        can_link_customer: current_user.can_access_screen?('customers'))
      if current_user.can_access_screen?('customers') && c.contact.customer
        result[:customer] = customer_payload(c.contact.customer)
        result[:orders_url] = orders_path(customer_id: c.contact.customer_id) if current_user.can_access_screen?('orders')
      end
      result
    end
    def customer_payload(customer)
      { id: customer.id, name: customer.full_name.presence || customer.name, phone: customer.phone }
    end
  end
end
