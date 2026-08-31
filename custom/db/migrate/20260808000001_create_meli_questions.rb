class CreateMeliQuestions < ActiveRecord::Migration[7.1]
  def change
    # Idempotente: en dev la tabla ya existía (creada a mano); en producción se crea.
    # No incluye las columnas de retención — las agrega 20260808000002_add_retention_to_meli_questions.
    create_table :meli_questions, primary_key: :question_id, id: :text, if_not_exists: true do |t|
      t.integer :account_id, null: false
      t.integer :cw_conversation_id
      t.string :status, limit: 50, default: 'pending'
      t.timestamptz :created_at, default: -> { 'CURRENT_TIMESTAMP' }
    end
  end
end
