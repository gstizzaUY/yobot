class AddConversationLifecycleToMeliOrders < ActiveRecord::Migration[7.0]
  def change
    add_column :meli_orders, :estado_conversacion, :string, null: false, default: 'activa' # activa|cerrada|needs_human|bloqueada
    add_column :meli_orders, :handoff_reason, :string
    add_column :meli_orders, :last_sentiment, :string # POSITIVO|NEUTRAL|INSATISFECHO|ENOJADO
    add_column :meli_orders, :consecutive_enojado, :integer, null: false, default: 0
    add_column :meli_orders, :repeat_count, :integer, null: false, default: 0
    add_column :meli_orders, :ultimos_mensajes_comprador, :jsonb, null: false, default: []
    add_column :meli_orders, :blocked_substatus, :string
    add_column :meli_orders, :last_message_at, :datetime

    add_index :meli_orders, [:account_id, :estado_conversacion]
  end
end
