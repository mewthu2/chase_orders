require 'test_helper'
require 'base64'
require_relative '../../support/nfe_test_certificate'

class Nfe::SignerTest < ActiveSupport::TestCase
  NS = { 'n' => 'http://www.portalfiscal.inf.br/nfe', 'ds' => 'http://www.w3.org/2000/09/xmldsig#' }.freeze
  C14N = Nokogiri::XML::XML_C14N_1_0

  def setup
    @certificate = Nfe::Certificate.new(NfeTestCertificate.pfx, 'senha123')
    company = Company.new(
      legal_name: 'Empresa Teste Ltda', cnpj: '11222333000181', state_registration: '123456789', tax_regime: 1,
      street: 'Rua A', number: '10', neighbourhood: 'Centro', city: 'Belo Horizonte', city_ibge_code: '3106200',
      state: 'MG', zip: '30000-000', environment: :homologacao
    )
    @result = Nfe::XmlBuilder.new(
      company: company,
      recipient: { name: 'Cliente', document: '25405327000174', ie_indicator: 9, street: 'Rua B', number: '20',
                   neighbourhood: 'Bairro', city: 'Belo Horizonte', city_ibge_code: '3106200', state: 'MG', zip: '31000000' },
      items: [{ code: 'A', description: 'Item', ncm: '61091000', origin: 0, unit: 'UN', quantity: 1, unit_price: '10.00', cfop: '5102' }],
      number: 7, series: 1, operation_nature: 'Venda', issued_at: Time.utc(2026, 9, 20, 15), cnf: '12345678'
    ).call
    @signed = Nfe::Signer.new(@certificate).sign(@result.xml)
  end

  def parse(xml)
    Nokogiri::XML(xml) { |config| config.strict }
  end

  test 'adds a Signature after infNFe that references the NFe id' do
    doc = parse(@signed)

    assert_equal 'NFe', doc.root.name
    assert_equal %w[infNFe Signature], doc.root.element_children.map(&:name)
    reference = doc.at_xpath('//ds:Reference', NS)
    assert_equal "#NFe#{@result.access_key}", reference['URI']
    assert_equal 'http://www.w3.org/2000/09/xmldsig#rsa-sha1', doc.at_xpath('//ds:SignatureMethod', NS)['Algorithm']
    assert_equal 'http://www.w3.org/2000/09/xmldsig#sha1', doc.at_xpath('//ds:DigestMethod', NS)['Algorithm']
    assert_equal @certificate.base64_der, doc.at_xpath('//ds:X509Certificate', NS).text
  end

  test 'the digest matches the canonicalized infNFe' do
    doc = parse(@signed)
    inf = doc.at_xpath('//n:infNFe', NS)
    expected = Base64.strict_encode64(OpenSSL::Digest::SHA1.digest(inf.canonicalize(C14N)))

    assert_equal expected, doc.at_xpath('//ds:DigestValue', NS).text
  end

  test 'the signature value verifies against the certificate public key' do
    doc = parse(@signed)
    signed_info = doc.at_xpath('//ds:SignedInfo', NS).canonicalize(C14N)
    signature = Base64.decode64(doc.at_xpath('//ds:SignatureValue', NS).text)

    assert @certificate.certificate.public_key.verify(OpenSSL::Digest.new('SHA1'), signature, signed_info)
  end

  test 'tampering with the signed content breaks the digest' do
    doc = parse(@signed.sub('<vNF>10.00</vNF>', '<vNF>99.00</vNF>'))
    inf = doc.at_xpath('//n:infNFe', NS)
    recomputed = Base64.strict_encode64(OpenSSL::Digest::SHA1.digest(inf.canonicalize(C14N)))

    assert_not_equal recomputed, doc.at_xpath('//ds:DigestValue', NS).text
  end

  test 'the signed XML keeps no indentation' do
    refute_match(/>\s+</, @signed)
  end

  test 'raises when the XML has no infNFe with an Id' do
    assert_raises(Nfe::Signer::Error) { Nfe::Signer.new(@certificate).sign('<NFe xmlns="http://www.portalfiscal.inf.br/nfe"/>') }
  end
end
