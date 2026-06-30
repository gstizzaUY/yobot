# config/initializers/reply-ai_routes.rb
# Las rutas se definen una sola vez al arrancar, sin to_prepare,
# para evitar el error "route name already in use" en recargas de desarrollo.

Rails.application.routes.prepend do
  root to: 'landing#index', as: :reply_ai_marketing_root
  get  '/signup'             => 'landing#signup',              as: :reply_ai_signup
  post '/signup'             => 'landing#create_account',      as: :signup_process
  get  '/callback'           => 'landing#meli_callback',       as: :callback
  get  '/dashboard'          => 'landing#dashboard',           as: :reply_ai_dashboard
  get  '/dashboard/status'   => 'landing#dashboard_status',    as: :reply_ai_dashboard_status
  get  '/dashboard/products'    => 'landing#dashboard_products',     as: :reply_ai_dashboard_products
  get  '/dashboard/pv-products' => 'landing#pv_dashboard_products',  as: :reply_ai_pv_dashboard_products
  post '/dashboard/update'   => 'landing#update_settings',     as: :update_settings
  post   '/dashboard/upload'     => 'landing#upload_document',  as: :upload_document
  delete '/dashboard/docs/:id'   => 'landing#destroy_document', as: :reply_ai_destroy_doc
  post   '/rag/search'           => 'landing#rag_search',        as: :rag_search
  get  '/go_to_chats'        => 'landing#go_to_chats',          as: :go_to_chats
  # Tiendas oficiales MercadoLibre
  patch '/dashboard/stores/:store_id/greeting' => 'landing#update_store_greeting', as: :update_store_greeting
  post  '/dashboard/stores/refresh'            => 'landing#refresh_official_stores', as: :refresh_official_stores
  # Forzar refresco de tokens ML (manual, vía GET)
  get   '/dashboard/refresh-tokens'            => 'landing#refresh_tokens',          as: :refresh_tokens
  # Estado del bot considerando programación horaria (para n8n)
  get   '/bot_active'            => 'landing#bot_active',            as: :bot_active
  # Kill-switch post-venta: verifica si la IA debe responder en una conversación
  match '/conversation_ai_gate'  => 'landing#conversation_ai_gate',  as: :conversation_ai_gate, via: [:get, :post]
  # Vista dedicada de configuración IA Post-Venta
  get  '/dashboard/post-venta'        => 'landing#post_venta',           as: :reply_ai_post_venta
  post '/dashboard/post-venta/update' => 'landing#update_post_venta',    as: :update_post_venta
  post   '/dashboard/pv-upload'          => 'landing#pv_upload_document',  as: :pv_upload_document
  delete '/dashboard/pv-docs/:id'        => 'landing#pv_destroy_document', as: :reply_ai_pv_destroy_doc
  post   '/rag/pv_search'                => 'landing#pv_rag_search',        as: :pv_rag_search
  # Importación masiva desde Excel/CSV
  post   '/dashboard/bulk-import/preview' => 'landing#bulk_import_preview',  as: :bulk_import_preview
  post   '/dashboard/bulk-import'         => 'landing#bulk_import',           as: :bulk_import
  # Gestión de documentos RAG por referencia (AJAX)
  get    '/dashboard/docs'                 => 'landing#product_docs_list',     as: :product_docs_list
  delete '/dashboard/docs/:id/ajax'        => 'landing#destroy_document_ajax', as: :destroy_doc_ajax
  delete '/dashboard/pv-docs/:id/ajax'     => 'landing#pv_destroy_document_ajax', as: :pv_destroy_doc_ajax
end