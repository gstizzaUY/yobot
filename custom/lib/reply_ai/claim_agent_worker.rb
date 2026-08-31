module ReplyAi
  # Motor agente de reclamos: loop ReAct con function calling (OpenAI).
  # Máximo 5 iteraciones. En modo supervisado, las tools con requires_confirmation
  # se detienen en pending_action hasta que un humano las aprueba (agent-execute).
  class ClaimAgentWorker
    include Sidekiq::Worker
    sidekiq_options queue: 'default', retry: 1

    MODEL = 'gpt-4o-mini'.freeze
    MAX_ITERATIONS = 5
    CONFIRM_TOOLS = %w[accept_return offer_partial_refund full_refund].freeze

    TOOL_DEFINITIONS = [
      { type: 'function', function: {
          name: 'get_tracking_status',
          description: 'Consulta el estado real de un envío de MercadoLibre y analiza si fue entregado antes o después de la fecha del reclamo. Nunca inventa estados.',
          parameters: { type: 'object', properties: { shipment_id: { type: 'string', description: 'ID del envío (shipping id) de la orden' } }, required: ['shipment_id'] } } },
      { type: 'function', function: {
          name: 'check_claim_policy',
          description: 'Verifica la información del reclamo (tipo, motivo, resoluciones esperadas y acciones disponibles) para decidir qué hacer.',
          parameters: { type: 'object', properties: {} } } },
      { type: 'function', function: {
          name: 'accept_return',
          description: 'Acepta la devolución del producto en el reclamo.',
          parameters: { type: 'object', properties: {} } } },
      { type: 'function', function: {
          name: 'offer_partial_refund',
          description: 'Ofrece el reembolso parcial más bajo disponible para el reclamo.',
          parameters: { type: 'object', properties: {} } } },
      { type: 'function', function: {
          name: 'send_evidence',
          description: 'Envía evidencia de envío (PNR/tracking) al reclamo como prueba de entrega.',
          parameters: { type: 'object', properties: { shipment_id: { type: 'string', description: 'ID del envío (opcional, usa el del reclamo si no se provee)' } } } } },
      { type: 'function', function: {
          name: 'send_claim_message',
          description: 'Envía un mensaje al comprador o mediador dentro del reclamo.',
          parameters: { type: 'object', properties: { text: { type: 'string', description: 'Texto del mensaje' } }, required: ['text'] } } },
      { type: 'function', function: {
          name: 'full_refund',
          description: 'Realiza el reembolso total del reclamo.',
          parameters: { type: 'object', properties: {} } } },
      { type: 'function', function: {
          name: 'escalate_to_human',
          description: 'Deriva el reclamo a un operador humano porque no se puede resolver automáticamente.',
          parameters: { type: 'object', properties: { reason: { type: 'string', description: 'Motivo de la derivación' } } } } }
    ].freeze

    def perform(claim_id, account_id)
      claim = MeliClaim.find_by(id: claim_id, account_id: account_id)
      return unless claim
      return if claim.pending_action.present?

      claim.update!(agent_status: 'running', agent_log: [])
      api = MeliApi.for(claim.account)

      claim.update!(raw_data: api.claim(claim.claim_id))
      messages = build_messages(claim)
      status = run_loop(api, claim, messages, MAX_ITERATIONS)
      claim.update!(agent_status: status)
    rescue StandardError => e
      Rails.logger.error "[ClaimAgentWorker] error: #{e.class} #{e.message}"
      claim&.update!(agent_status: 'error')
    end

    # Modo recepción (testing): REPLY_RECEIVE_ONLY=true + cuenta marcada receive_only.
    # El agente corre en dry-run: analiza y decide, pero las tools que ejecutarían
    # acciones en ML/Yobot se simulan (resultado ok) sin llamar a la API.
    def receive_only?(account)
      ENV['REPLY_RECEIVE_ONLY'] == 'true' && account.custom_attributes.to_h['receive_only'] == true
    end

    # Cancela la acción pendiente (el agente queda en cancelled).
    def self.execute_pending!(claim_id, account_id)
      claim = MeliClaim.find_by(id: claim_id, account_id: account_id)
      return { error: 'reclamo no encontrado' } unless claim
      return { error: 'sin acción pendiente' } if claim.pending_action.blank?
      return { receive_only: true, accion_bloqueada: true } if new.send(:receive_only?, claim.account)

      pending = claim.pending_action
      api = MeliApi.for(claim.account)
      result = new.send(:execute_tool, api, claim, pending['tool'], pending['args'] || {})
      claim.update!(pending_action: nil)
      claim.update!(agent_log: (claim.agent_log || []) + [{ 'tipo' => 'confirmada', 'tool' => pending['tool'], 'resultado' => result }])

      perform_async(claim.id, claim.account_id)
      result
    end

    # Cancela la acción pendiente (el agente queda en cancelled).
    def self.cancel_pending!(claim_id, account_id)
      claim = MeliClaim.find_by(id: claim_id, account_id: account_id)
      return { error: 'reclamo no encontrado' } unless claim

      claim.update!(pending_action: nil, agent_status: 'cancelled')
      { ok: true }
    end

    private

    def run_loop(api, claim, messages, max_iterations)
      max_iterations.times do
        resp = openai_chat(messages, TOOL_DEFINITIONS)
        msg = resp.dig('choices', 0, 'message') || {}
        messages << msg

        tool_calls = msg['tool_calls'] || []
        return 'done' if tool_calls.empty? # la IA terminó sin pedir más tools

        tool_calls.each do |tc|
          name = tc.dig('function', 'name')
          args = safe_parse(tc.dig('function', 'arguments') || '{}')
          log(claim, name, args)

          if CONFIRM_TOOLS.include?(name) && supervised_mode?(claim)
            claim.update!(pending_action: { 'tool' => name, 'args' => args })
            return 'pending'
          end

          result = if receive_only?(claim.account)
                     { ok: true, receive_only: true, simulated: name, detalle: 'No ejecutado: modo recepción (testing)' }
                   else
                     execute_tool(api, claim, name, args)
                   end
          log_result(claim, result)
          messages << { role: 'tool', tool_call_id: tc['id'], content: result.to_json }
        end
      end
      'escalate'
    end

    def execute_tool(api, claim, name, args)
      case name
      when 'get_tracking_status'  then get_tracking_status(api, claim, args)
      when 'check_claim_policy'   then check_claim_policy(claim)
      when 'accept_return'        then { ok: true, detail: api.claim_allow_return(claim.claim_id) }
      when 'offer_partial_refund' then offer_partial_refund(api, claim)
      when 'send_evidence'        then send_evidence(api, claim, args)
      when 'send_claim_message'   then { ok: true, detail: api.send_claim_message(claim.claim_id, args['text'].to_s) }
      when 'full_refund'          then { ok: true, detail: api.claim_refund(claim.claim_id) }
      when 'escalate_to_human'    then escalate(claim, args)
      else { ok: false, error: "tool desconocida: #{name}" }
      end
    rescue MeliApi::Error => e
      { ok: false, error: e.message, status: e.status }
    end

    def get_tracking_status(api, _claim, args)
      shipment = api.shipment(args['shipment_id'].to_s)
      status = shipment['status'].to_s.downcase
      history = Array(shipment['history']).last
      {
        ok: true,
        shipment_id: shipment['id'],
        estado: status,
        entregado: status.include?('delivered'),
        fecha_estimada: shipment.dig('estimated_delivery_time', 'date') || shipment.dig('estimated_handling_limit', 'date'),
        ultimo_evento: history ? { fecha: history['date'], detalle: history['detail'] || history['status'] } : nil,
        tracking: shipment['tracking_number']
      }
    end

    def check_claim_policy(claim)
      {
        ok: true,
        tipo: claim.claim_type,
        motivo: claim.reason_id,
        stage: claim.stage,
        resoluciones_esperadas: claim.expected_resolutions,
        acciones_disponibles: Array(claim.players).flat_map { |p| Array(p['available_actions']) }
      }
    end

    def offer_partial_refund(api, claim)
      offers = api.claim_available_offers(claim.claim_id)
      offers = Array(offers.is_a?(Hash) ? offers['offers'] : offers)
      return { ok: false, error: 'sin_ofertas_disponibles' } if offers.empty?

      offer = offers.min_by { |o| o['amount'].to_f }
      api.claim_partial_refund(claim.claim_id, reason_id: offer['reason_id'], amount: offer['amount'])
      { ok: true, detalle: "Reembolso parcial de #{offer['amount']} aceptado" }
    end

    def send_evidence(api, claim, args)
      tracking = tracking_from_claim(api, claim, args['shipment_id'])
      return { ok: false, error: 'sin_tracking_disponible' } if tracking.blank?

      api.add_claim_evidence(claim.claim_id, tracking_number: tracking[:number], carrier: tracking[:carrier])
      { ok: true, detalle: "Evidencia del envío #{tracking[:number]} enviada" }
    end

    def escalate(claim, args)
      claim.update!(handoff_reason: args['reason'] || 'escalado_por_agente')
      { ok: true, detalle: 'Reclamo derivado a operador humano' }
    end

    def tracking_from_claim(api, claim, shipment_id = nil)
      if shipment_id.present?
        shipment = api.shipment(shipment_id)
        return { number: shipment['tracking_number'] || shipment_id, carrier: shipment['tracking_method'] || 'other' }
      end
      return nil unless claim.resource_id

      order = api.order(claim.resource_id) rescue nil
      return nil unless order && order.dig('shipping', 'tracking_number')

      { number: order.dig('shipping', 'tracking_number'), carrier: order.dig('shipping', 'tracking_method') || 'other' }
    end

    def supervised_mode?(claim)
      config = claim.account.custom_attributes&.dig('config', 'automatizacion_reclamos') || {}
      config['modoAgenteSupervisado'] == true
    end

    def build_messages(claim)
      order = claim.orden
      [
        { role: 'system', content: system_prompt(claim, order) },
        { role: 'user', content: user_prompt(claim, order) }
      ]
    end

    def system_prompt(claim, order)
      config = claim.account.custom_attributes&.dig('config', 'automatizacion_reclamos') || {}
      <<~PROMPT
        Sos el agente de gestión de reclamos de MercadoLibre de una tienda.
        Reglas:
        - Resolvé el reclamo solo si es seguro y está dentro de las políticas configuradas.
        - Si un reclamo ya tiene una resolución aplicada (según el log), no la vuelvas a pedir.
        - Las acciones con confirmación humana (aceptar devolución, reembolsos) se ejecutan por el sistema al confirmar; pedilas solo cuando corresponda.
        - Si no podés resolverlo con certeza, usá escalate_to_human.
        - Respondé siempre con herramientas; solo termina cuando el reclamo esté resuelto o escalado.
        Configuración del vendedor: #{config.slice('montoMaximoAuto', 'montoMaximoDevolucionAuto', 'tiposExcluidos').to_json}
        Log de acciones previas del agente: #{(claim.agent_log || []).to_json}
      PROMPT
    end

    def user_prompt(claim, order)
      order_ctx = if order
                    "Orden: #{order.ml_order_id} | Estado: #{order.order_status} | Item: #{order.item_id}"
                  else
                    'Sin orden vinculada'
                  end
      "Reclamo #{claim.claim_id}: tipo=#{claim.claim_type}, motivo=#{claim.reason_id}, stage=#{claim.stage}, status=#{claim.status}.
       #{order_ctx}
       Datos completos: #{claim.raw_data.to_json.truncate(6000)}"
    end

    def openai_chat(messages, tools)
      api_key = ENV.fetch('OPENAI_API_KEY') { raise 'OPENAI_API_KEY no configurada' }
      uri = URI('https://api.openai.com/v1/chat/completions')
      req = Net::HTTP::Post.new(uri)
      req['Authorization'] = "Bearer #{api_key}"
      req['Content-Type'] = 'application/json'
      req.body = JSON.generate(model: MODEL, temperature: 0.2, messages: messages, tools: tools, tool_choice: 'auto')
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(req) }
      raise "OpenAI error: #{res.code} #{res.body}" unless res.is_a?(Net::HTTPSuccess)

      JSON.parse(res.body)
    end

    def log(claim, tool, args)
      claim.update!(agent_log: (claim.agent_log || []) + [{ 'tipo' => 'herramienta', 'tool' => tool, 'args' => args }])
    end

    def log_result(claim, result)
      claim.update!(agent_log: (claim.agent_log || []) + [{ 'tipo' => 'resultado', 'resultado' => result }])
    end

    def safe_parse(json)
      JSON.parse(json)
    rescue JSON::ParserError
      {}
    end
  end
end
