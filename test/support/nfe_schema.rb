require 'nokogiri'

# Valida o XML da NF-e contra o XSD oficial (pacote PL_010), copiado em test/fixtures/files/nfe_schemas.
module NfeSchema
  module_function

  DIR = File.expand_path('../fixtures/files/nfe_schemas', __dir__)

  def errors(xml)
    schema = Dir.chdir(DIR) { Nokogiri::XML::Schema(File.read('nfe_v4.00.xsd')) }
    schema.validate(Nokogiri::XML(xml)).map(&:message)
  end
end
