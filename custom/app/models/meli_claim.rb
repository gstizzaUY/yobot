class MeliClaim < ApplicationRecord
  belongs_to :account

  validates :claim_id, presence: true, uniqueness: { scope: :account_id }

  scope :for_account, ->(account_id) { where(account_id: account_id) }
  scope :activos,     -> { where(status: 'opened') }
  scope :pendientes,  -> { where.not(pending_action: nil) }

  def activo?
    status == 'opened'
  end

  def dispute?
    stage == 'dispute'
  end

  def orden
    MeliOrder.find_by(id: sale_id)
  end

  # Timeline de eventos (histórico del reclamo en el panel). Cada entrada:
  # { at: Time.current.iso8601, tipo: 'sync'|'webhook'|'manual', evento: <descripción> }.
  # Se guarda siempre que el último evento difiera del anterior (evita duplicados en syncs).
  def registrar_evento_timeline!(tipo, evento)
    entries = timeline || []
    unless entries.last && entries.last['evento'] == evento
      entries << { at: Time.current.iso8601, tipo: tipo, evento: evento }
      update_column(:timeline, entries.last(50))
    end
    entries.last(50)
  end
end
