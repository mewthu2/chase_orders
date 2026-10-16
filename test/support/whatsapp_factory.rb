module WhatsappFactory
  def setup_whatsapp
    [Profile::ADMIN, Profile::MANAGER, Profile::USER].each { |id| Profile.find_or_create_by!(id: id) { |p| p.name = "Perfil #{id}" } }
    @profile = Profile.create!(name: 'Atendimento teste')
    @profile.screen_keys = %w[whatsapp_attend customers orders]
    @profile.save!
    @agent = User.create!(name: 'Ana Atendimento', email: "wa-#{SecureRandom.hex(4)}@example.test", password: 'password123', profiles: [@profile], active: true)
    @other = User.create!(name: 'Bia Atendimento', email: "wa-#{SecureRandom.hex(4)}@example.test", password: 'password123', profiles: [@profile], active: true)
    @admin = User.create!(name: 'Admin', email: "wa-#{SecureRandom.hex(4)}@example.test", password: 'password123', profiles: [Profile.find(Profile::ADMIN)], active: true)
    @a = Whatsapp::Connection.create!(name: 'Vendas', state: 'connected', phone: '+551100000001')
    @b = Whatsapp::Connection.create!(name: 'Atacado', state: 'connected', phone: '+5511999990000')
    @a.users = [@agent, @other]
    @b.users = [@other]
    @jid = '5511988887777@s.whatsapp.net'
    @conversation = nil
    @a.with_lock { @message = Whatsapp::Ingest.new(@a).message!(wa_message('message-1')); @conversation = @message.conversation }
    ActiveJob::Base.queue_adapter = :test
  end

  def wa_message(id, jid: @jid, from_me: false, text: 'Olá', status: nil, at: Time.current)
    { 'key' => { 'id' => id, 'remoteJid' => jid, 'fromMe' => from_me }, 'pushName' => 'Cliente Teste',
      'message' => { 'conversation' => text }, 'messageTimestamp' => at.to_i, 'status' => status }
  end

  def wa_outgoing(state: 'queued', nonce: SecureRandom.uuid)
    @conversation.messages.create!(connection: @a, user: @agent, body: 'Resposta', direction: 'outgoing', state: state,
      client_nonce: nonce, sent_at: Time.current)
  end

  def with_provider_env
    values = { 'WHATSAPP_EVOLUTION_URL' => 'http://evolution.test:8080', 'WHATSAPP_EVOLUTION_API_KEY' => 'fake-key', 'WHATSAPP_WEBHOOK_BASE_URL' => 'https://honey.test' }
    old = values.keys.to_h { |k| [k, ENV[k]] }
    values.each { |k, v| ENV[k] = v }
    yield
  ensure
    old.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
