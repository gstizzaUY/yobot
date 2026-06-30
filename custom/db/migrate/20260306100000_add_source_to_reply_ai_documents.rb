class AddSourceToReplyAiDocuments < ActiveRecord::Migration[7.0]
  def change
    add_column :reply_ai_documents,    :source, :string, default: 'manual', null: false
    add_column :reply_ai_pv_documents, :source, :string, default: 'manual', null: false
  end
end
