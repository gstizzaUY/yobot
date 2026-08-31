module ReplyAi
  # Sincroniza los reclamos abiertos de un seller desde ML (claims/search + upsert).
  # Disparadores: signup/OAuth (meli_callback) y botón "Sincronizar" del dashboard.
  class ClaimsSyncWorker
    include Sidekiq::Worker
    sidekiq_options queue: 'low', retry: 1

    def perform(account_id)
      account = Account.find_by(id: account_id)
      return unless account

      credential = account.meli_credentials.where(status: %w[active bridge]).order(:id).first
      return unless credential

      api = MeliApi.for(account)
      result = api.search_claims(credential.ml_user_id)
      claims = result.is_a?(Array) ? result : (result['results'] || [])

      claims.each do |data|
        claim = upsert_claim(account, data)
        apply_order_link(account, claim)
      end
      Rails.logger.info "[ClaimsSyncWorker] #{account.id}: #{claims.size} reclamos sincronizados"
    rescue StandardError => e
      Rails.logger.error "[ClaimsSyncWorker] error: #{e.class} #{e.message}"
    end

    private

    def upsert_claim(account, data)
      attrs = ClaimMapper.map(data, account.id)
      claim = account.meli_claims.find_or_initialize_by(claim_id: attrs[:claim_id])
      claim.assign_attributes(attrs)
      was_new = claim.new_record?
      claim.save!
      claim.registrar_evento_timeline!('sync', was_new ? 'Reclamo detectado' : 'Sincronizado con MercadoLibre')
      claim
    end

    def apply_order_link(account, claim)
      order = MeliOrder.find_by(account_id: account.id, ml_order_id: claim.resource_id.to_s)
      claim.update!(sale_id: order.id) if order && claim.sale_id != order.id
      order.bloquear!('claim_dispute') if claim.dispute? && order
    end
  end
end
