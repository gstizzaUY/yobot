class CreateReplyAiRagSystem < ActiveRecord::Migration[7.0]
  def change
    # Habilitar extensión pgvector (debe estar instalada en Postgres)
    enable_extension 'vector'

    # 1. Catálogo Espejo
    create_table :meli_products do |t|
      t.references :account, null: false
      t.string :meli_item_id, null: false
      t.string :title
      t.string :thumbnail
      t.string :status
      t.string :category_id
      t.timestamps
    end
    add_index :meli_products, [:account_id, :meli_item_id], unique: true

    # 2. Jerarquía de Categorías de ML
    create_table :meli_categories do |t|
      t.references :account, null: false
      t.string :meli_category_id, null: false
      t.string :name
      t.string :parent_id
      t.string :level # master o sub
      t.timestamps
    end

    # 3. Documentos RAG (Base de Conocimiento)
    create_table :reply_ai_documents do |t|
      t.references :account, null: false
      t.string :level # global, category, sub_category, product
      t.string :reference_id # meli_item_id o meli_category_id o 'global'
      t.string :file_name
      t.text :content # Texto extraído por Tika
      t.timestamps
    end

    # Columna vector separada: requiere que pgvector esté habilitado
    execute 'ALTER TABLE reply_ai_documents ADD COLUMN embedding vector(1536)'
  end
end