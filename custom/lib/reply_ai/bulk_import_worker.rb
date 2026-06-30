module ReplyAi
  class BulkImportWorker
    include Sidekiq::Worker
    sidekiq_options queue: 'default'

    # Parámetros:
    #   account_id    – ID de la cuenta
    #   file_path     – ruta absoluta al archivo temporal (CSV o XLSX)
    #   item_id_col   – nombre de la columna que contiene el item_id de MercadoLibre
    #   content_cols  – array de nombres de columnas que forman el contenido del documento
    #   mode          – 'pre' (reply_ai_documents) o 'pv' (reply_ai_pv_documents)
    def perform(account_id, file_path, item_id_col, content_cols, mode)
      account = Account.find_by(id: account_id)
      return Rails.logger.warn("BulkImportWorker: account #{account_id} no encontrada") unless account
      return Rails.logger.warn("BulkImportWorker: archivo no encontrado #{file_path}") unless File.exist?(file_path.to_s)

      model_class = mode == 'pv' ? ReplyAiPvDocument : ReplyAiDocument
      webhook_url = if mode == 'pv'
                      ENV.fetch('N8N_PV_EMBEDDING_WEBHOOK_URL', ENV['N8N_EMBEDDING_WEBHOOK_URL'])
                    else
                      ENV['N8N_EMBEDDING_WEBHOOK_URL']
                    end

      rows = parse_file(file_path)
      imported = 0
      skipped  = 0

      rows.each do |row|
        item_id = row[item_id_col].to_s.strip
        if item_id.blank?
          skipped += 1
          next
        end

        # Armar el contenido concatenando las columnas seleccionadas como "col: valor"
        content = content_cols.filter_map do |col|
          val = row[col].to_s.strip
          "#{col}: #{val}" unless val.blank?
        end.join("\n")

        if content.blank?
          skipped += 1
          next
        end

        doc = model_class.create!(
          account:      account,
          level:        'product',
          reference_id: item_id,
          file_name:    File.basename(file_path),
          content:      content,
          source:       'bulk_import'
        )

        if mode == 'pv'
          RestClient.post(webhook_url, { doc_id: doc.id, doc_type: 'pv' }.to_json, { content_type: :json }) rescue nil
        else
          RestClient.post(webhook_url, { doc_id: doc.id }.to_json, { content_type: :json }) rescue nil
        end

        imported += 1
      end

      Rails.logger.info "BulkImportWorker: cuenta=#{account_id} mode=#{mode} importados=#{imported} omitidos=#{skipped}"
    ensure
      File.delete(file_path) if file_path.present? && File.exist?(file_path.to_s)
    end

    private

    def parse_file(path)
      ext = File.extname(path).downcase

      if ext == '.csv'
        require 'csv'
        sample    = File.binread(path, 4096)
        encoding  = sample.dup.force_encoding('UTF-8').valid_encoding? ? 'BOM|UTF-8' : 'Windows-1252:UTF-8'
        first_line = sample.encode('UTF-8', 'Windows-1252', invalid: :replace, undef: :replace).lines.first.to_s
        col_sep   = first_line.count(';') >= first_line.count(',') ? ';' : ','
        CSV.read(path, headers: true, encoding: encoding, col_sep: col_sep).map(&:to_h)
      else
        require 'roo'
        xlsx  = Roo::Spreadsheet.open(path, extension: ext.delete('.').to_sym)
        sheet = xlsx.sheet(0)
        return [] if sheet.last_row.nil? || sheet.last_row < 2

        headers = sheet.row(1).map { |h| h.to_s.strip }
        (2..sheet.last_row).map do |i|
          headers.zip(sheet.row(i).map { |v| v.to_s }).to_h
        end
      end
    end
  end
end
