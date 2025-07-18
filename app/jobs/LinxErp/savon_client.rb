require 'savon'

module LinxErp
  class SavonClient

    def initialize
      @client = Savon.client(
        endpoint: "http://webapi.microvix.com.br/1.0/api/integracao",
        wsdl: nil,
        open_timeout: 10,
        read_timeout: 10,
        soap_version: 1,
        namespaces: { "xmlns:nsl" => "http://tempuri.org/" },
        log: true,
        pretty_print_xml: true
      )
    end

    def consulta_pedido_status(chave:, cnpj_emp:, timestamp:)
      xml = <<~XML
        <?xml version="1.0" encoding="ISO 8859-1" ?>
        <LinxMicrovix><Authentication user="linx_b2c" password="linx_b2c" />
        <ResponseFormat>xml</ResponseFormat>
        <Command><Name>B2CConsultaPedidos</Name>
         <Parameters>
          <Parameter id="chave">#{chave}</Parameter>
          <Parameter id="cnpjEmp">#{cnpj_emp}</Parameter>
          <Parameter id="timestamp">#{timestamp}</Parameter>
         </Parameters>
        </Command></LinxMicrovix>
      XML

      @client.call(
        :b2cconsulta_pedidos,
        soap_action: 'http://tempuri.org/B2CconsultaTransportadores',
        xml: xml,
        headers: { 'Content-Type' => 'text/xml; charset=ISO 8859-1' }
      )
    end

    def consulta_transportadores(chave:, cnpj_emp:, cod_transportador:)
      xml = <<~XML
        <?xml version="1.0" encoding="ISO 8859-1" ?>
        <LinxMicrovix><Authentication user="linx_b2c" password="linx_b2c" />
        <ResponseFormat>xml</ResponseFormat>
        <Command><Name>B2CconsultaTransportadores</Name>
         <Parameters>
          <Parameter id="chave">#{chave}</Parameter>
          <Parameter id="cnpjEmp">#{cnpj_emp}</Parameter>
          <Parameter id="cod_transportador">#{cod_transportador}</Parameter>
         </Parameters>
        </Command></LinxMicrovix>
      XML

      @client.call(
        :b2cconsulta_transportadores,
        soap_action: 'http://tempuri.org/B2CconsultaTransportadores',
        xml: xml,
        headers: { 'Content-Type' => 'text/xml; charset=ISO 8859-1' }
      )
    end
  end
end