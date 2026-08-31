class AddCwConversationIds < ActiveRecord::Migration[7.0]
  def change
    # Conversación de Chatwoot de la bandeja de reclamos (1 conversación = 1 reclamo, source_id = claim_id)
    add_column :meli_claims, :cw_conversation_id, :bigint

    # Conversación post-venta de Chatwoot vinculada (escrita por n8n get_or_create_conversation)
    add_column :meli_orders, :cw_conversation_id, :bigint
  end
end
