module ReplyAi
  # Dispara la sincronización de reclamos de todas las cuentas con credencial activa/bridge.
  # Respaldo del webhook de ML (topics claims/claims_actions): si una notificación se pierde,
  # el cron mantiene al día meli_claims. El upsert es idempotente (por claim_id).
  class ClaimsSyncAllWorker
    include Sidekiq::Worker
    sidekiq_options queue: 'low', retry: 1

    def perform
      account_ids = MeliCredential.where(status: %w[active bridge]).distinct.pluck(:account_id)
      account_ids.each { |account_id| ClaimsSyncWorker.perform_async(account_id) }
    end
  end
end
