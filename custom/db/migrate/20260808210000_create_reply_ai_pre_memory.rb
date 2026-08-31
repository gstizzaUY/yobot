class CreateReplyAiPreMemory < ActiveRecord::Migration[7.1]
  def change
    # Idempotente: en dev la tabla ya existía (creada a mano); en producción se crea.
    # La usa n8n (questions_main) como memoria de sesión de pre-venta.
    create_table :reply_ai_pre_memory, id: :serial, if_not_exists: true do |t|
      t.string :session_id, limit: 255, null: false
      t.jsonb :message, null: false
    end
  end
end
