require 'test_helper'
require 'webmock/minitest'

class Tiny::ContactsTest < ActiveSupport::TestCase
  def setup
    ENV['TOKEN_TINY3_PRODUCTION'] = 'fake-token'
    ENV['ALTERAR_CONTATO'] = 'https://api.tiny.com.br/api2/contato.alterar.php'
  end

  test 'update_address returns success on OK response' do
    stub_request(:post, 'https://api.tiny.com.br/api2/contato.alterar.php')
      .with(body: hash_including(
        'contato' => { 'cpf_cnpj' => '11737309904', 'bairro' => 'São José', 'cidade' => 'Reserva' }.to_json
      ))
      .to_return(body: { retorno: { status: 'OK' } }.to_json)

    result = Tiny::Contacts.update_address('11737309904', { bairro: 'São José', cidade: 'Reserva' })

    assert result[:success]
  end

  test 'update_address omits blank address fields from the payload' do
    stub_request(:post, 'https://api.tiny.com.br/api2/contato.alterar.php')
      .with(body: hash_including(
        'contato' => { 'cpf_cnpj' => '11737309904', 'bairro' => 'Centro' }.to_json
      ))
      .to_return(body: { retorno: { status: 'OK' } }.to_json)

    result = Tiny::Contacts.update_address('11737309904', { bairro: 'Centro', complemento: '' })

    assert result[:success]
  end

  test 'update_address returns the Tiny error message on failure' do
    stub_request(:post, 'https://api.tiny.com.br/api2/contato.alterar.php')
      .to_return(body: { retorno: { status: 'Erro', erros: { erro: 'Contato não encontrado' } } }.to_json)

    result = Tiny::Contacts.update_address('00000000000', { bairro: 'Centro' })

    refute result[:success]
    assert_equal 'Contato não encontrado', result[:error]
  end

  test 'update_address rescues connection errors' do
    stub_request(:post, 'https://api.tiny.com.br/api2/contato.alterar.php')
      .to_raise(HTTParty::Error.new('timeout'))

    result = Tiny::Contacts.update_address('11737309904', { bairro: 'São José' })

    refute result[:success]
    assert_equal 'timeout', result[:error]
  end
end
