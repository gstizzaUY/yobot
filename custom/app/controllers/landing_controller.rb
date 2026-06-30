require 'rest-client'
require 'erb'
require 'uri'

class LandingController < ApplicationController
  skip_before_action :authenticate_user!, only: [:index, :signup, :create_account, :meli_callback, :go_to_chats, :dashboard, :update_settings, :upload_document, :destroy_document, :dashboard_status, :dashboard_products, :pv_dashboard_products, :rag_search, :update_store_greeting, :refresh_official_stores, :refresh_tokens, :bot_active, :conversation_ai_gate, :post_venta, :update_post_venta, :pv_upload_document, :pv_destroy_document, :pv_rag_search, :bulk_import_preview, :bulk_import, :product_docs_list, :destroy_document_ajax, :pv_destroy_document_ajax], raise: false
  layout false
  before_action :set_account, only: [:dashboard, :update_settings, :upload_document, :destroy_document, :dashboard_status, :dashboard_products, :pv_dashboard_products, :update_store_greeting, :refresh_official_stores, :refresh_tokens, :post_venta, :update_post_venta, :pv_upload_document, :pv_destroy_document, :bulk_import_preview, :bulk_import, :product_docs_list, :destroy_document_ajax, :pv_destroy_document_ajax]
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

      # 5. Crear equipos, bandejas de entrada y agregar al usuario real como miembro
      real_user       = User.find(user_data['id'])
      real_user_token = real_user.access_token&.token
      if real_user_token
        ['Pre-Venta', 'Post-Venta'].each do |team_name|
          team_res = RestClient.post(
            "#{internal_base}/api/v1/accounts/#{account.id}/teams",
            { name: team_name }.to_json,
            { api_access_token: real_user_token, content_type: :json, accept: :json }
          )
          team_id = JSON.parse(team_res.body)['id']
          RestClient.post(
            "#{internal_base}/api/v1/accounts/#{account.id}/teams/#{team_id}/team_members",
            { user_ids: [real_user.id] }.to_json,
            { api_access_token: real_user_token, content_type: :json, accept: :json }
          )
        end

        ['Pre-venta (MercadoLibre)', 'Post-venta (MercadoLibre)'].each do |inbox_name|
          inbox_res = RestClient.post(
            "#{internal_base}/api/v1/accounts/#{account.id}/inboxes",
            { name: inbox_name, channel: { type: 'api', webhook_url: '' } }.to_json,
            { api_access_token: real_user_token, content_type: :json, accept: :json }
          )
          inbox_id = JSON.parse(inbox_res.body)['id']
          RestClient.post(
            "#{internal_base}/api/v1/accounts/#{account.id}/inbox_members",
            { inbox_id: inbox_id, user_ids: [real_user.id] }.to_json,
            { api_access_token: real_user_token, content_type: :json, accept: :json }
          ) rescue nil
        end

        default_labels.each do |label|
          RestClient.post(
            "#{internal_base}/api/v1/accounts/#{account.id}/labels",
            label.to_json,
            { api_access_token: real_user_token, content_type: :json, accept: :json }
          ) rescue nil
        end

        default_webhooks.each do |webhook|
          RestClient.post(
            "#{internal_base}/api/v1/accounts/#{account.id}/webhooks",
            { webhook: webhook }.to_json,
            { api_access_token: real_user_token, content_type: :json, accept: :json }
          ) rescue nil
        end
      end

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
    sch = params[:schedule] || {}
    tz = sch[:timezone].to_s.strip
    tz = 'America/Argentina/Buenos_Aires' unless VALID_TIMEZONES.include?(tz)

    begin; days_data      = JSON.parse(sch[:days_json].to_s);      rescue; days_data      = {}; end
    begin; overrides_data = JSON.parse(sch[:overrides_json].to_s); rescue; overrides_data = {}; end

    # Sanear slots por día
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

    # Sanear excepciones
    sanitized_overrides = {}
    overrides_data.each do |date_str, val|
      next unless date_str.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)
      next unless val.is_a?(Hash) && %w[always_on always_off].include?(val['mode'])
      sanitized_overrides[date_str] = { 'mode' => val['mode'] }
    end

    attrs['config']['scheduledMode'] = {
      'enabled'   => sch[:enabled] == '1',
      'timezone'  => tz,
      'days'      => sanitized_days,
      'overrides' => sanitized_overrides
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

    unless config['chatGPTEnabled']
      return render json: { active: false, reason: 'globally_disabled' }
    end

    schedule = config['scheduledMode'] || {}
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
    redirect_to reply_ai_dashboard_path(panel: 'panel-bulk-import'),
                notice: 'Importación iniciada. Los documentos se procesarán en segundo plano.'
  end

  private

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
    @schedule              = @config['scheduledMode'] || {}
    @bot_enabled   = @config['chatGPTEnabled']
    @delay_seconds = @config.dig('response_delay', 'seconds') || 60

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
      { title: 'atencion-prioritaria',               description: 'Conversación con reclamo o conflicto activo que requiere intervención urgente',                 color: '#EA580C', show_on_sidebar: false  }
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