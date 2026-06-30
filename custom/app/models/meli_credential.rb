class MeliCredential < ApplicationRecord
  belongs_to :account

  validates :ml_user_id, presence: true, uniqueness: true
  validates :access_token, presence: true
  validates :status, inclusion: { in: %w[pending active error] }
end