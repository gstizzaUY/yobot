class ReplyAiDocument < ApplicationRecord
  belongs_to :account
  has_one_attached :file # Chatwoot ya tiene ActiveStorage configurado
  has_neighbors :embedding

  # Niveles de jerarquía: global > category > sub > product
  LEVELS = %w[global category sub product].freeze

  # Busca los top-N documentos más relevantes para una query, filtrando por cuenta.
  # Prioriza resultados más específicos (product > sub > category > global).
  # reference_ids: array de IDs a incluir en el filtro (producto, sub, categoría, 'global')
  def self.search_for(account_id:, embedding:, reference_ids: [], limit: 5)
    scope = where(account_id: account_id).where.not(embedding: nil)
    scope = scope.where(reference_id: reference_ids.map(&:to_s)) if reference_ids.any?
    scope.nearest_neighbors(:embedding, embedding, distance: 'cosine').limit(limit)
  end
end