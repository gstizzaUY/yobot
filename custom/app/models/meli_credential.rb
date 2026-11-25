class MeliCredential < ApplicationRecord
  belongs_to :account

  validates :ml_user_id, presence: true, uniqueness: true
  validates :access_token, presence: true
  validates :status, inclusion: { in: %w[pending active error bridge inactive] }

  scope :bridge_enabled, -> { where(bridge_enabled: true, status: 'bridge') }

  # Cuentas gestionadas por Yobot (bridge puro o migradas): su configuración se
  # sincroniza desde Yobot (BridgeConfigSyncWorker / botón del dashboard).
  scope :yobot_managed, -> { where(status: %w[active bridge]).where('bridge_enabled = true OR status = ?', 'bridge') }

  # Bridge puro: Reply NO llama a la API de ML directamente; todo el tráfico va por Yobot.
  # Migrado: Reply llama directo a ML con el token emitido por la app de Yobot.
  def bridge?
    status == 'bridge'
  end

end