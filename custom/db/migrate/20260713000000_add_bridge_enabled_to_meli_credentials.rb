class AddBridgeEnabledToMeliCredentials < ActiveRecord::Migration[7.0]
  def change
    add_column :meli_credentials, :bridge_enabled, :boolean, default: false, null: false
  end
end
