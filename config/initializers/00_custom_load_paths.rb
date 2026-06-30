# frozen_string_literal: true

# Carga el directorio custom/ sin modificar ningún archivo core de Chatwoot.
# Usa push_dir de Zeitwerk (desarrollo) + eager_load_paths (producción).
#
# Al existir custom/, ChatwootApp.extensions devuelve ['enterprise', 'custom']
# y prepend_mod_with / include_mod_with buscan módulos en Custom:: además de Enterprise::.

custom_root = Rails.root.join('custom')

# ── Zeitwerk autoloader (desarrollo + eager_load en producción) ───────────
# push_dir registra el directorio en Zeitwerk, que se encarga tanto del
# lazy-loading en desarrollo como del eager_load! en producción.
# NO usamos eager_load_paths porque Rails lo congela antes de los initializers.
main_loader = Rails.autoloaders.main

main_loader.push_dir(custom_root.join('app/models'),     namespace: Object)
main_loader.push_dir(custom_root.join('app/controllers'), namespace: Object)

# custom/lib/ → módulo ReplyAi y cualquier extensión futura
main_loader.push_dir(custom_root.join('lib'), namespace: Object)

# ── Vistas ─────────────────────────────────────────────────────────────────
# config.paths['app/views'] también está congelado cuando corren los
# initializers. Usamos prepend_view_path en ActionController::Base.
Rails.application.config.to_prepare do
  ActionController::Base.prepend_view_path(custom_root.join('app/views'))
end
