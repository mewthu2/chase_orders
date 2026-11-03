require_relative 'nfe_test_certificate'

# Empresa emissora do Regime Normal em MG com certificado de teste e a natureza "Venda Online".
module NfeCompanyFactory
  def create_nfe_company(overrides = {})
    file = Tempfile.new(['cert', '.pfx'], binmode: true)
    file.write(NfeTestCertificate.pfx(cnpj: Nfe::Cnpj.digits(overrides[:cnpj] || '11222333000181')))
    file.rewind
    Company.create!({
      legal_name: 'Chase Brasil Comercio Ltda', cnpj: '11.222.333/0001-81', state_registration: '0029090240268',
      tax_regime: 3, icms_situation: '40', pis_cst: '49', cofins_cst: '49', street: 'Av. Raja Gabaglia', number: '4343',
      neighbourhood: 'Santa Lucia', city: 'Belo Horizonte', city_ibge_code: '3106200', state: 'MG', zip: '30350-577',
      phone: '11930541289', email: 'fiscal@example.com',
      certificate_file: Rack::Test::UploadedFile.new(file.path, 'application/x-pkcs12'), certificate_password: 'senha123'
    }.merge(overrides))
  end

  def create_sale_nature(company, overrides = {})
    company.operation_natures.create!({
      description: 'Venda Online', kind: :sale, default_for_kind: true, cfop: '?102',
      cfop_interstate_non_contributor: '6108', icms_situation: '00', icms_rate: 18, difal: true,
      pis_cst: '01', pis_rate: 1.65, cofins_cst: '01', cofins_rate: 7.6
    }.merge(overrides))
  end
end
