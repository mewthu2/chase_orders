class HomeController < ApplicationController
  def index
    redirect_to new_user_session_path unless current_user
  end

  # def curl_enviar_xml
  #   require 'httparty'

  #   url = 'https://cws.correios.com.br/efulfillment/v1/xmldanfepedido/xml'

  #   headers = {
  #     'numeroCartaoPostagem' => '0074549596',
  #     'codigoArmazem' => '00425002',
  #     'Content-Type' => 'application/xml',
  #     'Authorization' => 'Basic YnJhc2lsY2hhc2U6dm84UXNoUGpKR2FGSHBCSGMwV2dOTDdiWjZKbEpBOEx5ZFRYRWtXTg==',
  #     'Cookie' => 'LBprdExt1=533331978.47873.0000; LBprdint3=3107586058.47873.0000'
  #   }

  #   xml_data = '<?xml version=\"1.0\" encoding=\"UTF-8\"?><retorno><status_processamento>3</status_processamento><status>OK</status><xml_nfe><nfeProc xmlns=\"http://www.portalfiscal.inf.br/nfe\" versao=\"4.00\"><NFe xmlns=\"http://www.portalfiscal.inf.br/nfe\"><infNFe versao=\"4.00\" Id=\"NFe31231025405327000174550010000121601941308078\"><ide><cUF>31</cUF><cNF>94130807</cNF><natOp>Venda Online</natOp><mod>55</mod><serie>1</serie><nNF>12160</nNF><dhEmi>2023-10-02T07:27:33-03:00</dhEmi><dhSaiEnt>2023-10-02T07:27:59-03:00</dhSaiEnt><tpNF>1</tpNF><idDest>2</idDest><cMunFG>3106200</cMunFG><tpImp>1</tpImp><tpEmis>1</tpEmis><cDV>8</cDV><tpAmb>1</tpAmb><finNFe>1</finNFe><indFinal>1</indFinal><indPres>2</indPres><indIntermed>0</indIntermed><procEmi>0</procEmi><verProc>Tiny ERP</verProc></ide><emit><CNPJ>25405327000174</CNPJ><xNome>Chase Brasil Comercio de Artigos Esportivos Ltda.</xNome><xFant>Chase Brasil</xFant><enderEmit><xLgr>Rua Juvenal Melo Senra</xLgr><nro>355</nro><xBairro>Belvedere</xBairro><cMun>3106200</cMun><xMun>Belo Horizonte</xMun><UF>MG</UF><CEP>30320660</CEP><cPais>1058</cPais><xPais>Brasil</xPais><fone>31995501530</fone></enderEmit><IE>0029090240004</IE><CRT>3</CRT></emit><dest><CPF>09829661997</CPF><xNome>Ana Paula Machado</xNome><enderDest><xLgr>Rua Joao Pio Duarte Silva</xLgr><nro>1350</nro><xCpl>Ap 101</xCpl><xBairro>Corrego Grande</xBairro><cMun>4205407</cMun><xMun>Florianopolis</xMun><UF>SC</UF><CEP>88037001</CEP><cPais>1058</cPais><xPais>Brasil</xPais><fone>48998062972</fone></enderDest><indIEDest>9</indIEDest><email>anaamachadooo@gmail.com</email></dest><det nItem=\"1\"><prod><cProd>TOP-SIG-OFF-M</cProd><cEAN>7898675066048</cEAN><xProd>Top Signature Seamless Off White - M</xProd><NCM>61130000</NCM><CFOP>6102</CFOP><uCom>un</uCom><qCom>1.0000</qCom><vUnCom>189.90</vUnCom><vProd>189.90</vProd><cEANTrib>7898675066048</cEANTrib><uTrib>un</uTrib><qTrib>1.0000</qTrib><vUnTrib>189.90</vUnTrib><vFrete>7.35</vFrete><indTot>1</indTot><xPed>11462</xPed></prod><imposto><vTotTrib>59.72</vTotTrib><ICMS><ICMS00><orig>0</orig><CST>00</CST><modBC>3</modBC><vBC>197.25</vBC><pICMS>1.03</pICMS><vICMS>2.03</vICMS></ICMS00></ICMS><IPI><cEnq>999</cEnq><IPINT><CST>53</CST></IPINT></IPI><PIS><PISOutr><CST>49</CST><vBC>197.25</vBC><pPIS>0.00</pPIS><vPIS>0.00</vPIS></PISOutr></PIS><COFINS><COFINSOutr><CST>49</CST><vBC>197.25</vBC><pCOFINS>0.00</pCOFINS><vCOFINS>0.00</vCOFINS></COFINSOutr></COFINS><ICMSUFDest><vBCUFDest>197.25</vBCUFDest><vBCFCPUFDest>197.25</vBCFCPUFDest><pFCPUFDest>0.0000</pFCPUFDest><pICMSUFDest>0.0000</pICMSUFDest><pICMSInter>12.00</pICMSInter><pICMSInterPart>100.0000</pICMSInterPart><vFCPUFDest>0.00</vFCPUFDest><vICMSUFDest>0.00</vICMSUFDest><vICMSUFRemet>0.00</vICMSUFRemet></ICMSUFDest></imposto></det><det nItem=\"2\"><prod><cProd>SHO-SIG-OFF-G</cProd><cEAN>7898675066086</cEAN><xProd>Short Signature Seamless Off White - G</xProd><NCM>61130000</NCM><CFOP>6102</CFOP><uCom>un</uCom><qCom>1.0000</qCom><vUnCom>189.90</vUnCom><vProd>189.90</vProd><cEANTrib>7898675066086</cEANTrib><uTrib>un</uTrib><qTrib>1.0000</qTrib><vUnTrib>189.90</vUnTrib><vFrete>7.35</vFrete><indTot>1</indTot><xPed>11462</xPed></prod><imposto><vTotTrib>59.72</vTotTrib><ICMS><ICMS00><orig>0</orig><CST>00</CST><modBC>3</modBC><vBC>197.25</vBC><pICMS>1.03</pICMS><vICMS>2.03</vICMS></ICMS00></ICMS><IPI><cEnq>999</cEnq><IPINT><CST>53</CST></IPINT></IPI><PIS><PISOutr><CST>49</CST><vBC>197.25</vBC><pPIS>0.00</pPIS><vPIS>0.00</vPIS></PISOutr></PIS><COFINS><COFINSOutr><CST>49</CST><vBC>197.25</vBC><pCOFINS>0.00</pCOFINS><vCOFINS>0.00</vCOFINS></COFINSOutr></COFINS><ICMSUFDest><vBCUFDest>197.25</vBCUFDest><vBCFCPUFDest>197.25</vBCFCPUFDest><pFCPUFDest>0.0000</pFCPUFDest><pICMSUFDest>0.0000</pICMSUFDest><pICMSInter>12.00</pICMSInter><pICMSInterPart>100.0000</pICMSInterPart><vFCPUFDest>0.00</vFCPUFDest><vICMSUFDest>0.00</vICMSUFDest><vICMSUFRemet>0.00</vICMSUFRemet></ICMSUFDest></imposto></det><total><ICMSTot><vBC>394.50</vBC><vICMS>4.06</vICMS><vICMSDeson>0.00</vICMSDeson><vFCPUFDest>0.00</vFCPUFDest><vICMSUFDest>0.00</vICMSUFDest><vICMSUFRemet>0.00</vICMSUFRemet><vFCP>0.00</vFCP><vBCST>0.00</vBCST><vST>0.00</vST><vFCPST>0.00</vFCPST><vFCPSTRet>0.00</vFCPSTRet><vProd>379.80</vProd><vFrete>14.70</vFrete><vSeg>0.00</vSeg><vDesc>0.00</vDesc><vII>0.00</vII><vIPI>0.00</vIPI><vIPIDevol>0.00</vIPIDevol><vPIS>0.00</vPIS><vCOFINS>0.00</vCOFINS><vOutro>0.00</vOutro><vNF>394.50</vNF><vTotTrib>119.44</vTotTrib></ICMSTot></total><transp><modFrete>0</modFrete><transporta><CNPJ>34028316000103</CNPJ><xNome>EMPRESA BRASILEIRA DE CORREIOS E TELEGRAFOS</xNome><xEnder>Avenida Um, 800</xEnder><xMun>Contagem</xMun><UF>MG</UF></transporta><vol><pesoL>0.300</pesoL><pesoB>0.300</pesoB></vol></transp><cobr><fat><nFat>12160</nFat><vOrig>394.50</vOrig><vDesc>0</vDesc><vLiq>394.50</vLiq></fat><dup><nDup>001</nDup><dVenc>2023-10-02</dVenc><vDup>394.50</vDup></dup></cobr><pag><detPag><tPag>99</tPag><xPag>Conta a receber</xPag><vPag>394.50</vPag></detPag></pag><infAdic><infCpl>Operacao contratada no ambito do&lt;br /&gt;comercio eletronico ou do telemarketing&lt;br /&gt;::Mercadoria destinada a uso e&lt;br /&gt;consumo, vedado o aproveitamento do&lt;br /&gt;credito&lt;br /&gt;nos termos do inciso III do art 70 do&lt;br /&gt;RICMS&lt;br /&gt;&lt;br /&gt;Tributos aproximados: R$ 51,08 (Federal) e R$ 68,36 (Estadual). Fonte: IBPT 0D61CD&lt;br /&gt;OC: 11462</infCpl></infAdic><compra><xPed>11462</xPed></compra></infNFe><Signature xmlns=\"http://www.w3.org/2000/09/xmldsig#\"><SignedInfo><CanonicalizationMethod Algorithm=\"http://www.w3.org/TR/2001/REC-xml-c14n-20010315\"/><SignatureMethod Algorithm=\"http://www.w3.org/2000/09/xmldsig#rsa-sha1\"/><Reference URI=\"#NFe31231025405327000174550010000121601941308078\"><Transforms><Transform Algorithm=\"http://www.w3.org/2000/09/xmldsig#enveloped-signature\"/><Transform Algorithm=\"http://www.w3.org/TR/2001/REC-xml-c14n-20010315\"/></Transforms><DigestMethod Algorithm=\"http://www.w3.org/2000/09/xmldsig#sha1\"/><DigestValue>vmcbK/e8VbsnIDYUeBx7p+4sg90=</DigestValue></Reference></SignedInfo><SignatureValue>AsmkmiFdyGpglUfbAABdhEJFiVjI1sDlJ9VtRVw4ahLDZVBPfBm+PGbsWKNGfGus+hDKFR6wToUexkwckOSTIxMKNYRQDVS2JuuVOGc/ppTuH0m0Hh1AqCsa3qHUDCsog8meMdKeiczhC/L++qSFC4uUDh9q/hF3qkSibFJSpwVC6jOarmouDlFAvupr05JZQ6EBJo9SzwM0fzeMIvedF8xvCH7tQvUw66zAT+gVWJ+G9+FmgiK6ssjzYbCkQHLSu9sToHJTgYFKcYppX8/uF4nwuzWF+jN+YBEDJZvOL5Gr4YikncC3dnjGJ5gxUd8Sdjg1S90SwAJ9hEmgIQjWeg==</SignatureValue><KeyInfo><X509Data><X509Certificate>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</X509Certificate></X509Data></KeyInfo></Signature></NFe><protNFe versao=\"4.00\"><infProt><tpAmb>1</tpAmb><verAplic>J-3.1.37</verAplic><chNFe>31231025405327000174550010000121601941308078</chNFe><dhRecbto>2023-10-02T09:32:42-03:00</dhRecbto><nProt>131235599294135</nProt><digVal>vmcbK/e8VbsnIDYUeBx7p+4sg90=</digVal><cStat>100</cStat><xMotivo>Autorizado o uso da NF-e</xMotivo></infProt></protNFe></nfeProc></xml_nfe></retorno>'

  #   response = HTTParty.post(url, headers: headers, body: xml_data)

  #   puts response.body
  # end

  # def curl_criar_pedido
  #   url = 'https://cws.correios.com.br/efulfillment/v1/pedidos'
  #   headers = {
  #     'numeroCartaoPostagem' => '0074549596',
  #     'Content-Type' => 'application/json',
  #     'Authorization' => 'Basic YnJhc2lsY2hhc2U6dm84UXNoUGpKR2FGSHBCSGMwV2dOTDdiWjZKbEpBOEx5ZFRYRWtXTg==',
  #     'Cookie' => 'LBprdExt1=533331978.47873.0000; LBprdint3=3107586058.47873.0000'
  #   }

  #   payload = {
  #     "codigoArmazem": "00425002",
  #     "numero": "12160",
  #     "dataSolicitacao": "02/10/2023 07:27:33",
  #     "cartaoPostagem": "0074549596",
  #     "codigoservico": "39888",
  #     "numeroPLP": "",
  #     "numeroSerie": "1",
  #     "cnpjTransportadora": "34028316000103",
  #     "destinatario": {
  #         "nome": "Ana Paula Machado",
  #         "logradouro": "Rua João Pio Duarte Silva",
  #         "numeroEndereco": "1350",
  #         "complemento": "Ap 101",
  #         "bairro": "Córrego Grande",
  #         "cep": "88037001",
  #         "cidade": "Florianópolis",
  #         "uf": "SC",
  #         "ddd": "48",
  #         "telefone": "99806-2972",
  #         "email": "anaamachadooo@gmail.com",
  #         "cnpj": "",
  #         "cpf": "09829661997"
  #     },
  #     "itensPedido": [
  #         {
  #             "codigo": "TOP-SIG-OFF-M",
  #             "quantidade": "1"
  #         },
  #         {
  #             "codigo": "SHO-SIG-OFF-G",
  #             "quantidade": "1"
  #         }
  #     ]
  #   }

  #   response = HTTParty.post(url, headers: headers, body: payload.to_json)
  #   JSON.parse(response.body)
  # end

  # def curl_1
  #   url = 'https://api.tiny.com.br/api2/pedido.obter.php'
  #   token = '78c4321030e0a78144dc43e5f566d99f504f72db'
  #   id = '794130802'

  #   headers = {
  #     'Cookie' => '__cf_bm=JuKDUzmFz2Nh4RzJAcoGuoCZWFi6GEu_Ig8GEEHBkKQ-1696504130-0-Aaiv9iBEKQkocRXmI4HCtGcWDpOJENkxQPCch2zxTLzu7XAG5MgqnYzQ6P2ja7g3zklfW0QCKbP9SliPAZDmdAM='
  #   }

  #   response = HTTParty.get(url, query: { token: token, formato: 'json', id: id }, headers: headers)

  #   # Exibir a resposta
  #   puts response.body
  # end


  # def test
  #   url = "https://cws.correios.com.br/efulfillment/v1/pedidos"
  #   headers = {
  #     "numeroCartaoPostagem" => "0074549596",
  #     "Content-Type" => "application/json",
  #     "Authorization" => "Basic YnJhc2lsY2hhc2U6dm84UXNoUGpKR2FGSHBCSGMwV2dOTDdiWjZKbEpBOEx5ZFRYRWtXTg=="
  #   }

  #   payload = {
  #     "codigoArmazem": "00425002",
  #     "numero": "3046",
  #     "dataSolicitacao": "02/10/2023",
  #     "valordeclarado": "394.50",
  #     "cartaoPostagem": "0074549596",
  #     "codigoservico": "39888",
  #     "numeroPLP": "",
  #     "numeroSerie": "12160",
  #     "servicosAdicionais": [""],
  #     "cnpjTransportadora": "34.028.316/0007-07",
  #     "destinatario": {
  #       "nome": "Ana Paula Machado",
  #       "logradouro": "Rua João Pio Duarte Silva",
  #       "numeroEndereco": "1350",
  #       "complemento": "Ap 101",
  #       "bairro": "Córrego Grande",
  #       "cep": "string",
  #       "cidade": "Florianópolis",
  #       "uf": "SC",
  #       "ddd": "48",
  #       "telefone": "99806-2972",
  #       "email": "anaamachadooo@gmail.com",
  #       "cnpj": "",
  #       "cpf": "098.296.619-97"
  #     },
  #     "itensPedido": [
  #       {
  #         "codigo": "TOP-SIG-OFF-M",
  #         "quantidade": "1.00"
  #       },
  #       {
  #         "codigo": "SHO-SIG-OFF-G",
  #         "quantidade": "1.00"
  #       }
  #     ]
  #   }

  #   response = RestClient.post(url, payload.to_json, headers)
  #   puts response.body
  # end
  
  # def buscar_pedidos
  #   url = "https://api.tiny.com.br/api2/pedidos.pesquisa.php"
  #   url = "https://api.tiny.com.br/api2/notas.fiscais.pesquisa.php"
  #   url = "https://api.tiny.com.br/api2/contato.obter.php"
  #   pedido = "https://api.tiny.com.br/api2/pedido.obter.php"
  #   nota = 'https://api.tiny.com.br/api2/nota.fiscal.obter.php'
  #   emitir = 'https://api.tiny.com.br/api2/nota.fiscal.emitir.php'
  #   enviar_xml = 'https://cws.correios.com.br/efulfillment/v1/xmldanfepedido/xml'
  #   obter_xml = 'https://api.tiny.com.br/api2/nota.fiscal.obter.xml.php'

  #   url = 'URL_DO_ENDPOINT_AQUI'
  #   url = 'https://cws.correios.com.br/efulfillment/v1/xmldanfepedido/versao'

  #   username = 'brasilchase'
  #   password = 'vo8QshPjJGaFHpBHc0WgNL7bZ6JlJA8LydTXEkWN'
    
  #   headers = {
  #     Authorization: "#{Base64.strict_encode64("#{username}:#{password}")}",
  #     Host: 'cws.correios.com.br',
  #     'Content-Type' => 'application/xml',
  #     numeroCartaoPostagem: '0074549596',
  #     codigoArmazem: '00425002'
  #   }

  #   parametros = {
  #     'xml' => xml
  #   }
  #   url = 'https://cws.correios.com.br/efulfillment/v1/xmldanfepedido/xml'
  #   response = RestClient.post(url, headers: headers)
    
  #   # Parâmetros da sua requisição
  #   parametros = {
  #     token: '78c4321030e0a78144dc43e5f566d99f504f72db',
  #     formato: 'json',
  #     id: '794130807'
  #   }

  #   # Faz a requisição GET para a API usando RestClient
  #   response = RestClient.post pedido, params: parametros

  #   # Verifique se a resposta foi bem-sucedida (código de status 200)
  #   if response.code == 200
  #     # Faça algo com os dados da resposta (response.body)
  #     JSON.parse(response.body)
  #   else
  #     # Lida com erros, se necessário
  #     render json: { error: 'Erro na requisição à API Tiny' }, status: :unprocessable_entity
  #   end
  # end
end

