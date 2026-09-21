require 'nokogiri'
require 'openssl'
require 'base64'

module Nfe
  # Assina o XML da NF-e (XMLDSig enveloped) com o certificado A1 da empresa.
  # O layout da NF-e exige C14N inclusiva e SHA-1/RSA-SHA1; por isso não usamos algoritmos mais fortes.
  class Signer
    class Error < StandardError; end

    DSIG = 'http://www.w3.org/2000/09/xmldsig#'.freeze
    C14N_URI = 'http://www.w3.org/TR/2001/REC-xml-c14n-20010315'.freeze
    NFE_NS = 'http://www.portalfiscal.inf.br/nfe'.freeze

    def initialize(certificate)
      @certificate = certificate
    end

    def sign(xml)
      doc = Nokogiri::XML(xml) { |config| config.noblanks }
      inf = doc.at_xpath('//n:infNFe[@Id]', 'n' => NFE_NS)
      raise Error, 'XML sem infNFe com atributo Id.' unless inf

      digest = Base64.strict_encode64(OpenSSL::Digest::SHA1.digest(inf.canonicalize(Nokogiri::XML::XML_C14N_1_0)))
      signature = build_signature(doc, inf['Id'], digest)
      inf.add_next_sibling(signature)

      signed_info = signature.at_xpath('ds:SignedInfo', 'ds' => DSIG)
      raw = @certificate.private_key.sign(OpenSSL::Digest.new('SHA1'), signed_info.canonicalize(Nokogiri::XML::XML_C14N_1_0))
      signature.at_xpath('ds:SignatureValue', 'ds' => DSIG).content = Base64.strict_encode64(raw)

      doc.root.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML)
    end

    private

    def build_signature(doc, id, digest)
      fragment = Nokogiri::XML::DocumentFragment.new(doc, <<~XML.delete("\n").gsub(/>\s+</, '><'))
        <Signature xmlns="#{DSIG}">
          <SignedInfo>
            <CanonicalizationMethod Algorithm="#{C14N_URI}"/>
            <SignatureMethod Algorithm="#{DSIG}rsa-sha1"/>
            <Reference URI="##{id}">
              <Transforms>
                <Transform Algorithm="#{DSIG}enveloped-signature"/>
                <Transform Algorithm="#{C14N_URI}"/>
              </Transforms>
              <DigestMethod Algorithm="#{DSIG}sha1"/>
              <DigestValue>#{digest}</DigestValue>
            </Reference>
          </SignedInfo>
          <SignatureValue></SignatureValue>
          <KeyInfo>
            <X509Data>
              <X509Certificate>#{@certificate.base64_der}</X509Certificate>
            </X509Data>
          </KeyInfo>
        </Signature>
      XML
      fragment.children.first
    end
  end
end
