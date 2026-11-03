# Exceções do Bullet, valem no development e no test com BULLET=1 (config/environments/test.rb).
if defined?(Bullet)
  # B2bOrder#index eager-loads :client and :transfer_location together to
  # avoid N+1 across the list, but each order only ever renders one of the
  # two depending on its `kind` (sale vs stock_transfer). Whenever the
  # visible page happens to be all one kind, Bullet flags the other
  # association as unused eager loading — a false positive given both are
  # genuinely needed to cover a mixed-kind list.
  Bullet.add_safelist type: :unused_eager_loading, class_name: 'B2bOrder', association: :client
  Bullet.add_safelist type: :unused_eager_loading, class_name: 'B2bOrder', association: :transfer_location
  # Notas fiscais: a lista mistura notas do atacado, do site e das transferências; numa página só de
  # um tipo, Bullet acusa as outras origens como não usadas.
  Bullet.add_safelist type: :unused_eager_loading, class_name: 'FiscalNote', association: :b2b_order
  Bullet.add_safelist type: :unused_eager_loading, class_name: 'FiscalNote', association: :order
  Bullet.add_safelist type: :unused_eager_loading, class_name: 'FiscalNote', association: :internal_transfer_shipment
  # Interno do Active Storage ao anexar um arquivo (ex.: certificado da empresa).
  Bullet.add_safelist type: :unused_eager_loading, class_name: 'ActiveStorage::Attachment', association: :record
  # Fotos e anexos: a foto é lida por user.avatar (Attached::One), caminho que o Bullet não enxerga como
  # uso do blob pré-carregado. O aviso de N+1 (foto sem pré-carregar) continua valendo.
  Bullet.add_safelist type: :unused_eager_loading, class_name: 'ActiveStorage::Attachment', association: :blob
end
