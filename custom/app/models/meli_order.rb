class MeliOrder < ApplicationRecord
  belongs_to :account

  ESTADOS_CONVERSACION = %w[activa cerrada needs_human bloqueada].freeze
  SENTIMIENTOS = %w[POSITIVO NEUTRAL INSATISFECHO ENOJADO].freeze

  validates :ml_order_id, presence: true, uniqueness: { scope: :account_id }
  validates :estado_conversacion, inclusion: { in: ESTADOS_CONVERSACION }

  scope :for_account,     ->(account_id) { where(account_id: account_id) }
  scope :message_pending, -> { where(message_sent: false) }
  scope :with_questions,  -> { where(had_questions: true) }
  scope :activas,         -> { where(estado_conversacion: 'activa') }
  scope :needs_human,     -> { where(estado_conversacion: 'needs_human') }
  scope :bloqueadas,      -> { where(estado_conversacion: 'bloqueada') }
  scope :inactivas_desde, ->(hours) { activas.where('last_message_at < ?', hours.hours.ago) }

  def cerrar!
    update!(estado_conversacion: 'cerrada')
  end

  def reabrir!
    update!(estado_conversacion: 'activa', handoff_reason: nil, blocked_substatus: nil)
  end

  def derivar_a_humano!(razon)
    update!(estado_conversacion: 'needs_human', handoff_reason: razon)
  end

  def bloquear!(substatus)
    update!(estado_conversacion: 'bloqueada', blocked_substatus: substatus)
  end

  def actualizar_sentimiento!(sentimiento)
    consecutivo = sentimiento == 'ENOJADO' ? consecutive_enojado + 1 : 0
    update!(last_sentiment: sentimiento, consecutive_enojado: consecutivo)
  end

  def registrar_mensaje_comprador!(texto)
    ultimos = (ultimos_mensajes_comprador + [texto]).last(3)
    update!(ultimos_mensajes_comprador: ultimos, last_message_at: Time.current)
  end

  def registrar_loop!
    update!(repeat_count: repeat_count + 1)
  end
end
