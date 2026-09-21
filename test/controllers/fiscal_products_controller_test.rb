require 'test_helper'
require 'webmock/minitest'

class FiscalProductsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(name: 'Admin Fiscal Prod', email: 'admin_fiscal_prod@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @with_ncm = Product.create!(sku: 'COM-NCM', shopify_product_name: 'Com NCM', ncm: '61099000')
    @without_ncm = Product.create!(sku: 'SEM-NCM', shopify_product_name: 'Sem NCM')
  end

  test 'user without fiscal_notes access is redirected' do
    profile = Profile.create!(name: 'Sem Fiscal Prod')
    user = User.create!(name: 'Sem Fiscal', email: 'sem_fiscal_prod@example.com', password: 'password123')
    user.profiles << profile
    sign_in user

    get fiscal_products_path
    assert_redirected_to root_path
  end

  test 'lists products and can filter the ones missing NCM' do
    sign_in @admin

    get fiscal_products_path
    assert_response :success
    assert_select 'tbody tr', count: 2

    get fiscal_products_path(missing: '1')
    assert_select 'tbody tr', count: 1
    assert_select 'tbody', text: /SEM-NCM/
  end

  test 'searches by SKU or name' do
    sign_in @admin

    get fiscal_products_path(q: 'COM-')
    assert_select 'tbody tr', count: 1
    assert_select 'tbody', text: /COM-NCM/
  end

  test 'updates the fiscal fields of a product' do
    sign_in @admin

    patch fiscal_product_path(@without_ncm), params: { product: { ncm: '61091000', cest: '2806100', origin: 0, commercial_unit: 'PC' } }

    assert_redirected_to fiscal_products_path
    @without_ncm.reload
    assert_equal '61091000', @without_ncm.ncm
    assert_equal 'PC', @without_ncm.commercial_unit
  end

  test 'an invalid NCM is not saved and shows the error' do
    sign_in @admin

    patch fiscal_product_path(@without_ncm), params: { product: { ncm: '123' } }

    assert_redirected_to fiscal_products_path
    assert_nil @without_ncm.reload.ncm
    follow_redirect!
    assert_select '.flash-messages-container .alert', text: /NCM/
  end

  test 'only the fiscal fields can be changed' do
    sign_in @admin

    patch fiscal_product_path(@without_ncm), params: { product: { ncm: '61091000', price: '999' } }

    assert_nil @without_ncm.reload.price
  end

  TINY_URL = 'https://api.tiny.com.br/api2/produto.obter.php'.freeze

  test 'each product without NCM that has a Tiny id shows an import button, others do not' do
    sign_in @admin
    @without_ncm.update!(tiny_rj_id: 55)

    get fiscal_products_path

    assert_select "form[action='#{import_from_tiny_fiscal_product_path(@without_ncm)}']", count: 1
    assert_select "form[action='#{import_from_tiny_fiscal_product_path(@with_ncm)}']", count: 0
  end

  test 'import_from_tiny fills the product from Tiny and redirects keeping the filters' do
    sign_in @admin
    ENV['OBTER_PRODUTO'] = TINY_URL
    ENV['TOKEN_TINY2_PRODUCTION'] = 'token-tiny2'
    @without_ncm.update!(tiny_2_id: '55')
    stub_request(:get, TINY_URL).with(query: hash_including('id' => '55'))
                                .to_return(body: { retorno: { status: 'OK', produto: { ncm: '6109.10.00', origem: '0', unidade: 'un' } } }.to_json)

    post import_from_tiny_fiscal_product_path(@without_ncm, q: 'SEM', missing: '1')

    assert_redirected_to fiscal_products_path(q: 'SEM', missing: '1')
    assert_equal '61091000', @without_ncm.reload.ncm
    follow_redirect!
    assert_select '.flash-messages-container .alert-success', text: /SEM-NCM/
  end

  test 'import_from_tiny explains why a product could not be imported' do
    sign_in @admin

    post import_from_tiny_fiscal_product_path(@without_ncm)

    follow_redirect!
    assert_select '.flash-messages-container .alert', text: /não tem ID em nenhuma conta do Tiny/
  end

  test 'import_all_from_tiny enqueues the background job and does not call Tiny inline' do
    sign_in @admin

    assert_enqueued_with(job: ImportProductsFiscalDataJob) do
      post import_all_from_tiny_fiscal_products_path
    end
    assert_redirected_to fiscal_products_path
    assert_not_requested :get, TINY_URL
  end

  test 'import_all_from_tiny refuses to start while an import is running' do
    sign_in @admin
    Motor.create!(job_name: ImportProductsFiscalDataJob::JOB_NAME, start_time: 5.minutes.ago, step: '10/4000')

    assert_no_enqueued_jobs only: ImportProductsFiscalDataJob do
      post import_all_from_tiny_fiscal_products_path
    end
    follow_redirect!
    assert_select '.flash-messages-container .alert', text: /já está em andamento/
  end

  test 'a stale run (older than 6 hours) does not block a new import' do
    sign_in @admin
    Motor.create!(job_name: ImportProductsFiscalDataJob::JOB_NAME, start_time: 7.hours.ago, step: 'started')

    assert_enqueued_with(job: ImportProductsFiscalDataJob) do
      post import_all_from_tiny_fiscal_products_path
    end
  end

  test 'the page shows the import status and the last summary' do
    sign_in @admin
    Motor.create!(job_name: ImportProductsFiscalDataJob::JOB_NAME, start_time: 1.hour.ago, end_time: 30.minutes.ago,
                  running_time: 1800, step: 'finished', link: 'Atualizados: 3 · Sem NCM no Tiny: 1')

    get fiscal_products_path

    assert_select '.import-status', text: /Atualizados: 3/
  end

  test 'the import endpoints require the fiscal_notes permission' do
    profile = Profile.create!(name: 'Sem Import')
    user = User.create!(name: 'Sem Import', email: 'sem_import@example.com', password: 'password123')
    user.profiles << profile
    sign_in user

    post import_all_from_tiny_fiscal_products_path
    assert_redirected_to root_path
    post import_from_tiny_fiscal_product_path(@without_ncm)
    assert_redirected_to root_path
  end
end
