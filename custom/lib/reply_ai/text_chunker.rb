module ReplyAi
  # Divide el texto extraído de un documento en chunks con solape para el RAG.
  # Cada chunk se guarda como una fila con embedding propio (mejor recuperación
  # que un único vector para el documento completo).
  class TextChunker
    CHUNK_SIZE = 1000
    OVERLAP    = 150

    def self.chunks(text)
      clean = text.to_s.gsub(/[ \t]+/, ' ').gsub(/\n{3,}/, "\n\n").strip
      return [] if clean.blank?
      return [clean] if clean.length <= CHUNK_SIZE

      result = []
      start = 0
      while start < clean.length
        result << clean[start, CHUNK_SIZE]
        break if start + CHUNK_SIZE >= clean.length

        start += CHUNK_SIZE - OVERLAP
      end
      result
    end
  end
end
