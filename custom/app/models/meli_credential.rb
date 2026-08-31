class MeliCredential < ApplicationRecord
  belongs_to :account

  validates :ml_user_id, presence: true, uniqueness: true
  validates :access_token, presence: true
  validates :status, inclusion: { in: %w[pending active error bridge] }

  scope :bridge_enabled, -> { where(bridge_enabled: true, status: 'bridge') }

  # Usuarios de Yobot: Reply NO puede llamar a la API de ML directamente.
  # Todo el tráfico ML se gestiona a través de Yobot (bridge).
  def bridge?
    status == 'bridge'
  end

end