require 'test_helper'
require 'webmock/minitest'

class ImportProductsFiscalDataJobTest < ActiveSupport::TestCase
  TINY_URL = 'https://api.tiny.com.br/api2/produto.obter.php'.freeze

  def setup
    ENV['OBTER_PRODUTO'] = TINY_URL
    ENV['TOKEN_TINY2_PRODUCTION'] = 'token-tiny2'
    ImportProductsFiscalDataJob.throttle_seconds = 0
    ImportProductsFiscalDataJob.rate_limit_wait = 0
  end

  def teardown
    super # webmock/minitest limpa stubs e contagem de requisições aqui
    ImportProductsFiscalDataJob.throttle_seconds = ImportProductsFiscalDataJob::DEFAULT_THROTTLE_SECONDS
    ImportProductsFiscalDataJob.rate_limit_wait = ImportProductsFiscalDataJob::DEFAULT_RATE_LIMIT_WAIT
  end

  def stub_product(tiny_id, produto)
    stub_request(:get, TINY_URL).with(query: hash_including('id' => tiny_id))
                                .to_return(body: { retorno: { status: 'OK', produto: produto } }.to_json)
  end

  def motor
    Motor.where(job_name: ImportProductsFiscalDataJob::JOB_NAME).order(:id).last
  end

  test 'imports only products without NCM that have a Tiny id and summarizes the result' do
    ok = Product.create!(sku: 'OK', tiny_2_id: '1')
    invalid = Product.create!(sku: 'INV', tiny_2_id: '2')
    filled = Product.create!(sku: 'FILLED', tiny_2_id: '3', ncm: '62034200')
    no_id = Product.create!(sku: 'NOID')
    stub_product('1', { ncm: '6114.30.00', origem: '0', unidade: 'un' })
    stub_product('2', { ncm: '61', origem: '0', unidade: 'un' })

    ImportProductsFiscalDataJob.perform_now

    assert_equal '61143000', ok.reload.ncm
    assert_nil invalid.reload.ncm
    assert_equal '62034200', filled.reload.ncm
    assert_nil no_id.reload.ncm
    assert_not_requested :get, TINY_URL, query: hash_including('id' => '3')
    assert_equal 'finished', motor.step
    assert_not_nil motor.end_time
    assert_match(/Atualizados: 1/, motor.link)
    assert_match(/NCM inválido no Tiny: 1/, motor.link)
  end

  test 'waits and retries once when Tiny rate limits a product' do
    product = Product.create!(sku: 'RL', tiny_2_id: '1')
    calls = 0
    stub_request(:get, TINY_URL).with(query: hash_including('id' => '1')).to_return do
      calls += 1
      if calls == 1
        { body: { retorno: { status: 'Erro', codigo_erro: '6', erros: [{ erro: 'API Bloqueada' }] } }.to_json }
      else
        { body: { retorno: { status: 'OK', produto: { ncm: '61143000' } } }.to_json }
      end
    end

    ImportProductsFiscalDataJob.perform_now

    assert_equal 2, calls
    assert_equal '61143000', product.reload.ncm
  end

  test 'stops with an error message when Tiny keeps rate limiting, keeping what was imported' do
    first = Product.create!(sku: 'A', tiny_2_id: '1')
    Product.create!(sku: 'B', tiny_2_id: '2')
    stub_product('1', { ncm: '61143000' })
    stub_request(:get, TINY_URL).with(query: hash_including('id' => '2'))
                                .to_return(body: { retorno: { status: 'Erro', codigo_erro: '6', erros: [{ erro: 'API Bloqueada' }] } }.to_json)

    ImportProductsFiscalDataJob.perform_now

    assert_equal '61143000', first.reload.ncm
    assert_equal 'error', motor.step
    assert_match(/excesso de acessos/i, motor.link)
  end

  test 'is idempotent: a second run only handles what is still missing' do
    Product.create!(sku: 'A', tiny_2_id: '1')
    stub = stub_product('1', { ncm: '61143000' })

    ImportProductsFiscalDataJob.perform_now
    ImportProductsFiscalDataJob.perform_now

    assert_requested stub, times: 1
  end

  test 'runs on the products queue' do
    assert_equal 'products', ImportProductsFiscalDataJob.new.queue_name
  end

  test 'the scope includes products that only have an id in another Tiny account' do
    b2b = Product.create!(sku: 'B2B', tiny_2_id: '1')
    ls = Product.create!(sku: 'LS', tiny_lagoa_seca_product_id: '2')
    bh = Product.create!(sku: 'BH', tiny_bh_shopping_id: 3)
    rj = Product.create!(sku: 'RJ', tiny_rj_id: 4)
    Product.create!(sku: 'NENHUM')
    Product.create!(sku: 'BRANCO', tiny_2_id: '', tiny_lagoa_seca_product_id: '')
    Product.create!(sku: 'JA-TEM', tiny_2_id: '9', ncm: '61091000')

    assert_equal [b2b, ls, bh, rj].map(&:id).sort, ImportProductsFiscalDataJob.eligible_scope.pluck(:id).sort
  end
end
