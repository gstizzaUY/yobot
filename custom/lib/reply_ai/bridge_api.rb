module ReplyAi
  # Cliente del bridge Yobot: ejecuta acciones contra la API de MercadoLibre a través de
  # {YOBOT_BRIDGE_URL}/api/bridge/execute-claim-action (HMAC-SHA256 con BRIDGE_SECRET).
  # Misma interfaz pública que MeliApi para que controller/automation/agente sean
  # intercambiables vía ReplyAi::MeliApi.for(account). Las 21 acciones siguen el
  # contrato de docs/REQUERIMIENTOS_YOBOT.md §2 / §8.2.4.
  class BridgeApi
    class Error < MeliApi::Error; end

    def initialize(account)
      @account = account
      @credential = account.meli_credentials.where(status: 'bridge').order(:id).first
    end

    def ml_user_id
      @credential&.ml_user_id
    end

    # ==== Productos (panel "Producto ML") ====
    # El contrato del bridge NO incluye get_item: para cuentas bridge el panel usa el
    # catálogo local (meli_products) + el permalink público. Estos métodos lanzan un
    # error claro si alguien los invoca (el controller hace el fallback).
    def item(_item_id)
      raise Error.new(404, 'not_in_bridge_contract', 'El bridge de Yobot no expone get_item; usar catálogo local + permade')
    end

    def item_description(_item_id)
      raise Error.new(404, 'not_in_bridge_contract', 'El bridge de Yobot no expone get_item; usar catálogo local + permade')
    end

    # ==== Mensajes post-venta (estado de lectura: ticks delivered/read) ====
    # POST {YOBOT_BRIDGE_URL}/api/bridge/get-pack-messages (contrato 2026-08-07):
    # `mark_as_read: true` marca los mensajes del comprador como leídos en ML;
    # `mark_as_read: false` solo consulta (sync de lectura del vendedor).
    def pack_messages(pack_id, mark_as_read: true)
      raise Error.new(401, 'no_credentials', 'No hay credenciales bridge para la cuenta') if ml_user_id.blank?

      post("#{base}/api/bridge/get-pack-messages", { ml_user_id: ml_user_id, pack_id: pack_id, mark_as_read: mark_as_read })
    end

    # ==== Claims ====
    def claim(claim_id)
      execute('get_claim', {}, claim_id: claim_id)
    end

    def search_claims(_seller_id, status: 'opened')
      execute('search_claims', {}, claim_id: 0)
    end

    def claim_messages(claim_id)
      execute('get_messages', {}, claim_id: claim_id)
    end

    def send_claim_message(claim_id, text)
      execute('send_message', { text: text }, claim_id: claim_id)
    end

    def claim_refund(claim_id)
      execute('refund', {}, claim_id: claim_id)
    end

    def claim_partial_refund(claim_id, reason_id:, amount:)
      execute('partial_refund', { reason_id: reason_id, amount: amount }, claim_id: claim_id)
    end

    def claim_available_offers(claim_id)
      execute('available_offers', {}, claim_id: claim_id)
    end

    def claim_allow_return(claim_id)
      execute('allow_return', {}, claim_id: claim_id)
    end

    def claim_open_mediation(claim_id)
      execute('open_dispute', {}, claim_id: claim_id)
    end

    def claim_evidences(claim_id)
      execute('get_evidences', {}, claim_id: claim_id)
    end

    # Evidencia JSON (ej: { tracking_number:, carrier: } para PNR)
    def add_claim_evidence(claim_id, body)
      execute('add_evidence', body, claim_id: claim_id)
    end

    # Evidencia con archivo → Yobot arma el multipart hacia ML (file_base64)
    def upload_claim_evidence(claim_id, file:, filename:, content_type:)
      content = file.respond_to?(:read) ? file.read : File.binread(file)
      execute('add_evidence', { file_base64: Base64.strict_encode64(content), file_name: filename, mime_type: content_type }, claim_id: claim_id)
    end

    def claim_affects_reputation(claim_id)
      execute('affects_reputation', {}, claim_id: claim_id)
    end

    # ==== Órdenes y envíos (para evidencia PNR) ====
    def order(order_id)
      execute('get_order', { order_id: order_id }, claim_id: 0)
    end

    def shipment(shipment_id)
      execute('get_tracking', { shipment_id: shipment_id }, claim_id: 0)
    end

    # ==== Devoluciones ====
    def return_detail(claim_id)
      execute('get_returns', {}, claim_id: claim_id)
    end

    def return_review(return_id, status:)
      execute('review_return', { return_id: return_id, status: status }, claim_id: 0)
    end

    def return_reviews(return_id)
      execute('get_reviews', { return_id: return_id }, claim_id: 0)
    end

    def return_reasons(claim_id)
      execute('get_return_reasons', {}, claim_id: claim_id)
    end

    def return_cost(claim_id)
      execute('get_return_cost', {}, claim_id: claim_id)
    end

    # ==== Cambios ====
    def change_detail(claim_id)
      execute('get_changes', {}, claim_id: claim_id)
    end

    def change_allow_replace(claim_id)
      execute('allow_replace', {}, claim_id: claim_id)
    end

    # ==== Sync (catálogo y tiendas vía Yobot) ====
    def sync_products
      sync('sync-products')
    end

    def sync_official_stores
      sync('sync-official-stores')
    end

    private

    def base
      ENV.fetch('YOBOT_BRIDGE_URL', nil)
    end

    def secret
      ENV.fetch('BRIDGE_SECRET', nil)
    end

    def execute(action, params = {}, claim_id: 0)
      raise Error.new(400, 'bridge_not_configured', 'YOBOT_BRIDGE_URL/BRIDGE_SECRET no configurados en Reply-AI') if base.blank? || secret.blank?
      raise Error.new(401, 'no_credentials', 'No hay credenciales bridge para la cuenta') if ml_user_id.blank?

      body = { ml_user_id: ml_user_id, claim_id: claim_id, action: action, params: params }
      post("#{base}/api/bridge/execute-claim-action", body)
    end

    def sync(endpoint)
      raise Error.new(400, 'bridge_not_configured', 'YOBOT_BRIDGE_URL/BRIDGE_SECRET no configurados en Reply-AI') if base.blank? || secret.blank?
      raise Error.new(401, 'no_credentials', 'No hay credenciales bridge para la cuenta') if ml_user_id.blank?

      post("#{base}/api/bridge/#{endpoint}", { ml_user_id: ml_user_id })
    end

    def post(url, body)
      raw       = body.to_json
      signature = OpenSSL::HMAC.hexdigest('SHA256', secret, raw)
      res = RestClient.post(url, raw,
                            { 'Content-Type' => 'application/json',
                              'Authorization' => "Bearer #{secret}",
                              'X-Bridge-Signature' => signature,
                              accept: :json })
      parse_body(res)
    rescue RestClient::ExceptionWithResponse => e
      raise bridge_error(e.response)
    rescue RestClient::Exception => e
      raise Error.new(502, 'bridge_unreachable', "Bridge Yobot inaccesible: #{e.message}")
    end

    def bridge_error(response)
      parsed  = parse_body(response)
      message = parsed['error'].to_s.presence || parsed['message'].to_s.presence || "Error del bridge (#{response.code})"
      Error.new(response.code.to_i, 'bridge_error', message)
    end

    def parse_body(res)
      body = res.body.to_s
      body.empty? ? {} : JSON.parse(body)
    rescue JSON::ParserError
      { 'message' => body.truncate(200) }
    end
  end
end
