class MeliProduct < ApplicationRecord
  belongs_to :account
  def active?
    status == 'active'
  end
end