class AddChunkingToRagDocuments < ActiveRecord::Migration[7.1]
  def change
    [:reply_ai_documents, :reply_ai_pv_documents].each do |table|
      add_column table, :source_doc_id, :bigint
      add_column table, :chunk_index, :integer
      add_index table, :source_doc_id
    end
  end
end
