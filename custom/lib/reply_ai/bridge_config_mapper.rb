module ReplyAi
  # Traduce `User.config` de Yobot (Mongo) → `Account.custom_attributes` de Reply (JSONB).
  # Contrato aprobado en docs/REQUERIMIENTOS_YOBOT.md ("PLAN DE INTEGRACIÓN — MAPEO DE
  # CONFIGURACIÓN YOBOT → REPLY"). Consideraciones de Yobot incorporadas: día de la semana
  # Number (scheduledMode) vs String (postVentaScheduledMode) → normalizado a wday
  # (0 = Domingo, igual que la convención de Reply), prompts camelCase → mismos nombres,
  # envíos por subtipo → shipping_instructions, mensaje de venta inicial → post_sale.
  class BridgeConfigMapper
    SHIPPING_KEYS = {
      'enviosMe1' => 'me1', 'enviosMe2' => 'me2', 'enviosFull' => 'full',
      'enviosRetiroLocal' => 'pickup', 'enviosCustom' => 'custom'
    }.freeze

    PROMPT_KEYS = %w[precio mediosPago garantia envios condicionProducto otros saludoGeneral].freeze

    DAY_NAMES = %w[sunday monday tuesday wednesday thursday friday saturday].freeze

    # Devuelve { custom_attributes: Hash, stores: [{official_store_id, name, custom_greeting}] }
    def self.map(yobot_config)
      new(yobot_config).map
    end

    def initialize(yobot_config)
      @c = yobot_config || {}
      @prompts = @c['prompts'] || {}
    end

    def map
      {
        custom_attributes: { 'config' => build_config },
        stores: build_stores
      }
    end

    private

    def build_config
      config = {
        'chatGPTEnabled' => @c['chatGPTEnabled'] == true,
        'theme' => @c['theme'].presence || 'light',
        'prompts' => PROMPT_KEYS.index_with { |k| @prompts[k].to_s },
        'shipping_instructions' => build_shipping_instructions,
        'response_delay' => build_delay(@c['responseDelay']),
        'scheduledMode' => build_schedule(@c['scheduledMode']),
        'post_sale' => build_post_sale,
        'post_venta_ia' => build_post_venta,
        'automatizacion_reclamos' => build_automatizacion,
        # Control de confianza pre-venta (2026-08-08): retener respuestas sin info suficiente.
        'requireRagOrConfidence' => @c['requireRagOrConfidence'] == true,
        'confidenceByCategory' => (@c['confidenceByCategory'].is_a?(Hash) ? @c['confidenceByCategory'] : {})
      }
      config['shipping_instructions'] = nil if config['shipping_instructions'].blank?
      config.compact
    end

    def build_shipping_instructions
      instructions = {}
      SHIPPING_KEYS.each do |y_key, r_key|
        instructions[r_key] = @prompts[y_key].to_s if @prompts[y_key].present?
      end
      instructions['default'] = @prompts['instruccionesEntrega'].to_s if @prompts['instruccionesEntrega'].present?
      instructions
    end

    def build_delay(delay)
      delay = delay || {}
      {
        'enabled' => delay['enabled'] == true,
        'seconds' => (delay['seconds'] || 0).to_i.clamp(0, 900)
      }
    end

    # scheduledMode.workDays[].day es Number (JS: 0 = Domingo);
    # postVentaScheduledMode.workDays[].day es String (número o nombre en inglés).
    # Reply usa la convención wday de Ruby: 0 = Domingo.
    def build_schedule(schedule)
      schedule = schedule || {}
      days = {}
      Array(schedule['workDays']).each do |wd|
        day = normalize_day(wd['day'])
        next if day.nil? || wd['active'] != true

        slots = Array(wd['schedule']).filter_map do |s|
          next if s['start'].blank? || s['end'].blank?

          { 'start' => s['start'].to_s, 'end' => s['end'].to_s, 'active' => s['botEnabled'] == true }
        end
        days[day.to_s] = slots if slots.any?
      end

      overrides = {}
      Array(schedule['holidays']).each do |h|
        date_str = h['date'].to_s[0, 10]
        next unless date_str.match?(/\A\d{4}-\d{2}-\d{2}\z/)

        overrides[date_str] = { 'mode' => h['botEnabled'] == true ? 'always_on' : 'always_off' }
      end

      {
        'enabled' => schedule['enabled'] == true,
        'timezone' => schedule['timezone'].presence || 'America/Argentina/Buenos_Aires',
        'days' => days,
        'overrides' => overrides
      }
    end

    def normalize_day(day)
      return nil if day.blank?

      case day
      when Integer
        day.between?(0, 6) ? day : nil
      when String
        stripped = day.strip.downcase
        return stripped.to_i if stripped.match?(/\A[0-6]\z/)
        return DAY_NAMES.index(stripped) if DAY_NAMES.include?(stripped)

        nil
      else
        nil
      end
    end

    # Mensaje inicial de venta (respuesta de Yobot a la consulta §4): ME1 + instruccionesEntrega
    def build_post_sale
      entrega = @prompts['instruccionesEntrega'].to_s
      { 'enabled' => entrega.present?, 'message' => entrega }
    end

    def build_post_venta
      {
        'enabled' => @c['postVentaChatGPTEnabled'] == true,
        'model' => 'gpt-4o-mini',
        'delay' => build_delay(@c['postVentaResponseDelay']),
        'scheduledMode' => build_schedule(@c['postVentaScheduledMode']),
        'logistica' => { 'enabled' => true },
        'soporte' => { 'enabled' => true, 'fallback_to_human' => true },
        'cierre' => { 'enabled' => true, 'auto_resolve' => true },
        'reclamo' => { 'notify_customer' => false },
        'prompts' => {
          'logistica' => '', 'soporte' => @prompts['promptPostVenta'].to_s,
          'cierre' => '', 'escalacion' => '', 'tono' => ''
        }
      }
    end

    def build_automatizacion
      auto = @c['automatizacionReclamos'] || {}
      {
        'enabled' => auto['enabled'] == true,
        'autoEnviarEvidenciaPNR' => auto['autoEnviarEvidenciaPNR'] != false,
        'autoAceptarDevolucionPDD' => auto['autoAceptarDevolucionPDD'] == true,
        'autoReembolsoParcial' => auto['autoReembolsoParcial'] == true,
        'autoAprobarDevolucionSimple' => auto['autoAprobarDevolucionSimple'] == true,
        'montoMaximoAuto' => (auto['montoMaximoAuto'] || 0).to_f,
        'montoMaximoDevolucionAuto' => (auto['montoMaximoDevolucionAuto'] || 0).to_f,
        'modoAgenteSupervisado' => auto['modoAgenteSupervisado'] != false,
        'tiposExcluidos' => Array(auto['tiposExcluidos']),
        'delayRespuesta' => (auto['delayRespuesta'] || 60).to_i
      }
    end

    def build_stores
      Array(@c.dig('officialStores', 'stores')).filter_map do |store|
        id = store['official_store_id']
        next if id.blank?

        {
          'official_store_id' => id.to_s,
          'name' => store['name'].to_s,
          'custom_greeting' => store['customGreeting'].to_s
        }
      end
    end
  end
end
