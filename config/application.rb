require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module ChaseOrders
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 7.0

    config.time_zone = 'Brasilia'

    # Idioma: o painel é todo em português; o inglês fica só como reserva para chaves sem tradução.
    config.i18n.available_locales = [:'pt-BR', :en]
    config.i18n.default_locale = :'pt-BR'
    config.i18n.fallbacks = [:en]

    # Criptografia de atributos sensíveis (ex.: senha do certificado A1 da empresa).
    # Em dev e produção os mesmos valores precisam estar nas variáveis de ambiente.
    config.active_record.encryption.primary_key = ENV['ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY']
    config.active_record.encryption.deterministic_key = ENV['ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY']
    config.active_record.encryption.key_derivation_salt = ENV['ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT']
    
    config.active_record.default_timezone = :utc

    config.eager_load_paths << Rails.root.join('lib')
    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
