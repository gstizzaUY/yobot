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
  post   '/dashboard/bridge-sync-config'  => 'landing#bridge_sync_config',     as: :bridge_sync_config
  # Migración RAG desde Yobot (Supabase) — perfil MIGRADO (2026-08-08)
  post   '/dashboard/migrate-rag-pre'     => 'landing#migrate_rag_pre',  as: :migrate_rag_pre
  post   '/dashboard/migrate-rag-post'    => 'landing#migrate_rag_post', as: :migrate_rag_post
  # Control de confianza pre-venta: informe de preguntas retenidas (JSON, panel Informes)
  get    '/dashboard/confidence-report'   => 'landing#confidence_report', as: :confidence_report

  # ======= VENTAS POST-VENTA (tabla del dashboard + Dashboard App "Venta ML", 2026-08-08) =======
  get   '/dashboard/sales/data'           => 'landing#sales_list', as: :sales_list
  get   '/dashboard/sale-panel'           => 'landing#sale_panel', as: :sale_panel
  get   '/dashboard/sales/panel-data'     => 'landing#sale_panel_data', as: :sale_panel_data
  get   '/dashboard/sales/:id'            => 'landing#sale_detail', as: :sale_detail
  # Dashboard App "Producto ML" (2026-08-09)
  get   '/dashboard/product-panel'        => 'landing#product_panel', as: :product_panel
  get   '/dashboard/product-panel/data'   => 'landing#product_panel_data', as: :product_panel_data
  # Gestión de documentos RAG por referencia (AJAX)
  get    '/dashboard/docs'                 => 'landing#product_docs_list',     as: :product_docs_list
  delete '/dashboard/docs/:id/ajax'        => 'landing#destroy_document_ajax', as: :destroy_doc_ajax
  delete '/dashboard/pv-docs/:id/ajax'     => 'landing#pv_destroy_document_ajax', as: :pv_destroy_doc_ajax

  # ======= RECLAMOS / DEVOLUCIONES / CAMBIOS (Fase 2) =======
  post  '/claims_webhook'                   => 'landing#claims_webhook'            # webhook de ML (claims, claims_actions)
  get   '/dashboard/claims'                 => 'landing#claims_index', as: :claims_index
  get   '/dashboard/claim-panel'            => 'landing#claim_panel',  as: :claim_panel
  get   '/dashboard/claims/panel-data'      => 'landing#claim_panel_data', as: :claim_panel_data
  get   '/dashboard/claims/data'            => 'landing#claims_list',  as: :claims_list
  post  '/dashboard/claims/sync'            => 'landing#claims_sync',  as: :claims_sync
  get   '/dashboard/claims/:id'             => 'landing#claim_detail', as: :claim_detail
  get   '/dashboard/claims/:id/messages'    => 'landing#claim_messages'
  get   '/dashboard/claims/:id/evidences'   => 'landing#claim_evidences'
  post  '/dashboard/claims/:id/message'     => 'landing#claim_send_message'
  post  '/dashboard/claims/:id/evidence'    => 'landing#claim_send_evidence'
  post  '/dashboard/claims/:id/refund'      => 'landing#claim_refund'
  post  '/dashboard/claims/:id/partial-refund'   => 'landing#claim_partial_refund'
  get   '/dashboard/claims/:id/available-offers' => 'landing#claim_available_offers'
  post  '/dashboard/claims/:id/allow-return'     => 'landing#claim_allow_return'
  post  '/dashboard/claims/:id/open-dispute'     => 'landing#claim_open_dispute'
  get   '/dashboard/claims/:id/affects-reputation' => 'landing#claim_affects_reputation'
  get   '/dashboard/claims/:id/agent-pending'    => 'landing#claim_agent_pending'
  post  '/dashboard/claims/:id/agent-execute'    => 'landing#claim_agent_execute'
  post  '/dashboard/claims/:id/agent-cancel'     => 'landing#claim_agent_cancel'
  post  '/dashboard/claims/:id/agent-rerun'      => 'landing#claim_agent_rerun'
  # Devoluciones
  get   '/dashboard/returns/:id'            => 'landing#return_detail'
  post  '/dashboard/returns/:id/review'     => 'landing#return_review'
  get   '/dashboard/returns/:id/reasons'    => 'landing#return_reasons'
  get   '/dashboard/returns/:id/cost'       => 'landing#return_cost'
  # Cambios
  get   '/dashboard/changes/:id'            => 'landing#change_detail'
  post  '/dashboard/changes/:id/allow-replace' => 'landing#change_allow_replace'

  # ======= BRIDGE YOBOT ↔ REPLY-AI =======
  # Yobot → Reply-AI (forward de webhooks ML)
  post '/api/bridge/question'       => 'landing#bridge_question'
  post '/api/bridge/message'        => 'landing#bridge_message'
  post '/api/bridge/order'          => 'landing#bridge_order'
  post '/api/bridge/claim'          => 'landing#bridge_claim'
  post '/api/bridge/manual-response' => 'landing#bridge_manual_response'
  # Reply-AI → Yobot (consulta de estado / registro)
  get  '/api/bridge/seller/:ml_user_id' => 'landing#bridge_seller_status'
  post '/api/bridge/register'       => 'landing#bridge_register'
  # Interno n8n → Rails: firma HMAC para el bridge (los Code nodes no pueden usar crypto)
  post '/bridge/sign'               => 'landing#bridge_sign'
  # Interno n8n → Rails: estado de mensajes (ticks delivered/read + ml_message_id) y
  # sync de lectura de conversaciones post-venta (contrato 2026-08-07)
  post '/api/bridge/message-status'           => 'landing#bridge_message_status'
  post '/api/bridge/sync-conversation-reads'  => 'landing#bridge_sync_conversation_reads'
end