class CreateNoteTiny2Job < ActiveJob::Base
  def perform
    create_note
  end

  def create_note
    orders = Tiny::Orders.get_all_orders('tiny_3', 'enviado', '', '')

    orders.each do |order|
      p '2 segundos espera ai'
      sleep(2.seconds)
      p 'Pronto, vamos'

      if Attempt.find_by(kinds: :create_note_tiny2, tiny_order_id: order[:pedido][:id], status: :success).present?
        puts("Tentativa sucedida de criação de nota encontrada: #{order[:pedido][:id]}")
        next
      end

      puts('Não encontrei nenhuma tentativa sucedidade, bora')
      attempt = Attempt.create(kinds: :create_note_tiny2)

      attempt.update(tiny_order_id: order[:pedido][:id])

      begin
        selected_order = Tiny::Orders.obtain_order(ENV.fetch('TOKEN_TINY3_PRODUCTION'), order[:pedido][:id])
      rescue StandardError => e
        attempt.update(error: e, status: :error)
      end

      begin
        invoice = Tiny::Invoices.obtain_invoice(selected_order[:pedido][:id_nota_fiscal])
      rescue StandardError => e
        attempt.update(error: e, status: :error)
      end

      attempt.update(kinds: :create_note_tiny2,
                     id_nota_fiscal: selected_order[:pedido][:id_nota_fiscal])
      unless invoice.present?
        attempt.update(message: 'Nota fiscal não encontrada')
        next
      end

      invoice['itens'].each do |item|
        id_produto = item['item']['id_produto']

        obter_produto = HTTParty.get(ENV.fetch('OBTER_PRODUTO'),
                                     query: { token: ENV.fetch('TOKEN_TINY3_PRODUCTION'),
                                              formato: 'string',
                                              id: id_produto })
        doc = Nokogiri::XML(obter_produto)

        preco_custo = doc.at('preco_custo').text.to_f

        item['item']['gtin'] = doc.at('gtin').text
        item['item']['gtin_embalagem'] = doc.at('gtin_embalagem').text
        item['item']['ncm'] = doc.at('ncm').text
        item['item']['peso_bruto'] = doc.at('peso_bruto').text
        item['item']['peso_liquido'] = doc.at('peso_bruto').text
        item['item']['valor_unitario'] = preco_custo.to_s
        item['item']['valor_total'] = (preco_custo * item['item']['quantidade'].to_f).round(2).to_s
        item['item']['natureza'] = '5152 -  transferência de mercadoria adquirida ou recebida de terceiros em opera'
        item['item']['cfop'] = '5152'
      end

      total_valor_produtos = invoice['itens'].sum { |item| item['item']['valor_total'].to_f }

      invoice['valor_icms'] = (total_valor_produtos * 0.18).to_s
      total_impostos = (total_valor_produtos.round(2).to_i + invoice['valor_icms'].to_d).to_s

      invoice['valor_produtos'] = total_valor_produtos.round(2).to_s
      invoice['valor_nota'] = total_impostos
      invoice['base_icms'] = total_valor_produtos.to_s
      invoice['valor_faturado'] = total_impostos

      nota = mount_note(invoice)
      attempt.update(xml_nota: nota)

      begin
        request = HTTParty.post(ENV.fetch('INCLUIR_NOTA'),
                                body: { token: ENV.fetch('TOKEN_TINY2_PRODUCTION'),
                                        formato: 'string',
                                        nota: nota.to_json })
      rescue StandardError => e
        attempt.update(error: e, status: :error)
      end

      retorno = Nokogiri::XML(request.body)
      if retorno.nil? || retorno.at('id')
        begin
        rescue StandardError => e
          attempt.update(error: e, status: :error)
        end
      end

      attempt.update(message: request.message, requisition: request.body)

      if (retorno&.at('status_processamento')&.text == '3' && retorno&.at('status')&.text == 'OK') || retorno&.at('erro')&.text == 'Registro em duplicidade - Nota fiscal já cadastrada'
        attempt.update(status: :success)
        attempt.update(id_nota_tiny2: retorno.at('id').text, status_code: 200, requisition: request.body, message: request.message)
      end
    end
  end

  def mount_note(invoice)
    { 'nota_fiscal' => {
      'tipo' => 'S',
      'natureza_operacao' => 'CFOP 5152 - Transferência de mercadoria adquirida ou recebida de terceiros',
      'data_emissao' => DateTime.now.strftime('%d/%m/%Y'),
      'data_entrada_saida' => DateTime.now.strftime('%d/%m/%Y'),
      'hora_entrada_saida' => DateTime.now.strftime('%H:%M'),
      'cliente' => {
        'nome' => 'Chase Brasil Comercio de Artigos Esportivos Ltda. - 03',
        'tipo_pessoa' => 'J',
        'cpf_cnpj' => '25405327/0003-36',
        'ie' => '29090240268',
        'rg' => '',
        'endereco' => 'EST MUNICIPAL VEREADOR LAMARTINE JOSE DE OLIVEIRA',
        'numero' => '1137',
        'complemento' => '',
        'bairro' => 'DO RODEIO',
        'cep' => '37.640-000',
        'cidade' => 'Extrema',
        'uf' => 'MG',
        'fone' => '',
        'email' => 'site@chasebrasil.com',
        'atualizar_cliente' => 'N'
      },
      'endereco_entrega' => {
        'tipo_pessoa' => 'J',
        'cpf_cnpj' => '25405327/0003-36',
        'endereco' => 'EST MUNICIPAL VEREADOR LAMARTINE JOSE DE OLIVEIRA',
        'numero' => '1137',
        'complemento' => '',
        'bairro' => 'DO RODEIO',
        'cep' => '37.640-000',
        'cidade' => 'Extrema',
        'uf' => 'MG',
        'fone' => '',
        'nome_destinatario' => 'Chase Brasil Comercio de Artigos Esportivos Ltda. - 03',
        'ie' => '29090240268'
      },
      'itens' => invoice['itens'].map do |item|
        {
          'item' => {
            'codigo' => item['item']['codigo'],
            'descricao' => item['item']['descricao'],
            'unidade' => 'UN',
            'quantidade' => '1',
            'valor_unitario' => item['item']['valor_unitario'],
            'tipo' => 'P',
            'origem' => '',
            'numero_fci' => '',
            'ncm' => item['item']['ncm'],
            'peso_bruto' => item['item']['peso_bruto'],
            'peso_liquido' => item['item']['peso_liquido'],
            'gtin_ean' => item['item']['gtin'],
            'gtin_ean_embalagem' => item['item']['gtin_embalagem'],
            'codigo_lista_servicos' => '',
            'numero_pedido_compra' => '',
            'numero_item_pedido_compra' => '',
            'descricao_complementar' => '',
            'codigo_anvisa' => '',
            'valor_max' => '',
            'motivo_isencao' => ''
          }
        }
      end,
      'forma_pagamento' => '',
      'transportador' => {
        'codigo' => '',
        'nome' => '',
        'tipo_pessoa' => '',
        'cpf_cnpj' => '',
        'ie' => '',
        'endereco' => '',
        'cidade' => '',
        'uf' => ''
      },
      'frete_por_conta' => invoice['frete_por_conta'],
      'placa_veiculo' => invoice['placa'],
      'uf_veiculo' => invoice['uf_placa'],
      'quantidade_volumes' => invoice['quantidade_volumes'],
      'especie_volumes' => invoice['especie_volumes'],
      'marca_volumes' => invoice['marca_volumes'],
      'numero_volumes' => invoice['numero_volumes'],
      'valor_desconto' => '',
      'valor_frete' => '0',
      'valor_seguro' => invoice['valor_seguro'],
      'valor_despesas' => invoice['valor_outras'],
      'nf_produtor_rural' => {
        'serie' => '',
        'numero' => '',
        'ano_mes_emissao' => ''
      },
      'id_vendedor' => invoice['id_vendedor'],
      'numero_pedido_ecommerce' => invoice['numero_ecommerce'],
      'obs' => '',
      'finalidade' => invoice['finalidade'],
      'refNFe' => '',
      'intermediador' => {
        'nome' => '',
        'cnpj' => '',
        'cnpjPagamento' => ''
      }
    } }
  end
end
