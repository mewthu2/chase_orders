# Nota de transferência de uma remessa, ao enviar: a empresa da loja de origem emite para a empresa da
# loja de destino, direto na SEFAZ (nada passa pelo Tiny). Devolve a nota (autorizada ou não) ou nil
# quando as duas lojas são da mesma empresa (não há nota entre o mesmo CNPJ).
# Clicar em Enviar de novo continua de onde parou: consulta a nota que ficou sem resposta, reenvia a
# assinada ou gera outra no lugar da rejeitada (com o mesmo número).
class InternalTransferInvoicer
  class Error < StandardError; end

  def self.call(shipment)
    new(shipment).call
  end

  # Empresas que emitem e recebem a nota; nil se alguma loja ainda não foi ligada a uma empresa.
  def self.companies_for(shipment)
    [shipment.origin_location.company, shipment.internal_transfer.destination_location.company]
  end

  def initialize(shipment)
    @shipment = shipment
  end

  def call
    origin, destination = self.class.companies_for(@shipment)
    ensure_linked!(origin, @shipment.origin_location)
    ensure_linked!(destination, @shipment.internal_transfer.destination_location)
    return nil if origin.id == destination.id

    note = @shipment.fiscal_notes.where(company: origin, environment: origin.environment).order(:created_at, :id).last
    return note if note&.autorizada?

    Nfe::Transmitter.call(note, consult: true) if note&.erro?
    Nfe::Transmitter.call(note) if note&.assinada?
    return note if note && (note.autorizada? || note.erro?)

    note = Nfe::TransferGenerator.call(shipment: @shipment, company: origin, recipient_company: destination)
    Nfe::Transmitter.call(note)
  rescue Nfe::TransferGenerator::Error, Nfe::Transmitter::Error => e
    raise Error, e.message
  end

  private

  def ensure_linked!(company, location)
    return if company

    raise Error, "A loja #{location.name} ainda não está ligada a uma empresa. Escolha a loja em Empresas (Loja desta empresa) para emitir a nota de transferência."
  end
end
