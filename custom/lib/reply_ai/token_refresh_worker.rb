module ReplyAi
  class TokenRefreshWorker
    include Sidekiq::Worker
    sidekiq_options queue: 'low', retry: 3

    def perform
      # Ventana de 90 min: el cron corre cada 60 min, necesitamos margen suficiente
      # para garantizar que siempre se refresca ANTES de que expire
      credentials = MeliCredential.where(status: 'active')
                                  .where('expires_at < ?', 90.minutes.from_now)

      credentials.each { |credential| refresh_meli_token(credential) }
    end

    private

    def refresh_meli_token(credential)
      response = RestClient.post('https://api.mercadolibre.com/oauth/token', {
        grant_type: 'refresh_token',
        client_id: ENV['ML_APP_ID'],
        client_secret: ENV['ML_SECRET_KEY'],
        refresh_token: credential.refresh_token
      }, { content_type: :json, accept: :json })

      data = JSON.parse(response.body)

      credential.update!(
        access_token: data['access_token'],
        refresh_token: data['refresh_token'],
        expires_at: Time.current + data['expires_in'].seconds,
        status: 'active'
      )
    rescue => e
      Rails.logger.error "Error refrescando token ML cuenta #{credential.account_id}: #{e.message}"
      credential.update_columns(status: 'error')
    end
  end
end