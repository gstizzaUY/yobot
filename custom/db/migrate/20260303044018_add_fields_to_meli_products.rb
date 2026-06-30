class AddFieldsToMeliProducts < ActiveRecord::Migration[7.1]
  def change
    # Campos escalares indexables/filtrables
    add_column :meli_products, :price,              :decimal, precision: 15, scale: 2
    add_column :meli_products, :base_price,         :decimal, precision: 15, scale: 2
    add_column :meli_products, :original_price,     :decimal, precision: 15, scale: 2
    add_column :meli_products, :currency_id,        :string
    add_column :meli_products, :available_quantity, :integer
    add_column :meli_products, :sold_quantity,      :integer
    add_column :meli_products, :condition,          :string       # "new" | "used" | "refurbished"
    add_column :meli_products, :listing_type_id,    :string       # "gold_special", "gold_pro", etc.
    add_column :meli_products, :buying_mode,        :string       # "buy_it_now" | "auction"
    add_column :meli_products, :permalink,          :string
    add_column :meli_products, :secure_thumbnail,   :string
    add_column :meli_products, :warranty,           :string
    add_column :meli_products, :domain_id,          :string
    add_column :meli_products, :catalog_product_id, :string
    add_column :meli_products, :health,             :decimal, precision: 5, scale: 4
    add_column :meli_products, :accepts_mercadopago,:boolean
    add_column :meli_products, :free_shipping,      :boolean
    add_column :meli_products, :meli_date_created,  :datetime
    add_column :meli_products, :meli_last_updated,  :datetime

    # Arrays/objetos como jsonb
    add_column :meli_products, :pictures,           :jsonb, default: []
    add_column :meli_products, :attributes_data,    :jsonb, default: []  # "attributes" es reservado en AR
    add_column :meli_products, :shipping_data,      :jsonb, default: {}
    add_column :meli_products, :tags,               :jsonb, default: []

    # Respuesta completa de ML por si se necesita cualquier otro campo en el futuro
    add_column :meli_products, :raw_data,           :jsonb, default: {}

    add_index :meli_products, :status
    add_index :meli_products, :condition
    add_index :meli_products, :price
  end
end
