require 'rest-client'
require 'erb'
require 'uri'

class LandingController < ApplicationController
  include ReplyAi::BridgeAuth

  skip_before_action :authenticate_user!, only: [:index, :signup, :create_account, :meli_callback, :go_to_chats, :dashboard, :update_settings, :upload_document, :destroy_document, :dashboard_status, :dashboard_products, :pv_dashboard_products, :rag_search, :update_store_greeting, :refresh_official_stores, :refresh_tokens, :bot_active, :conversation_ai_gate, :post_venta, :update_post_venta, :pv_upload_document, :pv_destroy_document, :pv_rag_search, :bulk_import_preview, :bulk_import, :product_docs_list, :destroy_document_ajax, :pv_destroy_document_ajax, :migrate_rag_pre, :migrate_rag_post, :confidence_report, :bridge_question, :bridge_message, :bridge_order, :bridge_claim, :bridge_manual_response, :bridge_sign, :bridge_seller_status, :bridge_register, :bridge_sync_config, :bridge_message_status, :bridge_sync_conversation_reads, :claims_webhook, :claims_index, :claims_list, :claims_sync, :claim_detail, :claim_messages, :claim_evidences, :claim_send_message, :claim_send_evidence, :claim_refund, :claim_partial_refund, :claim_available_offers, :claim_allow_return, :claim_open_dispute, :claim_affects_reputation, :claim_agent_pending, :claim_agent_execute, :claim_agent_cancel, :claim_agent_rerun, :return_detail, :return_review, :return_reasons, :return_cost, :change_detail, :change_allow_replace, :claim_panel, :claim_panel_data, :sales_list, :sale_detail, :sale_panel, :sale_panel_data, :product_panel, :product_panel_data], raise: false
  layout false
  before_action :set_account, only: [:dashboard, :update_settings, :upload_document, :destroy_document, :dashboard_status, :dashboard_products, :pv_dashboard_products, :update_store_greeting, :refresh_official_stores, :refresh_tokens, :post_venta, :update_post_venta, :pv_upload_document, :pv_destroy_document, :bulk_import_preview, :bulk_import, :product_docs_list, :destroy_document_ajax, :pv_destroy_document_ajax, :migrate_rag_pre, :migrate_rag_post, :confidence_report, :claims_index, :claims_list, :claims_sync, :claim_detail, :claim_messages, :claim_evidences, :claim_send_message, :claim_send_evidence, :claim_refund, :claim_partial_refund, :claim_available_offers, :claim_allow_return, :claim_open_dispute, :claim_affects_reputation, :claim_agent_pending, :claim_agent_execute, :claim_agent_cancel, :claim_agent_rerun, :return_detail, :return_review, :return_reasons, :return_cost, :change_detail, :change_allow_replace, :claim_panel, :claim_panel_data, :sales_list, :sale_detail, :sale_panel, :sale_panel_data, :product_panel, :product_panel_data]
  # Modo recepción (testing): cuentas marcadas receive_only reciben/ingestan el flujo
  # (preguntas, mensajes, reclamos → Chatwoot) pero NUNCA ejecutan acciones que escriban en ML/Yobot.
  before_action :reject_receive_only_write, only: [:claim_send_message, :claim_send_evidence, :claim_refund, :claim_partial_refund, :claim_allow_return, :claim_open_dispute, :claim_agent_execute, :claim_agent_rerun, :return_review, :change_allow_replace]
  # Cuentas bridge: Reply NUNCA llama a la API de ML directamente — todo el tráfico
  # ML se gestiona a través de Yobot (bridge). `meli_api_for`/`MeliApi.for` rutean a
  # BridgeApi (execute-claim-action) para las cuentas bridgeadas.
  before_action :set_account_from_token, only: [:rag_search, :pv_rag_search]

  def index; end
  def signup; end

  # PASO 1: Crear usuario y cuenta vía Platform API → sesión Devise → ML Auth
  def create_account
    # Validación: ¿ya existe un usuario con este email asociado a una cuenta?
    email = params[:email].to_s.downcase.strip
    user = User.find_by(email: email)
    if user && user.accounts.exists?
      flash[:alert] = 'Ya existe una cuenta registrada con este correo electrónico. Por favor, inicia sesión o recupera tu acceso.'
      redirect_to '/signup'
      return
    end

    platform_token = ENV.fetch('CHATWOOT_PLATFORM_TOKEN')

    begin
      # 1. Crear Usuario vía API
      user_res = RestClient.post(
        "#{internal_base}/platform/api/v1/users",
        { name: params[:user_name], email: params[:email].downcase.strip, password: params[:password] }.to_json,
        { 'api_access_token' => platform_token, content_type: :json, accept: :json }
      )
      user_data = JSON.parse(user_res.body)

      # 2. Crear Cuenta vía API
      account_res = RestClient.post(
        "#{internal_base}/platform/api/v1/accounts",
        { name: params[:account_name] }.to_json,
        { 'api_access_token' => platform_token, content_type: :json, accept: :json }
      )
      account_data = JSON.parse(account_res.body)

      # 3. Vincular usuario a la cuenta como administrador (temporal para el setup)
      RestClient.post(
        "#{internal_base}/platform/api/v1/accounts/#{account_data['id']}/account_users",
        { user_id: user_data['id'], role: 'administrator' }.to_json,
        { 'api_access_token' => platform_token, content_type: :json, accept: :json }
      )

      # 4. Configurar atributos Reply-AI en la cuenta
      account = Account.find(account_data['id'])
      account.update_columns(
        limits: { 'agents' => 3, 'inboxes' => 5 },
        custom_attributes: default_reply_ai_config
      )

      # 5. Crear equipos, bandejas de entrada, labels y webhooks
      real_user       = User.find(user_data['id'])
      real_user_token = real_user.access_token&.token
      setup_account_channels(account, real_user.id, real_user_token) if real_user_token

      # 6. Degradar al usuario real a agente (el setup ya está completo)
      RestClient.put(
        "#{internal_base}/api/v1/accounts/#{account.id}/agents/#{user_data['id']}",
        { agent: { role: 'agent' } }.to_json,
        { api_access_token: real_user_token, content_type: :json, accept: :json }
      ) rescue nil

      # 7. Asociar el shadow user a la nueva cuenta como administrador
      shadow_email = ENV.fetch('SYSTEM_ADMIN_EMAIL')
      Rails.logger.info "[DEBUG] SYSTEM_ADMIN_EMAIL desde ENV: #{shadow_email}"
      shadow_user = User.find_by(email: shadow_email)
      if shadow_user
        Rails.logger.info "[DEBUG] Shadow user encontrado: id=#{shadow_user.id}, email=#{shadow_user.email}"
        RestClient.post(
          "#{internal_base}/platform/api/v1/accounts/#{account_data['id']}/account_users",
          { user_id: shadow_user.id, role: 'administrator' }.to_json,
          { 'api_access_token' => platform_token, content_type: :json, accept: :json }
        )
      else
        Rails.logger.warn "[DEBUG] Shadow user NO encontrado con email: #{shadow_email}"
      end

      # 7.5. Agregar usuario agente común reply-ai a la nueva cuenta
      reply_agent = ensure_reply_agent_user
      if reply_agent
        begin
          # Vincular a la cuenta como agente vía Platform API (igual que el shadow user en el paso 7)
          RestClient.post(
            "#{internal_base}/platform/api/v1/accounts/#{account_data['id']}/account_users",
            { user_id: reply_agent.id, role: 'agent' }.to_json,
            { 'api_access_token' => platform_token, content_type: :json, accept: :json }
          ) rescue nil
          # Agregar a inboxes (AR additive: no reemplaza miembros existentes)
          account.inboxes.each do |inbox|
            InboxMember.find_or_create_by!(user_id: reply_agent.id, inbox_id: inbox.id)
          end
          # Agregar a teams vía API usando el token del shadow_user (ya es admin de esta cuenta)
          shadow_token = User.find_by(email: ENV.fetch('SYSTEM_ADMIN_EMAIL', ''))&.access_token&.token
          account.teams.each do |team|
            if shadow_token
              RestClient.post(
                "#{internal_base}/api/v1/accounts/#{account.id}/teams/#{team.id}/team_members",
                { user_ids: [reply_agent.id] }.to_json,
                { api_access_token: shadow_token, content_type: :json, accept: :json }
              ) rescue nil
            else
              TeamMember.find_or_create_by!(user_id: reply_agent.id, team_id: team.id)
            end
          end
        rescue StandardError => e
          Rails.logger.error "Error adding reply agent to account #{account.id}: #{e.message}"
        end
      end

      # 8. Iniciar sesión Rails vía Devise (persiste durante el flujo ML → callback → dashboard)
      sign_in(User.find(user_data['id']))

      # 9. Redirigir directamente a ML Auth (state = account_id para el callback)
      redirect_to ml_auth_url(account.id), allow_other_host: true
    rescue => e
      render html: "Error al crear la cuenta: #{e.message}. <a href='/signup'>Reintentar</a>".html_safe, status: 500
    end
      # Fin del método create_account
  end

  # PASO 2: Callback de MercadoLibre — sesión Rails ya activa, guarda credenciales y redirige al dashboard
  def meli_callback
    @account = Account.find_by(id: params[:state])

    unless @account
      render html: 'Error: cuenta no encontrada.'.html_safe, status: 404 and return
    end

    begin
      response = RestClient.post(
        'https://api.mercadolibre.com/oauth/token',
        {
          grant_type: 'authorization_code',
          client_id: ENV.fetch('ML_APP_ID'),
          client_secret: ENV.fetch('ML_SECRET_KEY'),
          code: params[:code],
          redirect_uri: ENV.fetch('ML_REDIRECT_URI')
        }.to_json,
        { content_type: :json, accept: :json }
      )
      meli_data = JSON.parse(response.body)

      MeliCredential.find_or_initialize_by(ml_user_id: meli_data['user_id'].to_s).update!(
        account_id: @account.id,
        access_token: meli_data['access_token'],
        refresh_token: meli_data['refresh_token'],
        expires_at: Time.current + meli_data['expires_in'].seconds,
        status: 'active'
      )

      ReplyAi::MeliSyncProductsWorker.perform_async(@account.id)
      ReplyAi::MeliSyncOfficialStoresWorker.perform_async(@account.id)
      ReplyAi::ClaimsSyncWorker.perform_async(@account.id)

      # Detectar país del usuario ML para asignar idioma a la cuenta
      ml_user_res  = RestClient.get("https://api.mercadolibre.com/users/me",
                       { Authorization: "Bearer #{meli_data['access_token']}" })
      ml_user_data = JSON.parse(ml_user_res.body)
      site_id      = ml_user_data['site_id'].to_s.upcase
      locale       = site_id == 'MLB' ? 'pt_BR' : 'es'

      attrs = (@account.custom_attributes || {}).deep_dup
      attrs['mercadolibre']['user'] ||= {}
      attrs['mercadolibre']['user']['user_id']  = meli_data['user_id']
      attrs['mercadolibre']['user']['site_id']  = site_id
      attrs['mercadolibre']['user']['nickname'] = ml_user_data['nickname']

      # Actualizar locale y custom_attributes juntos con update_columns (bypasea validaciones de limits)
      @account.update_columns(locale: locale, custom_attributes: attrs)

      # Autenticar al usuario y hacer sign_in para persistir la sesión
      user = @account.users.where.not(email: ENV.fetch('SYSTEM_ADMIN_EMAIL')).first
      sign_in(:user, user) if user

      # Renderizar el dashboard directamente para evitar perder la sesión en el redirect
      render 'landing/welcome'
    rescue => e
      render html: "Error vinculando MercadoLibre: #{e.message}".html_safe, status: 500
    end
  end

  # PASO 3: Dashboard de configuración Reply-AI
  def dashboard
    setup_dashboard_vars
  end

  def post_venta
    setup_dashboard_vars
  end

  def update_post_venta
    attrs = (@account.custom_attributes || {}).deep_dup
    pvia  = params[:post_venta_ia] || {}
    attrs['config']['post_venta_ia'] = {
      'enabled' => pvia[:enabled] == '1',
      'model'   => %w[gpt-4o-mini gpt-4o].include?(pvia[:model].to_s) ? pvia[:model].to_s : 'gpt-4o-mini',
      'delay'   => {
        'enabled' => pvia[:delay_enabled] == '1',
        'seconds' => pvia[:delay_seconds].to_i.clamp(0, 900)
      },
      'scheduledMode' => sanitize_schedule(params[:schedule_pv]),
      'logistica' => { 'enabled' => pvia.dig(:logistica, :enabled) == '1' },
      'soporte'   => {
        'enabled'           => pvia.dig(:soporte, :enabled)           == '1',
        'fallback_to_human' => pvia.dig(:soporte, :fallback_to_human) == '1'
      },
      'cierre'  => {
        'enabled'      => pvia.dig(:cierre, :enabled)      == '1',
        'auto_resolve' => pvia.dig(:cierre, :auto_resolve) == '1'
      },
      'reclamo' => { 'notify_customer' => pvia.dig(:reclamo, :notify_customer) == '1' },
      'prompts' => {
        'logistica'  => pvia.dig(:prompts, :logistica).to_s.strip,
        'soporte'    => pvia.dig(:prompts, :soporte).to_s.strip,
        'cierre'     => pvia.dig(:prompts, :cierre).to_s.strip,
        'escalacion' => pvia.dig(:prompts, :escalacion).to_s.strip,
        'tono'       => pvia.dig(:prompts, :tono).to_s.strip
      }
    }
    @account.update_columns(custom_attributes: attrs)
    redirect_to reply_ai_dashboard_path, notice: 'Configuración guardada.'
  end

  # Sincroniza la configuración del bridge desde Yobot (botón del dashboard post-venta).
  def bridge_sync_config
    ReplyAi::BridgeConfigSyncWorker.perform_async(@account.id)
    redirect_to reply_ai_dashboard_path(tab: 'postventa', sub: 'ajustes'),
                notice: 'Sincronización de configuración de Yobot iniciada.'
  end

  # Endpoint JSON: estado de sincronización (usado por el polling del frontend)
  def dashboard_status
    attrs        = @account.custom_attributes || {}
    syncing      = attrs['syncing_products'] == true
    total        = @account.meli_products.count
    total_cats   = @account.meli_categories.count
    has_creds    = MeliCredential.where(account_id: @account.id, status: 'active').exists?
    still_syncing = syncing || (total.zero? && has_creds)
    render json: { syncing: still_syncing, total_products: total, total_categories: total_cats }
  end

  # Endpoint HTML: tabla de productos para actualización sin recarga
  def dashboard_products
    setup_products_vars
    @docs       = @account.reply_ai_documents.index_by(&:reference_id)
    @pv_docs    = @account.reply_ai_pv_documents.index_by(&:reference_id)
    @docs_count    = @account.reply_ai_documents.group(:reference_id).count
    @pv_docs_count = @account.reply_ai_pv_documents.group(:reference_id).count
    render partial: 'products_table', layout: false
  end

  def pv_dashboard_products
    setup_products_vars
    @docs       = @account.reply_ai_documents.index_by(&:reference_id)
    @pv_docs    = @account.reply_ai_pv_documents.index_by(&:reference_id)
    @docs_count    = @account.reply_ai_documents.group(:reference_id).count
    @pv_docs_count = @account.reply_ai_pv_documents.group(:reference_id).count
    render partial: 'products_table', locals: { rag_partial: 'pv_doc_row', tab_param: 'pv-prods' }, layout: false
  end

  # PASO 4: "Ir a mis chats" — verifica token firmado, obtiene SSO token vía Platform API y redirige a Chatwoot ya logueado
  def go_to_chats
    account_id = verify_account_token(params[:t])
    unless account_id
      redirect_to reply_ai_signup_path and return
    end

    account = Account.find_by(id: account_id)
    unless account
      redirect_to reply_ai_signup_path and return
    end

    user = account.users.where.not(email: ENV.fetch('SYSTEM_ADMIN_EMAIL')).first
    unless user
      redirect_to reply_ai_signup_path and return
    end

    login_res  = RestClient.get(
      "#{internal_base}/platform/api/v1/users/#{user.id}/login",
      { 'api_access_token' => ENV.fetch('CHATWOOT_PLATFORM_TOKEN'), accept: :json }
    )
    login_data = JSON.parse(login_res.body)
    sso_params = URI.decode_www_form(URI.parse(login_data['url']).query).to_h
    target     = ERB::Util.url_encode("/app/accounts/#{account.id}/conversations")

    redirect_to "#{public_base}/app/login?#{sso_params.to_query}&redirect_url=#{target}", allow_other_host: true
  rescue => e
    Rails.logger.error("go_to_chats error: #{e.message}")
    redirect_to "#{public_base}/app/login", allow_other_host: true
  end

  def update_settings
    attrs = (@account.custom_attributes || {}).deep_dup
    attrs['config']['prompts']                   = params[:prompts].permit!.to_h
    attrs['config']['shipping_instructions']     = params[:shipping_instructions].permit!.to_h
    attrs['config']['chatGPTEnabled']            = params[:chat_gpt_enabled] == '1'
    attrs['config']['response_delay']          ||= { 'enabled' => true, 'seconds' => 60 }
    attrs['config']['response_delay']['seconds'] = params[:delay_seconds].to_i
    # Aviso de despacho ME1
    ps = params[:post_sale] || {}
    attrs['config']['post_sale'] = {
      'enabled' => ps[:enabled] == '1',
      'message' => ps[:message].to_s.strip
    }
    # Programación Horaria
    attrs['config']['scheduledMode'] = sanitize_schedule(params[:schedule])

    # Control de confianza pre-venta (2026-08-08): retener respuestas sin información suficiente.
    attrs['config']['requireRagOrConfidence'] = params[:require_rag_or_confidence] == '1'
    conf_cats = params[:confidence_categories]
    attrs['config']['confidenceByCategory']   = (conf_cats.is_a?(ActionController::Parameters) ? conf_cats.to_unsafe_h : (conf_cats || {})).transform_values { |v| v == '1' }

    # Automatización de reclamos (Fase 2) — reglas deterministas + modo supervisado
    auto = params[:automatizacion_reclamos] || {}
    attrs['config']['automatizacion_reclamos'] = {
      'enabled'                     => auto[:enabled] == '1',
      'autoEnviarEvidenciaPNR'      => auto[:auto_enviar_evidencia_pnr] == '1',
      'autoAceptarDevolucionPDD'    => auto[:auto_aceptar_devolucion_pdd] == '1',
      'autoReembolsoParcial'        => auto[:auto_reembolso_parcial] == '1',
      'autoAprobarDevolucionSimple' => auto[:auto_aprobar_devolucion_simple] == '1',
      'montoMaximoAuto'             => auto[:monto_maximo_auto].to_f,
      'montoMaximoDevolucionAuto'   => auto[:monto_maximo_devolucion_auto].to_f,
      'modoAgenteSupervisado'       => auto[:modo_agente_supervisado] == '1',
      'tiposExcluidos'              => auto[:tipos_excluidos].to_s.split(',').map(&:strip).reject(&:empty?),
      'delayRespuesta'              => auto[:delay_respuesta].to_i
    }
    @account.update_columns(custom_attributes: attrs)
    redirect_to reply_ai_dashboard_path, notice: 'Configuración guardada.'
  end

  # Endpoint para n8n: ¿debe el bot responder ahora?
  # Auth: x-internal-secret header (igual que rag_search)
  # GET /bot_active?account_id=X
  def bot_active
    secret = request.headers['x-internal-secret'] || params[:internal_secret]
    unless secret == ENV.fetch('INTERNAL_API_SECRET', nil)
      render json: { error: 'No autorizado' }, status: :unauthorized and return
    end

    account = Account.find_by(id: params[:account_id])
    return render json: { active: false, reason: 'account_not_found' } unless account

    config = account.custom_attributes&.dig('config') || {}
    scope  = params[:scope].to_s == 'postventa' ? :postventa : :preventa

    enabled = if scope == :postventa
                config.dig('post_venta_ia', 'enabled') != false
              else
                config['chatGPTEnabled']
              end
    unless enabled
      return render json: { active: false, reason: 'globally_disabled' }
    end

    schedule = if scope == :postventa
                 config.dig('post_venta_ia', 'scheduledMode').presence || config['scheduledMode'] || {}
               else
                 config['scheduledMode'] || {}
               end
    unless schedule['enabled']
      return render json: { active: true, reason: 'no_schedule' }
    end

    active = bot_active_for_schedule?(schedule)
    render json: { active: active, reason: active ? 'schedule_active' : 'schedule_inactive' }
  end

  # Endpoint para n8n post-venta: ¿debe la IA responder en esta conversación?
  # Verifica: assigned_to_human, label 'atencion-humana', status resolved, bot global off.
  # Auth: x-internal-secret | POST /conversation_ai_gate
  # Body: { account_id, conversation_id, conversation_type (optional) }
  def conversation_ai_gate
    secret = request.headers['x-internal-secret'] || params[:internal_secret]
    unless secret == ENV.fetch('INTERNAL_API_SECRET', nil)
      render json: { error: 'No autorizado' }, status: :unauthorized and return
    end

    account = Account.find_by(id: params[:account_id])
    return render json: { should_respond: false, reason: 'account_not_found' } unless account

    config = account.custom_attributes&.dig('config') || {}

    # conversation_type puede venir como param directo (POST body) para evitar
    # depender de la DB cuando la conversación fue creada en otra instancia
    conversation_type = params[:conversation_type].presence

    conversation = account.conversations.find_by(id: params[:conversation_id])

    if conversation
      return render json: { should_respond: false, reason: 'conversation_resolved' } if conversation.resolved?
      return render json: { should_respond: false, reason: 'assigned_to_human' } if conversation.assignee_id.present?

      labels = conversation.label_list
      return render json: { should_respond: false, reason: 'human_handover_label', labels: labels } if labels.include?('atencion-humana')

      conversation_type ||= conversation.additional_attributes&.dig('type')
    else
      # La conversación fue creada en esta misma ejecución del workflow;
      # si no está en la DB local todavía (lag de replicación o instancia diferente)
      # confiamos en el tipo enviado por el workflow.
      Rails.logger.warn "conversation_ai_gate: conversation #{params[:conversation_id]} not found in DB, using params context"
      labels = []
    end

    is_postsale = conversation_type == 'post-venta'

    if is_postsale
      pv_ia = config['post_venta_ia'] || {}
      unless pv_ia.fetch('enabled', true)
        return render json: { should_respond: false, reason: 'postsale_ia_disabled' }
      end
    else
      unless config['chatGPTEnabled']
        return render json: { should_respond: false, reason: 'globally_disabled' }
      end

      pv_ia = {}
    end

    render json: { should_respond: true, reason: 'ok', labels: labels, pv_ia: pv_ia }
  rescue StandardError => e
    Rails.logger.error "conversation_ai_gate error: #{e.message}"
    render json: { should_respond: true, reason: 'error_fail_open' }
  end

  # n8n: actualiza el estado de un mensaje de Chatwoot (ticks delivered/read) y persiste
  # el `ml_message_id` de ML en `content_attributes` para el sync de lectura (match exacto).
  # Auth: x-internal-secret | POST /api/bridge/message-status
  # Body: { account_id, message_id, status, ml_message_id? }
  def bridge_message_status
    secret = request.headers['x-internal-secret'] || params[:internal_secret]
    unless secret == ENV.fetch('INTERNAL_API_SECRET', nil)
      return render json: { error: 'No autorizado' }, status: :unauthorized
    end

    message = Message.where(account_id: params[:account_id]).find_by(id: params[:message_id])
    return render json: { error: 'Message not found' }, status: :not_found unless message

    status = params[:status].to_s
    return render json: { error: 'Invalid status' }, status: :unprocessable_entity unless Message.statuses.key?(status)

    attrs = { status: status }
    if params[:ml_message_id].present?
      content_attributes = (message.content_attributes || {}).merge('ml_message_id' => params[:ml_message_id].to_s)
      attrs[:content_attributes] = content_attributes
    end
    message.update!(attrs)
    render json: { ok: true, message_id: message.id, status: message.status }
  end

  # n8n: sincroniza el estado de lectura de una conversación post-venta con ML — marca los
  # mensajes del comprador como leídos (el comprador ve "Visto") y PATCH a `read` los del
  # vendedor con `message_date.read` en ML (burbuja ✓✓ azul). Rama nativa/bridge.
  # Auth: x-internal-secret | POST /api/bridge/sync-conversation-reads
  # Body: { account_id, conversation_id }  (conversation_id = display_id)
  def bridge_sync_conversation_reads
    secret = request.headers['x-internal-secret'] || params[:internal_secret]
    unless secret == ENV.fetch('INTERNAL_API_SECRET', nil)
      return render json: { error: 'No autorizado' }, status: :unauthorized
    end

    account = Account.find_by(id: params[:account_id])
    return render json: { error: 'account_not_found' }, status: :not_found unless account

    conversation = account.conversations.find_by(display_id: params[:conversation_id])
    return render json: { error: 'conversation_not_found' }, status: :not_found unless conversation

    result = ReplyAi::MessageReadSync.perform(account, conversation, mark_as_read: true)
    render json: { ok: true }.merge(result)
  end

  def destroy_document
    doc = @account.reply_ai_documents.find(params[:id])
    doc.file.purge if doc.file.attached?
    doc.destroy!
    redirect_to reply_ai_dashboard_path, notice: 'Documento eliminado.'
  end

  def destroy_document_ajax
    doc = @account.reply_ai_documents.find(params[:id])
    doc.file.purge if doc.file.attached?
    doc.destroy!
    render json: { ok: true }
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def pv_destroy_document_ajax
    doc = @account.reply_ai_pv_documents.find(params[:id])
    doc.file.purge if doc.file.attached?
    doc.destroy!
    render json: { ok: true }
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def product_docs_list
    mode   = params[:mode].to_s
    ref_id = params[:reference_id].to_s
    @product_docs = if mode == 'pv'
                     @account.reply_ai_pv_documents.where(reference_id: ref_id).order(created_at: :desc)
                   else
                     @account.reply_ai_documents.where(reference_id: ref_id).order(created_at: :desc)
                   end
    @mode  = mode
    @reference_id = ref_id
    @product_title = params[:title].to_s
    render partial: 'product_docs_list', layout: false
  end

  # RAG: Búsqueda semántica sobre documentos del account
  # Llamado desde n8n antes de armar el prompt del AI Agent
  # Parámetros: account_id, query, item_id (opcional), category_id (opcional)
  # Auth: api_access_token header o param
  def rag_search
    query       = params[:query].to_s.strip
    item_id     = params[:item_id].to_s.presence
    category_id = params[:category_id].to_s.presence

    return render json: { error: 'query requerido' }, status: :unprocessable_entity if query.blank?

    embedding = openai_embedding(query)

    # Construir la lista completa de IDs relevantes resolviendo la jerarquía:
    # product → sub-category → category (parent) → global
    reference_ids = ['global']
    if category_id.present?
      reference_ids << category_id
      parent = MeliCategory.find_by(account_id: @account.id, meli_category_id: category_id)
      reference_ids << parent.parent_id if parent&.parent_id.present?
    end
    reference_ids << item_id if item_id.present?

    docs = ReplyAiDocument.search_for(
      account_id:    @account.id,
      embedding:     embedding,
      reference_ids: reference_ids
    )

    context = docs.map(&:content).join("\n---\n")

    render json: {
      context:    context,
      doc_count:  docs.size,
      doc_ids:    docs.map(&:id)
    }
  rescue StandardError => e
    Rails.logger.error "RAG search error: #{e.message}"
    render json: { context: '', doc_count: 0, error: e.message }, status: :ok
  end

  # Guardar saludo personalizado por tienda oficial (PATCH /dashboard/stores/:store_id/greeting)
  def update_store_greeting
    store = MeliOfficialStore.find_by(id: params[:store_id], account_id: @account.id)
    return render json: { error: 'Tienda no encontrada' }, status: :not_found unless store

    store.update!(custom_greeting: params[:greeting].presence)
    render json: { ok: true }
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # Refrescar tiendas oficiales desde ML en segundo plano (POST /dashboard/stores/refresh)
  def refresh_official_stores
    ReplyAi::MeliSyncOfficialStoresWorker.perform_async(@account.id)
    render json: { ok: true, message: 'Sincronización iniciada' }
  end

  # Forzar refresco de access tokens de MercadoLibre AHORA (GET /dashboard/refresh-tokens)
  def refresh_tokens
    credentials = @account.meli_credentials.where.not(refresh_token: nil)
    results = []

    credentials.each do |cred|
      begin
        worker = ReplyAi::TokenRefreshWorker.new
        worker.send(:refresh_meli_token, cred)
        cred.reload
        results << { id: cred.id, status: cred.status, expira: cred.expires_at, token_preview: cred.access_token&.first(25) }
      rescue => e
        results << { id: cred.id, error: e.message }
      end
    end

    render json: { ok: true, credentials: results }
  end

  # PASO 5: Subir documento de entrenamiento RAG
  def upload_document
    file = params[:file]
    return redirect_to reply_ai_dashboard_path, alert: 'No seleccionaste archivo' if file.nil?

    doc = @account.reply_ai_documents.find_or_initialize_by(reference_id: params[:reference_id])
    doc.assign_attributes(level: params[:level], file_name: file.original_filename)
    doc.file.attach(io: file, filename: file.original_filename, content_type: file.content_type)
    doc.save!

    ReplyAi::DocumentProcessorWorker.perform_async(doc.id)

    redirect_to reply_ai_dashboard_path, notice: 'Archivo recibido, procesando en segundo plano...'
  end

  # ─────────────────── RAG Post-venta ───────────────────

  def pv_upload_document
    file = params[:file]
    return redirect_to reply_ai_dashboard_path(panel: 'panel-postventa-docs'), alert: 'No seleccionaste archivo' if file.nil?

    doc = @account.reply_ai_pv_documents.find_or_initialize_by(reference_id: params[:reference_id])
    doc.assign_attributes(level: params[:level], file_name: file.original_filename)
    doc.file.attach(io: file, filename: file.original_filename, content_type: file.content_type)
    doc.save!

    ReplyAi::PvDocumentProcessorWorker.perform_async(doc.id)

    redirect_to reply_ai_dashboard_path(panel: 'panel-postventa-docs'), notice: 'Archivo recibido, procesando en segundo plano...'
  end

  def pv_destroy_document
    doc = @account.reply_ai_pv_documents.find(params[:id])
    doc.file.purge if doc.file.attached?
    doc.destroy!
    redirect_to reply_ai_dashboard_path(panel: 'panel-postventa-docs'), notice: 'Documento eliminado.'
  end

  # ── Migración RAG desde Yobot (Supabase) — perfil MIGRADO (2026-08-08) ──
  # Importa los documentos RAG de Yobot (chunks de Supabase, 1 fila por chunk) a Reply y
  # regenera los embeddings con ada-002 vía el webhook n8n. También dispara el sync de
  # productos (el catálogo alimenta el dashboard por reference_id).
  def migrate_rag_pre
    ReplyAi::YobotRagMigrator.perform_async(@account.id, 'pre')
    ReplyAi::MeliSyncProductsWorker.perform_async(@account.id)
    redirect_to reply_ai_dashboard_path(tab: 'preventa', sub: 'docs'), notice: 'Importación de documentos de Yobot (pre-venta) iniciada.'
  end

  def migrate_rag_post
    ReplyAi::YobotRagMigrator.perform_async(@account.id, 'post')
    ReplyAi::MeliSyncProductsWorker.perform_async(@account.id)
    redirect_to reply_ai_dashboard_path(tab: 'postventa', sub: 'docs'), notice: 'Importación de documentos de Yobot (post-venta) iniciada.'
  end

  # Control de confianza pre-venta: informe de preguntas retenidas (retenidas por falta
  # de información suficiente). GET /dashboard/confidence-report (JSON, panel Informes).
  def confidence_report
    rows = ActiveRecord::Base.connection.select_all(
      "SELECT question_id, cw_conversation_id, status, suggested_answer, created_at
       FROM meli_questions
       WHERE account_id = #{@account.id} AND retained_due_lack_of_info = true
       ORDER BY created_at DESC LIMIT 200"
    )

    questions = rows.map do |row|
      # cw_conversation_id se persiste con el display_id (id público) que expone la API.
      conversation = row['cw_conversation_id'] && @account.conversations.find_by(display_id: row['cw_conversation_id'])
      item_id      = conversation&.additional_attributes&.dig('ml_item_id') || conversation&.additional_attributes&.dig('item_id')
      product      = item_id.present? ? @account.meli_products.find_by(meli_item_id: item_id.to_s) : nil
      question_msg = conversation&.messages&.where(message_type: :incoming)&.order(:created_at)&.first
      {
        question_id: row['question_id'],
        conversation_id: row['cw_conversation_id'],
        question_text: question_msg&.content.to_s[0, 500],
        item_id: item_id,
        product_title: product&.title,
        suggested_answer: row['suggested_answer'],
        status: row['status'],
        created_at: row['created_at']
      }
    end

    render json: { total: questions.size, questions: questions }
  end

  def pv_rag_search
    query       = params[:query].to_s.strip
    item_id     = params[:item_id].to_s.presence
    category_id = params[:category_id].to_s.presence

    return render json: { error: 'query requerido' }, status: :unprocessable_entity if query.blank?

    embedding = openai_embedding(query)

    reference_ids = ['global']
    if category_id.present?
      reference_ids << category_id
      parent = MeliCategory.find_by(account_id: @account.id, meli_category_id: category_id)
      reference_ids << parent.parent_id if parent&.parent_id.present?
    end
    reference_ids << item_id if item_id.present?

    docs = ReplyAiPvDocument.search_for(
      account_id:    @account.id,
      embedding:     embedding,
      reference_ids: reference_ids
    )

    context = docs.map(&:content).join("\n---\n")

    render json: {
      context:   context,
      doc_count: docs.size,
      doc_ids:   docs.map(&:id)
    }
  rescue StandardError => e
    Rails.logger.error "PV RAG search error: #{e.message}"
    render json: { context: '', doc_count: 0, error: e.message }, status: :ok
  end

  # ── Importación masiva desde Excel/CSV ─────────────────────────────────────
  # PASO 1 (AJAX): recibe el archivo, persiste en tmp, devuelve las columnas detectadas.
  def bulk_import_preview
    file = params[:file]
    return render json: { error: 'No seleccionaste archivo' }, status: :bad_request if file.nil?

    ext = File.extname(file.original_filename).downcase
    return render json: { error: 'Formato no soportado. Usá CSV o XLSX.' }, status: :unprocessable_entity unless %w[.csv .xlsx .xls].include?(ext)

    token = SecureRandom.hex(16)
    FileUtils.mkdir_p(bulk_import_tmp_dir)
    dest = File.join(bulk_import_tmp_dir, "#{token}#{ext}")
    File.binwrite(dest, file.read)

    columns = extract_file_columns(dest, ext)
    sample  = extract_sample_rows(dest, ext)
    render json: { token: token, columns: columns, filename: file.original_filename, sample_rows: sample }
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # PASO 2 (submit): lanza el worker en background.
  # Params: token, item_id_col, content_cols (array), mode ('pre' o 'pv')
  def bulk_import
    token        = params[:token].to_s.strip
    item_id_col  = params[:item_id_col].to_s.strip
    content_cols = Array(params[:content_cols]).map(&:to_s).reject(&:blank?)
    mode         = params[:mode].to_s == 'pv' ? 'pv' : 'pre'

    if token.blank? || item_id_col.blank? || content_cols.empty?
      return redirect_to reply_ai_dashboard_path, alert: 'Configuración inválida. Revisá los campos requeridos.'
    end

    path = Dir.glob(File.join(bulk_import_tmp_dir, "#{token}.*")).first
    return redirect_to reply_ai_dashboard_path, alert: 'Sesión expirada. Volvé a subir el archivo.' if path.nil?

    ReplyAi::BulkImportWorker.perform_async(@account.id, path, item_id_col, content_cols, mode)
    destination = if mode == 'pv'
                    reply_ai_dashboard_path(tab: 'postventa', sub: 'docs')
                  else
                    reply_ai_dashboard_path(panel: 'panel-bulk-import')
                  end
    redirect_to destination, notice: 'Importación iniciada. Los documentos se procesarán en segundo plano.'
  end

  # ======== BRIDGE YOBOT ↔ REPLY-AI ========

  # Yobot consulta si un seller está bridgeado (el switch)
  def bridge_seller_status
    credential = MeliCredential.find_by(ml_user_id: params[:ml_user_id])
    if credential&.bridge_enabled?
      render json: {
        bridged: true,
        ml_user_id: credential.ml_user_id,
        account_id: credential.account_id,
        status: credential.status
      }
    else
      render json: { bridged: false, ml_user_id: params[:ml_user_id] }
    end
  end

  # Yobot registra un seller nuevo para bridge
  def bridge_register
    ml_user_id = params[:ml_user_id].to_s.strip
    return render json: { error: 'ml_user_id requerido' }, status: :unprocessable_entity if ml_user_id.blank?
    return render json: { error: 'Ya existe una credencial para este seller' }, status: :conflict if MeliCredential.exists?(ml_user_id: ml_user_id)

    platform_token = ENV.fetch('CHATWOOT_PLATFORM_TOKEN')
    account_name   = params[:nickname].presence || "ML Seller #{ml_user_id}"
    user_email     = params[:email].presence || "bridge-#{ml_user_id}@reply-ai.internal"
    # Cumple las reglas de complejidad de Chatwoot (mayúscula + especial + largo)
    user_password  = "Reply#{SecureRandom.hex(10)}!Aa1"

    account_res = RestClient.post(
      "#{internal_base}/platform/api/v1/accounts",
      { name: account_name }.to_json,
      { 'api_access_token' => platform_token, content_type: :json, accept: :json }
    )
    account_data = JSON.parse(account_res.body)

    user_res = RestClient.post(
      "#{internal_base}/platform/api/v1/users",
      { name: account_name, email: user_email, password: user_password }.to_json,
      { 'api_access_token' => platform_token, content_type: :json, accept: :json }
    )
    user_data = JSON.parse(user_res.body)

    RestClient.post(
      "#{internal_base}/platform/api/v1/accounts/#{account_data['id']}/account_users",
      { user_id: user_data['id'], role: 'administrator' }.to_json,
      { 'api_access_token' => platform_token, content_type: :json, accept: :json }
    )

    account = Account.find(account_data['id'])
    account.update_columns(
      limits: { 'agents' => 3, 'inboxes' => 5 },
      custom_attributes: default_reply_ai_config.merge(ENV['REPLY_RECEIVE_ONLY'] == 'true' ? { 'receive_only' => true } : {})
    )

    real_user = User.find(user_data['id'])
    real_user_token = real_user.access_token&.token
    # Misma infraestructura que las cuentas nativas: equipos, inboxes, labels y webhooks
    setup_account_channels(account, real_user.id, real_user_token) if real_user_token

    MeliCredential.create!(
      account: account,
      ml_user_id: ml_user_id,
      access_token: params[:access_token].to_s,
      refresh_token: params[:refresh_token].to_s,
      expires_at: params[:expires_at].presence,
      status: 'bridge',
      bridge_enabled: true
    )

    # Sync inicial de la configuración del seller desde Yobot (prompts, delays, schedules,
    # saludos por tienda, automatización de reclamos) — ver BridgeConfigMapper.
    ReplyAi::BridgeConfigSyncWorker.perform_async(account.id) rescue nil

    render json: {
      account_id: account.id,
      user_email: user_email,
      user_password: user_password,
      ml_user_id: ml_user_id,
      status: 'bridge'
    }, status: :created
  rescue RestClient::Exception => e
    Rails.logger.error "bridge_register error: #{e.message}"
    render json: { error: "Error creando cuenta bridge: #{e.message}" }, status: :internal_server_error
  end

  # Yobot forwardea una pregunta de ML → Reply-AI la procesa.
  # Idempotente: si la pregunta ya tiene conversación (Yobot puede re-forwardear la
  # misma notificación), se reusa y solo se agrega el mensaje si no está.
  def bridge_question
    find_bridge_account
    return if performed?

    question = params[:question] || {}
    item     = params[:item] || {}
    buyer    = params[:buyer] || {}

    contact = @account.contacts.find_or_initialize_by(
      identifier: "ml_buyer_#{buyer['id']}"
    )
    contact.update!(name: buyer['nickname'].presence || "ML Buyer #{buyer['id']}")

    inbox = @account.inboxes.find_by(name: 'Pre-venta (MercadoLibre)')
    unless inbox
      return render json: { error: 'Inbox pre-venta no encontrado' }, status: :internal_server_error
    end

    contact_inbox = contact.contact_inboxes.find_or_initialize_by(inbox: inbox)
    contact_inbox.source_id ||= "mlq_#{question['_id'] || question['id']}"
    contact_inbox.save!

    conversation = @account.conversations
                            .where("additional_attributes->>'ml_question_id' = ?", question['id'].to_s)
                            .order(created_at: :desc).first
    reused = !conversation.nil?

    if conversation.nil?
      conversation = @account.conversations.create!(
        inbox: inbox,
        contact: contact,
        contact_inbox: contact_inbox,
        status: 'open',
        additional_attributes: {
          ml_question_id: question['id'].to_s,
          ml_item_id: item['id'].to_s,
          ml_buyer_id: buyer['id'].to_s
        }
      )
    else
      conversation.update!(status: 'open') if conversation.resolved?
    end

    message = conversation.messages
                          .where(message_type: :incoming, private: false)
                          .where(content: question['text'].to_s)
                          .order(created_at: :desc).first
    message_existed = !message.nil?

    if message.nil?
      message = conversation.messages.create!(
        content: question['text'].to_s,
        message_type: :incoming,
        sender: contact,
        account: @account,
        inbox: inbox
      )
    end

    # Re-forward duplicado (Yobot reenvía la misma notificación): no reprocesar.
    if reused && message_existed
      return render json: { conversation_id: conversation.display_id, conversation_db_id: conversation.id, message_id: message.id, status: 'already_processed' }
    end

    # La notificación nativa de ML (doble registro de apps en el piloto) pudo insertar la
    # idempotencia antes y "consumir" la pregunta con datos incompletos. El forward bridge
    # es la fuente autoritativa para cuentas bridge: se limpia la fila stale para que el
    # flujo n8n procese la pregunta completa (nota privada + IA).
    question_key = (question['_id'] || question['id']).to_s
    ActiveRecord::Base.connection.execute("DELETE FROM meli_questions WHERE question_id = #{ActiveRecord::Base.connection.quote(question_key)}")

    webhook_url = ENV.fetch('N8N_QUESTIONS_WEBHOOK_URL', 'https://n8nn.w1206-app.site/webhook/9979f346-6abc-46d1-a3e6-12db669f1b37')
    RestClient.post(webhook_url, {
      event: 'bridge_question',
      topic: 'questions',
      resource: params[:resource],
      user_id: params[:ml_user_id],
      contact_id: contact.id,
      conversation_id: conversation.display_id,
      conversation_db_id: conversation.id,
      account_id: @account.id,
      message_id: message.id,
      ml_user_id: params[:ml_user_id],
      access_token: params[:access_token],
      _id: question['id'],
      question: question,
      item: item,
      buyer: buyer
    }.to_json, { content_type: :json, accept: :json }) rescue nil

    render json: {
      conversation_id: conversation.display_id,
      conversation_db_id: conversation.id,
      message_id: message.id,
      status: 'processing'
    }
  rescue StandardError => e
    Rails.logger.error "bridge_question error: #{e.message}"
    render json: { error: e.message }, status: :internal_server_error
  end

  # Yobot forwardea un mensaje post-venta de ML (forward completo: message + order +
  # shipment + conversation_status + pack_id + attachments).
  def bridge_message
    find_bridge_account
    return if performed?

    message = params[:message] || {}
    order   = params[:order] || {}
    shipment = params[:shipment] || {}

    ml_order_id = params[:pack_id].presence || params[:sale_id].presence || order['id'].to_s.presence
    order_db = if ml_order_id.present?
                 first_item = order.dig('order_items')&.first
                 MeliOrder.find_or_initialize_by(account: @account, ml_order_id: ml_order_id).tap do |o|
                   o.assign_attributes(
                     ml_buyer_id: order.dig('buyer', 'id'),
                     buyer_nickname: order.dig('buyer', 'nickname'),
                     item_id: first_item&.dig('item', 'id'),
                     item_title: first_item&.dig('item', 'title'),
                     quantity: first_item&.dig('quantity'),
                     total_amount: order['total_amount'],
                     currency_id: order['currency_id'],
                     pack_id: params[:pack_id],
                     order_status: order['status'],
                     date_created: order['date_created']
                   )
                   o.save! if o.changed?
                 end
               else
                 Rails.logger.warn "[bridge_message] cuenta=#{@account.id}: sin pack_id/order en el forward — orden no registrada"
                 nil
               end

    webhook_url = ENV.fetch('N8N_POSTSALE_WEBHOOK_URL', 'https://n8nn.w1206-app.site/webhook/chatwoot-postsale')
    RestClient.post(webhook_url, {
      event: 'bridge_message',
      topic: 'messages',
      resource: params[:resource],
      user_id: params[:ml_user_id],
      _id: message['id'],
      account_id: @account.id,
      ml_user_id: params[:ml_user_id],
      access_token: params[:access_token],
      pack_id: params[:pack_id],
      message: message,
      order: order,
      shipment: shipment,
      conversation_status: params[:conversation_status],
      attachments: params[:attachments],
      order_db_id: order_db&.id
    }.to_json, { content_type: :json, accept: :json }) rescue nil

    render json: { order_id: order_db&.id, status: 'processing' }
  rescue StandardError => e
    Rails.logger.error "bridge_message error: #{e.message}"
    render json: { error: e.message }, status: :internal_server_error
  end

  # Yobot forwardea una orden nueva de ML
  def bridge_order
    find_bridge_account
    return if performed?

    order = MeliOrder.find_or_initialize_by(
      account: @account,
      ml_order_id: params.dig(:order, 'id')
    )
    first_item = params.dig(:order, 'order_items')&.first
    order.assign_attributes(
      ml_buyer_id: params.dig(:order, 'buyer', 'id'),
      buyer_nickname: params.dig(:order, 'buyer', 'nickname'),
      item_id: first_item&.dig('item', 'id'),
      item_title: first_item&.dig('item', 'title'),
      quantity: first_item&.dig('quantity'),
      total_amount: params.dig(:order, 'total_amount'),
      currency_id: params.dig(:order, 'currency_id'),
      order_status: params.dig(:order, 'status'),
      date_created: params.dig(:order, 'date_created')
    )
    order.save! if order.changed?

    # Dispara orders_main en n8n para el mensaje post-venta inicial (bridge-aware:
    # usa body.order del forward; con el envelope actual degrada con error claro hasta
    # que Yobot forwardee la orden completa — ver docs/REQUERIMIENTOS_YOBOT.md).
    webhook_url = ENV.fetch('N8N_WEBHOOK_URL', 'https://n8nn.w1206-app.site/webhook/9979f346-6abc-46d1-a3e6-12db669f1b37')
    RestClient.post(webhook_url, {
      event: 'bridge_order',
      topic: 'orders_v2',
      ml_user_id: params[:ml_user_id],
      access_token: params[:access_token],
      order: params[:order]
    }.to_json, { content_type: :json, accept: :json }) rescue nil

    render json: { order_id: order.id, status: 'saved' }
  rescue StandardError => e
    Rails.logger.error "bridge_order error: #{e.message}"
    render json: { error: e.message }, status: :internal_server_error
  end
  # Yobot forwardea un reclamo de ML (bridge): la notificación llega a Yobot y este
  # la reenvía a Reply-AI. `resource` = claim id de ML.
  # Reply NO consulta la API de ML para cuentas bridge: completa el claim vía
  # BridgeApi (get_claim), espeja los mensajes (get_messages) y evalúa la
  # automatización/agente (que ejecutan acciones vía execute-claim-action).
  def bridge_claim
    find_bridge_account
    return if performed?

    claim_id = params[:resource].to_s.presence || params[:claim_id].to_s
    return render json: { error: 'resource/claim_id requerido' }, status: :unprocessable_entity if claim_id.blank?

    claim = @account.meli_claims.find_or_initialize_by(claim_id: claim_id)
    claim_data = params[:claim_data].is_a?(ActionController::Parameters) ? params[:claim_data].to_unsafe_h : params[:claim_data]
    if claim_data.is_a?(Hash)
      claim.raw_data = claim_data
      claim.status   = claim_data['status'] if claim_data['status'].present?
      claim.stage    = claim_data['stage'] if claim_data['stage'].present?
    end
    claim.save!

    begin
      # Datos autoritativos de ML vía bridge (get_claim) → upsert completo
      full = ReplyAi::MeliApi.for(@account).claim(claim_id)
      claim = upsert_claim(@account, full) if full.is_a?(Hash) && full['id'].present?
    rescue ReplyAi::MeliApi::Error => e
      Rails.logger.warn "[bridge_claim] get_claim falló (#{e.message}) — claim mínimo conservado"
    end

    conv_id = refresh_claim_labels(@account, claim)
    mirror_claim_messages(@account, claim, conv_id)
    process_claim_event(@account, claim)

    render json: { status: 'ok', claim_db_id: claim.id, ml_claim_id: claim.claim_id }
  rescue StandardError => e
    Rails.logger.error "[bridge_claim] error: #{e.class} #{e.message}"
    render json: { error: e.message }, status: :internal_server_error
  end

  # Yobot notifica que un humano respondió manualmente (desde Yobot o Chatwoot).
  # Reply registra una nota privada en la conversación correspondiente (pre-venta por
  # question_id, post-venta por pack_id) para auditoría del flujo bridgeado.
  def bridge_manual_response
    find_bridge_account
    return if performed?

    question_id = params[:question_id].to_s.presence
    pack_id     = params[:pack_id].to_s.presence
    text        = params[:text].to_s.presence

    conversation = if question_id.present?
                     @account.conversations
                             .where("additional_attributes->>'ml_question_id' = ?", question_id)
                             .order(created_at: :desc).first
                   elsif pack_id.present?
                     @account.conversations
                             .where('source_id = ? OR additional_attributes->>\'pack_id\' = ?', pack_id, pack_id)
                             .order(created_at: :desc).first
                   end

    if conversation && text
      reply_agent = ensure_reply_agent_user
      conversation.messages.create!(
        content: "Respuesta manual registrada (Yobot): #{text}",
        message_type: :outgoing,
        private: true,
        user: reply_agent,
        account: @account,
        inbox: conversation.inbox,
        conversation: conversation
      )
    else
      Rails.logger.warn "[bridge_manual_response] cuenta=#{@account.id}: conversación no encontrada (question_id=#{question_id.inspect} pack_id=#{pack_id.inspect})"
    end

    render json: { status: 'acknowledged' }
  rescue StandardError => e
    Rails.logger.error "bridge_manual_response error: #{e.class} #{e.message}"
    render json: { error: e.message }, status: :internal_server_error
  end

  # Firma HMAC-SHA256 para el bridge — los Code nodes de n8n 2.x NO pueden usar
  # require('crypto') ("Module 'crypto' is disallowed"), así que delegan la firma
  # aquí (auth: X-Bridge-Secret == BRIDGE_SECRET; se firma el string exacto a enviar).
  def bridge_sign
    return render json: { error: 'No autorizado' }, status: :unauthorized unless request.headers['X-Bridge-Secret'] == ENV['BRIDGE_SECRET']

    render json: { signature: OpenSSL::HMAC.hexdigest('SHA256', ENV['BRIDGE_SECRET'].to_s, params[:body].to_s) }
  end

  # Vista compacta para la Dashboard App de Chatwoot (iframe en el sidebar de la
  # conversación del reclamo). Resuelve el reclamo por conversation_id o claim_id.
  def claim_panel
    @claim = resolve_panel_claim
  end

  # JSON para la Dashboard App "Reclamo ML": el iframe recibe conversation.id por
  # postMessage (appContext) y resuelve el reclamo de esa conversación.
  def claim_panel_data
    claim = resolve_panel_claim
    return render json: { error: 'Reclamo no encontrado para esta conversación' }, status: :not_found unless claim

    render json: claim_summary(claim).merge(
      raw_data: claim.raw_data,
      agent_log: claim.agent_log || [],
      pending_action: claim.pending_action
    )
  end

  def resolve_panel_claim
    if params[:conversation_id].present?
      cid = params[:conversation_id]
      # Chatwoot entrega conversation.id = display_id (postMessage appContext); fallback
      # por id interno para datos guardados antes del fix (2026-08-09).
      claim = @account.meli_claims.find_by(cw_conversation_id: cid)
      return claim if claim

      conv = @account.conversations.find_by(display_id: cid) || @account.conversations.find_by(id: cid)
      if conv
        # Las conversaciones del inbox de reclamos (ML nativo) llevan el claim_id en
        # contact_inbox.source_id; las de API/post-venta no — ahí se vincula por conversación.
        source_id = conv.contact_inbox&.source_id.to_s
        claim_by_source = @account.meli_claims.find_by(claim_id: source_id)
        return claim_by_source if claim_by_source

        return @account.meli_claims.find_by(cw_conversation_id: conv.id)
      end
    end
    @account.meli_claims.find_by(id: params[:claim_id])
  end

  # ======== RECLAMOS / DEVOLUCIONES / CAMBIOS (Fase 2) ========

  # Webhook de ML (topics: claims, claims_actions) — SOLO para cuentas nativas.
  # Los reclamos de sellers bridgeados entran por POST /api/bridge/claim.
  def claims_webhook
    user_id = params[:user_id].to_s
    resource = params[:resource].to_s
    return head :unprocessable_entity if user_id.blank? || resource.blank?

    credential = MeliCredential.find_by(ml_user_id: user_id)
    return head :not_found unless credential

    if credential.bridge?
      Rails.logger.warn "[claims_webhook] seller bridgeado #{user_id}: los reclamos bridge entran por /api/bridge/claim"
      return render json: { status: 'ok', ignored: true }
    end

    account = credential.account
    data = ReplyAi::MeliApi.new(account).claim(resource)
    claim = upsert_claim(account, data)
    process_claim_event(account, claim)
    refresh_claim_labels(account, claim)
    mirror_claim_messages(account, claim, claim.cw_conversation_id)

    render json: { status: 'ok', claim_id: claim.id }
  rescue ReplyAi::MeliApi::Error => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # Sincroniza reclamos abiertos desde ML (botón UI / signup / activación)
  def claims_sync
    credential = @account.meli_credentials.where(status: %w[active bridge]).order(:id).first
    return render json: { error: 'Sin credenciales de MercadoLibre' }, status: :unprocessable_entity unless credential

    api = ReplyAi::MeliApi.for(@account)
    result = api.search_claims(credential.ml_user_id)
    claims = result.is_a?(Array) ? result : (result['results'] || [])
    count = 0
    claims.each do |data|
      claim = upsert_claim(@account, data)
      process_claim_event(@account, claim, enqueue_agent: false)
      count += 1
    end
    render json: { ok: true, sincronizados: count }
  rescue ReplyAi::MeliApi::Error => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # Vista principal del dashboard de reclamos
  def claims_index
    @claims = @account.meli_claims.order(updated_at: :desc).limit(200)
    @claims_pendientes = @account.meli_claims.pendientes.count
    render 'claims'
  end

  # JSON para la tabla (AJAX / polling)
  def claims_list
    claims = @account.meli_claims.order(updated_at: :desc).limit(200)
    render json: claims.map { |c| claim_summary(c) }
  end

  def claim_detail
    claim = set_claim
    render json: claim_summary(claim).merge(
      raw_data: claim.raw_data,
      agent_log: claim.agent_log || [],
      pending_action: claim.pending_action
    )
  end

  def claim_messages
    claim = set_claim
    render json: meli_api_for.claim_messages(claim.claim_id)
  rescue ReplyAi::MeliApi::Error => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def claim_evidences
    claim = set_claim
    render json: meli_api_for.claim_evidences(claim.claim_id)
  rescue ReplyAi::MeliApi::Error => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def claim_send_message
    claim = set_claim
    text = params[:text].to_s
    return render json: { error: 'Texto requerido' }, status: :unprocessable_entity if text.blank?

    result = meli_api_for.send_claim_message(claim.claim_id, text)
    render json: { ok: true, result: result }
  rescue ReplyAi::MeliApi::Error => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def claim_send_evidence
    claim = set_claim
    api = meli_api_for
    if params[:file].present?
      uploaded = params[:file]
      result = api.upload_claim_evidence(claim.claim_id, file: uploaded.tempfile, filename: uploaded.original_filename.to_s.gsub(/\s+/, '_'), content_type: uploaded.content_type.to_s)
    else
      body = JSON.parse(params[:content].to_s) rescue {}
      result = api.add_claim_evidence(claim.claim_id, body)
    end
    render json: { ok: true, result: result }
  rescue ReplyAi::MeliApi::Error => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def claim_refund
    claim = set_claim
    result = meli_api_for.claim_refund(claim.claim_id)
    claim.update!(agent_status: 'done')
    render json: { ok: true, result: result }
  rescue ReplyAi::MeliApi::Error => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def claim_partial_refund
    claim = set_claim
    offer = meli_api_for.claim_available_offers(claim.claim_id)
    offers = offer.is_a?(Hash) ? offer['offers'] : offer
    chosen = Array(offers).min_by { |o| o['amount'].to_f }
    return render json: { error: 'Sin ofertas disponibles' }, status: :unprocessable_entity unless chosen

    result = meli_api_for.claim_partial_refund(claim.claim_id, reason_id: chosen['reason_id'], amount: chosen['amount'])
    render json: { ok: true, result: result }
  rescue ReplyAi::MeliApi::Error => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def claim_available_offers
    claim = set_claim
    render json: meli_api_for.claim_available_offers(claim.claim_id)
  rescue ReplyAi::MeliApi::Error => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def claim_allow_return
    claim = set_claim
    result = meli_api_for.claim_allow_return(claim.claim_id)
    claim.update!(agent_status: 'done')
    render json: { ok: true, result: result }
  rescue ReplyAi::MeliApi::Error => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def claim_open_dispute
    claim = set_claim
    result = meli_api_for.claim_open_mediation(claim.claim_id)
    render json: { ok: true, result: result }
  rescue ReplyAi::MeliApi::Error => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def claim_affects_reputation
    claim = set_claim
    render json: meli_api_for.claim_affects_reputation(claim.claim_id)
  rescue ReplyAi::MeliApi::Error => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def claim_agent_pending
    claim = set_claim
    render json: { pending: claim.pending_action, agent_status: claim.agent_status }
  end

  def claim_agent_execute
    claim = set_claim
    return if performed?
    result = ReplyAi::ClaimAgentWorker.execute_pending!(claim.id, @account.id)
    refresh_claim_labels(@account, claim)
    render json: result.is_a?(Hash) && result.key?(:error) ? { error: result[:error] } : { ok: true, result: result }
  end

  def claim_agent_cancel
    claim = set_claim
    return if performed?
    result = ReplyAi::ClaimAgentWorker.cancel_pending!(claim.id, @account.id)
    refresh_claim_labels(@account, claim)
    render json: result
  end

  def claim_agent_rerun
    claim = set_claim
    return if performed?
    claim.update!(pending_action: nil, agent_status: 'idle')
    refresh_claim_labels(@account, claim)
    ReplyAi::ClaimAgentWorker.perform_async(claim.id, @account.id)
    render json: { ok: true }
  end

  # ==== Devoluciones ====
  def return_detail
    claim = set_claim(return_key: true)
    render json: meli_api_for.return_detail(claim.claim_id)
  rescue ReplyAi::MeliApi::Error => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def return_review
    claim = set_claim(return_key: true)
    status = params[:status].to_s
    return render json: { error: 'Estado requerido' }, status: :unprocessable_entity if status.blank?

    result = meli_api_for.return_review(params[:id], status: status)
    render json: { ok: true, result: result }
  rescue ReplyAi::MeliApi::Error => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def return_reasons
    claim = set_claim(return_key: true)
    render json: meli_api_for.return_reasons(claim.claim_id)
  rescue ReplyAi::MeliApi::Error => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def return_cost
    claim = set_claim(return_key: true)
    render json: meli_api_for.return_cost(claim.claim_id)
  rescue ReplyAi::MeliApi::Error => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # ==== Cambios ====
  def change_detail
    claim = set_claim(return_key: true)
    render json: meli_api_for.change_detail(claim.claim_id)
  rescue ReplyAi::MeliApi::Error => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def change_allow_replace
    claim = set_claim(return_key: true)
    result = meli_api_for.change_allow_replace(claim.claim_id)
    render json: { ok: true, result: result }
  rescue ReplyAi::MeliApi::Error => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # ── Ventas post-venta (tabla del dashboard + Dashboard App "Venta ML", 2026-08-08) ──
  # JSON para la sub-pestaña "Ventas": lista las órdenes con el detalle de la venta
  # (producto, comprador, total, estado) + preguntas pre-venta relacionadas
  # (conversaciones del mismo item + buyer → link directo a la conversación).
  def sales_list
    orders = @account.meli_orders.order(created_at: :desc).limit(200)
    render json: orders.map { |o| sale_summary(o) }
  end

  # Detalle de una venta para el panel embebido (Dashboard App "Venta ML").
  def sale_detail
    order = set_sale
    render json: sale_summary(order).merge(
      messages: order.cw_conversation_id.present? ? postsale_conversation_messages(order.cw_conversation_id) : []
    )
  end

  # Vista compacta para la Dashboard App de Chatwoot (iframe en el sidebar de la
  # conversación post-venta). Resuelve la venta por conversation_id (id interno
  # que persiste n8n en meli_orders.cw_conversation_id) o por pack_id de la
  # conversación.
  def sale_panel
    @order = resolve_panel_sale
  end

  # JSON para la Dashboard App "Venta ML": resuelve la venta por conversation_id
  # (el iframe no puede sustituir {{conversation.id}} — el contexto llega por
  # postMessage appContext y la vista consulta este endpoint).
  def sale_panel_data
    order = resolve_panel_sale
    return render json: { error: 'Venta no encontrada' }, status: :not_found unless order

    payload = sale_summary(order).merge(
      messages: order.cw_conversation_id.present? ? postsale_conversation_messages(order.cw_conversation_id) : []
    )
    # Datos frescos de ML (order + shipment) — best-effort, si falla se omite.
    order_ml = fetch_order_ml(order)
    shipment_ml = fetch_shipment_ml(order, order_ml)
    payload[:order_ml] = order_ml
    payload[:shipment_ml] = shipment_ml
    # Secciones normalizadas para la vista (siempre presentes, con fallback a lo local).
    payload[:buyer] = buyer_section(order, order_ml)
    payload[:payment] = payment_section(order, order_ml)
    payload[:shipment] = shipment_section(order, order_ml, shipment_ml)
    payload[:item_detail] = item_detail_section(order, order_ml)
    render json: payload
  end

  # Vista compacta para la Dashboard App "Producto ML": el iframe no puede sustituir
  # {{conversation.id}} → el contexto llega por postMessage y la vista consulta el JSON.
  def product_panel
    @item_id = params[:item_id]
  end

  # JSON del producto: ML directo (nativo/MIGRADO) o catálogo local + permade (bridge).
  def product_panel_data
    item_id = params[:item_id].to_s
    # El iframe de la Dashboard App solo conoce conversation.id (postMessage appContext):
    # resolver la venta de esa conversación y tomar su item; si es pre-venta (sin venta),
    # el item vive en additional_attributes de la conversación.
    if item_id.blank? && params[:conversation_id].present?
      order = resolve_panel_sale
      item_id = order&.item_id.to_s
      if item_id.blank?
        cid = params[:conversation_id]
        conv = @account.conversations.find_by(display_id: cid) || @account.conversations.find_by(id: cid)
        item_id = conv&.additional_attributes&.dig('ml_item_id').to_s if conv
        item_id = conv.additional_attributes&.dig('item_id').to_s if item_id.blank? && conv
      end
    end
    return render json: { error: 'item_id requerido' }, status: :unprocessable_entity if item_id.blank?

    api = meli_api_for
    if api.is_a?(ReplyAi::BridgeApi)
      # Bridge: sin contrato get_item → catálogo local sincronizado + permalink público.
      product = @account.meli_products.find_by(meli_item_id: item_id)
      return render json: { error: 'Producto no encontrado en el catálogo', item_id: item_id }, status: :not_found unless product

      return render json: product_panel_summary(
        item: product.raw_data || product.attributes_data || {},
        local: {
          id: product.meli_item_id,
          title: product.title,
          thumbnail: product.thumbnail,
          price: product.price,
          currency_id: product.currency_id,
          condition: product.condition,
          permalink: product.permalink
        }
      )
    end

    begin
      item = api.item(item_id)
      description = begin
                      api.item_description(item_id)['plain_text']
                    rescue StandardError
                      nil
                    end
      render json: product_panel_summary(item: item, description: description)
    rescue ReplyAi::MeliApi::Error => e
      render json: { error: e.message, item_id: item_id }, status: :unprocessable_entity
    end
  end

  def product_panel_summary(item:, description: nil, local: nil)
    source = local || item
    {
      id: source['id'] || source[:id],
      title: source['title'] || source[:title],
      permalink: source['permalink'] || source[:permalink],
      thumbnail: source['thumbnail'] || source[:secure_thumbnail],
      price: source['price'] || source[:price],
      currency_id: source['currency_id'] || source[:currency_id],
      condition: source['condition'] || source[:condition],
      category_id: source['category_id'] || source[:category_id],
      available_quantity: source['available_quantity'] || source[:available_quantity],
      sold_quantity: source['sold_quantity'] || source[:sold_quantity],
      warranty: source['warranty'] || source[:warranty],
      shipping: source['shipping'] || source[:shipping],
      attributes: source['attributes'] || [],
      pictures: source['pictures'] || [],
      description: description
    }
  end

  private

  def fetch_order_ml(order)
    return nil if order.ml_order_id.blank?

    api = meli_api_for
    return nil if api.is_a?(ReplyAi::BridgeApi)

    api.order(order.ml_order_id)
  rescue ReplyAi::MeliApi::Error
    nil
  end

  def fetch_shipment_ml(order, order_ml)
    shipment_id = order_ml&.dig('shipping', 'id')
    return nil if shipment_id.blank?

    api = meli_api_for
    return nil if api.is_a?(ReplyAi::BridgeApi)

    api.shipment(shipment_id)
  rescue ReplyAi::MeliApi::Error
    nil
  end

  # ── Secciones normalizadas del panel Venta ML (2026-08-09) ──────────────
  # Prefieren los datos frescos de ML y caen al registro local (meli_orders).

  def buyer_section(order, order_ml)
    buyer = order_ml&.dig('buyer') || {}
    {
      id: buyer['id'] || order.ml_buyer_id,
      nickname: buyer['nickname'] || order.buyer_nickname,
      first_name: buyer['first_name'],
      last_name: buyer['last_name']
    }.compact
  end

  def payment_section(order, order_ml)
    payment = Array(order_ml&.dig('payments')).first || {}
    currency = payment['currency_id'] || order_ml&.dig('currency_id') || order.currency_id
    {
      method: payment['payment_method_id'],
      type: payment['payment_type'],
      installments: payment['installments'],
      status: payment['status'],
      status_detail: payment['status_detail'],
      amount: payment['transaction_amount'],
      refunded: payment['transaction_amount_refunded'],
      currency_id: currency,
      date_approved: payment['date_approved'],
      operation_type: payment['operation_type']
    }.compact
  end

  def shipment_section(order, order_ml, shipment_ml)
    receiver = shipment_ml&.dig('receiver_address') || {}
    {
      id: shipment_ml&.dig('id'),
      tracking_number: shipment_ml&.dig('tracking_number'),
      tracking_method: shipment_ml&.dig('tracking_method'),
      mode: shipment_ml&.dig('mode'),
      logistic_type: shipment_ml&.dig('logistic_type'),
      status: shipment_ml&.dig('status'),
      substatus: shipment_ml&.dig('substatus'),
      date_created: shipment_ml&.dig('date_created'),
      date_first_printed: shipment_ml&.dig('date_first_printed'),
      date_shipped: shipment_ml&.dig('status_history', 'date_shipped'),
      date_delivered: shipment_ml&.dig('status_history', 'date_delivered'),
      receiver_name: receiver['receiver_name'],
      address_line: receiver['address_line'],
      street_name: receiver['street_name'],
      city: receiver.dig('city', 'name'),
      state: receiver.dig('state', 'name'),
      zip_code: receiver['zip_code'],
      country: receiver.dig('country', 'name'),
      estimated_delivery: shipment_ml&.dig('shipping_option', 'estimated_delivery_final', 'date')
    }.compact
  end

  def item_detail_section(order, order_ml)
    item = Array(order_ml&.dig('order_items')).first || {}
    item_data = item['item'] || {}
    {
      id: item_data['id'] || order.item_id,
      title: item_data['title'] || order.item_title,
      quantity: item['quantity'] || order.quantity,
      unit_price: item['unit_price'],
      sale_fee: item['sale_fee'],
      category_id: item_data['category_id']
    }.compact
  end

  def set_claim(return_key: false)
    claim = @account.meli_claims.find_by(id: params[:id])
    unless claim
      render json: { error: 'Reclamo no encontrado' }, status: :not_found
      return nil
    end
    claim
  end

  def meli_api_for
    ReplyAi::MeliApi.for(@account)
  end

  # Activa con REPLY_RECEIVE_ONLY=true (env) + cuenta marcada receive_only (se setea
  # automáticamente en bridge_register durante la ventana de testing).
  def receive_only?(account)
    ENV['REPLY_RECEIVE_ONLY'] == 'true' && account.custom_attributes.to_h['receive_only'] == true
  end

  def reject_receive_only_write
    return unless receive_only?(@account)

    render json: { receive_only: true, accion_bloqueada: true,
                   mensaje: 'Modo recepción: acción bloqueada (no se envía a ML/Yobot). El flujo se ingesta en Chatwoot para revisión.' },
           status: :ok
  end

  def upsert_claim(account, data)
    attrs = ReplyAi::ClaimMapper.map(data, account.id)
    claim = account.meli_claims.find_or_initialize_by(claim_id: attrs[:claim_id])
    was_new = claim.new_record?
    claim.assign_attributes(attrs)
    changes = claim.changes.slice('status', 'stage', 'reason_id')
    claim.save!
    if was_new
      claim.registrar_evento_timeline!('webhook', 'Reclamo detectado')
    else
      changes.each do |attr, (before, after)|
        next if before == after
        claim.registrar_evento_timeline!('webhook', "#{attr.humanize}: #{before || '—'} → #{after || '—'}")
      end
    end
    claim
  end

  # Vincula la orden, bloquea/desbloquea mensajería por dispute y dispara la automatización.
  # Las cuentas bridge NO ejecutan automatización/agente (requieren ML, que se gestiona
  # vía Yobot — ver docs/REQUERIMIENTOS_YOBOT.md).
  def process_claim_event(account, claim, enqueue_agent: true)
    order = MeliOrder.find_by(account_id: account.id, ml_order_id: claim.resource_id.to_s)
    claim.update!(sale_id: order.id) if order && claim.sale_id != order.id

    if claim.dispute? && order
      order.bloquear!('claim_dispute')
    elsif !claim.dispute? && order && order.estado_conversacion == 'bloqueada' && order.blocked_substatus == 'claim_dispute'
      order.reabrir!
    end

    return unless enqueue_agent

    automation = ReplyAi::ClaimAutomation.new(account, claim)
    return unless automation.enabled?

    decision = automation.evaluar
    if decision.is_a?(Hash)
      if receive_only?(account)
        claim.update!(agent_log: (claim.agent_log || []) + [{ 'tipo' => 'automatizacion_receive_only', 'action' => decision[:action], 'resultado' => 'no ejecutado (modo recepción)' }])
        return
      end
      result = automation.ejecutar(decision)
      claim.update!(agent_log: (claim.agent_log || []) + [{ 'tipo' => 'automatizacion', 'action' => decision[:action], 'resultado' => result }])
      claim.update!(agent_status: 'done') if result && result[:ok]
    else
      return if receive_only?(account)
      ReplyAi::ClaimAgentWorker.perform_async(claim.id, account.id)
    end
  end

  # Aplica etiquetas de reclamo + conversación del reclamo + etiqueta de la conversación
  # post-venta vinculada. Cierre manual: el reclamo se cierra cuando ML lo cierra (status=closed);
  # la conversación la resuelve el agente a mano (sin auto-resolve).
  def refresh_claim_labels(account, claim)
    conv_id = ensure_claim_conversation(account, claim)
    apply_claim_labels(account, conv_id, claim)
    label_postsale_conversation(account, claim)
    conv_id
  rescue StandardError => e
    Rails.logger.warn "[refresh_claim_labels] #{e.class} #{e.message}"
    nil
  end

  # 1 conversación = 1 reclamo en el inbox "Reclamos (MercadoLibre)".
  # El source_id del reclamo vive en el ContactInbox (Chatwoot 4.15: conversations
  # no tiene columna source_id; el matching es por contact_inbox.source_id).
  def ensure_claim_conversation(account, claim)
    inbox = account.inboxes.find_by(name: 'Reclamos (MercadoLibre)')
    return nil unless inbox

    if claim.cw_conversation_id.present?
      conv = account.conversations.find_by(id: claim.cw_conversation_id)
      return conv&.id
    end

    contact = find_or_create_claim_contact(account, claim)
    return nil unless contact

    contact_inbox = contact.contact_inboxes.find_or_initialize_by(inbox: inbox)
    contact_inbox.source_id = claim.claim_id.to_s if contact_inbox.source_id.blank?
    contact_inbox.save!

    conv = account.conversations.find_by(contact_inbox_id: contact_inbox.id)
    conv ||= account.conversations.create!(
      inbox: inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      status: 'open',
      additional_attributes: { type: 'reclamo', claim_id: claim.claim_id.to_s }
    )
    claim.update_columns(cw_conversation_id: conv.id)
    conv.id
  end

  def find_or_create_claim_contact(account, claim)
    buyer = claim_buyer(claim)
    identifier = buyer[:id].present? ? "ml_buyer_#{buyer[:id]}" : "ml_claim_#{claim.claim_id}"
    contact = account.contacts.find_or_initialize_by(identifier: identifier)
    contact.name ||= buyer[:nickname].presence || (buyer[:id].present? ? "ML Buyer #{buyer[:id]}" : "ML Reclamo #{claim.claim_id}")
    contact.save!
    contact
  end

  # Comprador del reclamo: player complainant del claim, o el comprador de la orden vinculada.
  def claim_buyer(claim)
    data = claim.raw_data.is_a?(Hash) ? claim.raw_data : {}
    complainant = Array(data['players']).find { |p| p['role'] == 'complainant' }
    if complainant
      return { id: complainant['user_id'], nickname: complainant['nickname'] }
    end

    order = claim.orden
    order ? { id: order.ml_buyer_id, nickname: nil } : {}
  end

  def claim_contact(account, claim)
    buyer = claim_buyer(claim)
    identifier = buyer[:id].present? ? "ml_buyer_#{buyer[:id]}" : "ml_claim_#{claim.claim_id}"
    account.contacts.find_by(identifier: identifier)
  end

  # Labels de la conversación del reclamo (replace: es nuestra conversación).
  def apply_claim_labels(account, conversation_id, claim)
    return unless conversation_id

    desired = []
    if claim.status == 'closed'
      desired << 'reclamo-cerrado'
    else
      desired << 'reclamo-abierto'
      desired << 'reclamo-mediacion' if claim.dispute?
    end
    desired << 'reclamo-pendiente-accion' if claim.pending_action.present?

    conv = account.conversations.find_by(id: conversation_id)
    conv&.update_labels(desired)
  rescue StandardError => e
    Rails.logger.warn "[apply_claim_labels] #{e.message}"
  end

  # Etiqueta la conversación post-venta vinculada preservando sus labels existentes.
  def label_postsale_conversation(account, claim)
    conv = find_postsale_conversation(account, claim)
    return unless conv

    labels = conv.labels
    labels = if claim.status == 'closed'
               labels - %w[reclamo-abierto reclamo-mediacion] + ['reclamo-cerrado']
             else
               (labels + ['reclamo-abierto'] + (claim.dispute? ? ['reclamo-mediacion'] : [])).uniq
             end
    conv.update_labels(labels)
  rescue StandardError => e
    Rails.logger.warn "[label_postsale] #{e.message}"
  end

  def find_postsale_conversation(account, claim)
    order = claim.orden
    return nil unless order

    if order.cw_conversation_id.present?
      return account.conversations.find_by(id: order.cw_conversation_id)
    end

    contact = claim_contact(account, claim)
    return nil unless contact

    pack_id = order.pack_id.to_s
    inbox_id = account.inboxes.find_by(name: 'Post-venta (MercadoLibre)')&.id
    return nil if pack_id.blank? || inbox_id.blank?

    # Matching por contact_inbox.source_id (como lo hace n8n con meta.source_id)
    contact_inbox_ids = contact.contact_inboxes.where(inbox_id: inbox_id, source_id: pack_id).pluck(:id)
    conv = contact.conversations.where(contact_inbox_id: contact_inbox_ids).first
    conv || contact.conversations.find do |c|
      c.inbox_id == inbox_id && c.additional_attributes&.dig('pack_id').to_s == pack_id
    end
  end

  # Refleja los mensajes del reclamo en la conversación de Chatwoot (dedupe por ml_message_id).
  # Solo nativo: para bridge queda pendiente execute-claim-action get_messages (Yobot).
  def mirror_claim_messages(account, claim, conversation_id)
    return unless conversation_id

    messages = ReplyAi::MeliApi.for(account).claim_messages(claim.claim_id)
    list = messages.is_a?(Array) ? messages : (messages['messages'] || [])
    conv = account.conversations.find_by(id: conversation_id)
    return unless conv

    conv.update!(status: 'open') if conv.resolved?

    existing_ids = conv.messages
                       .where("content_attributes->>'ml_message_id' IS NOT NULL")
                       .pluck(Arel.sql("content_attributes->>'ml_message_id'"))
    reply_agent = ensure_reply_agent_user
    list.each do |m|
      mid = m['id'].to_s
      next if mid.blank? || existing_ids.include?(mid)

      conv.messages.create!(
        content: m['text'].to_s,
        message_type: m['from_seller'] ? :outgoing : :incoming,
        sender: m['from_seller'] ? nil : conv.contact,
        user: reply_agent,
        account: account,
        inbox: conv.inbox,
        conversation: conv,
        content_attributes: { ml_message_id: mid, source: 'ml_claim' }
      )
    end
  rescue ReplyAi::MeliApi::Error => e
    Rails.logger.warn "[mirror_claim_messages] #{e.message}"
  end

  def claim_summary(claim)
    {
      id: claim.id,
      claim_id: claim.claim_id,
      claim_type: claim.claim_type,
      stage: claim.stage,
      status: claim.status,
      reason_id: claim.reason_id,
      resource: claim.resource,
      resource_id: claim.resource_id,
      affects_reputation: claim.affects_reputation,
      pending_action: claim.pending_action,
      agent_status: claim.agent_status,
      sale_id: claim.sale_id,
      timeline: claim.timeline || [],
      updated_at: claim.updated_at,
      created_at: claim.created_at,
      order: claim.orden && { ml_order_id: claim.orden.ml_order_id, item_id: claim.orden.item_id, estado_conversacion: claim.orden.estado_conversacion }
    }
  end

  # ── Ventas post-venta (tabla del dashboard, 2026-08-08) ──────────────
  def sale_summary(order)
    question_conv = order_pv_questions_conversation(order)
    {
      id: order.id,
      ml_order_id: order.ml_order_id,
      pack_id: order.pack_id,
      item_id: order.item_id,
      item_title: order.item_title,
      buyer_nickname: order.buyer_nickname,
      ml_buyer_id: order.ml_buyer_id,
      total_amount: order.total_amount&.to_s,
      currency_id: order.currency_id,
      quantity: order.quantity,
      order_status: order.order_status,
      estado_conversacion: order.estado_conversacion,
      date_created: order.date_created,
      created_at: order.created_at,
      cw_conversation_id: order.cw_conversation_id,
      questions: {
        count: question_conv ? 1 : 0,
        conversation_display_id: question_conv&.display_id
      }
    }
  end

  # Conversación pre-venta del mismo item + buyer (todas las que existan; la más
  # reciente es la que se linkea). Equivalente Reply del cruce de Yobot
  # (Question.find({item_id, 'from.id': buyer.id})).
  def order_pv_questions_conversation(order)
    return nil if order.item_id.blank?

    convs = @account.conversations
                    .where("additional_attributes->>'ml_item_id' = ?", order.item_id.to_s)
    convs = convs.where("additional_attributes->>'ml_buyer_id' = ?", order.ml_buyer_id.to_s) if order.ml_buyer_id.present?
    convs.order(created_at: :desc).first
  end

  def set_sale
    order = @account.meli_orders.find_by(id: params[:id])
    return render json: { error: 'Venta no encontrada' }, status: :not_found unless order

    order
  end

  def resolve_panel_sale
    if params[:conversation_id].present?
      cid = params[:conversation_id]
      # Chatwoot entrega conversation.id = display_id (postMessage appContext); fallback
      # por id interno para datos guardados antes del fix (2026-08-09).
      order = @account.meli_orders.find_by(cw_conversation_id: cid)
      return order if order

      conv = @account.conversations.find_by(display_id: cid) || @account.conversations.find_by(id: cid)
      return nil unless conv

      pack_id = conv.additional_attributes&.dig('pack_id').to_s
      return @account.meli_orders.find_by(pack_id: pack_id) if pack_id.present?
    end
    @account.meli_orders.find_by(id: params[:sale_id])
  end

  def postsale_conversation_messages(conversation_id)
    conv = @account.conversations.find_by(display_id: conversation_id) || @account.conversations.find_by(id: conversation_id)
    return [] unless conv

    conv.messages.order(created_at: :asc).limit(100).map do |m|
      {
        id: m.id,
        content: m.content,
        message_type: m.message_type,
        private: m.private,
        created_at: m.created_at,
        sender: m.sender&.name
      }
    end
  end

  def set_account_from_token
    secret = request.headers['x-internal-secret'] || params[:internal_secret]
    unless secret == ENV.fetch('INTERNAL_API_SECRET', nil)
      render json: { error: 'No autorizado' }, status: :unauthorized and return
    end
    @account = Account.find_by(id: params[:account_id])
    unless @account
      render json: { error: 'Cuenta no encontrada' }, status: :not_found and return
    end
  end

  def openai_embedding(text)
    api_key = ENV.fetch('OPENAI_API_KEY') { raise 'OPENAI_API_KEY no configurada' }
    uri = URI('https://api.openai.com/v1/embeddings')
    req = Net::HTTP::Post.new(uri)
    req['Authorization'] = "Bearer #{api_key}"
    req['Content-Type']  = 'application/json'
    req.body = JSON.generate(model: 'text-embedding-ada-002', input: text)

    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(req) }
    raise "OpenAI embeddings error: #{res.code} #{res.body}" unless res.is_a?(Net::HTTPSuccess)

    JSON.parse(res.body).dig('data', 0, 'embedding')
  end

  # Encuentra o crea silenciosamente el usuario agente común reply-ai.
  # Skip de confirmación para evitar envío de emails.
  def ensure_reply_agent_user
    email = ENV.fetch('REPLY_AGENT_EMAIL', 'usuario-reply@replylatam.com')
    User.find_by(email: email) || begin
      # Crear vía Platform API: igual que el shadow user, garantiza access_token y registro formal
      res = RestClient.post(
        "#{internal_base}/platform/api/v1/users",
        {
          name:     ENV.fetch('REPLY_AGENT_NAME',     'reply usuario'),
          email:    email,
          password: ENV.fetch('REPLY_AGENT_PASSWORD')
        }.to_json,
        { 'api_access_token' => ENV.fetch('CHATWOOT_PLATFORM_TOKEN'), content_type: :json, accept: :json }
      )
      User.find(JSON.parse(res.body)['id'])
    end
  rescue StandardError => e
    Rails.logger.error "ensure_reply_agent_user: #{e.message}"
    nil
  end

  def set_account
    # Usamos warden directamente: evita que devise_token_auth limpie la sesión
    # antes de que podamos verificarla
    user = warden.user(:user)
    unless user
      redirect_to reply_ai_signup_path and return
    end

    # Si viene account_id en el parámetro, intentar usarlo
    if params[:account_id].present?
      requested = Account.find_by(id: params[:account_id])
      if requested
        # SuperAdmin puede acceder a cualquier cuenta sin tener account_user
        is_super_admin = user.type == 'SuperAdmin'
        # Administrador de cuenta: verificar membresía formal
        has_access = is_super_admin || user.account_ids.include?(requested.id)
        if has_access
          @account = requested
          return
        end
      end
    end

    # Fallback: primera cuenta disponible excluyendo las de la cuenta de sistema
    system_account_ids = User.find_by(email: ENV.fetch('SYSTEM_ADMIN_EMAIL', ''))&.account_ids || []
    @account = user.accounts.where.not(id: system_account_ids).first || user.accounts.first
  end

  def setup_dashboard_vars
    @attrs         = @account.custom_attributes || {}
    @config        = @attrs['config'] || {}
    @prompts               = @config['prompts'] || {}
    @shipping_instructions = @config['shipping_instructions'] || {}
    @post_sale             = @config['post_sale'] || {}
    @pv_ia                 = @config['post_venta_ia'] || {}
    @automatizacion_reclamos = @config['automatizacion_reclamos'] || {}
    @schedule              = @config['scheduledMode'] || {}
    @bot_enabled   = @config['chatGPTEnabled']
    @delay_seconds = @config.dig('response_delay', 'seconds') || 60
    # Control de confianza pre-venta (2026-08-08): retención por falta de información.
    @require_rag_or_confidence = @config['requireRagOrConfidence'] == true
    @confidence_by_category    = @config['confidenceByCategory'] || {}

    # Token firmado con account_id, válido 2 horas, no requiere sesión Rails
    @magic_link_to_chats = go_to_chats_path(t: signed_account_token(@account.id))

    # RAG Data: syncing si el flag está activo, O si no hay productos pero sí hay credenciales ML
    has_credentials = MeliCredential.where(account_id: @account.id, status: 'active').exists?
    @is_syncing = @attrs['syncing_products'] == true || (@account.meli_products.empty? && has_credentials)
    setup_products_vars

    @master_categories = @account.meli_categories.where(level: 'master')
    @sub_categories    = @account.meli_categories.where(level: 'sub')

    # Tiendas oficiales MercadoLibre
    @official_stores = MeliOfficialStore.for_account(@account.id)
    @default_greeting = @prompts['saludoGeneral'].to_s

    # Mapa de documentos para saber qué tiene cada cosa
    @docs       = @account.reply_ai_documents.index_by(&:reference_id)
    @pv_docs    = @account.reply_ai_pv_documents.index_by(&:reference_id)
    @docs_count    = @account.reply_ai_documents.group(:reference_id).count
    @pv_docs_count = @account.reply_ai_pv_documents.group(:reference_id).count
  end

  def setup_products_vars
    @q        = params[:q].to_s.strip
    @sort_col = %w[title status price condition].include?(params[:sort]) ? params[:sort] : 'title'
    @sort_dir = params[:dir] == 'desc' ? 'desc' : 'asc'
    @page     = [params[:page].to_i, 1].max
    @per_page = 25

    products_scope = @account.meli_products
    products_scope = products_scope.where('title ILIKE ? OR meli_item_id ILIKE ?', "%#{@q}%", "%#{@q}%") if @q.present?
    products_scope = products_scope.order(@sort_col => @sort_dir)

    @total_products = products_scope.count
    @total_pages    = [(@total_products / @per_page.to_f).ceil, 1].max
    @page           = [@page, @total_pages].min
    @products       = products_scope.offset((@page - 1) * @per_page).limit(@per_page)
  end

  def signed_account_token(account_id)
    ActiveSupport::MessageVerifier.new(Rails.application.secret_key_base)
                                  .generate(account_id, expires_in: 2.hours)
  end

  def verify_account_token(token)
    return nil if token.blank?
    ActiveSupport::MessageVerifier.new(Rails.application.secret_key_base)
                                  .verify(token)
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    nil
  end

  # Evalúa si el bot debe estar activo según la programación horaria.
  # Prioridad: override de fecha > franjas del día de la semana > inactivo.
  # Sanea el parámetro de programación horaria (mismo formato para pre-venta y post-venta).
  # Params: { enabled, timezone, days_json, overrides_json } → { enabled, timezone, days, overrides }
  def sanitize_schedule(raw)
    sch = raw || {}
    tz = sch[:timezone].to_s.strip
    tz = 'America/Argentina/Buenos_Aires' unless VALID_TIMEZONES.include?(tz)

    begin; days_data      = JSON.parse(sch[:days_json].to_s);      rescue; days_data      = {}; end
    begin; overrides_data = JSON.parse(sch[:overrides_json].to_s); rescue; overrides_data = {}; end

    sanitized_days = {}
    (0..6).each do |d|
      slots = days_data[d.to_s]
      next unless slots.is_a?(Array)

      clean = slots.filter_map do |s|
        st = s['start'].to_s; en = s['end'].to_s
        next unless st.match?(/\A([01]\d|2[0-3]):[0-5]\d\z/) && en.match?(/\A([01]\d|2[0-3]):[0-5]\d\z/)
        { 'start' => st, 'end' => en, 'active' => s['active'] == true }
      end
      sanitized_days[d.to_s] = clean if clean.any?
    end

    sanitized_overrides = {}
    overrides_data.each do |date_str, val|
      next unless date_str.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)
      next unless val.is_a?(Hash) && %w[always_on always_off].include?(val['mode'])
      sanitized_overrides[date_str] = { 'mode' => val['mode'] }
    end

    {
      'enabled'   => sch[:enabled] == '1',
      'timezone'  => tz,
      'days'      => sanitized_days,
      'overrides' => sanitized_overrides
    }
  end

  def bot_active_for_schedule?(schedule)
    tz_name = schedule['timezone'].presence || 'America/Argentina/Buenos_Aires'
    tz      = TZInfo::Timezone.get(tz_name)
    now     = tz.now

    # 1. Chequear override de fecha (máxima prioridad)
    today_str = now.strftime('%Y-%m-%d')
    override  = (schedule['overrides'] || {})[today_str]
    if override.is_a?(Hash)
      case override['mode']
      when 'always_on'  then return true
      when 'always_off' then return false
      end
    end

    # 2. Buscar entre las franjas del día de semana actual
    slots     = (schedule['days'] || {})[now.wday.to_s]
    current_m = now.hour * 60 + now.min
    active_from_slots(slots, current_m)
  rescue => e
    Rails.logger.error("Schedule check error: #{e.message}")
    true # fail-open: ante error el bot responde
  end

  # Busca el primer slot que cubra current_m y retorna su estado activo.
  # Los slots son extremos inclusivos (HH:MM→HH:MM). No se soportan overnight
  # en slots individuales; para cubrir la medianoche usá dos slots:
  # 18:00→23:59 y 00:00→08:00.
  def active_from_slots(slots, current_m)
    return false unless slots.is_a?(Array)
    slots.each do |s|
      sh, sm = s['start'].to_s.split(':').map(&:to_i)
      eh, em = s['end'].to_s.split(':').map(&:to_i)
      start_m = sh * 60 + sm
      end_m   = eh * 60 + em
      return s['active'] == true if current_m >= start_m && current_m <= end_m
    end
    false # ningún slot cubre la hora actual → inactivo
  end

  VALID_TIMEZONES = %w[
    America/Argentina/Buenos_Aires
    America/Santiago
    America/Lima
    America/Bogota
    America/Caracas
    America/Mexico_City
    America/Montevideo
    America/Sao_Paulo
    America/New_York
    America/Los_Angeles
    Europe/Madrid
    UTC
  ].freeze

  def internal_base
    'http://localhost:3000'
  end

  def public_base
    ENV.fetch('FRONTEND_URL').gsub(%r{/$}, '')
  end

  def ml_auth_url(account_id)
    "https://auth.mercadolibre.com/authorization?response_type=code" \
      "&client_id=#{ENV.fetch('ML_APP_ID')}" \
      "&redirect_uri=#{ENV.fetch('ML_REDIRECT_URI')}" \
      "&state=#{account_id}"
  end

  # Crea la infraestructura de canales de una cuenta nueva (nativa o bridge):
  # equipos, bandejas de entrada, labels y webhooks. Compartido entre
  # create_account (signup) y bridge_register (sellers de Yobot).
  def setup_account_channels(account, user_id, user_token)
    return if user_token.blank?

    ['Pre-Venta', 'Post-Venta'].each do |team_name|
      team_res = RestClient.post(
        "#{internal_base}/api/v1/accounts/#{account.id}/teams",
        { name: team_name }.to_json,
        { api_access_token: user_token, content_type: :json, accept: :json }
      )
      team_id = JSON.parse(team_res.body)['id']
      RestClient.post(
        "#{internal_base}/api/v1/accounts/#{account.id}/teams/#{team_id}/team_members",
        { user_ids: [user_id] }.to_json,
        { api_access_token: user_token, content_type: :json, accept: :json }
      )
    end

    ['Pre-venta (MercadoLibre)', 'Post-venta (MercadoLibre)', 'Reclamos (MercadoLibre)'].each do |inbox_name|
      inbox_res = RestClient.post(
        "#{internal_base}/api/v1/accounts/#{account.id}/inboxes",
        { name: inbox_name, channel: { type: 'api', webhook_url: '' } }.to_json,
        { api_access_token: user_token, content_type: :json, accept: :json }
      )
      inbox_id = JSON.parse(inbox_res.body)['id']
      RestClient.post(
        "#{internal_base}/api/v1/accounts/#{account.id}/inbox_members",
        { inbox_id: inbox_id, user_ids: [user_id] }.to_json,
        { api_access_token: user_token, content_type: :json, accept: :json }
      ) rescue nil
    end

    default_labels.each do |label|
      RestClient.post(
        "#{internal_base}/api/v1/accounts/#{account.id}/labels",
        label.to_json,
        { api_access_token: user_token, content_type: :json, accept: :json }
      ) rescue nil
    end

    default_webhooks.each do |webhook|
      RestClient.post(
        "#{internal_base}/api/v1/accounts/#{account.id}/webhooks",
        { webhook: webhook }.to_json,
        { api_access_token: user_token, content_type: :json, accept: :json }
      ) rescue nil
    end

    # Dashboard App: panel de gestión del reclamo embebido en el sidebar de la
    # conversación (bandeja Reclamos). {{conversation.id}} lo resuelve Chatwoot.
    RestClient.post(
      "#{internal_base}/api/v1/accounts/#{account.id}/dashboard_apps",
      {
        title: 'Reclamo ML',
        content: [{ type: 'frame', url: "#{public_base}/dashboard/claim-panel?conversation_id={{conversation.id}}" }]
      }.to_json,
      { api_access_token: user_token, content_type: :json, accept: :json }
    ) rescue nil

    # Dashboard App: detalles de la venta embebidos en el sidebar de la conversación
    # post-venta. El contexto llega por postMessage (appContext); la URL no se sustituye.
    RestClient.post(
      "#{internal_base}/api/v1/accounts/#{account.id}/dashboard_apps",
      {
        title: 'Venta ML',
        content: [{ type: 'frame', url: "#{public_base}/dashboard/sale-panel?conversation_id={{conversation.id}}" }]
      }.to_json,
      { api_access_token: user_token, content_type: :json, accept: :json }
    ) rescue nil

    # Dashboard App: ficha del producto de la conversación (item ML). El contexto
    # llega por postMessage (appContext); el item se resuelve desde la venta.
    RestClient.post(
      "#{internal_base}/api/v1/accounts/#{account.id}/dashboard_apps",
      {
        title: 'Producto ML',
        content: [{ type: 'frame', url: "#{public_base}/dashboard/product-panel?conversation_id={{conversation.id}}" }]
      }.to_json,
      { api_access_token: user_token, content_type: :json, accept: :json }
    ) rescue nil
  end

  def default_webhooks
    [
      {
        url: ENV.fetch('N8N_WEBHOOK_URL', 'https://n8nn.w1206-app.site/webhook/4a26f4e3-6b9d-483b-b071-d0a5dc5ac441'),
        name: 'Reply-AI: Salida Manual',
        subscriptions: ['message_created']
      },
      {
        url: ENV.fetch('N8N_POSTSALE_WEBHOOK_URL', 'https://n8nn.w1206-app.site/webhook/chatwoot-postsale'),
        name: 'Reply-AI: Post-Venta IA',
        subscriptions: ['message_created']
      },
      {
        url: ENV.fetch('N8N_POSTSALE_OUTBOUND_WEBHOOK_URL', 'http://n8n-main:5678/webhook/postsale-outbound'),
        name: 'Reply-AI: Post-Venta Salida',
        subscriptions: ['message_created']
      },
      {
        url: ENV.fetch('N8N_CLAIMS_OUTBOUND_WEBHOOK_URL', 'http://n8n-main:5678/webhook/claims-outbound'),
        name: 'Reply-AI: Reclamos Salida',
        subscriptions: ['message_created']
      }
    ]
  end

  def default_labels
    [
      { title: 'esperando_respuesta_manual',          description: 'Etiqueta preguntas que deben responderse manualmente a través de un agente',                    color: '#D91337', show_on_sidebar: false },
      { title: 'esperando_tiempo_retraso_programado', description: 'Informa que se está esperando el tiempo de retraso programado para responder en mercadolibre', color: '#D9B513', show_on_sidebar: false },
      { title: 'procesando_con_ia',                  description: 'Marca la conversación como procesada con IA',                                                  color: '#5213D9', show_on_sidebar: false },
      { title: 'respondida_con_ia',                  description: 'Identifica una pregunta respondida con IA',                                                    color: '#37D913', show_on_sidebar: false },
      { title: 'respondida_manualmente',             description: 'Indica que la pregunta fue respondida por un agente humano',                                    color: '#13D9B5', show_on_sidebar: false },
      # Post-Venta IA + Humano
      { title: 'bot-procesando',                     description: 'La IA tiene el control de esta conversación post-venta',                                        color: '#7C3AED', show_on_sidebar: false  },
      { title: 'atencion-humana',                    description: 'Kill switch: la IA se desactiva y cede el control al agente humano',                           color: '#DC2626', show_on_sidebar: false  },
      { title: 'atencion-prioritaria',               description: 'Conversación con reclamo o conflicto activo que requiere intervención urgente',                 color: '#EA580C', show_on_sidebar: false  },
      { title: 'mensajeria-bloqueada',               description: 'Mensajería bloqueada por MercadoLibre (reclamo en mediación o bloqueo de ML) — la IA no responde', color: '#0D9488', show_on_sidebar: false },
      # Reclamos (bandeja Reclamos-MercadoLibre) — acciones automáticas, no se muestran en el sidebar
      { title: 'reclamo-abierto',                    description: 'Reclamo de MercadoLibre abierto en la conversación',                                          color: '#DC2626', show_on_sidebar: false },
      { title: 'reclamo-mediacion',                  description: 'Reclamo en mediación: los mensajes van a MercadoLibre, no al comprador',                        color: '#F59E0B', show_on_sidebar: false },
      { title: 'reclamo-cerrado',                    description: 'Reclamo de MercadoLibre cerrado',                                                               color: '#16A34A', show_on_sidebar: false },
      { title: 'reclamo-pendiente-accion',           description: 'El agente IA espera confirmación humana para actuar sobre el reclamo',                         color: '#7C3AED', show_on_sidebar: false },
      { title: 'reclamo-derivado',                   description: 'Reclamo derivado a un operador humano',                                                         color: '#EA580C', show_on_sidebar: false }
    ]
  end

  def default_reply_ai_config
    {
      'mercadolibre' => {
        'user' => {},
        'metrics' => { 'responses' => { 'total' => { 'response_time' => 0 } } }
      },
      'paypal' => {
        'suscription' => {
          'status' => 'TRIAL',
          'plan_id' => 'TRIAL',
          'finish_time' => (Time.now.utc + 7.days).iso8601
        }
      },
      'config' => {
        'theme' => 'light',
        'chatGPTEnabled' => true,
        'prompts' => {
          'condicionProducto' => '', 'envios' => '', 'garantia' => '',
          'mediosPago' => '', 'otros' => '', 'precio' => '', 'saludoGeneral' => ''
        },
        'scheduledMode' => {
          'enabled'   => false,
          'timezone'  => 'America/Argentina/Buenos_Aires',
          'days'      => {},
          'overrides' => {}
        },
        'response_delay' => { 'enabled' => true, 'seconds' => 60 },
        'post_venta_ia' => {
          'enabled'   => true,
          'model'     => 'gpt-4o-mini',
          'logistica' => { 'enabled' => true },
          'soporte'   => { 'enabled' => true, 'fallback_to_human' => true },
          'cierre'    => { 'enabled' => true, 'auto_resolve' => true },
          'reclamo'   => { 'notify_customer' => false },
          'prompts'   => {
            'logistica' => '', 'soporte' => '', 'cierre' => '',
            'escalacion' => '', 'tono' => ''
          }
        }
      }
    }
  end

  # ── Helpers para importación masiva ──────────────────────────────────────

  def bulk_import_tmp_dir
    Rails.root.join('tmp', 'bulk_import').to_s
  end

  # Extrae los encabezados de columna del archivo subido sin leer todas las filas.
  def extract_file_columns(path, ext)
    if ext == '.csv'
      require 'csv'
      row = CSV.open(path, 'r', headers: true, **csv_open_options(path)) { |csv| csv.first }
      row&.headers || []
    else
      require 'roo'
      xlsx  = Roo::Spreadsheet.open(path, extension: ext.delete('.').to_sym)
      sheet = xlsx.sheet(0)
      sheet.row(1).map { |h| h.to_s.strip }.reject(&:blank?)
    end
  rescue StandardError => e
    Rails.logger.error "extract_file_columns error: #{e.message}"
    []
  end

  # Extrae las primeras N filas como array de hashes para el preview.
  def extract_sample_rows(path, ext, limit: 5)
    if ext == '.csv'
      require 'csv'
      CSV.read(path, headers: true, **csv_open_options(path)).first(limit).map(&:to_h)
    else
      require 'roo'
      xlsx    = Roo::Spreadsheet.open(path, extension: ext.delete('.').to_sym)
      sheet   = xlsx.sheet(0)
      return [] if sheet.last_row.nil? || sheet.last_row < 2
      headers = sheet.row(1).map { |h| h.to_s.strip }
      (2..[sheet.last_row, limit + 1].min).map { |i| headers.zip(sheet.row(i).map(&:to_s)).to_h }
    end
  rescue StandardError => e
    Rails.logger.error "extract_sample_rows error: #{e.message}"
    []
  end

  # Detecta encoding y separador del CSV automáticamente.
  def csv_open_options(path)
    sample = File.binread(path, 4096)
    encoding = sample.dup.force_encoding('UTF-8').valid_encoding? ? 'BOM|UTF-8' : 'Windows-1252:UTF-8'
    # Decodificar la primera línea para contar separadores
    first_line = sample.encode('UTF-8', 'Windows-1252', invalid: :replace, undef: :replace).lines.first.to_s
    col_sep = first_line.count(';') >= first_line.count(',') ? ';' : ','
    { encoding: encoding, col_sep: col_sep }
  end

end

