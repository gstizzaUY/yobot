class CreateReplyAiPvDocuments < ActiveRecord::Migration[7.0]
  def change
    create_table :reply_ai_pv_documents do |t|
      t.references :account, null: false
      t.string :level        # global, category, sub, product
      t.string :reference_id # meli_item_id, meli_category_id o 'global'
      t.string :file_name
      t.text :content        # Texto extraído por Tika
      t.timestamps
    end

    execute 'ALTER TABLE reply_ai_pv_documents ADD COLUMN embedding vector(1536)'
  end
end
