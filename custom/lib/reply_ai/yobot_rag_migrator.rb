module ReplyAi
  # Migra los documentos RAG de un usuario MIGRADO desde Supabase (Yobot) a Postgres (Reply).
  # - Lee los chunks de la tabla `{ml_user_id}` (pre-venta) o `pv_{ml_user_id}` (post-venta)
  #   de Supabase vía REST (`SUPABASE_URL` + `SUPABASE_SERVICE_KEY`), paginado.
  # - Inserta 1 fila por chunk en `reply_ai_documents` / `reply_ai_pv_documents` mapeando
  #   level/reference_id: global → `global`/'global', category → `category`/category_id,
  #   product → `product`/item_id. El nivel `sub` de Reply queda vacío (solo Reply lo llena).
  # - Regenera los embeddings con `text-embedding-ada-002` vía el webhook n8n existente
  #   (`N8N_EMBEDDING_WEBHOOK_URL` pre / `N8N_PV_EMBEDDING_WEBHOOK_URL` post, `{doc_id}` /
  #   `{doc_id, doc_type: 'pv'}`) — los vectores de Yobot son `text-embedding-3-small`,
  #   no reutilizables.
  # Idempotente por `yobot_chunk_id` (re-runs no duplican y re-emiten embeddings faltantes);
  # throttling leve porque el webhook n8n responde onReceived (async).
  class YobotRagMigrator
    include Sidekiq::Worker
    sidekiq_options queue: 'low', retry: 1

    class SupabaseTableNotFound < StandardError; end

    PAGE_SIZE = 500
    EMBED_THROTTLE = 0.2 # segundos entre envíos al webhook de embeddings

    def perform(account_id, ambito)
      account = Account.find_by(id: account_id)
      return Rails.logger.warn "[YobotRagMigrator] cuenta #{account_id} no encontrada" unless account

      credential = account.meli_credentials.where(status: 'active').order(:id).first
      return Rails.logger.warn "[YobotRagMigrator] cuenta #{account_id}: sin credencial activa" unless credential

      ml_user_id = credential.ml_user_id
      table = ambito == 'post' ? "pv_#{ml_user_id}" : ml_user_id.to_s
      set_syncing(account, ambito, true)

      total = 0
      processed = 0
      errors = []
      offset = 0

      loop do
        chunks = fetch_chunks(table, offset)
        break if chunks.blank?

        chunks.each do |chunk|
          total += 1
          begin
            row = upsert_chunk(account, ambito, chunk)
            if row
              enqueue_embedding(row, ambito)
              processed += 1
            end
          rescue => e
            errors << "chunk=#{chunk['id']} #{e.class}: #{e.message}"
          end
        end

        offset += PAGE_SIZE
        break if chunks.size < PAGE_SIZE
      end

      Rails.logger.info "[YobotRagMigrator] cuenta=#{account_id} ambito=#{ambito} tabla=#{table} total=#{total} procesados=#{processed} errores=#{errors.size}"
      Rails.logger.error "[YobotRagMigrator] cuenta=#{account_id} errores: #{errors.first(10).join(' | ')}" if errors.any?
    rescue SupabaseTableNotFound => e
      Rails.logger.info "[YobotRagMigrator] cuenta=#{account_id} ambito=#{ambito}: sin documentos (#{e.message})"
    rescue StandardError => e
      Rails.logger.error "[YobotRagMigrator] cuenta=#{account_id} error global: #{e.class}: #{e.message}"
    ensure
      set_syncing(account, ambito, false) if account
    end

    private

    def fetch_chunks(table, offset)
      uri = URI("#{ENV.fetch('SUPABASE_URL')}/rest/v1/#{table}")
      uri.query = URI.encode_www_form(select: 'id,content,metadata', limit: PAGE_SIZE, offset: offset)
      req = Net::HTTP::Get.new(uri)
      req['apikey'] = ENV.fetch('SUPABASE_SERVICE_KEY')
      req['Authorization'] = "Bearer #{ENV.fetch('SUPABASE_SERVICE_KEY')}"
      req['Accept-Encoding'] = 'identity'
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 30) { |http| http.request(req) }

      # Supabase puede responder gzip aunque se pida identity → descomprimir si aplica.
      body = res.body.to_s
      body = Zlib::GzipReader.new(StringIO.new(body)).read if res['content-encoding'].to_s.include?('gzip')

      raise SupabaseTableNotFound, "tabla #{table} no existe" if res.code.to_i == 404
      raise "Supabase #{res.code}: #{body[0, 200]}" unless res.is_a?(Net::HTTPSuccess)

      JSON.parse(body)
    end

    def upsert_chunk(account, ambito, chunk)
      metadata = chunk['metadata'] || {}
      mapping = map_level(metadata)
      return nil if mapping.nil?

      model = ambito == 'post' ? ReplyAiPvDocument : ReplyAiDocument
      row = model.find_or_initialize_by(account_id: account.id, yobot_chunk_id: chunk['id'].to_s)

      if row.new_record?
        row.assign_attributes(
          level: mapping[:level],
          reference_id: mapping[:reference_id],
          file_name: metadata['item_name'].presence || "doc_#{chunk['id']}",
          content: chunk['content'].to_s,
          source: 'yobot'
        )
        row.save!
      elsif row.embedding.present?
        # ya importado con embedding → no reprocesar
        return nil
      end

      row
    end

    # Mapeo de niveles de Yobot → Reply. `sub` y desconocidos → nil (se saltean).
    def map_level(metadata)
      case metadata['level'].to_s
      when 'global'
        { level: 'global', reference_id: 'global' }
      when 'category'
        return nil if metadata['category_id'].blank?

        { level: 'category', reference_id: metadata['category_id'].to_s }
      when 'product'
        return nil if metadata['item_id'].blank?

        { level: 'product', reference_id: metadata['item_id'].to_s }
      end
    end

    def enqueue_embedding(row, ambito)
      webhook = if ambito == 'post'
                  ENV.fetch('N8N_PV_EMBEDDING_WEBHOOK_URL', ENV['N8N_EMBEDDING_WEBHOOK_URL'])
                else
                  ENV.fetch('N8N_EMBEDDING_WEBHOOK_URL')
                end
      payload = ambito == 'post' ? { doc_id: row.id, doc_type: 'pv' } : { doc_id: row.id }
      RestClient.post(webhook, payload.to_json, { content_type: :json }) rescue nil
      sleep EMBED_THROTTLE
    end

    def set_syncing(account, ambito, value)
      key = ambito == 'post' ? 'syncing_rag_post' : 'syncing_rag_pre'
      attrs = (account.custom_attributes || {}).deep_dup
      attrs[key] = value
      account.update_column(:custom_attributes, attrs)
    end
  end
end
