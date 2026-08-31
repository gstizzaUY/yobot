module ReplyAi
  # Reglas de decisión automática de reclamos (sin IA, pre-agente).
  # Config en custom_attributes.config.automatizacion_reclamos.
  # Contratos ML verificados contra Yobot (handleIncomingClaim.js).
  class ClaimAutomation
    SIMPLE_RETURN_REASONS = %w[
      REASON_BUYER_REGRET DOESNT_FIT CHANGED_MIND WRONG_SIZE WRONG_COLOR
      DONT_LIKE_IT FOUND_BETTER_PRICE NOT_NEEDED
    ].freeze

    def initialize(account, claim)
      @account = account
      @claim = claim
      @config = account.custom_attributes&.dig('config', 'automatizacion_reclamos') || {}
    end

    def enabled?
      @config['enabled'] != false
    end

    def supervised_mode?
      @config['modoAgenteSupervisado'] == true
    end

    # Devuelve :handoff (derivar a humano/agente), nil (sin regla aplicable → agente),
    # o { action:, } para ejecutar directamente.
    def evaluar
      return :handoff if excluded_type? || limite_superado?

      reason = @claim.reason_id.to_s
      actions = available_actions

      if reason.start_with?('PNR')
        return { action: :send_evidence } if actions.include?('add_shipping_evidence')
      elsif reason.start_with?('PDD')
        return { action: :accept_return } if actions.include?('allow_return') && @config['autoAceptarDevolucionPDD'] != false
        return { action: :partial_refund } if actions.include?('allow_partial_refund') && @config['autoReembolsoParcial'] != false
      elsif devolucion_simple?
        return { action: :accept_return } if actions.include?('allow_return') && @config['autoAprobarDevolucionSimple'] != false
      end

      :handoff
    end

    def ejecutar(decision)
      api = MeliApi.for(@account)
      case decision[:action]
      when :send_evidence
        tracking = order_tracking(api)
        return { ok: false, error: 'sin_tracking' } if tracking.blank?

        api.add_claim_evidence(@claim.claim_id, tracking_number: tracking[:number], carrier: tracking[:carrier])
        { ok: true, detail: "Evidencia del envío #{tracking[:number]} enviada" }
      when :accept_return
        api.claim_allow_return(@claim.claim_id)
        { ok: true, detail: 'Devolución aceptada automáticamente' }
      when :partial_refund
        offer = lowest_offer(api)
        return { ok: false, error: 'sin_ofertas' } unless offer

        api.claim_partial_refund(@claim.claim_id, reason_id: offer['reason_id'], amount: offer['amount'])
        { ok: true, detail: "Reembolso parcial de #{offer['amount']} ofrecido" }
      end
    end

    private

    def excluded_type?
      Array(@config['tipos_excluidos']).include?(@claim.claim_type)
    end

    def limite_superado?
      max = @config['montoMaximoAuto'].to_f
      max.positive? && claim_amount > max
    end

    def devolucion_simple?
      @claim.claim_type == 'return' && SIMPLE_RETURN_REASONS.include?(@claim.reason_id)
    end

    def claim_amount
      data = @claim.raw_data || {}
      (Array(data['expected_resolutions']).first || {})['amount'].to_f
    end

    def available_actions
      Array(@claim.players).flat_map { |p| Array(p['available_actions']) }
                           .filter_map { |a| a.is_a?(Hash) ? (a['action'] || a['name']) : a }
                           .compact
    end

    def order_tracking(api)
      return nil unless @claim.resource_id

      order = api.order(@claim.resource_id) rescue nil
      return nil unless order && order.dig('shipping', 'tracking_number')

      { number: order.dig('shipping', 'tracking_number'), carrier: order.dig('shipping', 'tracking_method') || 'other' }
    end

    def lowest_offer(api)
      offers = api.claim_available_offers(@claim.claim_id)
      offers = Array(offers.is_a?(Hash) ? offers['offers'] : offers)
      offers.min_by { |o| o['amount'].to_f }
    end
  end
end
