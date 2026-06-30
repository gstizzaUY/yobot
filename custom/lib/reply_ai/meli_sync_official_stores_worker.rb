module ReplyAi
  class MeliSyncOfficialStoresWorker
    include Sidekiq::Worker
    sidekiq_options queue: 'default', retry: 3

    def perform(account_id)
      credential = MeliCredential.find_by(account_id: account_id, status: 'active')
      return unless credential

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
      stores_data = JSON.parse(stores_res.body)

      stores_data.each do |store|
        MeliOfficialStore.find_or_initialize_by(
          account_id:    account_id,
          meli_store_id: store['id'].to_s
        ).tap do |s|
          s.name   = store['name']
          s.status = store['status'] || 'active'
          s.logo   = store['logo']
          s.save!
        end
      end

      Rails.logger.info "[MeliSyncOfficialStores] account=#{account_id} synced=#{stores_data.size} stores"
    rescue RestClient::Exception => e
      Rails.logger.error "[MeliSyncOfficialStores] account=#{account_id} error=#{e.message}"
    end
  end
end
