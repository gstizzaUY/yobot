# frozen_string_literal: true

# Garantiza que las tablas custom de Reply-AI / MercadoLibre existan siempre,
# incluso después de un db:schema:load o db:reset que las borraría.
#
# Al arrancar, verifica si hay migraciones custom pendientes y las aplica.
# También registra el path para que rake db:migrate las incluya.

custom_migrations = Rails.root.join('custom/db/migrate')
return unless custom_migrations.directory?

# ── Incluir en db:migrate ──────────────────────────────────────────────────
ActiveRecord::Migrator.migrations_paths << custom_migrations.to_s

# ── Auto-aplicar migraciones faltantes al boot ────────────────────────────
Rails.application.config.after_initialize do
  begin
    connection = ActiveRecord::Base.connection
  rescue StandardError
    next # Base de datos no disponible aún (primer boot, migraciones iniciales)
  end

  next unless connection.table_exists?('schema_migrations')

  context = ActiveRecord::MigrationContext.new(custom_migrations.to_s)
  applied = context.get_all_versions.to_set
  pending = context.migrations.reject { |m| applied.include?(m.version) }

  if pending.any?
    Rails.logger.info "[reply_ai] Aplicando #{pending.size} migracion(es) custom pendiente(s)..."
    pending.each do |migration|
      Rails.logger.info "[reply_ai]   -> #{migration.filename}"
    end
    context.migrate
    Rails.logger.info "[reply_ai] Migraciones custom aplicadas."
  end
end
