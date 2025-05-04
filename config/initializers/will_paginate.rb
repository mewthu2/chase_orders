# config/initializers/will_paginate.rb
if defined?(WillPaginate)
  module WillPaginate
    module ActionView
      class BootstrapLinkRenderer < LinkRenderer
        def container_attributes
          {class: "pagination pagination-sm justify-content-center"}
        end

        def page_number(page)
          if page == current_page
            tag(:li, tag(:span, page, class: 'page-link'), class: 'page-item active')
          else
            tag(:li, link(page, page, class: 'page-link', rel: rel_value(page)), class: 'page-item')
          end
        end

        def gap
          tag(:li, tag(:span, '&hellip;'.html_safe, class: 'page-link'), class: 'page-item disabled')
        end

        def previous_or_next_page(page, text, classname)
          if page
            tag(:li, link(text, page, class: 'page-link'), class: 'page-item')
          else
            tag(:li, tag(:span, text, class: 'page-link'), class: 'page-item disabled')
          end
        end
      end
    end
  end
end
