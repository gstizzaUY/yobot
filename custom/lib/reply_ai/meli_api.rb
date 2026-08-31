module ReplyAi
  # Cliente de la API de MercadoLibre para reclamos, devoluciones y cambios.
  # Contratos verificados contra Yobot (claimsController.js, returnsController.js,
  # changesController.js, handleIncomingClaim.js). Claims API en /post-purchase/.
  class MeliApi
    BASE = 'https://api.mercadolibre.com'.freeze

    class Error < StandardError
      attr_reader :status, :code

      def initialize(status, code, message)
        @status = status
        @code = code
        super(message)
      end
    end

    def initialize(account)
      @account = account
      @credential = account.meli_credentials.where(status: %w[active bridge]).order(:id).first
    end

    # Factory: cuentas con credencial primaria `bridge` usan BridgeApi (todo el tráfico ML
    # vía Yobot); las demás (nativas y MIGRADAS — `status: 'active'` + `bridge_enabled`)
    # usan MeliApi (ML directo con el token del seller, emitido por la app de Yobot).
    def self.for(account)
      credential = account.meli_credentials.where(status: %w[active bridge]).order(:id).first
      credential&.status == 'bridge' ? BridgeApi.new(account) : new(account)
    end

    def token
      @credential&.access_token
    end

    def ml_user_id
      @credential&.ml_user_id
    end

    # ==== Mensajes post-venta (estado de lectura: ticks delivered/read) ====
    # El GET del pack marca los mensajes del comprador como leídos por defecto en ML;
    # `mark_as_read: false` solo consulta (sync de lectura del vendedor).
    def pack_messages(pack_id, mark_as_read: true)
      get("/messages/packs/#{pack_id}/sellers/#{ml_user_id}", tag: 'post_sale', mark_as_read: mark_as_read)
    end

    # ==== Claims ====
    def claim(claim_id)
      get("/post-purchase/v1/claims/#{claim_id}")
    end

    def search_claims(seller_id, status: 'opened')
      get('/post-purchase/v1/claims/search', seller_id: seller_id, status: status)
    end

    def claim_messages(claim_id)
      get("/post-purchase/v1/claims/#{claim_id}/messages")
    end

    def send_claim_message(claim_id, text)
      post("/post-purchase/v1/claims/#{claim_id}/actions/send-message", text: text)
    end

    def claim_refund(claim_id)
      post("/post-purchase/v1/claims/#{claim_id}/expected-resolutions/refund", {})
    end

    def claim_partial_refund(claim_id, reason_id:, amount:)
      post("/post-purchase/v1/claims/#{claim_id}/expected-resolutions/partial-refund", reason_id: reason_id, amount: amount)
    end

    def claim_available_offers(claim_id)
      get("/post-purchase/v1/claims/#{claim_id}/partial-refund/available-offers")
    end

    def claim_allow_return(claim_id)
      post("/post-purchase/v1/claims/#{claim_id}/expected-resolutions/allow-return", {})
    end

    def claim_open_mediation(claim_id)
      post("/post-purchase/v1/claims/#{claim_id}/actions/open-dispute", {})
    end

    def claim_evidences(claim_id)
      get("/post-purchase/v1/claims/#{claim_id}/evidences")
    end

    # Evidencia JSON (ej: { tracking_number:, carrier: } para PNR)
    def add_claim_evidence(claim_id, body)
      post("/post-purchase/v1/claims/#{claim_id}/actions/evidences", body)
    end

    # Evidencia con archivo (multipart, campo "file")
    def upload_claim_evidence(claim_id, file:, filename:, content_type:)
      post_multipart("/post-purchase/v1/claims/#{claim_id}/actions/evidences", file: file, filename: filename, content_type: content_type)
    end

    def claim_affects_reputation(claim_id)
      get("/post-purchase/v1/claims/#{claim_id}/affects-reputation")
    end

    # ==== Órdenes y envíos (para evidencia PNR) ====
    def order(order_id)
      get("/orders/#{order_id}")
    end

    def shipment(shipment_id)
      get("/shipments/#{shipment_id}")
    end

    # ==== Productos (panel "Producto ML") ====
    def item(item_id)
      get("/items/#{item_id}")
    end

    def item_description(item_id)
      get("/items/#{item_id}/description")
    end

    # ==== Devoluciones (keyed por claim_id o return_id según endpoint) ====
    def return_detail(claim_id)
      get("/post-purchase/v2/claims/#{claim_id}/returns")
    end

    def return_review(return_id, status:)
      post("/post-purchase/v1/returns/#{return_id}/return-review", status: status)
    end

    def return_reviews(return_id)
      get("/post-purchase/v1/returns/#{return_id}/reviews")
    end

    def return_reasons(claim_id)
      get('/post-purchase/v1/returns/reasons', flow: 'seller_return_failed', claim_id: claim_id)
    end

    def return_cost(claim_id)
      get("/post-purchase/v1/claims/#{claim_id}/charges/return-cost")
    end

    # ==== Cambios (keyed por claim_id) ====
    def change_detail(claim_id)
      get("/post-purchase/v1/claims/#{claim_id}/changes")
    end

    def change_allow_replace(claim_id)
      post("/post-purchase/v1/claims/#{claim_id}/expected-resolutions/allow-replace", {})
    end

    private

    def get(path, params = {})
      request(:get, path, params: params)
    end

    def post(path, body)
      request(:post, path, body: body)
    end

    def request(method, path, params: {}, body: nil)
      raise Error.new(401, 'no_credentials', 'No hay credenciales de MercadoLibre para la cuenta') if token.blank?

      uri = URI("#{BASE}#{path}")
      uri.query = URI.encode_www_form(params) if params.any?
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 20

      req = case method
            when :get  then Net::HTTP::Get.new(uri)
            when :post then Net::HTTP::Post.new(uri)
            end
      req['Authorization'] = "Bearer #{token}"
      req['Content-Type'] = 'application/json'
      # Los GET no deben llevar body: ML responde 403 si un GET trae body
      # (ej. GET /messages/packs/... — bug pre-existente expuesto por el perfil MIGRADO).
      req.body = body.to_json unless method == :get

      perform(http, req)
    end

    def post_multipart(path, file:, filename:, content_type:)
      raise Error.new(401, 'no_credentials', 'No hay credenciales de MercadoLibre para la cuenta') if token.blank?

      boundary = "----replyai#{SecureRandom.hex(10)}"
      io = file.respond_to?(:read) ? file : File.open(file, 'rb')
      data = +''.b
      data << "--#{boundary}\r\n".b
      data << "Content-Disposition: form-data; name=\"file\"; filename=\"#{filename}\"\r\n".b
      data << "Content-Type: #{content_type}\r\n\r\n".b
      data << io.read.b
      data << "\r\n--#{boundary}--\r\n".b
      io.close if file.respond_to?(:read)

      uri = URI("#{BASE}#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 20

      req = Net::HTTP::Post.new(uri)
      req['Authorization'] = "Bearer #{token}"
      req['Content-Type'] = "multipart/form-data; boundary=#{boundary}"
      req.body = data

      perform(http, req)
    end

    def perform(http, req)
      res = http.request(req)
      parsed = parse_body(res)
      return parsed if res.is_a?(Net::HTTPSuccess)

      raise Error.new(*parse_ml_error(res, parsed))
    end

    def parse_body(res)
      body = res.body.to_s
      body.empty? ? {} : JSON.parse(body)
    rescue JSON::ParserError
      { 'message' => body.truncate(200) }
    end

    # Mapea errores de ML a {status, code, message} legibles (401/403/404/400)
    def parse_ml_error(res, body)
      case res.code.to_i
      when 401
        [401, 'unauthorized', 'Token de MercadoLibre inválido o sin scope Post Purchase']
      when 403
        [403, body['error'] || 'forbidden', body['message'] || 'Acción no permitida por MercadoLibre']
      when 404
        [404, 'not_found', body['message'] || 'Recurso no encontrado en MercadoLibre']
      else
        [res.code.to_i, body['error'] || 'ml_error', body['message'] || 'Error de MercadoLibre']
      end
    end
  end
end
