# Páginas de erro estáticas do Honey (public/400.html, 404, 422, 500 e 503) com o visual do painel.
# São HTML puro, sem asset pipeline nem banco: precisam abrir mesmo com o app quebrado.
# Para mudar o texto ou o visual, edite ERROR_PAGES / lib/templates/error_page.html.erb e rode:
#   bin/rails honey:error_pages
namespace :honey do
  desc 'Gera as páginas de erro de public/ a partir de lib/templates/error_page.html.erb'
  task :error_pages do
    require 'erb'
    require Rails.root.join('lib/error_pages').to_s

    template = ERB.new(Rails.root.join('lib/templates/error_page.html.erb').read, trim_mode: '-')
    ErrorPages::PAGES.each do |code, page|
      html = template.result_with_hash(code: code, page: page, support_url: ErrorPages::SUPPORT_URL)
      Rails.root.join("public/#{code}.html").write(html)
      puts "public/#{code}.html"
    end
  end
end
