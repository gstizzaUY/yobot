class AddTimelineToMeliClaims < ActiveRecord::Migration[7.1]
  def change
    add_column :meli_claims, :timeline, :jsonb, default: [], null: false
  end
end
