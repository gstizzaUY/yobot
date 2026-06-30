class AddExtraFieldsToMeliProducts < ActiveRecord::Migration[7.1]
  def change
    # Precios con mayor precisión
    change_column :meli_products, :price, :decimal, precision: 15, scale: 2

    # Agrega columnas solo si no existen
    columns = ActiveRecord::Base.connection.columns(:meli_products).map(&:name)

    add_column :meli_products, :base_price,         :decimal, precision: 15, scale: 2 unless columns.include?("base_price")
    add_column :meli_products, :original_price,     :decimal, precision: 15, scale: 2 unless columns.include?("original_price")
    add_column :meli_products, :buying_mode,        :string unless columns.include?("buying_mode")
    add_column :meli_products, :secure_thumbnail,   :string unless columns.include?("secure_thumbnail")
    add_column :meli_products, :warranty,           :string unless columns.include?("warranty")
    add_column :meli_products, :domain_id,          :string unless columns.include?("domain_id")
    add_column :meli_products, :catalog_product_id, :string unless columns.include?("catalog_product_id")
    add_column :meli_products, :health,             :decimal, precision: 5, scale: 4 unless columns.include?("health")
    add_column :meli_products, :accepts_mercadopago, :boolean unless columns.include?("accepts_mercadopago")
    add_column :meli_products, :free_shipping,      :boolean unless columns.include?("free_shipping")
    add_column :meli_products, :pictures,           :jsonb, default: [] unless columns.include?("pictures")
    add_column :meli_products, :attributes_data,    :jsonb, default: [] unless columns.include?("attributes_data")
    add_column :meli_products, :shipping_data,      :jsonb, default: {} unless columns.include?("shipping_data")
    add_column :meli_products, :tags,               :jsonb, default: [] unless columns.include?("tags")

    # Índices útiles (solo si no existen)
    add_index :meli_products, :status unless index_exists?(:meli_products, :status)
    add_index :meli_products, :condition unless index_exists?(:meli_products, :condition)
    add_index :meli_products, :price unless index_exists?(:meli_products, :price)
  end
end
