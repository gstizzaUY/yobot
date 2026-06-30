class MeliOfficialStore < ApplicationRecord
  belongs_to :account

  validates :meli_store_id, presence: true, uniqueness: { scope: :account_id }
  validates :name, presence: true

  scope :for_account, ->(account_id) { where(account_id: account_id).order(:name) }
end
