# frozen_string_literal: true

# Verificación completa de integridad Reply-AI / Meli.
# Ejecutar después de cualquier actualización de Chatwoot:
#   docker compose exec rails bundle exec rails runner custom/verify.rb
#   bundle exec rails runner custom/verify.rb

require 'set'

PASS = "\e[32m✓\e[0m"
FAIL = "\e[31m✗\e[0m"
WARN = "\e[33m!\e[0m"
total = 0
ok   = 0

def check(label)
  print "  #{label.ljust(52)} "
  $stdout.flush
  begin
    result = yield
    if result
      puts PASS
      true
    else
      puts "#{FAIL} (false)"
      false
    end
  rescue StandardError => e
    puts "#{FAIL} #{e.message.split("\n").first}"
    false
  end
end

puts
puts '══════════════════════════════════════════════════════════════'
puts '  VERIFICACIÓN REPLY-AI / MERCADOLIBRE'
puts '══════════════════════════════════════════════════════════════'
puts

# ── 1. Custom directory ──────────────────────────────────────────────────
puts '1. Directorio custom/'
check('custom/ existe')          { Rails.root.join('custom').directory? }
check('custom/app/models/')      { Rails.root.join('custom/app/models').directory? }
check('custom/app/controllers/') { Rails.root.join('custom/app/controllers').directory? }
check('custom/app/views/landing/') { Rails.root.join('custom/app/views/landing').directory? }
check('custom/lib/reply_ai/')    { Rails.root.join('custom/lib/reply_ai').directory? }
check('custom/db/migrate/')      { Rails.root.join('custom/db/migrate').directory? }
check('NO hay archivos meli en app/models/') { Dir[Rails.root.join('app/models/meli_*')].empty? }
check('NO hay archivos reply_ai en app/models/') { Dir[Rails.root.join('app/models/reply_ai_*')].empty? }
check('NO hay landing en app/controllers/') { !Rails.root.join('app/controllers/landing_controller.rb').exist? }

# ── 2. Autoloading ───────────────────────────────────────────────────────
puts
puts '2. Autoloading de clases'

MODELS = %w[MeliCredential MeliProduct MeliCategory MeliOfficialStore
            MeliOrder ReplyAiDocument ReplyAiPvDocument].freeze
MODELS.each { |m| check("Modelo #{m}") { m.constantize } }

WORKERS = %w[TokenRefreshWorker MeliSyncProductsWorker MeliSyncOfficialStoresWorker
             BulkImportWorker DocumentProcessorWorker PvDocumentProcessorWorker
             InjectCssMiddleware].freeze
WORKERS.each { |w| check("Worker ReplyAi::#{w}") { "ReplyAi::#{w}".constantize } }

check('Controller LandingController') { LandingController }

# ── 3. Base de datos ─────────────────────────────────────────────────────
puts
puts '3. Tablas custom en la base de datos'

TABLES = %w[meli_credentials meli_products meli_categories meli_official_stores
            meli_orders meli_questions reply_ai_documents reply_ai_pv_documents].freeze
TABLES.each do |t|
  check("Tabla #{t}") { ActiveRecord::Base.connection.table_exists?(t) }
end

# ── 4. Schema guard ──────────────────────────────────────────────────────
puts
puts '4. Schema guard'

custom_migrations = Rails.root.join('custom/db/migrate')
check('Path en Migrator') do
  ActiveRecord::Migrator.migrations_paths.include?(custom_migrations.to_s)
end

begin
  context = ActiveRecord::MigrationContext.new(custom_migrations.to_s)
  applied = context.get_all_versions.to_set
  migrations = context.migrations
  pending  = migrations.reject { |m| applied.include?(m.version) }

  check("Migraciones encontradas (#{migrations.size})") { migrations.size == 8 }
  check("Migraciones pendientes (#{pending.size})")     { pending.empty? }

  if pending.any?
    puts "    #{WARN} Hay #{pending.size} migraciones pendientes que se aplicarán al boot"
  end
rescue StandardError => e
  puts "    #{FAIL} Error: #{e.message}"
end

# ── 5. Initializers ──────────────────────────────────────────────────────
puts
puts '5. Initializers custom'

INITIALIZERS = %w[
  00_custom_load_paths
  reply-ai_routes
  reply_ai_account_associations
  reply_ai_cron
  reply_ai_middleware
  reply_ai_schema_guard
].freeze

INITIALIZERS.each do |name|
  check("config/initializers/#{name}.rb") do
    Dir[Rails.root.join("config/initializers/#{name}*")].any?
  end
end

check('NO reply_ai_extensions.rb (duplicado)') do
  !Rails.root.join('config/initializers/reply_ai_extensions.rb').exist?
end

# ── 6. Asociaciones de Account ───────────────────────────────────────────
puts
puts '6. Asociaciones en modelo Account'

ASSOCIATIONS = %w[meli_products meli_categories meli_credentials
                  reply_ai_documents reply_ai_pv_documents].freeze
ASSOCIATIONS.each do |assoc|
  check("Account.has_many :#{assoc}") do
    Account.reflect_on_association(assoc.to_sym).present?
  end
end

# ── 7. Resumen ───────────────────────────────────────────────────────────
puts
puts '══════════════════════════════════════════════════════════════'
puts '  RESUMEN'
puts '══════════════════════════════════════════════════════════════'

# Contar todos los checks que pasaron (buscamos ✓ en la salida)
# Simplemente un resumen descriptivo
puts
puts '  Para verificar en producción:'
puts '    1. Correr este script:  rails runner custom/verify.rb'
puts '    2. Probar /signup y /dashboard'
puts '    3. Verificar Sidekiq:    sidekiq processes muestre workers ReplyAi'
puts '    4. Probar flujo Meli OAuth (si hay credenciales)'
puts '    5. Verificar CSS inyectado en /app/ (items del menú ocultos)'
puts
