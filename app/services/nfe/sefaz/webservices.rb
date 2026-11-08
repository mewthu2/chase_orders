module Nfe
  module Sefaz
    # Endereços dos web services NF-e 4.00 por autorizadora. Cada UF autoriza na própria SEFAZ ou na SVRS.
    module Webservices
      class Unsupported < StandardError; end

      SERVICES = %i[autorizacao ret_autorizacao consulta_protocolo].freeze

      SP = {
        producao: 'https://nfe.fazenda.sp.gov.br/ws/%s.asmx',
        homologacao: 'https://homologacao.nfe.fazenda.sp.gov.br/ws/%s.asmx',
        paths: { autorizacao: 'nfeautorizacao4', ret_autorizacao: 'nferetautorizacao4',
                 consulta_protocolo: 'nfeconsultaprotocolo4' }
      }.freeze

      RS_PATHS = { autorizacao: 'NfeAutorizacao/NFeAutorizacao4', ret_autorizacao: 'NfeRetAutorizacao/NFeRetAutorizacao4',
                   consulta_protocolo: 'NfeConsulta/NfeConsulta4' }.freeze

      SVRS = {
        producao: 'https://nfe.svrs.rs.gov.br/ws/%s.asmx',
        homologacao: 'https://nfe-homologacao.svrs.rs.gov.br/ws/%s.asmx',
        paths: RS_PATHS
      }.freeze

      RS = {
        producao: 'https://nfe.sefazrs.rs.gov.br/ws/%s.asmx',
        homologacao: 'https://nfe-homologacao.sefazrs.rs.gov.br/ws/%s.asmx',
        paths: RS_PATHS
      }.freeze

      MG = {
        producao: 'https://nfe.fazenda.mg.gov.br/nfe2/services/%s',
        homologacao: 'https://hnfe.fazenda.mg.gov.br/nfe2/services/%s',
        paths: { autorizacao: 'NFeAutorizacao4', ret_autorizacao: 'NFeRetAutorizacao4',
                 consulta_protocolo: 'NFeConsultaProtocolo4' }
      }.freeze

      PR = {
        producao: 'https://nfe.sefa.pr.gov.br/nfe/%s',
        homologacao: 'https://homologacao.nfe.sefa.pr.gov.br/nfe/%s',
        paths: { autorizacao: 'NFeAutorizacao4', ret_autorizacao: 'NFeRetAutorizacao4',
                 consulta_protocolo: 'NFeConsultaProtocolo4' }
      }.freeze

      SVRS_STATES = %w[AC AL AP CE DF ES PB PI RJ RN RO RR SC SE TO].freeze
      AUTHORIZERS = { 'SP' => SP, 'RS' => RS, 'MG' => MG, 'PR' => PR }
                    .merge(SVRS_STATES.to_h { |uf| [uf, SVRS] }).freeze

      module_function

      def url(state, environment, service)
        authorizer = AUTHORIZERS[state.to_s]
        raise Unsupported, "Autorizadora da UF #{state} ainda não configurada no Honey." unless authorizer
        raise ArgumentError, "Serviço desconhecido: #{service}" unless SERVICES.include?(service)

        format(authorizer.fetch(environment.to_sym), authorizer[:paths].fetch(service))
      end

      def supported?(state)
        AUTHORIZERS.key?(state.to_s)
      end
    end
  end
end
