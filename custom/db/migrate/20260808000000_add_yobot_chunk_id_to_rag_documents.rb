class AddYobotChunkIdToRagDocuments < ActiveRecord::Migration[7.1]
  def change
    add_column :reply_ai_documents, :yobot_chunk_id, :string
    add_column :reply_ai_pv_documents, :yobot_chunk_id, :string
    add_index :reply_ai_documents, [:account_id, :yobot_chunk_id], unique: true, name: 'idx_rag_docs_account_yobot_chunk'
    add_index :reply_ai_pv_documents, [:account_id, :yobot_chunk_id], unique: true, name: 'idx_rag_pv_docs_account_yobot_chunk'
  end
end
