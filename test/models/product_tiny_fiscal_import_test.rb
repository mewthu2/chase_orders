require 'test_helper'
require 'webmock/minitest'

class ProductTinyFiscalImportTest < ActiveSupport::TestCase
  TINY_URL = 'https://api.tiny.com.br/api2/produto.obter.php'.freeze

  def setup
    ENV['OBTER_PRODUTO'] = TINY_URL
    ENV['TOKEN_TINY2_PRODUCTION'] = 'token-tiny2'
    ENV['TOKEN_TINY_PRODUCTION'] = 'token-ls'
    ENV['TOKEN_TINY_PRODUCTION_BH_SHOPPING'] = 'token-bh'
    ENV['TOKEN_TINY_PRODUCTION_RJ'] = 'token-rj'
    @product = Product.create!(sku: 'BAB-377-G', shopify_product_name: 'Baby Look', tiny_2_id: '782960009')
  end

  def stub_tiny(produto: nil, retorno: nil)
    body = { retorno: retorno || { status_processamento: '3', status: 'OK', produto: produto } }
    stub_request(:get, TINY_URL).with(query: hash_including('id' => '782960009', 'token' => 'token-tiny2')).to_return(body: body.to_json)
  end

  test 'fills NCM, CEST, origin and unit from Tiny, normalizing the formats' do
    stub = stub_tiny(produto: { ncm: '6114.30.00', cest: '28.061.00', origem: '1', unidade: 'pc' })

    assert_equal :updated, @product.import_fiscal_data_from_tiny

    assert_requested stub
    @product.reload
    assert_equal '61143000', @product.ncm
    assert_equal '2806100', @product.cest
    assert_equal 1, @product.origin
    assert_equal 'PC', @product.commercial_unit
  end

  test 'keeps the defaults when Tiny sends no CEST, origin or unit' do
    stub_tiny(produto: { ncm: '61143000', cest: '', origem: '', unidade: '' })

    assert_equal :updated, @product.import_fiscal_data_from_tiny

    @product.reload
    assert_nil @product.cest
    assert_equal 0, @product.origin
    assert_equal 'UN', @product.commercial_unit
  end

  test 'never overwrites a product that already has an NCM and does not call Tiny' do
    @product.update!(ncm: '62034200', commercial_unit: 'CX')

    assert_equal :already_filled, @product.import_fiscal_data_from_tiny

    assert_not_requested :get, TINY_URL
    assert_equal 'CX', @product.reload.commercial_unit
  end

  test 'a product without a Tiny id is skipped without calling Tiny' do
    @product.update!(tiny_2_id: nil)

    assert_equal :no_tiny_id, @product.import_fiscal_data_from_tiny
    assert_not_requested :get, TINY_URL
  end

  test 'reports products Tiny does not know' do
    stub_tiny(retorno: { status_processamento: '1', status: 'Erro', codigo_erro: '20', erros: [{ erro: 'Produto não encontrado' }] })

    assert_equal :not_found, @product.import_fiscal_data_from_tiny
    assert_nil @product.reload.ncm
  end

  test 'reports Tiny products with no NCM or an invalid NCM and changes nothing' do
    stub_tiny(produto: { ncm: '', origem: '0', unidade: 'un' })
    assert_equal :no_ncm_in_tiny, @product.import_fiscal_data_from_tiny

    stub_tiny(produto: { ncm: '6114', origem: '0', unidade: 'un' })
    assert_equal :invalid_ncm, @product.import_fiscal_data_from_tiny
    assert_nil @product.reload.ncm
  end

  test 'reports the Tiny rate limit' do
    stub_tiny(retorno: { status_processamento: '1', status: 'Erro', codigo_erro: '6', erros: [{ erro: 'API Bloqueada - Excesso de acessos' }] })

    assert_equal :rate_limited, @product.import_fiscal_data_from_tiny
  end

  test 'a network or parse failure is reported as an error and does not raise' do
    stub_request(:get, TINY_URL).with(query: hash_including('id' => '782960009')).to_return(body: 'nao e json')

    assert_equal :error, @product.import_fiscal_data_from_tiny
  end

  test 'it only reads from Tiny: no write endpoint is ever called' do
    stub_tiny(produto: { ncm: '61143000' })

    @product.import_fiscal_data_from_tiny

    assert_not_requested :post, /tiny\.com\.br/
  end

  def stub_account(token, id, produto: nil, retorno: nil)
    body = { retorno: retorno || { status_processamento: '3', status: 'OK', produto: produto } }
    stub_request(:get, TINY_URL).with(query: hash_including('id' => id.to_s, 'token' => token)).to_return(body: body.to_json)
  end

  test 'falls back to the other Tiny accounts when the product has no B2B id' do
    product = Product.create!(sku: 'SO-LS', tiny_lagoa_seca_product_id: '900')
    stub = stub_account('token-ls', 900, produto: { ncm: '6109.10.00', origem: '0', unidade: 'un' })

    assert_equal :updated, product.import_fiscal_data_from_tiny

    assert_requested stub
    assert_equal '61091000', product.reload.ncm
  end

  test 'tries BH and RJ accounts by their own ids and tokens' do
    bh = Product.create!(sku: 'SO-BH', tiny_bh_shopping_id: 901)
    rj = Product.create!(sku: 'SO-RJ', tiny_rj_id: 902)
    stub_account('token-bh', 901, produto: { ncm: '61091000' })
    stub_account('token-rj', 902, produto: { ncm: '62034200' })

    assert_equal :updated, bh.import_fiscal_data_from_tiny
    assert_equal :updated, rj.import_fiscal_data_from_tiny
    assert_equal '62034200', rj.reload.ncm
  end

  test 'uses another account when the B2B record exists but has no NCM' do
    @product.update!(tiny_lagoa_seca_product_id: '903')
    stub_tiny(produto: { ncm: '', origem: '0', unidade: 'un' })
    stub_account('token-ls', 903, produto: { ncm: '6114.30.00', origem: '0', unidade: 'un' })

    assert_equal :updated, @product.import_fiscal_data_from_tiny
    assert_equal '61143000', @product.reload.ncm
  end

  test 'stops at the first account that answers and does not query the others' do
    @product.update!(tiny_lagoa_seca_product_id: '903')
    stub_tiny(produto: { ncm: '61143000' })
    other = stub_account('token-ls', 903, produto: { ncm: '99999999' })

    @product.import_fiscal_data_from_tiny

    assert_not_requested other
    assert_equal '61143000', @product.reload.ncm
  end

  test 'a rate limit on any account stops right away without trying the next ones' do
    @product.update!(tiny_lagoa_seca_product_id: '903')
    stub_tiny(retorno: { status: 'Erro', codigo_erro: '6', erros: [{ erro: 'API Bloqueada' }] })
    other = stub_account('token-ls', 903, produto: { ncm: '61143000' })

    assert_equal :rate_limited, @product.import_fiscal_data_from_tiny
    assert_not_requested other
  end

  test 'when no account has an NCM the most informative reason is reported' do
    @product.update!(tiny_lagoa_seca_product_id: '903')
    stub_tiny(retorno: { status: 'Erro', codigo_erro: '20', erros: [{ erro: 'Produto não encontrado' }] })
    stub_account('token-ls', 903, produto: { ncm: '', origem: '0' })

    assert_equal :no_ncm_in_tiny, @product.import_fiscal_data_from_tiny
    assert_nil @product.reload.ncm
  end

  test 'accounts without a configured token are skipped' do
    ENV.delete('TOKEN_TINY_PRODUCTION')
    product = Product.create!(sku: 'SO-LS2', tiny_lagoa_seca_product_id: '904')

    assert_equal :no_tiny_id, product.import_fiscal_data_from_tiny
    assert_not_requested :get, TINY_URL
  ensure
    ENV['TOKEN_TINY_PRODUCTION'] = 'token-ls'
  end
end
