# Atalhos para montar cenários de chamados nos testes.
module TicketFactory
  PNG_1X1 = Base64.decode64('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==')

  def create_user(name, admin: false, **attrs)
    user = User.create!({ name: name, email: "#{name.parameterize}-#{SecureRandom.hex(3)}@example.com", password: 'password123' }.merge(attrs))
    user.profiles << Profile.find(Profile::ADMIN) if admin
    user
  end

  def create_sector(name = "Setor #{SecureRandom.hex(3)}", **attrs)
    TicketSector.create!({ name: name }.merge(attrs))
  end

  def create_responsability(users:, hours: 4, **attrs)
    attrs[:ticket_sector] ||= create_sector
    TicketResponsability.create!({ name: "Área #{SecureRandom.hex(3)}", description: 'Atende pedidos da área', response_time_hours: hours, users: users }.merge(attrs))
  end

  # Perfil extra que libera os setores informados para o usuário.
  def grant_sectors(user, *sectors)
    user.profiles << Profile.create!(name: "Setores #{SecureRandom.hex(3)}", ticket_sectors: sectors)
    user.reload
  end

  def png_upload(name = 'print.png')
    { io: StringIO.new(PNG_1X1), filename: name, content_type: 'image/png' }
  end
end
