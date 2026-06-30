class CreateMeliOrders < ActiveRecord::Migration[7.0]
  def change
    create_table :meli_orders do |t|
      t.references :account,      null: false, foreign_key: true
      t.string  :ml_order_id,     null: false
      t.string  :ml_buyer_id
      t.string  :item_id
      t.string  :pack_id
      t.string  :order_status                   # paid, confirmed, cancelled, etc.
      t.string  :shipping_mode                  # me1, me2, fulfillment, other

      # Mensaje post-venta
      t.boolean :message_sent,    null: false, default: false
      t.datetime :message_sent_at
      t.text    :message_error                  # error si falló el envío

      # Conversión / efectividad IA (para uso futuro)
      t.boolean :had_questions,   null: false, default: false
      t.boolean :ai_answered,     null: false, default: false
      t.integer :questions_count, null: false, default: 0
      t.datetime :conversion_checked_at

      t.timestamps
    end

    add_index :meli_orders, [:account_id, :ml_order_id], unique: true
    add_index :meli_orders, [:account_id, :message_sent]
    add_index :meli_orders, [:account_id, :created_at]
  end
end
