# Be sure to restart your server when you modify this file.

# Version of your assets, change this if you want to expire all your assets.
Rails.application.config.assets.version = '1.0'

# Add additional assets to the asset load path.
Rails.application.config.assets.paths << Rails.root.join('node_modules')
Rails.application.config.assets.paths << Rails.root.join('vendor', 'assets')
Rails.application.config.assets.paths << Rails.root.join('app', 'assets')

# Precompile additional assets.
# application.js, application.css, and all non-JS/CSS in the app/assets
# folder are already added.

# Specify which specific assets to precompile:
Rails.application.config.assets.precompile += %w[*.js *.scss]
Rails.application.config.assets.precompile += %w[admin/views/*.css]
Rails.application.config.assets.precompile += %w[admin/views/*.js]
Rails.application.config.assets.precompile += %w[views/admin/college_exam/form.js]
Rails.application.config.assets.precompile += %w[views/admin/solicitations/form.js]
Rails.application.config.assets.precompile += %w( actiontext.css )

# If you have additional asset types, add them here:
# Rails.application.config.assets.precompile += %w( admin/images/*.png )