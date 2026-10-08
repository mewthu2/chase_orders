ENV['RAILS_ENV'] ||= 'test'
require_relative '../config/environment'
ENV['TICKET_EMAILS_ENABLED'] = 'true'
require 'rails/test_help'

class ActiveSupport::TestCase
  # Run tests in parallel with specified workers
  parallelize(workers: :number_of_processors)

  # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
  fixtures :all

  # Add more helper methods to be used by all tests here...
end

class ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  # O bloqueio por reserva consulta o estoque do Correios ao salvar pedidos B2B. Por padrão o estoque
  # é farto; testes que exercitam o estoque registram o próprio stub, que tem prioridade.
  setup do
    if defined?(WebMock)
      WebMock::API.stub_request(:get, %r{/estoque\z}).to_return(status: 200, body: { disponivel: 999_999 }.to_json)
    end
  end
end
