class AddRetentionToMeliQuestions < ActiveRecord::Migration[7.1]
  def change
    add_column :meli_questions, :retained_due_lack_of_info, :boolean, default: false
    add_column :meli_questions, :suggested_answer, :text
  end
end
