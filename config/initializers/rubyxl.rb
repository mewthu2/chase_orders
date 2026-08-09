# RubyXL 3.4+ splits its cell/font/color/workbook/worksheet formatting
# helpers (change_font_bold, change_fill, change_font_color, etc.) out of
# the core lib to cut memory footprint. The Gemfile only requires the
# core 'rubyXL' lib via Bundler, so those helpers must be pulled in
# explicitly or callers get NoMethodError on RubyXL::Cell.
require 'rubyXL/convenience_methods'
