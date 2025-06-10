module Tiny::Contacts
  module_function

  def obtain_contact(token, contact_id)
    response = JSON.parse(HTTParty.get(ENV.fetch('OBTER_CONTATO'),
                                       query: { token:,
                                                formato: 'json',
                                                id: contact_id }))
    response.with_indifferent_access[:retorno]
  end

  def search_contact(token, cpf_cnpj, search)
    response = JSON.parse(HTTParty.get(ENV.fetch('PESQUISA_CONTATO'),
                                       query: { token:,
                                                formato: 'json',
                                                cpf_cnpj:,
                                                pesquis: search }))
    response.with_indifferent_access[:retorno]
  end

  def find_contact_and_get_phone(token, cpf_cnpj, nome)
    cpf_search_result = search_contact(token, cpf_cnpj, '')

    if cpf_search_result && cpf_search_result['contatos']
      active_contacts = cpf_search_result['contatos'].select { |c| c['contato']['situacao'] == 'Ativo' }
      last_active = active_contacts.last

      if last_active
        contact_id = last_active['contato']['id']
        contact_details = obtain_contact(token, contact_id)
        return contact_details['contato']['celular'] if contact_details && contact_details['contato']
      end
    end

    name_search_result = search_contact(token, '', nome)

    if name_search_result && name_search_result['contatos']
      active_contacts = name_search_result['contatos'].select { |c| c['contato']['situacao'] == 'Ativo' }
      last_active = active_contacts.last

      if last_active
        contact_id = last_active['contato']['id']
        contact_details = obtain_contact(token, contact_id)
        return contact_details['contato']['celular'] if contact_details && contact_details['contato']
      end
    end
    nil
  end
end
