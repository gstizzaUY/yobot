require 'rest-client'
require 'erb'
require 'uri'

class LandingController < ApplicationController
  skip_before_action :authenticate_user!, only: [:index, :signup, :create_account, :meli_callback, :go_to_chats], raise: false
  layout false
  before_action :set_account, only: [:dashboard, :update_settings]

  def index; end
  def signup; end

  # PASO 1: Crear usuario y cuenta vía Platform API → sesión Devise → ML Auth
  def create_account
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

      # 3. Vincular usuario a la cuenta como administrador vía API
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
          RestClient.post(
            "#{internal_base}/api/v1/accounts/#{account.id}/inboxes",
            { name: inbox_name, channel: { type: 'api', webhook_url: '' } }.to_json,
            { api_access_token: real_user_token, content_type: :json, accept: :json }
          )
        end
      end

      # 6. Asociar el shadow user a la nueva cuenta como administrador
      shadow_user = User.find_by(email: ENV.fetch('SYSTEM_ADMIN_EMAIL'))
      if shadow_user
        RestClient.post(
          "#{internal_base}/platform/api/v1/accounts/#{account_data['id']}/account_users",
          { user_id: shadow_user.id, role: 'administrator' }.to_json,
          { 'api_access_token' => platform_token, content_type: :json, accept: :json }
        )
      end

      # 7. Iniciar sesión Rails vía Devise (persiste durante el flujo ML → callback → dashboard)
      sign_in(User.find(user_data['id']))

      # 8. Redirigir directamente a ML Auth (state = account_id para el callback)
      redirect_to ml_auth_url(account.id), allow_other_host: true
    rescue => e
      render html: "Error al crear la cuenta: #{e.message}. <a href='/signup'>Reintentar</a>".html_safe, status: 500
    end
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
        expires_at: Time.now + meli_data['expires_in'].seconds,
        status: 'active'
      )

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
      setup_dashboard_vars
      render 'landing/dashboard'
    rescue => e
      render html: "Error vinculando MercadoLibre: #{e.message}".html_safe, status: 500
    end
  end

  # PASO 3: Dashboard de configuración Reply-AI
  def dashboard
    setup_dashboard_vars
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
    attrs['config']['chatGPTEnabled']            = params[:chat_gpt_enabled] == '1'
    attrs['config']['response_delay']          ||= { 'enabled' => true, 'seconds' => 60 }
    attrs['config']['response_delay']['seconds'] = params[:delay_seconds].to_i
    @account.update_columns(custom_attributes: attrs)
    redirect_to reply_ai_dashboard_path, notice: 'Configuración guardada.'
  end

  private

  def set_account
    unless user_signed_in?
      redirect_to reply_ai_signup_path and return
    end
    @account = current_user.accounts.first
  end

  def setup_dashboard_vars
    @attrs         = @account.custom_attributes || {}
    @config        = @attrs['config'] || {}
    @prompts       = @config['prompts'] || {}
    @bot_enabled   = @config['chatGPTEnabled']
    @delay_seconds = @config.dig('response_delay', 'seconds') || 60
    # Token firmado con account_id, válido 2 horas, no requiere sesión Rails
    @magic_link_to_chats = go_to_chats_path(t: signed_account_token(@account.id))
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
          'enabled' => false,
          'timezone' => 'America/Argentina/Buenos_Aires',
          'workDays' => []
        },
        'response_delay' => { 'enabled' => true, 'seconds' => 60 }
      }
    }
  end
end