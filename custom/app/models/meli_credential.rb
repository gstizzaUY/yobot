class MeliCredential < ApplicationRecord
  belongs_to :account

  validates :ml_user_id, presence: true, uniqueness: true
  validates :access_token, presence: true
  validates :status, inclusion: { in: %w[pending active error bridge] }

  scope :bridge_enabled, -> { where(bridge_enabled: true, status: 'bridge') }

  # Cuentas gestionadas por Yobot (bridge puro o migradas): su configuración se
  # sincroniza desde Yobot (BridgeConfigSyncWorker / botón del dashboard).
  scope :yobot_managed, -> { where(status: %w[active bridge]).where('bridge_enabled = true OR status = ?', 'bridge') }

  # Usuarios de Yobot: Reply NO puede llamar a la API de ML directamente.
  # Todo el tráfico ML se gestiona a través de Yobot (bridge).
  def bridge?
    status == 'bridge'
  end

end