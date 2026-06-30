class CreateMeliCredentials < ActiveRecord::Migration[7.0]
  def change
    create_table :meli_credentials do |t|
      t.references :account, null: false, foreign_key: true
      t.string :ml_user_id
      t.string :access_token
      t.string :refresh_token
      t.datetime :expires_at
      t.string :status, default: 'pending'

      t.timestamps
    end
    # Asegúrate de que el índice también use el nombre correcto de la tabla
    add_index :meli_credentials, :ml_user_id, unique: true
  end
end