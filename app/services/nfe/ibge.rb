require 'httparty'

module Nfe
  # Código IBGE do município pelo CEP (ViaCEP). A NF-e exige o código; a Shopify só tem o nome da cidade.
  module Ibge
    module_function

    URL = 'https://viacep.com.br/ws/%s/json/'.freeze

    # Retorna { ibge:, city:, state:, neighbourhood:, street: } ou nil quando o CEP não existe ou o serviço falha.
    def lookup(zip)
      cep = Cnpj.digits(zip)
      return nil unless cep.length == 8

      Rails.cache.fetch("nfe/ibge/#{cep}", expires_in: 30.days, skip_nil: true) do
        response = HTTParty.get(format(URL, cep), timeout: 5)
        data = response.code == 200 ? response.parsed_response : nil
        next nil unless data.is_a?(Hash) && data['ibge'].present?

        { ibge: data['ibge'], city: data['localidade'], state: data['uf'],
          neighbourhood: data['bairro'], street: data['logradouro'] }
      end
    rescue StandardError => e
      Rails.logger.warn("[Nfe::Ibge] CEP #{cep}: #{e.message}")
      nil
    end
  end
end
