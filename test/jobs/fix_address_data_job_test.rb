require 'test_helper'
require 'webmock/minitest'

# Pedidos que param na criação do Correios por falta de bairro/número são completados pelo CEP
# (ViaCEP/BrasilAPI) e a correção fica salva no Honey para a próxima rodada.
class FixAddressDataJobTest < ActiveSupport::TestCase
  OBTER_PEDIDO = 'https://api.tiny.com.br/api2/pedido.obter.php'.freeze

  def setup
    ENV['OBTER_PEDIDO'] = OBTER_PEDIDO
    ENV['TOKEN_TINY3_PRODUCTION'] = 'token-tiny3'
    ENV['TOKEN_TINY2_PRODUCTION'] = 'token-tiny2'
  end

  def stub_tiny(cliente)
    body = { retorno: { pedido: { id: '920697217', cliente: cliente, endereco_entrega: nil } } }.to_json
    stub_request(:get, OBTER_PEDIDO).with(query: hash_including('id' => '920697217')).to_return(body: body)
  end

  def stub_viacep_cep(cep, body)
    stub_request(:get, "https://viacep.com.br/ws/#{cep}/json/").to_return(body: body.to_json)
  end

  def miranorte
    { endereco: 'Avenida Bernardo Sayão', numero: '69', complemento: 'Abaixo da prefeitura, Centro',
      bairro: '', cep: '77.660-000', cidade: 'Miranorte', uf: 'TO' }
  end

  test 'CEP geral da cidade: acha o bairro pela busca da rua no ViaCEP' do
    stub_viacep_cep('77660000', { cep: '77660-000', bairro: '' })
    stub_request(:get, 'https://viacep.com.br/ws/TO/Miranorte/Bernardo%20Say%C3%A3o/json/')
      .to_return(body: [{ bairro: 'Setor Central', unidade: 'AC Miranorte' }, { bairro: 'Setor Central', unidade: 'AC Miranorte' }].to_json)

    result = AddressDataFixer.new(miranorte).call
    assert_equal({ bairro: 'Setor Central' }, result.changes)
  end

  test 'sem bairro no CEP nem na rua: usa o bairro escrito no complemento' do
    stub_viacep_cep('77660000', { bairro: '' })
    stub_request(:get, %r{viacep.com.br/ws/TO/}).to_return(body: '[]')

    assert_equal 'Centro', AddressDataFixer.new(miranorte).call.changes[:bairro]
  end

  test 'CEP de rua: bairro pelo CEP; número tirado do fim da rua' do
    stub_viacep_cep('30130131', { bairro: 'Funcionários' })

    result = AddressDataFixer.new(endereco: 'Rua Rio Grande do Norte, 500', numero: '', bairro: '', cep: '30130-131',
                                  cidade: 'Belo Horizonte', uf: 'MG').call
    assert_equal({ bairro: 'Funcionários', numero: '500', endereco: 'Rua Rio Grande do Norte' }, result.changes)
  end

  test 'sem número em lugar nenhum: S/N' do
    result = AddressDataFixer.new(endereco: 'Rua A', numero: '', complemento: 'casa', bairro: 'Centro', cep: '30130131').call
    assert_equal({ numero: 'S/N' }, result.changes)
  end

  test 'ViaCEP fora do ar: tenta a BrasilAPI' do
    stub_request(:get, 'https://viacep.com.br/ws/30130131/json/').to_return(status: 500)
    stub_request(:get, 'https://brasilapi.com.br/api/cep/v2/30130131').to_return(body: { neighborhood: 'Funcionários' }.to_json)

    result = AddressDataFixer.new(endereco: 'Rua A', numero: '1', bairro: '', cep: '30130131', cidade: 'Belo Horizonte', uf: 'MG').call
    assert_equal 'Funcionários', result.changes[:bairro]
  end

  test 'o job grava a correção do pedido travado por bairro e não mexe de novo depois' do
    Attempt.create!(kinds: :create_correios_order, status: :error, tiny_order_id: 920_697_217, error: 'bairro não presente')
    stub_tiny(miranorte.merge(nome: 'Cliente'))
    stub_viacep_cep('77660000', { bairro: '' })
    stub_request(:get, %r{viacep.com.br/ws/TO/}).to_return(body: [{ bairro: 'Setor Central', unidade: '' }].to_json)

    FixAddressDataJob.perform_now

    correction = AddressCorrection.for(920_697_217)
    assert_equal 'Setor Central', correction.bairro
    assert_nil correction.numero
    assert_empty FixAddressDataJob.new.pending
  end

  test 'não sobrescreve correção feita à mão nem pedidos já criados' do
    Attempt.create!(kinds: :create_correios_order, status: :error, tiny_order_id: 920_697_217, error: 'bairro, numero não presente')
    AddressCorrection.create!(tiny_order_id: '920697217', bairro: 'Bairro Manual')
    stub_tiny(miranorte.merge(numero: ''))
    stub_viacep_cep('77660000', { bairro: 'Outro' })

    FixAddressDataJob.perform_now
    correction = AddressCorrection.for(920_697_217)
    assert_equal 'Bairro Manual', correction.bairro
    assert_equal 'S/N', correction.numero

    Attempt.create!(kinds: :create_correios_order, status: :error, tiny_order_id: 1, error: 'bairro não presente')
    Attempt.create!(kinds: :create_correios_order, status: :success, tiny_order_id: 1)
    assert_empty FixAddressDataJob.new.pending
  end
end
