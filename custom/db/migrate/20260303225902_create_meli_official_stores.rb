class CreateMeliOfficialStores < ActiveRecord::Migration[7.0]
  def change
    create_table :meli_official_stores do |t|
      t.references :account,       null: false, foreign_key: true
      t.string     :meli_store_id, null: false
      t.string     :name,          null: false
      t.string     :status                      # "active" | "inactive"
      t.string     :logo                        # URL logo de la tienda
      t.text       :custom_greeting             # nil → usa saludoGeneral como fallback

      t.timestamps
    end

    add_index :meli_official_stores, [:account_id, :meli_store_id], unique: true
  end
end
