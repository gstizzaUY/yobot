# config/initializers/reply_ai_cron.rb

# Esperamos a que Sidekiq esté listo para registrar la tarea
Rails.application.reloader.to_prepare do
  # Solo registrar el cron job cuando corre dentro del proceso Sidekiq server
  if defined?(Sidekiq::Cron::Job) && Sidekiq.server?
    Sidekiq::Cron::Job.create(
      name: 'ReplyAi::TokenRefreshWorker',
      cron: '0 * * * *', # Se ejecuta al minuto 0 de cada hora
      class: 'ReplyAi::TokenRefreshWorker',
      queue: 'low'       # Usamos la cola 'low' que ya existe en tu sidekiq.yml
    )
  end
end