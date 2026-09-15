module Tiny::Contacts
  module_function

  ADDRESS_FIELDS = %i[endereco numero complemento bairro cep cidade uf].freeze

  # DOC = https://tiny.com.br/api-docs/api2-contatos-alterar
  def update_address(cpf_cnpj, address, token = ENV.fetch('TOKEN_TINY3_PRODUCTION'))
    contato = { cpf_cnpj: }.merge(address.slice(*ADDRESS_FIELDS).compact_blank)

    response = JSON.parse(HTTParty.post(ENV.fetch('ALTERAR_CONTATO'),
                                        body: {
                                          token:,
                                          formato: 'json',
                                          contato: contato.to_json
                                        })).with_indifferent_access

    retorno = response[:retorno] || {}

    if retorno[:status] == 'OK'
      { success: true }
    else
      erro = retorno.dig(:registros, :registro, :erros, :erro) ||
             retorno.dig(:erros, :erro) ||
             'Erro desconhecido ao atualizar contato na Tiny'
      erro = erro.map { |e| e['erro'] || e[:erro] }.join(', ') if erro.is_a?(Array)

      { success: false, error: erro.to_s }
    end
  rescue StandardError => e
    { success: false, error: e.message }
  end
end
