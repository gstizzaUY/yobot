class CreateMeliClaims < ActiveRecord::Migration[7.0]
  def change
    create_table :meli_claims do |t|
      t.references :account, null: false, foreign_key: true
      t.bigint  :claim_id, null: false
      t.string  :resource              # order, shipment, payment
      t.bigint  :resource_id
      t.string  :claim_type            # mediations, return, fulfillment, etc.
      t.string  :stage                 # claim, dispute
      t.string  :status                # opened, closed
      t.string  :reason_id
      t.jsonb   :players, default: []
      t.jsonb   :expected_resolutions, default: []
      t.boolean :affects_reputation, default: false
      t.bigint  :sale_id               # FK a meli_orders
      t.string  :pending_action        # acción del agente que requiere confirmación (modo supervisado)
      t.string  :agent_status, default: 'idle' # idle|running|pending|done|escalate|error|cancelled
      t.jsonb   :agent_log, default: []
      t.jsonb   :raw_data, default: {}
      t.timestamps
    end

    add_index :meli_claims, [:account_id, :claim_id], unique: true
    add_index :meli_claims, [:account_id, :status]
  end
end
