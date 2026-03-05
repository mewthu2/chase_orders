class Location < ApplicationRecord
  has_many :stock_corrections, dependent: :restrict_with_error

  LOCATION_ENV_MAP = {
    'lagoa_seca'            => 'LOCATION_LAGOA_SECA',
    'bh_shopping'           => 'LOCATION_BH_SHOPPING',
    'rj'                    => 'LOCATION_BARRA_SHOPPING',
    'eldorado_sp'           => 'LOCATION_ELDORADO_SP',
    'fortaleza_rio_mar'     => 'LOCATION_FORTALEZA_RIO_MAR',
    'porto_alegre_bourbon'  => 'LOCATION_PORTO_ALEGRE_BOURBON',
    'iguatemi_campinas'     => 'LOCATION_IGUATEMI_CAMPINAS'
  }.freeze

  def self.shopify_location_id(location)
    env_key = LOCATION_ENV_MAP[location.to_s] || 'LOCATION_LAGOA_SECA'

    location_id = ENV.fetch(env_key, nil)
  end
end