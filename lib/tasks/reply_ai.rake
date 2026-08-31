# frozen_string_literal: true

namespace :reply_ai do
  desc 'Crea el inbox "Reclamos (MercadoLibre)", las labels reclamo-* y la Dashboard App en cuentas existentes'
  task backfill_claims_inbox: :environment do
    base = 'http://localhost:3000'

    Account.find_each do |account|
      admin_account_user = account.account_users.where(role: :administrator).first
      token = admin_account_user&.user&.access_token&.token
      unless token
        puts "SKIP account=#{account.id} (sin admin con token)"
        next
      end
      headers = { api_access_token: token, content_type: :json, accept: :json }
      inbox = account.inboxes.find_by(name: 'Reclamos (MercadoLibre)')
      unless inbox
        res = RestClient.post(
          "#{base}/api/v1/accounts/#{account.id}/inboxes",
          { name: 'Reclamos (MercadoLibre)', channel: { type: 'api', webhook_url: '' } }.to_json,
          headers
        )
        inbox = account.inboxes.find_by(name: 'Reclamos (MercadoLibre)')
        puts "account=#{account.id} inbox Reclamos creado"
      end

      if inbox
        # Los miembros de la bandeja de reclamos deben ser LOS MISMOS que los de
        # pre-venta y post-venta (nunca el usuario fantasma/super admin).
        target_ids = claims_inbox_member_ids(account)
        current_ids = inbox.inbox_members.pluck(:user_id)
        (target_ids - current_ids).each { |uid| InboxMember.find_or_create_by!(inbox: inbox, user_id: uid) }
        (current_ids - target_ids).each { |uid| inbox.inbox_members.where(user_id: uid).destroy_all }
      end

      existing = account.labels.index_by(&:title)
      LandingController.new.send(:default_labels).each do |label|
        found = existing[label[:title]]
        if found
          # Sincronizar visibilidad (las labels Reply-AI son para acciones, no para el sidebar)
          if found.show_on_sidebar != label[:show_on_sidebar]
            found.update_columns(show_on_sidebar: label[:show_on_sidebar])
            puts "account=#{account.id} label #{label[:title]} -> show_on_sidebar=#{label[:show_on_sidebar]}"
          end
          next
        end

        RestClient.post("#{base}/api/v1/accounts/#{account.id}/labels", label.to_json, headers) rescue nil
      end

      unless DashboardApp.exists?(account_id: account.id)
        app_url = "#{ENV.fetch('FRONTEND_URL', 'https://w1206-app.site')}/dashboard/claim-panel?conversation_id={{conversation.id}}"
        RestClient.post(
          "#{base}/api/v1/accounts/#{account.id}/dashboard_apps",
          { title: 'Reclamo ML', content: [{ type: 'frame', url: app_url }] }.to_json,
          headers
        ) rescue nil
        puts "account=#{account.id} Dashboard App Reclamo ML creada"
      end

      unless account.dashboard_apps.exists?(title: 'Venta ML')
        sale_url = "#{ENV.fetch('FRONTEND_URL', 'https://w1206-app.site')}/dashboard/sale-panel?conversation_id={{conversation.id}}"
        RestClient.post(
          "#{base}/api/v1/accounts/#{account.id}/dashboard_apps",
          { title: 'Venta ML', content: [{ type: 'frame', url: sale_url }] }.to_json,
          headers
        ) rescue nil
        puts "account=#{account.id} Dashboard App Venta ML creada"
      end

      existing_names = account.webhooks.pluck(:name)
      LandingController.new.send(:default_webhooks).each do |webhook|
        # Idempotente por NOMBRE (las URLs pueden diferir entre dev y producción)
        next if existing_names.include?(webhook[:name])

        RestClient.post(
          "#{base}/api/v1/accounts/#{account.id}/webhooks",
          { webhook: webhook }.to_json,
          headers
        ) rescue nil
        puts "account=#{account.id} webhook #{webhook[:name]} creado"
      end
    end

    puts 'Backfill completado'
  end

  # Miembros de la bandeja de reclamos = unión de los miembros de pre-venta y post-venta.
  # Fallback: todos los usuarios de la cuenta (nunca el usuario fantasma/super admin).
  def claims_inbox_member_ids(account)
    meli_inboxes = account.inboxes.where(name: ['Pre-venta (MercadoLibre)', 'Post-venta (MercadoLibre)'])
    ids = InboxMember.where(inbox_id: meli_inboxes.pluck(:id)).pluck(:user_id).uniq
    ids = account.account_users.pluck(:user_id) if ids.empty?
    ids
  end

  desc 'Sincroniza la configuración del bridge desde Yobot (POST /api/bridge/sync-config → custom_attributes). Uso: rails reply_ai:sync_bridge_config[account_id]'
  task :sync_bridge_config, [:account_id] => :environment do |_t, args|
    account_id = args[:account_id].to_i
    raise 'account_id requerido' if account_id.zero?

    result = ReplyAi::BridgeConfigSyncWorker.new.perform(account_id)
    puts "Config mapeada para account=#{result[:account_id]} (#{result[:stores]} tiendas)"
  end
end
