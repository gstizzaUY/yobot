module ReplyAi
  # Sincroniza el estado de lectura de una conversación post-venta con MercadoLibre:
  # - `mark_as_read: true` → el GET del pack marca los mensajes del comprador como leídos
  #   en ML (el comprador ve "Visto"; se limpian los "pendientes de leer" del seller).
  # - Para cada mensaje del vendedor con `message_date.read` presente → PATCH del mensaje
  #   de Chatwoot correspondiente (match por `content_attributes.ml_message_id`) a `read`
  #   (la burbuja pasa a ✓✓ azul; broadcast websocket vía `Message#after_update_commit`).
  # Rama nativa (MeliApi → ML directo) / bridge (BridgeApi → Yobot get-pack-messages).
  class MessageReadSync
    def self.perform(account, conversation, mark_as_read:)
      new(account, conversation, mark_as_read: mark_as_read).perform
    end

    def initialize(account, conversation, mark_as_read:)
      @account = account
      @conversation = conversation
      @mark_as_read = mark_as_read
    end

    def perform
      pack_id = @conversation.additional_attributes&.dig('pack_id')
      return { updated: 0, error: 'no_pack_id' } if pack_id.blank?

      api = MeliApi.for(@account)
      { updated: mark_read_messages(api, pack_messages(api, pack_id)) }
    rescue ReplyAi::MeliApi::Error => e
      Rails.logger.error "[MessageReadSync] pack=#{pack_id} error: #{e.class} #{e.message}"
      { updated: 0, error: e.message }
    end

    private

    def pack_messages(api, pack_id)
      response = api.pack_messages(pack_id, mark_as_read: @mark_as_read)
      response.is_a?(Hash) ? (response['messages'] || response[:messages] || []) : []
    end

    def mark_read_messages(api, messages)
      seller_id = String(api.ml_user_id)
      # content_attributes está doble-encodificado en BD (json con string JSON) → se usa el
      # accessor de Rails (parsea el hash) en vez del operador SQL `->>`.
      by_ml_id = @conversation.messages
                              .where(message_type: :outgoing, private: false)
                              .where.not(status: :read)
                              .to_a
                              .filter_map do |m|
                                ml_id = (m.content_attributes || {})['ml_message_id']
                                ml_id.present? ? [ml_id.to_s, m] : nil
                              end
                              .to_h
      updated = 0

      messages.each do |m|
        next unless String(m.dig('from', 'user_id')) == seller_id
        next if m.dig('message_date', 'read').blank?

        msg = by_ml_id[m['id'].to_s]
        next unless msg

        msg.update!(status: :read)
        updated += 1
      end
      updated
    end
  end
end
