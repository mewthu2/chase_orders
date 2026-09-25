require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # In the development environment your application's code is reloaded any time
  # it changes. This slows down response time but is perfect for development
  # since you don't have to restart the web server when you make code changes.
  config.cache_classes = false

  config.hosts << "36b2-2804-14d-587b-872b-1485-f0c8-8cb-16a1.ngrok-free.app"
  config.hosts << "36b2-2804-14d-587b-872b-1485-f0c8-8cb-16a1.ngrok-free.app"

  config.action_mailer.default_url_options = { host: 'localhost', port: 3000 }
  config.action_mailer.delivery_method = :smtp
  config.action_mailer.smtp_settings = {
    address: '127.0.0.1',
    port: 1025,
    domain: 'localhost:3000'
  }

  config.after_initialize do
    Bullet.enable = true
    Bullet.alert = true
    Bullet.bullet_logger = true
    Bullet.console = true
    Bullet.rails_logger = true
    Bullet.add_footer = true

    # B2bOrder#index eager-loads :client and :transfer_location together to
    # avoid N+1 across the list, but each order only ever renders one of the
    # two depending on its `kind` (sale vs stock_transfer). Whenever the
    # visible page happens to be all one kind, Bullet flags the other
    # association as unused eager loading — a false positive given both are
    # genuinely needed to cover a mixed-kind list.
    Bullet.add_safelist type: :unused_eager_loading, class_name: 'B2bOrder', association: :client
    Bullet.add_safelist type: :unused_eager_loading, class_name: 'B2bOrder', association: :transfer_location
  end

  # Do not eager load code on boot.
  config.eager_load = false

  # Show full error reports.
  config.consider_all_requests_local = true
  
  # O REDIS_URL do .env é o mesmo da produção: com :sidekiq, o que o dev enfileira roda no
  # worker do Heroku com o código deployado. Em dev os jobs rodam aqui mesmo, em memória.
  config.active_job.queue_adapter = :async
  # Enable server timing
  config.server_timing = true

  # Enable/disable caching. By default caching is disabled.
  # Run rails dev:cache to toggle caching.
  if Rails.root.join("tmp/caching-dev.txt").exist?
    config.action_controller.perform_caching = true
    config.action_controller.enable_fragment_cache_logging = true

    config.cache_store = :memory_store
    config.public_file_server.headers = {
      "Cache-Control" => "public, max-age=#{2.days.to_i}"
    }
  else
    config.action_controller.perform_caching = false

    config.cache_store = :null_store
  end

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :bucketeer

  # Don't care if the mailer can't send.
  config.action_mailer.raise_delivery_errors = false

  config.action_mailer.perform_caching = false

  # Print deprecation notices to the Rails logger.
  config.active_support.deprecation = :log

  # Raise exceptions for disallowed deprecations.
  config.active_support.disallowed_deprecation = :raise

  # Tell Active Support which deprecation messages to disallow.
  config.active_support.disallowed_deprecation_warnings = []

  # Raise an error on page load if there are pending migrations.
  config.active_record.migration_error = :page_load

  # Highlight code that triggered database queries in logs.
  config.active_record.verbose_query_logs = true

  # Suppress logger output for asset requests.
  config.assets.quiet = true

  # Raises error for missing translations.
  # config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  # config.action_view.annotate_rendered_view_with_filenames = true

  # Uncomment if you wish to allow Action Cable access from any origin.
  # config.action_cable.disable_request_forgery_protection = true
end
