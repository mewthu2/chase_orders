require 'test_helper'

class B2bCatalogsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  def setup
    @admin = User.create!(name: 'Admin Catálogo', email: 'admin_catalogo@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    Product.create!(sku: 'LEG-ASH-P', shopify_product_name: 'Legging Apex Seamless Ash', option1: 'P', shopify_product_id: '1')
    Product.create!(sku: 'LEG-ASH-M', shopify_product_name: 'Legging Apex Seamless Ash', option1: 'M', shopify_product_id: '1')
    Product.create!(sku: 'LEG-SKY-P', shopify_product_name: 'Legging Apex Seamless Sky', option1: 'P', shopify_product_id: '2')
    sign_in @admin
  end

  def catalog_params(**extra)
    { b2b_catalog: { title: 'Coleção Verão', kind: 'general', notes: 'Pedidos até sexta', products_attributes: {
      '0' => { style_name: 'Legging Apex Seamless', color_name: 'Ash', position: 0, skus: %w[LEG-ASH-P LEG-ASH-M] },
      '1' => { style_name: 'Legging Apex Seamless', color_name: 'Sky', position: 1, skus: %w[LEG-SKY-P] }
    } }.merge(extra) }
  end

  def create_catalog
    post b2b_catalogs_path, params: catalog_params
    B2bCatalog.last
  end

  test 'creates a catalog with colors and sizes and refreshes it right away' do
    assert_enqueued_with(job: B2bCatalogRefreshJob) do
      assert_difference('B2bCatalog.count', 1) { post b2b_catalogs_path, params: catalog_params }
    end
    catalog = B2bCatalog.last

    assert_redirected_to b2b_catalog_path(catalog)
    assert_equal %w[Ash Sky], catalog.products.map(&:color_name)
    assert_equal %w[P M], catalog.products.first.variants.map(&:size)
    assert_equal @admin, catalog.user
  end

  test 'a client catalog without client is refused' do
    post b2b_catalogs_path, params: catalog_params(kind: 'client')
    assert_response :unprocessable_entity
  end

  test 'product_picker groups variants by color' do
    get product_picker_b2b_catalogs_path, params: { query: 'apex' }
    products = JSON.parse(response.body)['products']

    assert_equal 2, products.size
    ash = products.find { |p| p['name'] == 'Legging Apex Seamless Ash' }
    assert_equal %w[LEG-ASH-P LEG-ASH-M].sort, ash['skus'].sort
  end

  test 'split_names suggests style and color' do
    post split_names_b2b_catalogs_path, params: { names: ['Legging Apex Seamless Ash', 'Legging Apex Seamless Sky'] }, as: :json
    assert_equal ['Legging Apex Seamless', 'Sky'], JSON.parse(response.body)['Legging Apex Seamless Sky']
  end

  test 'update renames, reorders and removes a color' do
    catalog = create_catalog
    ash, sky = catalog.products.to_a

    patch b2b_catalog_path(catalog), params: { b2b_catalog: { title: 'Verão 2', products_attributes: {
      '0' => { id: ash.id, _destroy: '1' },
      '1' => { id: sky.id, color_name: 'Céu', position: 0 }
    } } }

    assert_redirected_to b2b_catalog_path(catalog)
    assert_equal ['Céu'], catalog.reload.products.map(&:color_name)
    assert_equal 'Verão 2', catalog.title
  end

  test 'index shows the new orders badge and show lists the orders' do
    catalog = create_catalog
    catalog.catalog_orders.create!(customer_name: 'Loja Centro', customer_registration: '25.405.327/0001-74')

    get b2b_catalogs_path
    assert_select '.catalog-new-badge', text: /1/

    get b2b_catalog_path(catalog)
    assert_select '.catalog-order-row', text: /Loja Centro/
    assert_includes response.body, public_catalog_url(catalog.public_token)
  end

  test 'close, reopen and regenerate the link' do
    catalog = create_catalog
    old_token = catalog.public_token

    post toggle_status_b2b_catalog_path(catalog)
    assert catalog.reload.closed?
    post toggle_status_b2b_catalog_path(catalog)
    assert catalog.reload.active?

    post regenerate_token_b2b_catalog_path(catalog)
    refute_equal old_token, catalog.reload.public_token
  end

  test 'the edit form warns before removing a color that has items in orders' do
    catalog = create_catalog
    order = catalog.catalog_orders.create!(customer_name: 'Loja', customer_registration: '25.405.327/0001-74')
    order.replace_items!({ catalog.variants.first.id => 2 }, edited_by: 'customer')

    get edit_b2b_catalog_path(catalog)

    assert_select "[data-ordered-pieces='2']"
  end

  test 'users without the screen are redirected' do
    profile = Profile.create!(name: 'Sem Catalogo')
    user = User.create!(name: 'Sem Catalogo', email: 'sem_catalogo@example.com', password: 'password123')
    user.profiles << profile
    sign_in user

    get b2b_catalogs_path
    assert_redirected_to root_path
  end

  test 'sidebar shows Catálogos with the pending badge' do
    catalog = create_catalog
    catalog.catalog_orders.create!(customer_name: 'Loja', customer_registration: '25.405.327/0001-74')

    get b2b_orders_path

    assert_select "#pedidosB2bDropdown a[href='#{b2b_catalogs_path}']", text: /Catálogos/
    assert_select "#pedidosB2bDropdown a[href='#{b2b_catalogs_path}'] .nav-count-badge", text: '1'
  end

  test 'pdf downloads the catalog' do
    catalog = create_catalog
    get pdf_b2b_catalog_path(catalog)

    assert_equal 'application/pdf', response.media_type
    assert_match(/catalogo-colecao-verao\.pdf/, response.headers['Content-Disposition'])
  end
end
