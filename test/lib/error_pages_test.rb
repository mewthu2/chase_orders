require 'test_helper'
require Rails.root.join('lib/error_pages').to_s

# As páginas de public/ são geradas por `bin/rails honey:error_pages`; este teste falha se alguém
# editar o modelo (ou o conteúdo) e esquecer de gerar de novo.
class ErrorPagesTest < ActiveSupport::TestCase
  TEMPLATE = ERB.new(Rails.root.join('lib/templates/error_page.html.erb').read, trim_mode: '-')

  ErrorPages::PAGES.each do |code, page|
    test "public/#{code}.html is the Honey page generated from the template" do
      html = Rails.root.join("public/#{code}.html").read

      assert_equal TEMPLATE.result_with_hash(code: code, page: page, support_url: ErrorPages::SUPPORT_URL), html,
                   'rode bin/rails honey:error_pages'
      assert_includes html, page[:title]
      assert_includes html, 'Por que isso acontece?'
      assert_includes html, '/honey-chase-logo.webp'
      refute_includes html, 'rails-default-error-page'
    end
  end

  test 'the logo used by the error pages is served from public' do
    assert Rails.root.join('public/honey-chase-logo.webp').file?
  end
end
