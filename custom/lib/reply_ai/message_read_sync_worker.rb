module ReplyAi
  # Sync periódico del estado de lectura de mensajes post-venta (cron cada 1 min, ver
  # config/schedule.yml `reply_ai_message_read_sync_job`): para cada cuenta con
  # credenciales y conversaciones post-venta abiertas con mensajes salientes sin `read`,
  # consulta el pack con `mark_as_read: false` (solo consulta, no marca nada en ML) y
  # PATCH a `read` los mensajes del vendedor cuyo `message_date.read` ya existe en ML
  # (burbuja ✓✓ azul). Rama nativa (MeliApi) / bridge (BridgeApi).
  # Cada 1 min (no 5) porque la API de ML tarda >30s en reflejar el `read` tras la
  # lectura del comprador — el sync por forward (nodo `sync_message_reads`) corre antes
  # y no lo ve; el worker es el que garantiza el tick azul en <=1 min.
  class MessageReadSyncWorker
    include Sidekiq::Worker
    sidekiq_options queue: 'low', retry: 1

    def perform
      accounts = Account.joins(:meli_credentials).distinct
      accounts.each { |account| process_account(account) }
    end

    private

    def process_account(account)
      # content_attributes está doble-encodificado en BD (json con string JSON) → el
      # accessor de Rails lo parsea; el filtro se hace en Ruby (el SQL `->>` no aplica).
      pending = Message.where(account_id: account.id, message_type: :outgoing, private: false)
                       .where.not(status: :read)
                       .where("content_attributes::text LIKE '%ml_message_id%'")
                       .select { |m| (m.content_attributes || {})['ml_message_id'].present? }
      conversation_ids = pending.map(&:conversation_id).uniq
      return if conversation_ids.blank?

      Conversation.where(id: conversation_ids, status: :open).find_each do |conversation|
        result = MessageReadSync.perform(account, conversation, mark_as_read: false)
        Rails.logger.info "[MessageReadSyncWorker] cuenta=#{account.id} pack=#{conversation.additional_attributes&.dig('pack_id')} resultado=#{result.inspect}"
      end
    end
  end
end
