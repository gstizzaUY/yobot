# config/initializers/reply_ai_middleware.rb
#
# Registra el middleware de personalización UI de Reply-AI.
# Debe cargarse después del stack core de Chatwoot para que pueda
# interceptar las respuestas HTML del dashboard.

require Rails.root.join('custom/lib/reply_ai/inject_css_middleware')

Rails.application.config.middleware.use ReplyAi::InjectCssMiddleware
