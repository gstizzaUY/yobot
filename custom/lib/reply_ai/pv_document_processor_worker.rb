module ReplyAi
  class PvDocumentProcessorWorker
    include Sidekiq::Worker
    sidekiq_options queue: 'default'

    def perform(doc_id)
      doc = ReplyAiPvDocument.find(doc_id)
      return unless doc.file.attached?

      raw_bytes    = doc.file.download
      content_type = doc.file.blob.content_type.to_s

      text = if content_type.start_with?('text/plain')
               candidate = raw_bytes.dup.force_encoding('UTF-8')
               candidate.valid_encoding? ? candidate : raw_bytes.encode('UTF-8', 'Windows-1252', invalid: :replace, undef: :replace, replace: '')
             else
               tika_base = ENV.fetch('TIKA_URL', 'http://localhost:9998')
               uri       = URI.parse("#{tika_base}/tika")
               request   = Net::HTTP::Put.new(uri)
               request['Accept']       = 'text/plain; charset=utf-8'
               request['Content-Type'] = content_type
               request.body            = raw_bytes
               response   = Net::HTTP.start(uri.host, uri.port) { |h| h.request(request) }
               tika_raw   = response.body
               tika_text  = tika_raw.dup.force_encoding('UTF-8')
               tika_text.valid_encoding? ? tika_text : tika_raw.encode('UTF-8', 'Windows-1252', invalid: :replace, undef: :replace, replace: '')
             end

      text = text.strip
      doc.update_columns(content: text)

      webhook_url = ENV.fetch('N8N_PV_EMBEDDING_WEBHOOK_URL', ENV['N8N_EMBEDDING_WEBHOOK_URL'])
      ReplyAiPvDocument.where(source_doc_id: doc.id).delete_all
      chunks = ReplyAi::TextChunker.chunks(text)
      chunks.each_with_index do |chunk, index|
        row = ReplyAiPvDocument.create!(
          account_id: doc.account_id,
          level: doc.level,
          reference_id: doc.reference_id,
          file_name: "#{doc.file_name} [#{index + 1}/#{chunks.size}]",
          content: chunk,
          source: doc.source,
          source_doc_id: doc.id,
          chunk_index: index
        )
        RestClient.post(webhook_url, { doc_id: row.id, doc_type: 'pv' }.to_json, { content_type: :json }) rescue nil
      end
    end
  end
end
