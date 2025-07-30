AvailableLocation.seed_default_locations

puts "✅ Locations padrão criadas/atualizadas:"
AvailableLocation.all.each do |location|
  puts "  - #{location.name} (#{location.key}) - #{location.active? ? 'Ativa' : 'Inativa'}"
end
