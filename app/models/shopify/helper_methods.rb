module HelperMethods
  def build_address(cliente, phone = nil)
    phone ||= format_phone_number(cliente['fone'])

    {
      'address1' => [cliente['endereco'], cliente['numero']].compact.join(', '),
      'address2' => cliente['complemento'] || '',
      'city' => cliente['cidade'] || 'Cidade não informada',
      'province' => cliente['uf'] || 'SP',
      'country' => 'BR',
      'zip' => cliente['cep']&.gsub(/\D/, '') || '00000000',
      'first_name' => cliente['nome'].split.first,
      'last_name' => cliente['nome'].split[1..].join(' '),
      'phone' => phone,
      'company' => cliente['nome_fantasia'] || ''
    }
  end

  def format_date(date_str)
    return Time.now.iso8601 if date_str.nil? || date_str.empty?

    begin
      if date_str.match(%r{\d{2}/\d{2}/\d{4}})
        DateTime.strptime("#{date_str} 12:00:00", '%d/%m/%Y %H:%M:%S').iso8601
      else
        Time.parse(date_str).iso8601
      end
    rescue ArgumentError
      Time.now.iso8601
    end
  end

  def generate_unique_phone(original_phone, session)
    base_phone = if original_phone.present?
                   format_phone_number(original_phone)
                 else
                   '+5511999999999'
                 end

    return base_phone if phone_unique?(base_phone, session)

    3.times do |i|
      unique_phone = if base_phone.end_with?('9')
                       base_phone.gsub(/(\d{2})$/, (i + 1).to_s.rjust(2, '0'))
                     else
                       "#{base_phone}#{i + 1}"
                     end

      return unique_phone if phone_unique?(unique_phone, session)
    end

    "+55119#{SecureRandom.rand(100000000..999999999)}"
  end

  def phone_unique?(phone, session)
    return false unless phone.present?

    # Search for customers with this phone
    customers = ShopifyAPI::Customer.all(
      session:,
      phone:,
      limit: 1
    )

    customers.empty?
  rescue
    false
  end

  def format_phone_number(phone)
    return nil unless phone.present?

    cleaned = phone.gsub(/\D/, '')

    case cleaned.size
    when 11, 10 then "+55#{cleaned}"
    when 8 then "+5511#{cleaned}"
    else "+55#{cleaned}"
    end
  end
end