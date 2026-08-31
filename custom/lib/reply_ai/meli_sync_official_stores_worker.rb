module ReplyAi
  class MeliSyncOfficialStoresWorker
    include Sidekiq::Worker
    sidekiq_options queue: 'default', retry: 3

    def perform(account_id)
      credential = MeliCredential.find_by(account_id: account_id, status: %w[active bridge])
      return unless credential

      stores_data = if credential.bridge?
                      data = ReplyAi::MeliApi.for(Account.find(account_id)).sync_official_stores
                      data.is_a?(Array) ? data : (data['stores'] || [])
                    else
                      fetch_stores_via_ml(credential)
                    end

      persist_stores(account_id, stores_data)
      Rails.logger.info "[MeliSyncOfficialStores] account=#{account_id} synced=#{stores_data.size} stores"
    rescue RestClient::Exception => e
      Rails.logger.error "[MeliSyncOfficialStores] account=#{account_id} error=#{e.message}"
    rescue ReplyAi::MeliApi::Error => e
      Rails.logger.error "[MeliSyncOfficialStores] account=#{account_id} error=#{e.message}"
    end

    private

    def fetch_stores_via_ml(credential)
      token = credential.access_token

      # Obtener el user_id del vendedor autenticado
      me_res  = RestClient.get('https://api.mercadolibre.com/users/me',
                               { Authorization: "Bearer #{token}" })
      me_data = JSON.parse(me_res.body)
      user_id = me_data['id']

      # Buscar todas las tiendas oficiales del vendedor
      stores_res  = RestClient.get(
        "https://api.mercadolibre.com/users/#{user_id}/official_stores",
        { Authorization: "Bearer #{token}" }
      )
      JSON.parse(stores_res.body)
    end

    def persist_stores(account_id, stores_data)
      stores_data.each do |store|
        MeliOfficialStore.find_or_initialize_by(
          account_id:    account_id,
          meli_store_id: (store['official_store_id'] || store['id']).to_s
        ).tap do |s|
          s.name   = store['name'] || store['normalized_name']
          s.status = store['status'] || 'active'
          s.logo   = store['logo']
          s.save!
        end
      end
    end
  end
end
