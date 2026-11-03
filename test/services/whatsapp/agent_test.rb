require 'test_helper'
require 'minitest/mock'
require_relative '../../support/whatsapp_factory'
class WhatsappAgentTest < ActiveSupport::TestCase
  include WhatsappFactory
  include ActiveJob::TestHelper
  self.fixture_table_names = []
  setup do
    setup_whatsapp
    @automation = @a.automations.create!(name: 'Resposta automática', enabled: true, mode: 'approve', instructions: 'Seja cordial.')
    @automation.rules.create!(trigger: 'quiser trocar', response: 'mande o link https://chasebrasil.troque.app.br/')
  end

  def decision(action, reply: '', question: '')
    Whatsapp::Agent::Decision.new(action: action, reply: reply, question: question, reason: 'teste')
  end

  def run_agent(result, message_id: @message.id, force: false)
    fake = Object.new
    fake.define_singleton_method(:decide) { |*_args, **_kw| result }
    Whatsapp::Agent.stub(:new, fake) { Whatsapp::AgentJob.perform_now(@conversation.id, message_id, force) }
  end

  test 'prompt carries instructions, numbered commands and the never-invent rules' do
    prompt = Whatsapp::Agent.new(@automation).system_prompt('Maria')
    assert_includes prompt, 'Seja cordial.'
    assert_includes prompt, "1. QUANDO: quiser trocar\n   FAÇA: mande o link https://chasebrasil.troque.app.br/"
    assert_includes prompt, 'Nunca invente'
    assert_includes prompt, '"Maria"'
  end

  test 'invalid or empty model output becomes unsure instead of a reply' do
    agent = Whatsapp::Agent.new(@automation)
    assert agent.send(:parse, 'nada de json').unsure?
    assert agent.send(:parse, '{"action":"reply","reply":""}').unsure?
    assert agent.send(:parse, '{"action":"inventada"}').unsure?
    ok = agent.send(:parse, '{"action":"reply","reply":"Oi!"}')
    assert ok.reply?
  end

  test 'missing key is reported without calling OpenAI' do
    old = ENV.delete('OPENAI_API_KEY')
    assert_raises(Whatsapp::Agent::NotConfigured) { Whatsapp::Agent.new(@automation).decide([]) }
  ensure
    ENV['OPENAI_API_KEY'] = old if old
  end

  test 'customer message schedules the agent only when a number has an enabled automation' do
    assert_enqueued_with(job: Whatsapp::AgentJob) { @a.with_lock { Whatsapp::Ingest.new(@a).message!(wa_message('m2')) } }
    @automation.update!(enabled: false)
    assert_no_enqueued_jobs(only: Whatsapp::AgentJob) { @a.with_lock { Whatsapp::Ingest.new(@a).message!(wa_message('m3')) } }
  end

  test 'conversation mode: a paused conversation never schedules the agent' do
    @conversation.update!(agent_paused: true)
    assert_no_enqueued_jobs(only: Whatsapp::AgentJob) { @a.with_lock { Whatsapp::Ingest.new(@a).message!(wa_message('pausada')) } }
    @conversation.update!(state: 'closed')
    assert_enqueued_with(job: Whatsapp::AgentJob) { @a.with_lock { Whatsapp::Ingest.new(@a).message!(wa_message('voltou')) } }
    refute @conversation.reload.agent_paused?
  end

  test 'approve mode stores a draft and sends nothing' do
    assert_no_enqueued_jobs(only: Whatsapp::SendJob) { run_agent(decision('reply', reply: 'Oi! Segue o link.')) }
    @conversation.reload
    assert_equal 'Oi! Segue o link.', @conversation.agent_draft
    assert_equal @message.id, @conversation.agent_draft_for_id
    assert_equal 1, @conversation.messages.count
  end

  test 'auto mode sends as the agent once, even if the job runs twice' do
    @automation.update!(mode: 'auto')
    assert_enqueued_jobs(1, only: Whatsapp::SendJob) { 2.times { run_agent(decision('reply', reply: 'Oi!')) } }
    sent = @conversation.messages.where(direction: 'outgoing').sole
    assert sent.by_agent?
    assert_nil sent.user
    assert_equal 'Agente Honey', sent.author_name
    assert_equal 'responding', @conversation.reload.stage
  end

  test 'auto mode finish replies and finalizes; a new customer message reopens as pending' do
    @automation.update!(mode: 'auto')
    run_agent(decision('finish', reply: 'Disponha!'))
    assert_equal %w[closed finished], @conversation.reload.values_at(:state, :stage)
    @a.with_lock { Whatsapp::Ingest.new(@a).message!(wa_message('volta', text: 'Oi de novo')) }
    assert_equal %w[open pending], @conversation.reload.values_at(:state, :stage)
  end

  test 'unsure marks the conversation for the team and records what to teach' do
    run_agent(decision('unsure', question: 'Cliente quer saber do estorno'))
    @conversation.reload
    assert @conversation.needs_human?
    assert_equal 'Não sei o que fazer neste caso: Cliente quer saber do estorno', @conversation.agent_note
    gap = @automation.gaps.open.sole
    assert_equal 'Cliente quer saber do estorno', gap.question
    run_agent(decision('unsure', question: 'Cliente quer saber do estorno'))
    assert_equal 1, @automation.gaps.count
  end

  test 'agent gives up when the customer wrote again or the team already answered' do
    @a.with_lock { Whatsapp::Ingest.new(@a).message!(wa_message('mais-uma', text: 'e aí?', at: 1.second.from_now)) }
    run_agent(decision('reply', reply: 'Velha'))
    assert_nil @conversation.reload.agent_draft
  end

  test 'message typed on the company phone pauses the agent; paused agent does nothing unless asked' do
    @a.with_lock { Whatsapp::Ingest.new(@a).message!(wa_message('celular', from_me: true, text: 'Oi, aqui é a Ana', at: 1.second.from_now)) }
    @conversation.reload
    assert @conversation.agent_paused?
    assert_equal 'responding', @conversation.stage
    @a.with_lock { @message = Whatsapp::Ingest.new(@a).message!(wa_message('cliente-2', text: 'Ok', at: 2.seconds.from_now)) }
    run_agent(decision('reply', reply: 'Não deveria'))
    assert_nil @conversation.reload.agent_draft
    run_agent(decision('reply', reply: 'Sugestão pedida'), force: true)
    assert_equal 'Sugestão pedida', @conversation.reload.agent_draft
  end

  test 'agent messages are sent while the automation is on and blocked after it is turned off' do
    @automation.update!(mode: 'auto')
    run_agent(decision('reply', reply: 'Oi!'))
    sent = @conversation.messages.find_by!(by_agent: true)
    @automation.update!(enabled: false)
    Whatsapp::SendJob.perform_now(sent.id)
    assert_equal 'failed', sent.reload.state
  end

  test 'enabling one automation turns off the others of the same number' do
    other = @a.automations.create!(name: 'Fora do horário', mode: 'approve')
    other.update!(enabled: true)
    refute @automation.reload.enabled?
    assert_equal other, Whatsapp::Automation.active_for(@a.id)
  end
end
