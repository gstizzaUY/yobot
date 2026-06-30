module ReplyAi
  class DocumentProcessorWorker
    include Sidekiq::Worker
    sidekiq_options queue: 'default'

    def perform(doc_id)
      doc = ReplyAiDocument.find(doc_id)
      return unless doc.file.attached?

      # 1. Extraer texto del archivo
      raw_bytes = doc.file.download
      content_type = doc.file.blob.content_type.to_s

      text = if content_type.start_with?('text/plain')
               # Para .txt: saltear Tika — si Tika autodetecta encoding (ej: GBK vs UTF-8)
               # puede corromper tildes/eñes. Decodificamos los bytes directamente.
               candidate = raw_bytes.dup.force_encoding('UTF-8')
               if candidate.valid_encoding?
                 candidate
               else
                 raw_bytes.encode('UTF-8', 'Windows-1252', invalid: :replace, undef: :replace, replace: '')
               end
             else
               # Para PDF, DOCX, etc.: usar Tika
               tika_base = ENV.fetch('TIKA_URL', 'http://localhost:9998')
               uri = URI.parse("#{tika_base}/tika")
               request = Net::HTTP::Put.new(uri)
               request['Accept']       = 'text/plain; charset=utf-8'
               request['Content-Type'] = content_type
               request.body = raw_bytes
               response = Net::HTTP.start(uri.host, uri.port) { |h| h.request(request) }
               tika_raw = response.body
               tika_text = tika_raw.dup.force_encoding('UTF-8')
               unless tika_text.valid_encoding?
                 tika_text = tika_raw.encode('UTF-8', 'Windows-1252', invalid: :replace, undef: :replace, replace: '')
               end
               tika_text
             end
      text = text.strip

      # 2. Guardar texto y avisar a n8n
      doc.update_columns(content: text)
      
      # Webhook de n8n para generar el vector
      RestClient.post(ENV['N8N_EMBEDDING_WEBHOOK_URL'], { doc_id: doc.id }.to_json, {content_type: :json}) rescue nil
    end
  end
end