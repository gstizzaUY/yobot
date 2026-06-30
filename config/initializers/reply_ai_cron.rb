# config/initializers/reply_ai_cron.rb

# Registrar el cron de refresco de tokens de MercadoLibre.
# Usamos after_initialize porque to_prepare NO se ejecuta en producción.
Rails.application.config.after_initialize do
  if defined?(Sidekiq::Cron::Job) && Sidekiq.server?
    Sidekiq::Cron::Job.create(
      name: 'ReplyAi::TokenRefreshWorker',
      cron: '*/5 * * * *', # Cada 5 minutos para no esperar hasta la hora en punto
      class: 'ReplyAi::TokenRefreshWorker',
      queue: 'low'
    )
  end
end