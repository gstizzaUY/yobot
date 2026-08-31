module ReplyAi
  # Sincroniza la configuración del bridge desde Yobot: llama a
  # POST {YOBOT_BRIDGE_URL}/api/bridge/sync-config (HMAC), mapea con BridgeConfigMapper
  # y persiste en Account.custom_attributes + meli_official_stores.custom_greeting.
  # Fuente de verdad: Reply en FULL (1-way Yobot → Reply al bridgear).
  class BridgeConfigSyncWorker
    include Sidekiq::Worker
    sidekiq_options queue: 'default', retry: 2

    def perform(account_id)
      account = Account.find_by(id: account_id)
      return unless account

      credential = account.meli_credentials.where(status: 'bridge').order(:id).first
      return unless credential

      base   = ENV.fetch('YOBOT_BRIDGE_URL', nil)
      secret = ENV.fetch('BRIDGE_SECRET', nil)
      raise 'BridgeConfigSync: YOBOT_BRIDGE_URL/BRIDGE_SECRET no configurados en Reply-AI' if base.blank? || secret.blank?

      body      = { ml_user_id: credential.ml_user_id }
      raw       = body.to_json
      signature = OpenSSL::HMAC.hexdigest('SHA256', secret, raw)
      res = RestClient.post("#{base}/api/bridge/sync-config", raw,
                            { 'Content-Type' => 'application/json',
                              'Authorization' => "Bearer #{secret}",
                              'X-Bridge-Signature' => signature,
                              accept: :json })
      data = JSON.parse(res.body)
      mapped = BridgeConfigMapper.map(data['config'])

      attrs = (account.custom_attributes || {}).deep_dup
      attrs['config'] = mapped[:custom_attributes]['config']
      account.update_columns(custom_attributes: attrs)

      mapped[:stores].each do |store|
        MeliOfficialStore.find_or_initialize_by(account_id: account.id, meli_store_id: store['official_store_id']).tap do |s|
          s.name = store['name'] if store['name'].present?
          s.custom_greeting = store['custom_greeting']
          s.save!
        end
      end

      Rails.logger.info "[BridgeConfigSync] account=#{account.id} config mapeada (sync_at=#{data['sync_at']})"
      { ok: true, account_id: account.id, stores: mapped[:stores].size }
    rescue RestClient::ExceptionWithResponse => e
      Rails.logger.error "[BridgeConfigSync] account=#{account_id} error #{e.response.code}: #{e.response.body.to_s[0, 250]}"
      raise
    rescue RestClient::Exception => e
      Rails.logger.error "[BridgeConfigSync] account=#{account_id} bridge inaccesible: #{e.message}"
      raise
    end
  end
end
