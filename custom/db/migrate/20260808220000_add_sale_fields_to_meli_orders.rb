class AddSaleFieldsToMeliOrders < ActiveRecord::Migration[7.1]
  def change
    add_column :meli_orders, :item_title,      :string
    add_column :meli_orders, :buyer_nickname,  :string
    add_column :meli_orders, :total_amount,    :decimal, precision: 12, scale: 2
    add_column :meli_orders, :currency_id,     :string
    add_column :meli_orders, :quantity,        :integer
    add_column :meli_orders, :date_created,    :datetime
  end
end
