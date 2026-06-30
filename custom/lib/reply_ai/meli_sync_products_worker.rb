module ReplyAi
  class MeliSyncProductsWorker
    include Sidekiq::Worker
    sidekiq_options queue: 'low'

    BATCH_SIZE = 20 # límite de la API /items?ids=
    PAGE_LIMIT = 50 # máximo por página en /items/search

    def perform(account_id)
      account = Account.find(account_id)
      creds   = MeliCredential.find_by(account_id: account_id, status: 'active')
      return unless creds

      mark_syncing(account, true)

      headers = { Authorization: "Bearer #{creds.access_token}" }
      offset  = 0

      loop do
        res      = JSON.parse(RestClient.get(
          "https://api.mercadolibre.com/users/#{creds.ml_user_id}/items/search?limit=#{PAGE_LIMIT}&offset=#{offset}",
          headers
        ).body)

        item_ids = res['results'] || []
        break if item_ids.empty?

        item_ids.each_slice(BATCH_SIZE) do |batch|
          items = JSON.parse(RestClient.get(
            "https://api.mercadolibre.com/items?ids=#{batch.join(',')}",
            headers
          ).body)

          items.each do |r|
            item = r['body']
            MeliProduct.find_or_initialize_by(account_id: account.id, meli_item_id: item['id']).update!(
              # Campos básicos
              title:               item['title'],
              thumbnail:           item['thumbnail'],
              status:              item['status'],
              category_id:         item['category_id'],

              # Precio y stock
              price:               item['price'],
              base_price:          item['base_price'],
              original_price:      item['original_price'],
              currency_id:         item['currency_id'],
              available_quantity:  item['available_quantity'],
              sold_quantity:       item['sold_quantity'],

              # Condición y tipo
              condition:           item['condition'],
              listing_type_id:     item['listing_type_id'],
              buying_mode:         item['buying_mode'],

              # URLs
              permalink:           item['permalink'],
              secure_thumbnail:    item['secure_thumbnail'],

              # Descripción y detalles
              warranty:            item['warranty'],
              domain_id:           item['domain_id'],
              catalog_product_id:  item['catalog_product_id'],
              health:              item['health'],
              accepts_mercadopago: item['accepts_mercadopago'],
              free_shipping:       item.dig('shipping', 'free_shipping'),

              # Fechas de ML
              date_created:        item['date_created'],
              last_updated:        item['last_updated'],

              # Arrays/objetos
              pictures:            item['pictures'] || [],
              attributes_data:     item['attributes'] || [],
              shipping_data:       item['shipping'] || {},
              tags:                item['tags'] || [],

              # Respuesta completa (fallback para cualquier campo futuro)
              raw_data:            item
            )
            sync_category(account, item['category_id'])
          end
        end

        total   = res.dig('paging', 'total').to_i
        offset += PAGE_LIMIT
        break if offset >= total
      end

      mark_syncing(account, false)
    rescue StandardError
      mark_syncing(account, false)
      raise
    end

    private

    def mark_syncing(account, value)
      attrs = (account.custom_attributes || {}).deep_dup
      attrs['syncing_products'] = value
      account.update_columns(custom_attributes: attrs)
    end

    def sync_category(account, cat_id)
      return if MeliCategory.exists?(account_id: account.id, meli_category_id: cat_id)

      res = JSON.parse(RestClient.get("https://api.mercadolibre.com/categories/#{cat_id}").body)
      MeliCategory.create!(
        account: account, meli_category_id: cat_id,
        name: res['name'], level: 'sub',
        parent_id: res['path_from_root']&.first&.[]('id')
      )
      MeliCategory.find_or_create_by!(account: account, meli_category_id: res['path_from_root'].first['id']) do |c|
        c.name  = res['path_from_root'].first['name']
        c.level = 'master'
      end
    end
  end
end