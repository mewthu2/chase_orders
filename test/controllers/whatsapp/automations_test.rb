require 'test_helper'
require_relative '../../support/whatsapp_factory'
class WhatsappAutomationsTest < ActionDispatch::IntegrationTest
  include WhatsappFactory
  include ActiveJob::TestHelper
  self.fixture_table_names = []
  setup { setup_whatsapp }

  test 'attendants cannot manage automations' do
    sign_in @agent
    get whatsapp_automations_path
    assert_response :forbidden
  end

  test 'admin creates an automation from what was learned, edits and teaches a gap' do
    sign_in @admin
    get whatsapp_automations_path
    assert_response :success
    post whatsapp_automations_path, params: { connection_id: @a.id, name: 'Resposta automática', template: '1' }
    automation = @a.automations.sole
    assert_redirected_to whatsapp_automation_path(automation)
    assert_equal 'approve', automation.mode
    refute automation.enabled?
    assert_equal Whatsapp::LearnedTemplate::RULES.size, automation.rules.count
    get whatsapp_automation_path(automation)
    assert_response :success

    patch whatsapp_automation_path(automation), params: { automation: { enabled: 'true', mode: 'auto' } }
    assert automation.reload.enabled?
    assert automation.auto?

    gap = automation.gaps.create!(conversation: @conversation, message_id: @message.id, question: 'Tem desconto na primeira compra?')
    post teach_gap_whatsapp_automation_path(automation, gap_id: gap.id), params: { rule: { trigger: gap.question, response: 'Sim, cupom BEMVINDA10.' } }
    assert_equal 'taught', gap.reload.state
    assert_equal 'Sim, cupom BEMVINDA10.', gap.rule.response
  end

  test 'approved draft keeps the agent on; a message written by the team pauses it' do
    automation = @a.automations.create!(name: 'Auto', enabled: true)
    @conversation.update!(agent_draft: 'Oi!', agent_draft_for_id: @message.id, agent_draft_finish: true)
    sign_in @agent
    post whatsapp_conversation_messages_path(@conversation), params: { client_nonce: SecureRandom.uuid, body: 'Oi!', from_draft: '1' }
    assert_response :accepted
    @conversation.reload
    refute @conversation.agent_paused?
    assert_nil @conversation.agent_draft
    assert_equal 'closed', @conversation.state

    patch whatsapp_conversation_path(@conversation), params: { operation: 'reopen' }
    post whatsapp_conversation_messages_path(@conversation), params: { client_nonce: SecureRandom.uuid, body: 'Escrevi eu' }
    assert @conversation.reload.agent_paused?
    assert_equal 'responding', @conversation.stage
    get whatsapp_conversation_path(@conversation, format: :json)
    assert_equal automation.name, response.parsed_body.dig('automation', 'name')
    assert_equal 'Respondendo', response.parsed_body['stage_label']
  end

  test 'conversation mode turns itself off after the configured minutes without the team writing' do
    automation = @a.automations.create!(name: 'Auto', enabled: true, conversation_mode_minutes: 20)
    sign_in @admin
    patch whatsapp_automation_path(automation), params: { automation: { conversation_mode_minutes: '15' } }
    assert_equal 15, automation.reload.conversation_mode_minutes

    sign_in @agent
    post whatsapp_conversation_messages_path(@conversation), params: { client_nonce: SecureRandom.uuid, body: 'Escrevi eu' }
    assert @conversation.reload.agent_paused?
    get whatsapp_conversation_path(@conversation, format: :json)
    assert_in_delta 15.minutes.from_now, Time.zone.parse(response.parsed_body['agent_paused_until']), 5

    # Ainda dentro do prazo: a cliente escreve e o agente segue fora.
    message = @conversation.messages.create!(connection: @a, direction: 'incoming', body: 'Oi?', sent_at: Time.current)
    Whatsapp::AgentJob.schedule(@conversation, message)
    assert @conversation.reload.agent_paused?
    assert_no_enqueued_jobs(only: Whatsapp::AgentJob) { Whatsapp::AgentJob.schedule(@conversation, message) }

    travel 16.minutes do
      message = @conversation.messages.create!(connection: @a, direction: 'incoming', body: 'Alguém?', sent_at: Time.current)
      assert_enqueued_with(job: Whatsapp::AgentJob) { Whatsapp::AgentJob.schedule(@conversation, message) }
      refute @conversation.reload.agent_paused?
    end

    automation.update!(conversation_mode_minutes: 0)
    @conversation.update!(agent_paused: true)
    assert_nil @conversation.agent_paused_until
    travel(2.days) { refute @conversation.expire_agent_pause! }
  end

  test 'stage filters list pending and needs-human conversations' do
    sign_in @agent
    get whatsapp_conversations_path(format: :json), params: { state: 'pending' }
    assert_equal [@conversation.id], response.parsed_body['conversations'].map { |c| c['id'] }
    get whatsapp_conversations_path(format: :json), params: { state: 'responding' }
    assert_empty response.parsed_body['conversations']
    get whatsapp_conversations_path(format: :json), params: { human: '1' }
    assert_empty response.parsed_body['conversations']
  end
end
