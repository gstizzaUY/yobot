class UnifyMeliProductsDateColumns < ActiveRecord::Migration[7.1]
  # Unifica los nombres de las columnas de fechas de meli_products.
  #
  # El worker de sync (ReplyAi::MeliSyncProductsWorker) escribe date_created /
  # last_updated (sin prefijo), igual que db/schema.rb. Pero la migración
  # 20260303044018 las creó como meli_date_created / meli_last_updated, por lo
  # que en producción (construida corriendo migraciones) el sync de productos
  # moría con ActiveModel::UnknownAttributeError y ningún catálogo se persistía.
  #
  # rename si existe el nombre viejo con prefijo; no-op si ya existe el canónico
  # (bases creadas desde schema.rb). Sin datos que preservar: producción nunca
  # sincronizó productos con los nombres viejos.
  def up
    rename_if_needed(:meli_date_created, :date_created)
    rename_if_needed(:meli_last_updated, :last_updated)
  end

  def down
    rename_if_needed(:date_created, :meli_date_created)
    rename_if_needed(:last_updated, :meli_last_updated)
  end

  private

  def rename_if_needed(from, to)
    return unless column_exists?(:meli_products, from)
    return if column_exists?(:meli_products, to)

    rename_column :meli_products, from, to
  end
end
