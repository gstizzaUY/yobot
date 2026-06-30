module ReplyAi
  class TokenRefreshWorker
    include Sidekiq::Worker
    sidekiq_options queue: 'low', retry: 3

    def perform(account_id = nil)
      scope = MeliCredential.where.not(refresh_token: nil)
      scope = scope.where(account_id: account_id) if account_id

      # Intentar refrescar: activos próximos a vencer + los que fallaron antes
      to_refresh = scope.where(status: %w[active error])
                        .where('expires_at IS NULL OR expires_at < ?', 2.hours.from_now)

      Rails.logger.info "[TokenRefreshWorker] Revisando #{to_refresh.count} credencial(es)..."

      to_refresh.each { |credential| refresh_meli_token(credential) }
    end

    private

    def refresh_meli_token(credential)
      Rails.logger.info "[TokenRefreshWorker] Refrescando token cuenta=#{credential.account_id} ml_user=#{credential.ml_user_id}"

      response = RestClient.post('https://api.mercadolibre.com/oauth/token', {
        grant_type: 'refresh_token',
        client_id: ENV.fetch('ML_APP_ID'),
        client_secret: ENV.fetch('ML_SECRET_KEY'),
        refresh_token: credential.refresh_token
      }, { content_type: :json, accept: :json })

      data = JSON.parse(response.body)

      # update_columns para evitar validaciones que puedan fallar
      credential.update_columns(
        access_token: data['access_token'],
        refresh_token: data['refresh_token'] || credential.refresh_token,
        expires_at: Time.current + data['expires_in'].seconds,
        status: 'active',
        updated_at: Time.current
      )

      Rails.logger.info "[TokenRefreshWorker] Token refrescado OK cuenta=#{credential.account_id} expira=#{credential.expires_at}"
    rescue RestClient::Exception => e
      Rails.logger.error "[TokenRefreshWorker] ML API error cuenta=#{credential.account_id}: #{e.response&.body || e.message}"
      # No cambiar a error - dejar que reintente en el próximo ciclo
      credential.update_columns(updated_at: Time.current)
    rescue => e
      Rails.logger.error "[TokenRefreshWorker] Error inesperado cuenta=#{credential.account_id}: #{e.message}"
      credential.update_columns(updated_at: Time.current)
    end
  end
end