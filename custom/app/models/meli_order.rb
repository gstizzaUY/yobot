class MeliOrder < ApplicationRecord
  belongs_to :account

  validates :ml_order_id, presence: true, uniqueness: { scope: :account_id }

  scope :for_account,     ->(account_id) { where(account_id: account_id) }
  scope :message_pending, -> { where(message_sent: false) }
  scope :with_questions,  -> { where(had_questions: true) }
end
