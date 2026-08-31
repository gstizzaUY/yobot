module ReplyAi
  class TokenRefreshWorker
    include Sidekiq::Worker
    sidekiq_options queue: 'low', retry: 3

    def perform(account_id = nil)
      scope = MeliCredential.where.not(refresh_token: nil)
      scope = scope.where(account_id: account_id) if account_id

      # Intentar refrescar: activos/bridge próximos a vencer + los que fallaron antes
      to_refresh = scope.where(status: %w[active error bridge])
                        .where('expires_at IS NULL OR expires_at < ?', 2.hours.from_now)

      Rails.logger.info "[TokenRefreshWorker] Revisando #{to_refresh.count} credencial(es)..."

      to_refresh.each { |credential| refresh_meli_token(credential) }
    end

    private

    # Rutas de refresh según el perfil del usuario (2026-08-07):
    # - MIGRADO (`bridge_enabled` + credenciales de la app de Yobot en .env): refresh
    #   directo a ML con `YOBOT_ML_APP_ID`/`YOBOT_ML_SECRET_KEY` (el token lo emitió la app
    #   de Yobot; solo esa app puede refrescarlo). El flag de Yobot es `full` → su token
    #   obsoleto es irrelevante.
    # - BRIDGE PURO (`status == 'bridge'` sin las vars de Yobot): vía `/api/bridge/refresh-token`.
    # - NATIVO: refresh directo a ML con `ML_APP_ID`/`ML_SECRET_KEY` (app de Reply).
    def refresh_meli_token(credential)
      if credential.bridge_enabled && yobot_app_credentials?
        refresh_via_ml_with_yobot_app(credential)
      elsif credential.status == 'bridge'
        refresh_via_yobot(credential)
      else
        refresh_via_ml(credential)
      end
    end

    def yobot_app_credentials?
      ENV.fetch('YOBOT_ML_APP_ID', nil).present? && ENV.fetch('YOBOT_ML_SECRET_KEY', nil).present?
    end

    def refresh_via_yobot(credential)
      Rails.logger.info "[TokenRefreshWorker] Refrescando vía Yobot cuenta=#{credential.account_id} ml_user=#{credential.ml_user_id}"

      body = { ml_user_id: credential.ml_user_id, refresh_token: credential.refresh_token }.to_json
      signature = OpenSSL::HMAC.hexdigest('SHA256', ENV.fetch('BRIDGE_SECRET'), body)

      response = RestClient.post(
        "#{ENV.fetch('YOBOT_BRIDGE_URL')}/api/bridge/refresh-token",
        body,
        {
          content_type: :json,
          accept: :json,
          Authorization: "Bearer #{ENV.fetch('BRIDGE_SECRET')}",
          'X-Bridge-Signature': signature
        }
      )

      data = JSON.parse(response.body)

      credential.update_columns(
        access_token: data['access_token'],
        refresh_token: data['refresh_token'] || credential.refresh_token,
        expires_at: Time.current + data['expires_in'].seconds,
        updated_at: Time.current
      )

      Rails.logger.info "[TokenRefreshWorker] Token bridge refrescado OK cuenta=#{credential.account_id} expira=#{credential.expires_at}"
    rescue RestClient::Exception => e
      Rails.logger.error "[TokenRefreshWorker] Yobot bridge error cuenta=#{credential.account_id}: #{e.response&.body || e.message}"
      credential.update_columns(updated_at: Time.current)
    rescue => e
      Rails.logger.error "[TokenRefreshWorker] Error bridge cuenta=#{credential.account_id}: #{e.message}"
      credential.update_columns(updated_at: Time.current)
    end

    def refresh_via_ml(credential)
      refresh_with_app(credential, ENV.fetch('ML_APP_ID'), ENV.fetch('ML_SECRET_KEY'), log_tag: 'nativo')
    end

    def refresh_via_ml_with_yobot_app(credential)
      refresh_with_app(credential, ENV.fetch('YOBOT_ML_APP_ID'), ENV.fetch('YOBOT_ML_SECRET_KEY'), log_tag: 'migrado (app Yobot)')
    end

    def refresh_with_app(credential, client_id, client_secret, log_tag:)
      Rails.logger.info "[TokenRefreshWorker] Refrescando (#{log_tag}) cuenta=#{credential.account_id} ml_user=#{credential.ml_user_id}"

      response = RestClient.post('https://api.mercadolibre.com/oauth/token', {
        grant_type: 'refresh_token',
        client_id: client_id,
        client_secret: client_secret,
        refresh_token: credential.refresh_token
      }, { content_type: :json, accept: :json })

      data = JSON.parse(response.body)

      credential.update_columns(
        access_token: data['access_token'],
        refresh_token: data['refresh_token'] || credential.refresh_token,
        expires_at: Time.current + data['expires_in'].seconds,
        status: 'active',
        updated_at: Time.current
      )

      Rails.logger.info "[TokenRefreshWorker] Token (#{log_tag}) refrescado OK cuenta=#{credential.account_id} expira=#{credential.expires_at}"
    rescue RestClient::Exception => e
      Rails.logger.error "[TokenRefreshWorker] ML (#{log_tag}) error cuenta=#{credential.account_id}: #{e.response&.body || e.message}"
      credential.update_columns(updated_at: Time.current)
    rescue => e
      Rails.logger.error "[TokenRefreshWorker] Error (#{log_tag}) cuenta=#{credential.account_id}: #{e.message}"
      credential.update_columns(updated_at: Time.current)
    end
  end
end