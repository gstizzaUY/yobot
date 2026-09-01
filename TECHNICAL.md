# Chatwoot + Reply-AI — Documentación Técnica Unificada

> **Versión**: Chatwoot 4.17.1 + Reply-AI / Meli  
> **Última actualización**: 2026-09-01  
> **Propósito**: Referencia completa para agentes IA y desarrolladores.

---

## Tabla de Contenidos

1. [Resumen del Proyecto](#1-resumen-del-proyecto)
2. [Stack Tecnológico](#2-stack-tecnológico)
3. [Arquitectura General](#3-arquitectura-general)
4. [Custom Layer (Reply-AI / Meli)](#4-custom-layer-reply-ai--meli)
5. [Modelos Custom](#5-modelos-custom)
6. [LandingController (~2050 líneas)](#6-landingcontroller-~2050-líneas)
7. [Workers (Sidekiq)](#7-workers-sidekiq)
8. [Middleware de UI (InjectCssMiddleware)](#8-middleware-de-ui-injectcssmiddleware)
9. [Initializers Custom](#9-initializers-custom)
10. [Esquema de Base de Datos Custom](#10-esquema-de-base-de-datos-custom)
11. [n8n Workflows](#11-n8n-workflows)
12. [Rutas Custom](#12-rutas-custom)
13. [Variables de Entorno Necesarias](#13-variables-de-entorno-necesarias)
14. [Mecanismo de Extensión (custom/)](#14-mecanismo-de-extensión-custom)
15. [Flujo de Actualización de Chatwoot](#15-flujo-de-actualización-de-chatwoot)
16. [Script de Verificación](#16-script-de-verificación)
17. [Desarrollo Local](#17-desarrollo-local)
18. [Plan de Implementación — Features Pendientes](#18-plan-de-implementación--features-pendientes-yobot--reply-ai)
    - [18.0 Decisiones del owner](#180-decisiones-del-owner)
    - [18.1 Comparativa Yobot vs Reply-AI](#181-comparativa-yobot-vs-reply-ai)
    - [18.2 Fase 1 — Post-venta IA Avanzada](#182-fase-1--post-venta-ia-avanzada)
    - [18.3 Fase 2 — Reclamos, Devoluciones y Cambios](#183-fase-2--reclamos-devoluciones-y-cambios)
    - [18.4 Fase 3 — Bridge Yobot ↔ Reply-AI](#184-fase-3--bridge-yobot--reply-ai)
    - [18.5 Reglas de Implementación](#185-reglas-de-implementación)
    - [18.6 Verificación por Fase](#186-verificación-por-fase)
    - [18.7 Bridge Yobot ↔ Reply-AI — Guía completa (Fase 3)](#187-bridge-yobot--reply-ai--guía-completa-fase-3)
    - [18.8 Bandeja de Reclamos en Chatwoot](#188-bandeja-de-reclamos-mercadolibre-en-chatwoot-implementado-2026-08-04)
    - [18.10 Migración RAG Yobot → Reply](#1810-migración-rag-yobot--reply-perfil-migrado-implementado-2026-08-08)
    - [18.11 Control de confianza pre-venta](#1811-control-de-confianza-pre-venta-implementado-2026-08-08)
19. [Modo Recepción Solamente (receive-only)](#19-modo-recepción-solamente-receive-only)
20. [Operaciones n8n (importación, versiones, smoke tests)](#20-operaciones-n8n-importación-versiones-smoke-tests)
21. [Paneles Dashboard Apps (Venta ML, Reclamo ML, Producto ML)](#21-paneles-dashboard-apps-venta-ml-reclamo-ml-producto-ml)
22. [Enterprise sin licencia — blindaje custom](#22-enterprise-sin-licencia-blindaje-custom-2026-08-31)
23. [Despliegue de n8n a producción](#23-despliegue-de-n8n-a-producción-2026-09-01)

---

## 1. Resumen del Proyecto

**Chatwoot** es una plataforma open-source de atención al cliente omnicanal (alternativa a Intercom/Zendesk).  
**Reply-AI** es una capa custom que extiende Chatwoot para automatizar respuestas en MercadoLibre usando IA (RAG + OpenAI vía n8n).

### Flujo de negocio

```
Cliente pregunta en MercadoLibre
  → Webhook de ML notifica a n8n
    → n8n consulta BD de Chatwoot (credenciales, docs RAG, custom_attributes)
      → n8n genera respuesta con OpenAI + contexto RAG
        → n8n crea conversación en Chatwoot vía Platform API
          → Si aplica, n8n envía respuesta automática a ML
          → Si necesita humano, agente responde desde Chatwoot
            → n8n detecta respuesta humana y la reenvía a ML
```

### Dos modos de operación

| Modo | Inbox en Chatwoot | Flujo |
|------|-------------------|-------|
| **Pre-venta** | "Pre-venta (MercadoLibre)" | Preguntas de compradores → IA responde usando docs RAG por producto |
| **Post-venta** | "Post-venta (MercadoLibre)" | Mensajes post-compra → IA responde usando docs RAG post-venta |

---

## 2. Stack Tecnológico

| Capa | Tecnología | Versión |
|------|-----------|---------|
| Backend | Ruby on Rails | 7.1.5.2 |
| Frontend | Vue 3 (Composition API) | 3.x |
| Build | Vite | 5.x |
| Base de datos | PostgreSQL + pgvector | 16 |
| Cache / PubSub | Redis | Alpine |
| Background jobs | Sidekiq | 7.x |
| Búsqueda vectorial | pgvector (neighbors gem) | — |
| Extracción texto | Apache Tika | latest-full |
| Automatización | n8n | 2.6.4 |
| CSS | Tailwind (sin custom CSS) | — |
| Ruby | MRI | 3.4.4 |
| Package manager | pnpm | 10.x |

---

## 3. Arquitectura General

```
chatwoot/
├── app/                     ← 100% Chatwoot core (NUNCA modificar)
│   ├── models/              ← Modelos core (Account, User, Conversation, Inbox...)
│   ├── controllers/         ← API v1/v2, Dashboard, Widget, Public...
│   ├── services/            ← Lógica de negocio (45+ servicios)
│   ├── jobs/                ← Sidekiq jobs core
│   ├── channels/            ← ActionCable (RoomChannel)
│   ├── javascript/          ← Frontend Vue 3 (dashboard, widget, portal, survey)
│   └── views/               ← Vistas core
├── enterprise/              ← Chatwoot Enterprise Edition (overlay)
├── custom/                  ← TODO el código Reply-AI / Meli
│   ├── app/
│   │   ├── controllers/     ← LandingController (~2050 líneas)
│   │   ├── models/          ← 12 modelos Meli/ReplyAi
│   │   └── views/landing/   ← 15+ vistas ERB (dashboard 3100+, claims, claim_panel...)
│   ├── lib/
│   │   ├── custom.rb        ← Módulo Custom (placeholder)
│   │   └── reply_ai/        ← 12 workers/librerías + middleware CSS
│   ├── db/migrate/          ← 17 migraciones custom
│   └── verify.rb            ← Script de verificación
├── config/initializers/     ← Incluye 7 initializers custom
├── n8n/                     ← 9 workflows JSON (+ GUIA_BRIDGE_N8N.md)
└── db/migrate/              ← Solo migraciones core
```

### Cómo se carga custom/ sin modificar core

1. **`config/initializers/00_custom_load_paths.rb`**: Usa `Zeitwerk::Loader#push_dir` para registrar `custom/app/models/`, `custom/app/controllers/`, `custom/lib/` en el autoloader. También configura `ActionController::Base.prepend_view_path` para las vistas.
2. **`ChatwootApp.extensions`**: Al existir el directorio `custom/`, `lib/chatwoot_app.rb` devuelve `['enterprise', 'custom']`, habilitando `prepend_mod_with` para buscar módulos en `Custom::`.
3. **Ningún archivo core fue modificado**.

---

## 4. Custom Layer (Reply-AI / Meli)

### Estructura de archivos custom

```
custom/
├── app/
│   ├── controllers/
│   │   └── landing_controller.rb          (~2050 líneas)
│   ├── models/
│   │   ├── meli_credential.rb             (7 líneas)
│   │   ├── meli_product.rb                (6 líneas)
│   │   ├── meli_category.rb               (3 líneas)
│   │   ├── meli_official_store.rb         (8 líneas)
│   │   ├── meli_order.rb                  (9 líneas)
│   │   ├── meli_claim.rb                  (modelo de reclamos, Fase 2; + timeline 2026-08-09)
│   │   ├── reply_ai_document.rb           (17 líneas)
│   │   └── reply_ai_pv_document.rb        (17 líneas)
│   └── views/landing/
│       ├── index.html.erb
│       ├── signup.html.erb
│       ├── setup_meli.html.erb
│       ├── meli_error.html.erb
│       ├── welcome.html.erb
│       ├── dashboard.html.erb             (~2900 líneas; tabs Pre-Venta/Post-Venta/Informes)
│       ├── post_venta.html.erb            (~560 líneas)
│       ├── claims.html.erb                (tabla de reclamos estilo Yobot)
│       ├── claim_panel.html.erb           (Dashboard App Reclamo ML, ficha + timeline)
│       ├── sale_panel.html.erb            (Dashboard App Venta ML, 2026-08-08)
│       ├── product_panel.html.erb         (Dashboard App Producto ML, ficha de producto 2026-08-09)
│       ├── auth_sync.html.erb
│       ├── _products_table.html.erb       (213 líneas)
│       ├── _doc_card.html.erb             (102 líneas)
│       ├── _doc_row.html.erb
│       ├── _pv_doc_row.html.erb
│       └── _product_docs_list.html.erb    (108 líneas)
├── lib/
│   ├── custom.rb                          ← module Custom; end
│   └── reply_ai/
│       ├── inject_css_middleware.rb       (325 líneas)
│       ├── token_refresh_worker.rb        (38 líneas)
│       ├── meli_sync_products_worker.rb   (119 líneas)
│       ├── meli_sync_official_stores_worker.rb (42 líneas)
│       ├── bulk_import_worker.rb          (94 líneas)
│       ├── document_processor_worker.rb   (48 líneas)
│       ├── pv_document_processor_worker.rb (35 líneas)
│       ├── meli_api.rb                    (cliente ML, Fase 2)
│       ├── claim_mapper.rb                (Fase 2)
│       ├── claim_automation.rb            (Fase 2)
│       ├── claim_agent_worker.rb          (agente ReAct, Fase 2)
│       ├── claims_sync_worker.rb          (Fase 2; + timeline en upsert 2026-08-09)
│       ├── bridge_api.rb                  (cliente bridge Yobot: 21 acciones + syncs, 2026-08-05; item/item_description con error not_in_bridge_contract 2026-08-09)
│       ├── bridge_config_mapper.rb         (mapeo config Yobot → custom_attributes, 2026-08-06)
│       └── bridge_config_sync_worker.rb    (sync-config vía bridge, 2026-08-06)
├── db/migrate/                            ← 17 migraciones
└── verify.rb                              (152 líneas)
```

---

## 5. Modelos Custom

### 5.1 MeliCredential
```ruby
# custom/app/models/meli_credential.rb
class MeliCredential < ApplicationRecord
  belongs_to :account
  validates :ml_user_id, presence: true, uniqueness: true
  validates :access_token, presence: true
  validates :status, inclusion: { in: %w[pending active error] }
end
```
Almacena tokens OAuth2 de MercadoLibre por cuenta. Campos: `account_id`, `ml_user_id` (unique), `access_token`, `refresh_token`, `expires_at`, `status`.

### 5.2 MeliProduct
```ruby
class MeliProduct < ApplicationRecord
  belongs_to :account
  def active?; status == 'active'; end
end
```
Catálogo de productos sincronizado desde ML. ~30 columnas: `meli_item_id`, `title`, `thumbnail`, `price`, `sold_quantity`, `pictures` (JSONB), `attributes_data` (JSONB), `raw_data` (JSONB), etc.

### 5.3 MeliCategory
```ruby
class MeliCategory < ApplicationRecord
  belongs_to :account
end
```
Jerarquía de categorías (2 niveles: master/sub). Campos: `meli_category_id`, `name`, `parent_id`, `level`.

### 5.4 MeliOfficialStore
```ruby
class MeliOfficialStore < ApplicationRecord
  belongs_to :account
  validates :meli_store_id, presence: true, uniqueness: { scope: :account_id }
  validates :name, presence: true
  scope :for_account, ->(account_id) { where(account_id: account_id).order(:name) }
end
```
Tiendas oficiales del vendedor. Campos: `meli_store_id`, `name`, `status`, `logo`, `custom_greeting`.

### 5.5 MeliOrder
```ruby
class MeliOrder < ApplicationRecord
  belongs_to :account
  validates :ml_order_id, presence: true, uniqueness: { scope: :account_id }
  scope :for_account,     ->(account_id) { where(account_id: account_id) }
  scope :message_pending, -> { where(message_sent: false) }
  scope :with_questions,  -> { where(had_questions: true) }
end
```
Tracking de órdenes para post-venta. Campos: `ml_order_id`, `ml_buyer_id`, `item_id`, `pack_id`, `order_status`, `shipping_mode`, `message_sent`, `message_sent_at`, `message_error`, `had_questions`, `ai_answered`, `questions_count`, `conversion_checked_at` + ciclo de vida (Fase 1): `estado_conversacion`, `handoff_reason`, `last_sentiment`, `consecutive_enojado`, `repeat_count`, `ultimos_mensajes_comprador` (jsonb), `blocked_substatus`, `last_message_at` + panel de venta (2026-08-08): `cw_conversation_id`, `item_title`, `buyer_nickname`, `total_amount`, `currency_id`, `quantity`, `date_created`.

### 5.6 ReplyAiDocument y ReplyAiPvDocument
```ruby
class ReplyAiDocument < ApplicationRecord
  belongs_to :account
  has_one_attached :file
  has_neighbors :embedding  # pgvector
  LEVELS = %w[global category sub product].freeze

  def self.search_for(account_id:, embedding:, reference_ids: [], limit: 5)
    scope = where(account_id: account_id).where.not(embedding: nil)
    scope = scope.where(reference_id: reference_ids.map(&:to_s)) if reference_ids.any?
    scope.nearest_neighbors(:embedding, embedding, distance: 'cosine').limit(limit)
  end
end
```
Documentos RAG (pre-venta y post-venta). Almacenan embeddings vectoriales generados por OpenAI vía n8n. Usan `neighbors` gem con `pgvector`. Búsqueda por cosine distance.

### 5.7 MeliClaim (Fase 2)
```ruby
class MeliClaim < ApplicationRecord
  belongs_to :account
  validates :claim_id, presence: true, uniqueness: { scope: :account_id }
  scope :activos,   -> { where(status: 'opened') }
  scope :pendientes, -> { where.not(pending_action: nil) }

  def orden
    MeliOrder.find_by(id: sale_id)
  end

  # Timeline de eventos del reclamo (2026-08-09): { at:, tipo: 'sync'|'webhook'|'manual', evento: }
  # Dedupe si el último evento es idéntico; máx 50 entradas.
  def registrar_evento_timeline!(tipo, evento)
    entries = timeline || []
    unless entries.last && entries.last['evento'] == evento
      entries << { at: Time.current.iso8601, tipo: tipo, evento: evento }
      update_column(:timeline, entries.last(50))
    end
    entries.last(50)
  end
end
```
Reclamos ML: `claim_id` (unique por account), `resource`/`resource_id`, `claim_type`, `stage`, `status`, `reason_id`, `players` (jsonb), `expected_resolutions` (jsonb), `affects_reputation`, `sale_id`, `pending_action`, `agent_status`, `agent_log` (jsonb), `raw_data` (jsonb), `cw_conversation_id`, `timeline` (jsonb, 2026-08-09).

### Asociaciones en Account (inyectadas vía initializer)

El initializer `reply_ai_account_associations.rb` extiende `Account` con `class_eval`:

```ruby
Account.class_eval do
  has_many :meli_products,        dependent: :destroy, class_name: 'MeliProduct'
  has_many :meli_categories,      dependent: :destroy, class_name: 'MeliCategory'
  has_many :meli_credentials,     dependent: :destroy, class_name: 'MeliCredential'
  has_many :reply_ai_documents,   dependent: :destroy, class_name: 'ReplyAiDocument'
  has_many :reply_ai_pv_documents,dependent: :destroy, class_name: 'ReplyAiPvDocument'
end
```

---

## 6. LandingController (~2400 líneas)

`custom/app/controllers/landing_controller.rb` — El controlador principal de Reply-AI.

### Endpoints públicos (sin autenticación)

| Método | Ruta | Acción | Propósito |
|--------|------|--------|-----------|
| GET | `/` | `index` | Landing page |
| GET | `/signup` | `signup` | Formulario de registro |
| POST | `/signup` | `create_account` | Crea User + Account vía Platform API, crea 2 inboxes ("Pre-venta (MercadoLibre)" y "Post-venta (MercadoLibre)"), redirige a OAuth de ML |
| GET | `/callback` | `meli_callback` | Callback OAuth2 de ML: guarda tokens, dispara sync de productos y tiendas |
| GET | `/go_to_chats` | `go_to_chats` | SSO al dashboard de Chatwoot |

### Endpoints del dashboard de configuración

| Método | Ruta | Acción | Propósito |
|--------|------|--------|-----------|
| GET | `/dashboard` | `dashboard` | Dashboard principal de configuración (2854 líneas de vista) |
| GET | `/dashboard/status` | `dashboard_status` | JSON: estado de sync (syncing_products, conteo) |
| GET | `/dashboard/products` | `dashboard_products` | AJAX: tabla de productos (pre-venta) |
| GET | `/dashboard/pv-products` | `pv_dashboard_products` | AJAX: tabla de productos (post-venta) |
| POST | `/dashboard/update` | `update_settings` | Guarda configuración (prompts, delays, schedule) |
| POST | `/dashboard/upload` | `upload_document` | Sube documento RAG vía ActiveStorage |
| DELETE | `/dashboard/docs/:id` | `destroy_document` | Elimina documento RAG |
| GET | `/dashboard/docs` | `product_docs_list` | AJAX: lista docs por producto |
| DELETE | `/dashboard/docs/:id/ajax` | `destroy_document_ajax` | Elimina doc vía AJAX |
| GET | `/dashboard/post-venta` | `post_venta` | Dashboard post-venta |
| POST | `/dashboard/post-venta/update` | `update_post_venta` | Guarda config post-venta |
| POST | `/dashboard/pv-upload` | `pv_upload_document` | Sube doc RAG post-venta |
| DELETE | `/dashboard/pv-docs/:id` | `pv_destroy_document` | Elimina doc post-venta |
| DELETE | `/dashboard/pv-docs/:id/ajax` | `pv_destroy_document_ajax` | Elimina doc post-venta vía AJAX |
| PATCH | `/dashboard/stores/:id/greeting` | `update_store_greeting` | Actualiza saludo custom por tienda |
| POST | `/dashboard/stores/refresh` | `refresh_official_stores` | Dispara sync de tiendas |

### Endpoints para n8n

| Método | Ruta | Acción | Propósito |
|--------|------|--------|-----------|
| GET | `/bot_active` | `bot_active` | n8n consulta si el bot debe responder (schedule + global toggle) |
| GET/POST | `/conversation_ai_gate` | `conversation_ai_gate` | Kill-switch: n8n verifica si IA debe intervenir en una conversación (asignación humana, label "atencion-humana", status resolved, AI deshabilitada) |
| POST | `/rag/search` | `rag_search` | n8n busca docs RAG pre-venta por embedding |
| POST | `/rag/pv_search` | `pv_rag_search` | n8n busca docs RAG post-venta por embedding |

### Endpoints de importación

| Método | Ruta | Acción | Propósito |
|--------|------|--------|-----------|
| POST | `/dashboard/bulk-import/preview` | `bulk_import_preview` | Preview de archivo CSV/XLSX |
| POST | `/dashboard/bulk-import` | `bulk_import` | Dispara BulkImportWorker |

### Endpoints de las Dashboard Apps (2026-08-08/09, ver §21)

| Método | Ruta | Acción | Propósito |
|--------|------|--------|-----------|
| GET | `/dashboard/sale-panel` | `sale_panel` | HTML del panel Venta ML (siempre renderiza; contexto por postMessage) |
| GET | `/dashboard/sales/panel-data` | `sale_panel_data` | JSON: venta + mensajes + order_ml/shipment_ml + secciones buyer/payment/shipment/item_detail |
| GET | `/dashboard/product-panel` | `product_panel` | HTML del panel Producto ML |
| GET | `/dashboard/product-panel/data` | `product_panel_data` | JSON: ficha del item (ML directo o catálogo local bridge; resuelve item por conversación pre/post-venta) |
| GET | `/dashboard/claim-panel` | `claim_panel` | HTML del panel Reclamo ML (siempre renderiza; contexto por postMessage) |
| GET | `/dashboard/claims/panel-data` | `claim_panel_data` | JSON: reclamo por conversación + raw_data/agent_log/pending_action/timeline |

Resolvers de contexto: `resolve_panel_sale` (venta por cw_conversation_id → display_id → pack_id → sale_id) y `resolve_panel_claim` (claim por cw_conversation_id → contact_inbox.source_id → conversación). Ver §21.

### Flujo de signup

1. Usuario completa formulario en `/signup` (name, email, password, account_name)
2. `create_account`:
   - Crea User vía `POST /platform/api/v1/users`
   - Crea Account vía `POST /platform/api/v1/accounts`
   - Vincula User como administrator vía `POST /platform/api/v1/accounts/:id/account_users`
   - Configura `custom_attributes` con defaults + `settings.auto_resolve_after = 4320` (72h)
   - `setup_account_channels(account, user_id, user_token)` (helper compartido con `bridge_register`):
     - Crea 2 equipos: "Pre-Venta" y "Post-Venta" (con el usuario como miembro)
     - Crea 3 API-channel inboxes: "Pre-venta (MercadoLibre)", "Post-venta (MercadoLibre)" y **"Reclamos (MercadoLibre)"**
     - Crea **14 labels**: las 9 de IA/post-venta (`esperando_respuesta_manual`, `esperando_tiempo_retraso_programado`, `procesando_con_ia`, `respondida_con_ia`, `respondida_manualmente`, `bot-procesando`, `atencion-humana`, `atencion-prioritaria`, `mensajeria-bloqueada`) + **5 de reclamos** (`reclamo-abierto`, `reclamo-mediacion`, `reclamo-cerrado`, `reclamo-pendiente-accion`, `reclamo-derivado`)
     - Crea 4 webhooks para integración con n8n (Salida Manual, Post-Venta IA, Post-Venta Salida, **Reclamos Salida**)
     - Registra las **3 Dashboard Apps**: **"Reclamo ML"** (`/dashboard/claim-panel?conversation_id={{conversation.id}}`), **"Venta ML"** (`/dashboard/sale-panel?conversation_id={{conversation.id}}`) y **"Producto ML"** (`/dashboard/product-panel?conversation_id={{conversation.id}}`) — ver §21
    - Degrada al usuario real a agente; asocia shadow user + usuario agente común
   - Inicia sesión Devise y redirige a OAuth de MercadoLibre

> **`bridge_register` usa la misma infraestructura** (2026-08-04): `setup_account_channels` +
> password que cumple las reglas de complejidad de Chatwoot. Antes no creaba equipos ni labels
> y no seteaba auto-resolve.
> **Auto-cierre**: ya no se configura desde Reply (se eliminó la card del dashboard y el default
> en las cuentas). El vendedor lo activa nativamente en Chatwoot (Settings → Conversation Workflows)
> si lo desea. La conversación del reclamo se cierra a mano.

### Flujo de OAuth Meli

1. Usuario autoriza en `auth.mercadolibre.com/authorization`
2. ML redirige a `/callback?code=...`
3. `meli_callback`:
   - Intercambia `authorization_code` por tokens OAuth
   - Guarda `MeliCredential`
   - Detecta país del vendedor (`site_id`)
   - Dispara `MeliSyncProductsWorker` (sync de catálogo)
   - Dispara `MeliSyncOfficialStoresWorker` (sync de tiendas)
   - Redirige a página de bienvenida

---

## 7. Workers (Sidekiq)

### 7.1 TokenRefreshWorker
```ruby
module ReplyAi
  class TokenRefreshWorker
    include Sidekiq::Worker
    sidekiq_options queue: 'low', retry: 3
  end
end
```
**Cron**: Cada 5 minutos (`*/5 * * * *`).  
**Función**: Refresca tokens OAuth de ML próximos a expirar (ventana de 90 min).  
**API**: `POST https://api.mercadolibre.com/oauth/token` con `grant_type=refresh_token`.

### 7.2 MeliSyncProductsWorker
**Queue**: `low`.  
**Función**: Sincroniza catálogo completo de productos desde ML.  
**Flujo**:
1. Pagina `/users/{ml_user_id}/items/search` (50 items por página)
2. Para cada lote de 20 items, consulta `/items?ids=...`
3. Crea/actualiza `MeliProduct` con 30+ campos
4. Sincroniza categorías (sub + master)
5. Actualiza `custom_attributes.syncing_products` para polling del dashboard

### 7.3 MeliSyncOfficialStoresWorker
**Queue**: `default`, retry: 3.  
**Función**: Sincroniza tiendas oficiales del vendedor.  
**API**: `/users/me` → `/users/{user_id}/official_stores`.

### 7.4 DocumentProcessorWorker
**Queue**: `default`.  
**Función**: Procesa documentos RAG (pre-venta): extrae texto con Tika (PDF, DOCX) o lee TXT directamente, guarda contenido, notifica a n8n para generar embedding.

### 7.5 PvDocumentProcessorWorker
**Queue**: `default`.  
**Función**: Igual que DocumentProcessorWorker pero para documentos post-venta (`ReplyAiPvDocument`).

### 7.6 BulkImportWorker
**Queue**: `default`.  
**Función**: Importa documentos desde CSV/XLSX. Parsea archivo, crea `ReplyAiDocument` o `ReplyAiPvDocument` por fila, notifica a n8n para embeddings. Soporta CSV (con detección de encoding y separador) y XLSX (vía gem `roo`). Recibe `mode: 'pre' | 'pv'` (post-venta usa el webhook de embeddings PV con `doc_type: 'pv'`).

### 7.7 ClaimsSyncWorker (Fase 2)
**Función**: Sincroniza reclamos abiertos desde ML (`POST /post-purchase/v1/claims/search?seller_id=&status=opened`) → upsert `MeliClaim` → vincula orden → evalua automatización. Se dispara desde OAuth/signup/activación/botón UI.

### 7.8 ClaimAgentWorker (Fase 2)
**Función**: Motor agente ReAct con OpenAI function calling (8 tools, máx 5 iteraciones, modo supervisado → `pending_action`). Ver §18.3.3. En **modo receive-only** corre en dry-run (las tools que ejecutarían en ML se simulan: `{ok, receive_only, simulated}`).

### 7.9 ClaimAutomation (Fase 2)
**Función**: Automatización determinista pre-agente (PNR→evidencia, PDD→devolución/reembolso parcial, devolución simple, límite de montos, tipos excluidos). Ver §18.3.4. En **modo receive-only** evalúa y registra la decisión en `agent_log` (`automatizacion_receive_only`) sin ejecutar.

### 7.10 BridgeApi (bridge Yobot, 2026-08-05)
**Función**: Cliente del bridge — `POST {YOBOT_BRIDGE_URL}/api/bridge/execute-claim-action` con HMAC (`BRIDGE_SECRET` + `X-Bridge-Signature`). Misma interfaz pública que `MeliApi` (intercambiable vía `ReplyAi::MeliApi.for(account)` — cuentas bridge → `BridgeApi`, nativas → `MeliApi`). Cubre las 21 acciones de claims/returns/changes + `sync-products`/`sync-official-stores`. `upload_claim_evidence` envía `{file_base64, file_name, mime_type}` (Yobot arma el multipart). Errores: `BridgeApi::Error < MeliApi::Error`; 502 con detalle crudo de ML; `bridge_not_configured` si faltan las env vars. **2026-08-07**: agrega `pack_messages(pack_id, mark_as_read:)` → `POST /api/bridge/get-pack-messages` (estado de lectura de mensajes post-venta); `MeliApi` agrega la misma firma (GET directo a ML con `tag=post_sale`). **2026-08-09**: agrega `item(item_id)`/`item_description(item_id)` a `MeliApi` (GET `/items/:id` — panel Producto ML); `BridgeApi` los define con error `not_in_bridge_contract` (el contrato Yobot no los expone → el controller hace fallback a catálogo local + permalink).

### 7.11 MessageReadSyncWorker (estado de lectura, 2026-08-07)
**Cron**: `*/1 * * * *` (`reply_ai_message_read_sync_job` en `config/schedule.yml`).
**Función**: Para cada cuenta con credenciales y conversaciones post-venta abiertas con mensajes salientes sin `read` (con `content_attributes.ml_message_id`), consulta el pack con `mark_as_read: false` (solo consulta) y PATCH a `read` los mensajes del vendedor cuyo `message_date.read` ya existe en ML → la burbuja pasa a ✓✓ azul. Lógica compartida en `ReplyAi::MessageReadSync` (también usado por el endpoint `sync-conversation-reads` con `mark_as_read: true` — marca los mensajes del comprador como leídos en ML). Rama nativa (`MeliApi`) / bridge (`BridgeApi`). **Cada 1 min (no 5) porque la API de ML tarda >30s en reflejar el `message_date.read` tras la lectura del comprador** — el sync por forward (nodo `sync_message_reads`) corre antes y no lo ve; el worker garantiza el tick azul en ≤1 min.

---

## 8. Middleware de UI (InjectCssMiddleware)

`custom/lib/reply_ai/inject_css_middleware.rb` (325 líneas)

### Qué hace

Inyecta CSS y JavaScript en las respuestas HTML del dashboard (`/app/*`).

### CSS inyectado (agentes)

| Regla | Efecto |
|-------|--------|
| Oculta sub-items de Informes | Solo deja "Resumen" |
| Oculta panel central vacío | Limpia el estado "sin conversaciones" |
| Oculta sección Campañas | `li:has(a[href*="/campaigns"])` |
| Oculta Centro de ayuda | `li:has(a[href*="/portals"])` |
| Oculta sub-items de Ajustes | Solo deja "Respuestas personalizadas" |
| Oculta items del menú de perfil | Solo deja "Cerrar sesión" |
| Oculta botón "Redactar nueva conversación" | Botón lápiz |
| Oculta acciones de contacto | Merge, delete, etc. |
| Oculta etiquetas de conversación | Sidebar labels |
| Oculta Macros | Sidebar macros |
| **MercadoLibre inbox**: oculta emoji, attachments, mic, firma, copilot | Solo cuando `body.reply-ai-meli-inbox` |

### JavaScript inyectado

1. **Patch de permisos de Reports**: Agrega `'agent'` a los permisos de la ruta `account_overview_reports` para que agentes vean Reportes.
2. **Detector de inbox Meli**: `MutationObserver` que agrega clase `reply-ai-meli-inbox` al `<body>` cuando el inbox activo contiene "MercadoLibre".
3. **Link "Configuración Bot"**: Inyecta un item en el menú de perfil que navega a `/dashboard?account_id=X`. Detecta el `account_id` del Vue store, del dataset del sidebar switcher, o del path.

### Control de acceso

El middleware verifica la sesión Warden para decidir qué inyectar:
- **SuperAdmins y Admins**: Solo el link "Configuración Bot" (sin restricciones de UI).
- **Agentes**: CSS completo de restricciones + link de configuración.

---

## 9. Initializers Custom

### 9.1 `00_custom_load_paths.rb`
Registra `custom/` en Zeitwerk y configura vistas. Ver sección 14.

### 9.2 `reply-ai_routes.rb`
Define 29 rutas prependidas al router de Rails. Ver sección 12.

### 9.3 `reply_ai_account_associations.rb`
Extiende `Account` con `has_many` para los 5 modelos custom.

### 9.4 `reply_ai_cron.rb`
Registra `ReplyAi::TokenRefreshWorker` como cron job de Sidekiq (cada hora, minuto 0).

### 9.5 `reply_ai_middleware.rb`
Registra `ReplyAi::InjectCssMiddleware` en el stack de Rack.

### 9.6 `reply_ai_schema_guard.rb`
**Propósito**: Proteger tablas custom contra `db:schema:load` o `db:reset`.  
**Mecanismo**:
1. Agrega `custom/db/migrate/` a `ActiveRecord::Migrator.migrations_paths`
2. En `after_initialize`, verifica si hay migraciones custom pendientes
3. Si las hay, las aplica automáticamente

### 9.7 `custom_error_codes.rb`
```ruby
Rack::Utils::HTTP_STATUS_CODES[901] = 'Trial Expired'
Rack::Utils::HTTP_STATUS_CODES[902] = 'Account Suspended'
```

---

## 10. Esquema de Base de Datos Custom

### Tablas (10 total)

| Tabla | Columnas clave | Propósito |
|-------|---------------|-----------|
| `meli_credentials` | `account_id`, `ml_user_id` (unique), `access_token`, `refresh_token`, `expires_at`, `status` | Tokens OAuth ML |
| `meli_products` | `account_id`, `meli_item_id` (unique), `title`, `thumbnail`, `status`, `category_id`, `price`, `sold_quantity`, `pictures` (jsonb), `attributes_data` (jsonb), `raw_data` (jsonb), +20 campos más | Catálogo ML |
| `meli_categories` | `account_id`, `meli_category_id`, `name`, `parent_id`, `level` | Categorías ML |
| `meli_official_stores` | `account_id`, `meli_store_id` (unique), `name`, `status`, `logo`, `custom_greeting` | Tiendas oficiales |
| `meli_orders` | `account_id`, `ml_order_id` (unique), `ml_buyer_id`, `item_id`, `pack_id`, `order_status`, `message_sent`, `had_questions`, `ai_answered`, `questions_count` + ciclo de vida (Fase 1): `estado_conversacion` (activa/cerrada/needs_human/bloqueada), `handoff_reason`, `last_sentiment`, `consecutive_enojado`, `repeat_count`, `ultimos_mensajes_comprador` (jsonb), `blocked_substatus`, `last_message_at` | Órdenes post-venta + ciclo de vida de conversación |
| `meli_questions` | `question_id` (PK text), `account_id`, `cw_conversation_id`, `status`, `retained_due_lack_of_info` (bool, control de confianza 2026-08-08), `suggested_answer` (text) | Deduplicación de preguntas + retención por falta de información |
| `meli_claims` | `account_id`, `claim_id` (unique), `resource`, `resource_id`, `claim_type`, `stage` (claim/dispute), `status` (opened/closed), `reason_id`, `players` (jsonb), `expected_resolutions` (jsonb), `affects_reputation`, `sale_id`, `pending_action`, `agent_status` (idle/running/pending/done/escalate/error/cancelled), `agent_log` (jsonb), `raw_data` (jsonb), `timeline` (jsonb, historial de eventos 2026-08-09) | Reclamos ML (Fase 2) |
| `reply_ai_documents` | `account_id`, `level`, `reference_id`, `file_name`, `content`, `embedding` (vector(1536)), `source` | Docs RAG pre-venta |
| `reply_ai_pv_documents` | Igual que arriba | Docs RAG post-venta |
| `reply_ai_pre_memory` | `session_id` (string, PK), `message` (jsonb) | Memoria de sesiones pre-venta; usada por `reply_ai_questions_main` en n8n para mantener contexto entre preguntas de un mismo cliente |

### Migraciones (17 archivos en `custom/db/migrate/`)

| Archivo | Descripción |
|---------|-------------|
| `20260210140338_create_meli_credentials.rb` | Crea tabla de credenciales |
| `20260303024806_create_reply_ai_rag_system.rb` | Crea `meli_products`, `meli_categories`, `reply_ai_documents` con vector |
| `20260303044018_add_fields_to_meli_products.rb` | Añade 20+ columnas a productos |
| `20260303044310_add_extra_fields_to_meli_products.rb` | Ídem (idempotente) |
| `20260303225902_create_meli_official_stores.rb` | Crea tiendas oficiales |
| `20260304102833_create_meli_orders.rb` | Crea órdenes |
| `20260305100000_create_reply_ai_pv_documents.rb` | Crea docs post-venta |
| `20260306100000_add_source_to_reply_ai_documents.rb` | Añade columna `source` |
| `20260713000000_add_bridge_enabled_to_meli_credentials.rb` | Añade `bridge_enabled` (bridge Yobot) |
| `20260803000000_add_conversation_lifecycle_to_meli_orders.rb` | Añade ciclo de vida de conversación a `meli_orders` (Fase 1) |
| `20260803100000_create_meli_claims.rb` | Crea tabla de reclamos ML (Fase 2) |
| `20260804000000_add_cw_conversation_ids.rb` | Añade `cw_conversation_id` a `meli_claims` y `meli_orders` (bandeja de reclamos) |
| `20260808000000_add_yobot_chunk_id_to_rag_documents.rb` | Añade `yobot_chunk_id` (index único por account) a `reply_ai_documents` y `reply_ai_pv_documents` (migración RAG, 2026-08-08) |
| `20260808000002_add_retention_to_meli_questions.rb` | Añade `retained_due_lack_of_info` + `suggested_answer` a `meli_questions` (control de confianza, 2026-08-08) |
| `20260809000000_add_timeline_to_meli_claims.rb` | Añade columna JSONB `timeline` (default `[]`) a `meli_claims` (historial de eventos del reclamo, 2026-08-09) |
| `20990101000001_add_conversation_lifecycle_to_meli_orders.rb` | (renombrada desde `20260803000000` — colisionó con upstream v4.17.1) Añade ciclo de vida a `meli_orders` (Fase 1) |
| `20990101000002_add_cw_conversation_ids.rb` | (renombrada desde `20260804000000` — ídem) Añade `cw_conversation_id` a `meli_claims` y `meli_orders` |
| `20260808000001_create_meli_questions.rb` | Crea `meli_questions` (`if_not_exists` — fix crash loop producción 2026-08-31: la tabla nunca tuvo migración, solo el ALTER de retención explotaba al boot) |
| `20260808210000_create_reply_ai_pre_memory.rb` | Crea `reply_ai_pre_memory` (`if_not_exists`; memoria de sesión pre-venta usada por `questions_main` en n8n) |

---

## 11. n8n Workflows

9 workflows JSON en `n8n/` (los JSON del repo son **exports fieles de la instancia dev** —
re-generados el 2026-09-01 desde la DB de n8n de dev; ver §20 y §23):

| Archivo | Función |
|---------|---------|
| `reply_ai_questions_main.json` | **Pre-venta**: Recibe webhook de ML (path `9979f346-...`) → busca credenciales → crea conversación en Chatwoot → busca docs RAG → genera respuesta con OpenAI → envía a ML (nativo) o Yobot (bridge). **Recibe-only**: answer → nota privada en Chatwoot, conversación queda abierta |
| `reply_ai_questions_manual.json` | **Pre-venta manual**: Cuando un humano responde en Chatwoot, reenvía la respuesta a ML (nativo) / Yobot (bridge) |
| `reply_ai_orders_main.json` | **Órdenes**: Recibe notificación de orden → escribe `meli_orders` → envía mensaje post-venta (cortesía/acción-guía) según `cap`/`already_sent` |
| `reply_ai_postsale_main.json` | **Post-venta IA**: pipeline completo (77 nodos): trigger → idempotencia → normalize → sentimiento → lifecycle → RAG post-venta (`/rag/pv_search`) → context_assembler → classify_intent (normalizado) → respuestas con ciclo de labels (`bot-procesando` → `respondida_con_ia` / `atencion-humana` / `esperando_respuesta_manual`) y **ticks de lectura** (`delivered` ✓✓ gris al enviar vía los mirrors Code, `read` ✓✓ azul vía `sync_message_reads` + worker). Ver abajo |
| `reply_ai_postsale_outbound.json` | **Post-venta outbound**: Respuestas humanas de Chatwoot → ML (nativo) / Yobot (bridge), webhook `postsale-outbound`; tras envío exitoso aplica `respondida_manualmente` (reemplaza `esperando_respuesta_manual`) y marca la burbuja `delivered` (✓✓ gris) + persiste `ml_message_id` vía `/api/bridge/message-status` (2026-08-07) |
| `reply_ai_embedding_generator.json` | **Embeddings pre-venta**: webhook `4ac3153f-...` → extrae texto → OpenAI `text-embedding-ada-002` → `UPDATE reply_ai_documents.embedding` |
| `reply_ai_pv_embedding_generator.json` | **Embeddings post-venta**: webhook `pv-embeddings` → igual pero sobre `reply_ai_pv_documents` (RAG post-venta separado, 2026-08-05) |
| `reply_ai_claims_outbound.json` | **Reclamos outbound**: webhook `claims-outbound` → mensajes del agente en el inbox Reclamos → ML (nativo) / `execute-claim-action` (bridge) |
| `reply_ai_postsale_webhook.json` | **Entrada del flujo de mensajes post-venta** (2026-08-05): webhook `chatwoot-postsale` → `Execute Workflow` → `postsale_main` (passthrough). Recibe las notificaciones de mensajes nativas y los forwards de `bridge_message`. Referenciado por `N8N_POSTSALE_WEBHOOK_URL` (sin este workflow los mensajes post-venta no entraban a n8n) |

### RAG post-venta (separado del pre-venta, 2026-08-05)

| | Pre-venta | Post-venta |
|---|---|---|
| Tabla | `reply_ai_documents` | `reply_ai_pv_documents` (misma estructura, tabla propia) |
| Modelo | `ReplyAiDocument` | `ReplyAiPvDocument` (idéntico, `search_for` con cosine) |
| Endpoint n8n | `POST /rag/search` | `POST /rag/pv_search` |
| Embeddings | `reply_ai_embedding_generator` (webhook `4ac3153f-...`) | `reply_ai_pv_embedding_generator` (webhook `pv-embeddings`, worker envía `doc_type: 'pv'`) |
| Workflow que lo usa | `questions_main` (con `item_id` + `category_id`) | `postsale_main` (nodo `rag_search` → `/rag/pv_search`, `item_id` del order del trigger cuando existe) |
| UI | Documentos (tab Pre-Venta) + Importación Masiva | Documentos (tab Post-Venta) + **wizard de Importación Masiva propio** (ids `pv-bulk-*`, destino fijo post-venta) |

- `BulkImportWorker` acepta `mode: 'pv'` → crea `ReplyAiPvDocument` (`source: 'bulk_import'`, level `product`) y postea al webhook PV. El redirect de `bulk_import` con `mode=pv` va a `?tab=postventa&sub=docs`.
- **Bug corregido (2026-08-05)**: el workflow `postsale_main` consultaba `/rag/search` (base pre-venta) — ahora usa `/rag/pv_search`. Y el webhook `pv-embeddings` no existía (los docs PV nunca se indexaban) — se creó el workflow dedicado.

### Grafo de `postsale_main` (restaurado 2026-08-05)

El workflow desplegado tenía **solo 18 conexiones** (pipeline de lifecycle: `process_attachments → get_order_state → check_lifecycle → lifecycle_router → ... → persist_cw_conversation`); el flujo principal (trigger → idempotencia → normalize → RAG → context → intent → respuestas) estaba **desconectado** y `postsale_main` tenía **0 ejecuciones**. Se restauró fusionando las conexiones de la versión anterior (commit `b294af55c`, 28 claves del flujo principal) con las actuales → **58 claves / 67 nodos**, validado con ejecución real (trigger → check_idempotency → is_new_message? → get_account_details → get_message_details). El nodo `rag_search` quedó conectado entre `normalize_message` y `context_assembler`.

**Reglas de negocio post-venta**: el trigger usa `inputSource: passthrough` (recibe el item del caller); `check_idempotency` inserta en `meli_questions` (`'ms_' || body._id`, `account_id` resuelto por `body.user_id`); los 5 nodos de envío (`send_*_reply_ml`) y la escalación son Code nodes con rama bridge (`{YOBOT_BRIDGE_URL}/api/bridge/send-message` con HMAC) / nativa (ML directo); los mirror postean la respuesta a Chatwoot (`private:false`, `source: n8n_ai`).

**Ciclo de labels post-venta (2026-08-07)**: `set_bot_label` (`bot-procesando`) se aplica después de la clasificación de intent (`classify_intent → Wait delay pv → normalize_intent → set_bot_label → intent_router`); `normalize_intent` quita tildes/puntuación para que la clasificación matchee (`Logística.` → `logistica`). `intent_router` tiene fallback (`fallbackOutput: extra`) → nota privada `post_ai_unavailable_note` + `atencion-humana`/`atencion-prioritaria` cuando el intent no matchea o la rama está deshabilitada (`saludo_enabled?`/`logistica_enabled?`/`soporte_enabled?`/`cierre_enabled?` false). Las ramas saludo y cierre terminan con `label_saludo_done`/`label_cierre_done` (`respondida_con_ia`). `bot_active_pv?` false (IA desactivada/horario) → `set_manual_label` (`esperando_respuesta_manual`, patrón pre-venta). `postsale_outbound` aplica `respondida_manualmente` tras el envío manual exitoso (`chatwoot_remove_manual_label` + `chatwoot_add_manual_answer_completed`). Como `POST /labels` reemplaza la lista completa, cada nodo de label deja el estado final deseado.

**Ticks de lectura post-venta (2026-08-07)**: los mensajes salientes de API inbox reflejan `message.status` en la burbuja (`sent` ✓ / `delivered` ✓✓ gris / `read` ✓✓ azul — `MessageMeta.vue`/`MessageStatus.vue`). `send-message` (Yobot) devuelve `{status, pack_id, message_id, ml_status}`; los 4 `mirror_*_to_chatwoot` (Code nodes) crean el mensaje con `content_attributes.ml_message_id` y lo marcan `delivered` vía `POST /api/bridge/message-status` (excepto receive-only). `postsale_outbound` hace lo mismo con el id del mensaje del webhook. El `read` lo sincronizan `sync_message_reads` (nodo tras la ingesta de cada mensaje del comprador → `sync-conversation-reads` con `mark_as_read: true`) y `ReplyAi::MessageReadSyncWorker` (cron `*/5`, `mark_as_read: false`) consultando el pack (`MeliApi#pack_messages` nativo / `BridgeApi#pack_messages` bridge) y matcheando por `ml_message_id` los mensajes del vendedor con `message_date.read`. **Nota (2026-08-07)**: `messages.content_attributes` se almacena doble-encodificado en BD (columna `json` guardando un string JSON) → el match se hace con el accessor de Rails (`m.content_attributes['ml_message_id']`), NO con el operador SQL `->>`; y el worker evita `distinct` + `default_scope` (order) con `::text LIKE` + filtro en Ruby.

### Cómo n8n interactúa con Chatwoot

Los workflows usan nodos de PostgreSQL para consultar directamente la BD:
- `meli_credentials`: tokens OAuth
- `accounts.custom_attributes`: configuración de IA (prompts, delays)
- `meli_official_stores`: saludos por tienda
- `meli_questions`: deduplicación
- `meli_orders`: tracking post-venta

Y usan la **Platform API** de Chatwoot para:
- Crear/actualizar contacts
- Crear conversaciones en el inbox correcto
- Crear mensajes (IA o humanos)
- Cambiar estado de conversación (reopen resolved)

> **Resolución de credenciales determinista (2026-08-07)**: cuando una cuenta tiene varias
> `meli_credentials` (ej. la cuenta 50 del piloto bridge con `1367850269` y `777004`), los
> flujos salientes deben elegir la credencial de forma determinista: `ORDER BY c.id ASC
> LIMIT 1` en el SQL de n8n y `.order(:id).first` en `BridgeApi`/`MeliApi`/
> `ClaimsSyncWorker`/`BridgeConfigSyncWorker`/`claims_sync` (Rails). Un `LIMIT 1` sin orden
> devolvía una fila arbitraria (cambió al actualizarse la fila de `777004` por el
> `TokenRefreshWorker`) → `send-message`/`refresh-token` con `ml_user_id: 777004` → `404` de
> Yobot (el mensaje manual nunca llegaba a ML).

---

## 12. Rutas Custom

Definidas en `config/initializers/reply-ai_routes.rb` vía `Rails.application.routes.prepend`.

```
GET    /                                    landing#index
GET    /signup                              landing#signup
POST   /signup                              landing#create_account
GET    /callback                            landing#meli_callback
GET    /dashboard                           landing#dashboard
GET    /dashboard/status                    landing#dashboard_status
GET    /dashboard/products                  landing#dashboard_products
GET    /dashboard/pv-products               landing#pv_dashboard_products
POST   /dashboard/update                    landing#update_settings
POST   /dashboard/upload                    landing#upload_document
DELETE /dashboard/docs/:id                  landing#destroy_document
POST   /rag/search                          landing#rag_search
POST   /rag/pv_search                       landing#pv_rag_search
GET    /go_to_chats                         landing#go_to_chats
PATCH  /dashboard/stores/:store_id/greeting landing#update_store_greeting
POST   /dashboard/stores/refresh            landing#refresh_official_stores
GET    /bot_active                          landing#bot_active
GET|POST /conversation_ai_gate              landing#conversation_ai_gate
GET    /dashboard/post-venta                landing#post_venta
POST   /dashboard/post-venta/update         landing#update_post_venta
POST   /dashboard/pv-upload                 landing#pv_upload_document
DELETE /dashboard/pv-docs/:id               landing#pv_destroy_document
DELETE /dashboard/pv-docs/:id/ajax          landing#pv_destroy_document_ajax
POST   /dashboard/bulk-import/preview       landing#bulk_import_preview
POST   /dashboard/bulk-import               landing#bulk_import
GET    /dashboard/docs                      landing#product_docs_list
DELETE /dashboard/docs/:id/ajax             landing#destroy_document_ajax
GET    /dashboard/refresh-tokens            landing#refresh_tokens
POST   /dashboard/bridge-sync-config        landing#bridge_sync_config
POST   /dashboard/migrate-rag-pre           landing#migrate_rag_pre
POST   /dashboard/migrate-rag-post          landing#migrate_rag_post
GET    /dashboard/confidence-report         landing#confidence_report

# Reclamos / devoluciones / cambios (Fase 2, ver §18.3.5)
POST   /claims_webhook                      landing#claims_webhook
GET    /dashboard/claims                    landing#claims_index
GET    /dashboard/claim-panel               landing#claim_panel
GET    /dashboard/claims/panel-data         landing#claim_panel_data   # Dashboard App Reclamo ML (2026-08-09)
GET    /dashboard/claims/data               landing#claims_list
POST   /dashboard/claims/sync               landing#claims_sync
GET    /dashboard/claims/:id                landing#claim_detail
GET    /dashboard/claims/:id/messages       landing#claim_messages
GET    /dashboard/claims/:id/evidences      landing#claim_evidences
POST   /dashboard/claims/:id/message        landing#claim_send_message
POST   /dashboard/claims/:id/evidence       landing#claim_send_evidence
POST   /dashboard/claims/:id/refund         landing#claim_refund
POST   /dashboard/claims/:id/partial-refund landing#claim_partial_refund
GET    /dashboard/claims/:id/available-offers  landing#claim_available_offers
POST   /dashboard/claims/:id/allow-return   landing#claim_allow_return
POST   /dashboard/claims/:id/open-dispute   landing#claim_open_dispute
GET    /dashboard/claims/:id/affects-reputation landing#claim_affects_reputation
GET    /dashboard/claims/:id/agent-pending  landing#claim_agent_pending
POST   /dashboard/claims/:id/agent-execute  landing#claim_agent_execute
POST   /dashboard/claims/:id/agent-cancel   landing#claim_agent_cancel
POST   /dashboard/claims/:id/agent-rerun    landing#claim_agent_rerun
GET    /dashboard/returns/:id               landing#return_detail
POST   /dashboard/returns/:id/review        landing#return_review
GET    /dashboard/returns/:id/reasons       landing#return_reasons
GET    /dashboard/returns/:id/cost          landing#return_cost
GET    /dashboard/changes/:id               landing#change_detail
POST   /dashboard/changes/:id/allow-replace landing#change_allow_replace

# Bridge Yobot ↔ Reply-AI (Fase 3, ver §18.7)
POST   /api/bridge/seller-status            landing#bridge_seller_status
POST   /api/bridge/register                 landing#bridge_register
POST   /api/bridge/question                 landing#bridge_question
POST   /api/bridge/message                  landing#bridge_message
POST   /api/bridge/order                    landing#bridge_order
POST   /api/bridge/claim                    landing#bridge_claim
POST   /api/bridge/manual-response          landing#bridge_manual_response

# Estado de lectura de mensajes post-venta (2026-08-07) — interno n8n → Rails (x-internal-secret)
POST   /api/bridge/message-status           landing#bridge_message_status
POST   /api/bridge/sync-conversation-reads  landing#bridge_sync_conversation_reads

# Interno n8n → Rails: firma HMAC para el bridge (los Code nodes no pueden usar crypto)
POST   /bridge/sign                         landing#bridge_sign

# Dashboard Apps "Venta ML" y "Producto ML" (2026-08-08/09, ver §21)
GET    /dashboard/sale-panel                landing#sale_panel
GET    /dashboard/sales/panel-data          landing#sale_panel_data
GET    /dashboard/sales/:id                 landing#sale_detail
GET    /dashboard/product-panel             landing#product_panel
GET    /dashboard/product-panel/data        landing#product_panel_data
```

---

## 13. Variables de Entorno Necesarias

### Para Reply-AI

| Variable | Propósito |
|----------|-----------|
| `CHATWOOT_PLATFORM_TOKEN` | Token para Platform API (crear users/accounts/inboxes) |
| `ML_APP_ID` | MercadoLibre App ID (OAuth) |
| `ML_SECRET_KEY` | MercadoLibre Secret Key (OAuth) |
| `ML_REDIRECT_URI` | URL de callback OAuth |
| `N8N_WEBHOOK_URL` | Webhook de n8n para el flujo manual (workflow `questions_manual`, path `4a26f4e3-...`) — también se usa como webhook de salida manual en las cuentas |
| `N8N_QUESTIONS_WEBHOOK_URL` | Webhook de n8n de `questions_main` (path `9979f346-...`) — entrada de preguntas nativas y target de `bridge_question`/`bridge_order` (2026-08-04) |
| `N8N_POSTSALE_WEBHOOK_URL` | Webhook de n8n post-venta (`/webhook/chatwoot-postsale`, workflow `reply_ai_postsale_webhook` → `postsale_main`) — entrada de mensajes post-venta nativos y target de `bridge_message` |
| `N8N_POSTSALE_OUTBOUND_WEBHOOK_URL` | Webhook de n8n para salida manual post-venta |
| `N8N_EMBEDDING_WEBHOOK_URL` | Webhook de n8n para generar embeddings (pre-venta) |
| `N8N_PV_EMBEDDING_WEBHOOK_URL` | Webhook de n8n para embeddings post-venta (`/webhook/pv-embeddings`, workflow `reply_ai_pv_embedding_generator`) |
| `N8N_CLAIMS_OUTBOUND_WEBHOOK_URL` | Webhook de n8n para salida de reclamos (`/webhook/claims-outbound`, workflow `reply_ai_claims_outbound`) |
| `TIKA_URL` | URL de Apache Tika (extracción de texto) |
| `OPENAI_API_KEY` | API key de OpenAI (usada por n8n, referenciada en config) |
| `OPENAI_VISION_MODEL` | Modelo de visión para comprensión de imágenes en post-venta (default `gpt-4o-mini`, Fase 1) |
| `OPENAI_WHISPER_MODEL` | Modelo de transcripción de audio (default `whisper-1`, Fase 1) |
| `REPLY_RECEIVE_ONLY` | **Modo recepción solamente** (`true`/`false`, ver §19): habilita el gate de testing; las cuentas marcadas `receive_only` reciben/ingestan pero no envían a ML/Yobot. Debe estar en `.env` (rails la lee vía `env_file`) y en `docker-compose.yaml` para `n8n-main` y `n8n-worker` (n8n no tiene `env_file` — la var se pasa explícita con default `false`) |
| `INTERNAL_API_SECRET` | Secret para los endpoints internos de n8n (`x-internal-secret`: `/rag/search`, `/rag/pv_search`, `/bot_active`, `/conversation_ai_gate`) |
| `REPLY_AGENT_EMAIL` / `REPLY_AGENT_NAME` / `REPLY_AGENT_PASSWORD` | Usuario agente común reply-ai (creado en signup) |
| `BRIDGE_SECRET` / `YOBOT_BRIDGE_URL` | Bridge Yobot — **requeridas para el bridge** (2026-08-05). Rails las lee de `.env` (constante `BridgeAuth::BRIDGE_SECRET` al boot; cambiarlas requiere recrear el contenedor). n8n las lee de docker-compose (`n8n-main` + `n8n-worker`). `YOBOT_BRIDGE_URL` vacía → `BridgeApi` degrada con error claro (`bridge_not_configured`) |
| `YOBOT_ML_APP_ID` / `YOBOT_ML_SECRET_KEY` | Credenciales de la **app de ML de Yobot** — refresh directo a ML de los usuarios **MIGRADOS** (perfil §18.9, implementado 2026-08-07): `TokenRefreshWorker` refresca el token del seller con estas credenciales + su `refresh_token` (el token lo emitió la app de Yobot; solo esa app puede refrescarlo). Verificado en el piloto (cuenta 50) |
| `SUPABASE_URL` / `SUPABASE_SERVICE_KEY` | **Migración RAG desde Yobot** (§18.10, 2026-08-08): URL del proyecto Supabase de Yobot (`https://pwooibyvhlimuhtgtpsu.supabase.co`) + service role key. `YobotRagMigrator` lee los chunks (`{ml_user_id}` pre / `pv_{ml_user_id}` post) vía REST y los importa a Reply. Si faltan, el worker falla con error claro |

### Para Chatwoot base

Ver `.env.example` (285 líneas) para todas las variables de entorno de Chatwoot.

---

## 14. Mecanismo de Extensión (custom/)

### Principio
El directorio `custom/` es un overlay que extiende Chatwoot **sin modificar ningún archivo core**. Chatwoot lo soporta nativamente vía `lib/chatwoot_app.rb`.

### Cómo funciona

```
lib/chatwoot_app.rb:
  def self.custom?
    @custom ||= root.join('custom').exist?   # true si el directorio existe
  end

  def self.extensions
    if custom?
      %w[enterprise custom]   # custom tiene prioridad sobre enterprise
    elsif enterprise?
      %w[enterprise]
    else
      %w[]
    end
  end
```

### Carga de archivos

| Componente | Mecanismo | Archivo responsable |
|-----------|-----------|---------------------|
| Modelos | `Zeitwerk::Loader#push_dir` | `00_custom_load_paths.rb` |
| Controladores | `Zeitwerk::Loader#push_dir` | `00_custom_load_paths.rb` |
| Librerías | `Zeitwerk::Loader#push_dir` | `00_custom_load_paths.rb` |
| Vistas | `ActionController::Base.prepend_view_path` | `00_custom_load_paths.rb` |
| Rutas | `Rails.application.routes.prepend` | `reply-ai_routes.rb` |
| Migraciones | `ActiveRecord::Migrator.migrations_paths` + auto-apply | `reply_ai_schema_guard.rb` |
| Middleware | `Rails.application.config.middleware.use` | `reply_ai_middleware.rb` |
| Cron jobs | `Sidekiq::Cron::Job.create` | `reply_ai_cron.rb` |
| Asociaciones | `Account.class_eval` en `to_prepare` | `reply_ai_account_associations.rb` |

### Extensiones futuras

Para extender clases core, usar `prepend_mod_with` / `include_mod_with`:

```ruby
# custom/app/models/custom/concerns/account.rb
module Custom::Concerns::Account
  extend ActiveSupport::Concern
  included do
    has_many :mi_nuevo_modelo
  end
end

# En un initializer:
Account.include_mod_with('Concerns::Account')
```

---

## 15. Flujo de Actualización de Chatwoot

### Proceso seguro

```bash
# 1. Fetch upstream
git fetch upstream
git merge upstream/develop

# 2. Resolver conflictos si los hay
#    - Archivos eliminados por upstream: git rm
#    - Archivos nuevos de upstream: git add
#    - Content conflicts: resolver manualmente

# 3. Reconstruir y reiniciar
docker compose build --no-cache rails
docker compose down && docker compose up -d

# 4. Migrar base de datos
docker compose exec rails bundle exec rails db:migrate

# 5. Verificar integridad
docker compose exec rails bundle exec rails runner custom/verify.rb
# Deben salir todos ✓ (59 checks)

# 6. Commit y push
git add -A
git commit -m "update: chatwoot upstream vX.Y.Z"
git push origin master
```

### Qué NO hacer

- `rails db:reset` — borra TODAS las tablas (incluyendo custom)
- `rails db:schema:load` — recrea desde `schema.rb` (el schema guard lo mitiga pero los datos se pierden)
- `rails db:drop db:create db:migrate` — igual que reset

### Qué archivos preservar en updates

Estos archivos NO existen en el upstream de Chatwoot, por lo que no generan conflictos:
- `custom/` (todo el directorio)
- `config/initializers/00_custom_load_paths.rb`
- `config/initializers/custom_enterprise_guard.rb`
- `config/initializers/reply-ai_routes.rb`
- `config/initializers/reply_ai_account_associations.rb`
- `config/initializers/reply_ai_cron.rb`
- `config/initializers/reply_ai_middleware.rb`
- `config/initializers/reply_ai_schema_guard.rb`
- `n8n/` (workflows)
- `TECHNICAL.md` (este documento)

### 15.1 Lecciones de la actualización a v4.17.1 (2026-08-31)

1. **Mergear el TAG de release** (`git merge v4.17.1`), no `upstream/develop` (la punta puede traer commits sin liberar).
2. **Colisión de timestamps de migraciones**: antes de commitear el merge, comparar las migraciones nuevas de upstream contra las custom:
   `git diff --name-only --diff-filter=A <tag_viejo> <tag_nuevo> -- db/migrate/ | grep -f <(ls custom/db/migrate | cut -c1-14)`
   Una colisión hace que upstream **saltee silenciosamente** su migración (la fila de `schema_migrations` ya existe) y el boot crashee después. Convención nueva: **las migraciones custom nuevas usan el rango `2099...`** (imposible de colisionar).
3. **Si se renombra una migración ya aplicada**: hacer cirugía en `schema_migrations` (DELETE versión vieja + INSERT nueva) en local **y en producción ANTES del push** — si no, el schema guard del boot intenta re-aplicarla y crashea (y la migración upstream bloqueada no corre).
4. **Rails 7.2 = conexiones lazy**: `ActiveRecord::Base.connection` ya no conecta de verdad; el primer query sí y puede explotar fuera de rescates viejos. El schema guard ya tolera BD ausente (necesario para el `assets:precompile` del build de la imagen, que corre sin BD).
5. **Heap de Node**: el Dockerfile usa `NODE_OPTIONS --max-old-space-size=6144` (el dashboard de 4.17 tiene 5070 módulos; con 4096 el `assets:precompile` fallaba en CI).
6. **`.dockerignore` excluye symlinks de IDE** (`.windsurf`, `CLAUDE.md`): el build context desde Windows no los transfiere (`invalid file request`).
7. **`docker restart` sobre un contenedor de swarm task crea huérfanos** (el task viejo sigue corriendo + swarm crea reemplazo → tráfico partido). Para redeployar un servicio: `docker service update --force <servicio>` o el botón Deploy de Easypanel.
8. Tras el deploy: verificar `/api` (`queue_services` + `data_services` en `ok`), el checklist §22.4 y el smoke post-venta.
9. **HEALTHCHECK en la imagen** (self-healing): el runtime define `HEALTHCHECK` sobre `/api` (interval 30s, start-period 240s). En swarm, un task con el proceso wedged (threads bloqueados sin CPU, como ocurrió post-4.17.1) se reemplaza automáticamente en ~1-2 min. Nunca usar `docker restart` sobre contenedores de task: genera huérfanos y trae el wedged de vuelta — siempre `docker service update --force <servicio>`.
10. **`data_services: "failing"` cosmético**: con las conexiones lazy de Rails 7.2, `Base.connection.active?` del healthcheck puede devolver false si el hilo aún no hizo un query real. Las queries funcionan — es un artefacto del endpoint de upstream, corregir en upstream (no tocar).

---

## 16. Script de Verificación

`custom/verify.rb` — 59 checks en 6 categorías:

```bash
# Local
docker compose exec rails bundle exec rails runner custom/verify.rb

# Producción
rails runner custom/verify.rb
```

### Checks

| # | Categoría | Qué verifica |
|---|-----------|-------------|
| 1 | Directorios | `custom/` existe, `app/` está limpio (9 checks) |
| 2 | Autoloading | 15 clases cargan (modelos, workers, controller) |
| 3 | Base de datos | 8 tablas custom existen |
| 4 | Schema guard | Migraciones registradas, 0 pendientes |
| 5 | Initializers | 8 archivos presentes, sin duplicado |
| 6 | Asociaciones | Account tiene los 5 `has_many` correctos |

---

## 17. Desarrollo Local

### Requisitos
- Docker + Docker Compose
- Git

### Inicio

```bash
git clone <repo>
cd chatwoot
docker compose up -d
```

### Servicios

| Servicio | Puerto | Propósito |
|----------|--------|-----------|
| rails | 3000 | Backend Rails |
| vite | 3036 | Frontend dev server (HMR) |
| sidekiq | — | Background jobs |
| postgres | 5432 | Base de datos |
| redis | 6379 | Cache / PubSub |
| n8n | 5678 | Automatización |
| mailhog | 8025 | Captura de emails |
| tika | 9998 | Extracción de texto |

### Comandos útiles

```bash
# Rails console
docker compose exec rails bundle exec rails c

# Sidekiq web UI (super admin)
http://localhost:3000/sidekiq

# Ver logs
docker compose logs -f rails
docker compose logs -f sidekiq

# Ejecutar migrations
docker compose exec rails bundle exec rails db:migrate

# Verificar integridad
docker compose exec rails bundle exec rails runner custom/verify.rb
```

### Convenciones de código

- **Ruby**: RuboCop (150 char max line)
- **Vue/JS**: ESLint (Airbnb + Vue 3)
- **CSS**: Solo Tailwind (sin custom CSS, sin scoped styles, sin inline styles)
- **Frontend components**: `components-next/` para message bubbles
- **i18n**: Solo actualizar `en.yml` y `en.json`
- **Commits**: Conventional Commits (`type(scope): subject`)

---

## 18. Plan de Implementación — Features Pendientes (Yobot → Reply-AI)

> **Estado**: PENDIENTE — documento vivo. Se actualiza por fase a medida que se implementa (los items del checklist se marcan ✅ al completarlos).
> **Referencia**: Yobot es la app legacy (Node.js/MongoDB) en producción con sellers reales conectados. Reply-AI es la evolución hacia Rails + PostgreSQL + pgvector. El gap funcional se relevó del código de Yobot (`C:\Users\Acer\OneDrive\Documentos\Programación\Yobot` — `docs/RESUMEN_TECNICO_YOBOT.md`, 2026-08-03).

### 18.0 Decisiones del owner (2026-08-03)

| # | Tema | Decisión |
|---|------|----------|
| D1 | Roles y permisos | **Nativos de Chatwoot**. No se replica la matriz de roles de Yobot. Todo abierto por ahora |
| D2 | Suscripciones / Pagos | **No se implementa PayPal**. Sin feature gating por plan. Permisos nativos de Chatwoot |
| D3 | Métricas e informes | **Nativos de Chatwoot** (Reports). Sin endpoints custom de métricas |
| D4 | Control de confianza (`requireRagOrConfidence`) | **Decisión revisada (2026-08-08)**: SE implementa (toggle global + por categoría, retención por falta de info, informe "Info Faltante"). Detalle en §18.11. Originalmente: no implementar, compensar con mejor IA |
| D5 | Auto-cierre por inactividad | **Nativo de Chatwoot**: `Account.auto_resolve_after` (minutos) + `auto_resolve_message` / `auto_resolve_label`, procesado por `Conversations::ResolutionJob` (cada hora). Sin worker custom |
| D6 | Timeline de eventos | **Solo conversación nativa de Chatwoot**. Los eventos de sistema (handoff, cierre, reapertura, sentimiento) van como notas privadas / mensajes de actividad en la conversación. Sin columna `timeline` JSONB en `meli_orders` |
| D7 | Sentimiento | **Nodo dedicado de sentimiento** en n8n (costo/latencia aceptados). `classify_intent` queda solo para intención — sin reglas duplicadas |
| D8 | Multimedia | Chatwoot gestiona los adjuntos de forma nativa. Se agrega **comprensión IA de adjuntos** (imagen→Vision, PDF→Tika, audio→Whisper) en el pipeline |
| D9 | Bridge Yobot | **Último paso**: se implementa al terminar las Fases 1 y 2. Guía completa en §18.7 |
| D10 | Arquitectura | Todo el código en `custom/`, `n8n/`, `config/initializers/`. Cero cambios en `app/`, `lib/`, `enterprise/` |
| D11 | Config por seller | Todo en `Account.custom_attributes` (JSONB), mismo mecanismo actual |

### 18.1 Comparativa Yobot vs Reply-AI (con decisión)

| Funcionalidad | Yobot | Reply-AI actual | Decisión |
|--------------|-------|-----------------|----------|
| Pre-venta IA | Completo (prompt + RAG + delay + schedule) | Completo | ✅ Ya implementado |
| Post-venta IA | Pipeline multi-turno (sentimiento, handoff, auto-cierre, multimedia) | Básico (clasificación de intención + respuesta simple) | **Fase 1** (pendiente) |
| Sentiment analysis | 2 capas (keywords + IA) | Solo clasificación de intención | **Nodo dedicado** (D7) |
| Handoff a humano | Automático por múltiples reglas | Kill-switch `conversation_ai_gate` | **Fase 1** sobre el gate nativo |
| Ciclo de vida conversación | Máquina de estados (activa/cerrada/needs_human/bloqueada) | No | **Fase 1** |
| Auto-cierre | Cortesía + inactividad 72h + loop detection | No | **Nativo Chatwoot** (D5) + cortesía/loop en n8n |
| Gestión de reclamos ML | Dashboard + motor agente (function calling, 8 tools, ReAct) + auto PNR/PDD | No | **Fase 2** (pendiente) |
| Devoluciones y cambios | Tracking, revisión, costos | No | **Fase 2** |
| Suscripciones/Pagos | PayPal (TRIAL/STARTER/PLUS/MAX) + feature gating | Placeholder | ❌ No implementar (D2) |
| Roles y permisos | 6 roles granulares | Chatwoot nativo (Admin/Agent) | ❌ Nativos (D1) |
| Dashboard métricas | Heatmap, evolución, conversión, publicaciones sin info | Reports nativo | ❌ Nativos (D3) |
| Mejorar publicaciones | Detección de info faltante + bulk add | No | ❌ No implementar (D4) |
| Multicanal | Planificado (webchat, email, WA, FB, IG) | Nativo (Chatwoot omnicanal) | ✅ Nativo |

---

### 18.2 Fase 1 — Post-venta IA Avanzada

**Impacto**: Alto (experiencia del comprador post-compra).  
**Dependencia**: Ya existe `reply_ai_postsale_main.json` con clasificación básica.  
**Estado**: IMPLEMENTADO (2026-08-03) — pendiente de validación en runtime con seller real

#### Checklist Fase 1

- [x] 1.1 Migración `meli_orders` (campos de ciclo de vida, sentimiento y loop) — `20260803000000_add_conversation_lifecycle_to_meli_orders.rb`
- [x] 1.2 Modelo `MeliOrder` (scopes + helpers de máquina de estados) — `custom/app/models/meli_order.rb`
- [x] 1.3 Nodo dedicado de sentimiento en n8n (`detect_sentiment` + `parse_sentiment` + `update_sentiment_db`)
- [x] 1.4 Ciclo de vida + handoff H1–H6 + reapertura en n8n (`get_order_state` + `check_lifecycle` + `lifecycle_router` + `reopen_*` + `apply_handoff_db`)
- [x] 1.5 Auto-cierre nativo de Chatwoot (signup setea `auto_resolve_after` 72h + sección "Auto-cierre de Conversaciones" en dashboard)
- [x] 1.6 Loop detection en n8n (`detect_loop` + `update_loop_db`)
- [x] 1.7 Comprensión IA de adjuntos (`process_attachments` → Vision/Tika/Whisper, inyectado en `context_assembler`)
- [x] 1.8 Estado visible en UI — **implementado vía nativo (D6)**: label `atencion-humana` (handoff), label `mensajeria-bloqueada` (`set_blocked_label`), cierre nativo de conversación (`resolve_cortesia_conversation`). No hay lista de órdenes en `post_venta.html.erb` (es página de configuración)
- [ ] 1.9 Handoff manual: verificación en runtime del flujo nativo (agente asigna/etiqueta → gate detiene IA) — pendiente de validación con seller real

**Notas de implementación Fase 1 (2026-08-03)**:
- El workflow `reply_ai_postsale_main.json` pasó de 46 a 66 nodos (20 nuevos).
- La máquina de estados se evalúa ANTES del gate (`check_lifecycle` tras `normalize_message`): acciones de sistema (cierre, reapertura, bloqueo, handoff) corren siempre; el sentimiento y la respuesta IA solo cuando el gate permite (`should_ai_respond?`).
- Handoff: `eval_handoff` consolida H1 (sentimiento `requiere_humano`), H2 (`consecutive_enojado >= 2`), H3 (`repeat_count >= 3`) y H4 (keywords legales) → `needs_human` + label + nota privada (reusa `post_handover_note`/`set_human_label`). H5/H6 (claims y bloqueo ML) → `bloqueada` + `blocked_substatus` + label.
- Cortesía: `check_lifecycle` detecta mensajes ≤50 chars (gracias/ok/listo/...) → cierre sin respuesta (nativo: `toggle_status resolved`).
- Reapertura: `cerrada` + mensaje sustantivo → `POST /conversations/:id/reopen` + `estado_conversacion = 'activa'`.
- Loop detection: `ultimos_mensajes_comprador` (últimos 3) + `repeat_count` (≥3 → handoff).
- Adjuntos: `process_attachments` descarga de `GET /messages/attachments/:id`, clasifica por MIME (imagen→Vision con `OPENAI_VISION_MODEL`, PDF→`TIKA_URL`, audio→`whisper-1`) e inyecta `attachment_context` en el prompt. Env vars nuevas: `OPENAI_VISION_MODEL`, `OPENAI_WHISPER_MODEL` (documentar en `.env.example`).
- Variables de entorno nuevas de la Fase 1: `OPENAI_VISION_MODEL=gpt-4o-mini`, `OPENAI_WHISPER_MODEL=whisper-1`.
- **Gating bridge en workflows n8n (2026-08-03)**: los 4 workflows (`questions_main`, `postsale_main`, `questions_manual`, `postsale_outbound`) son bridge-aware:
  - `get_account_details`/`get_ml_credentials`/`get_question_details` incluyen `status`, `bridge_enabled`, `ml_user_id`.
  - Nodos de **fetch ML** (`get_queston_details`, `get_item_details`, descripciones, `get_buyer_details`, `get_message_details`) → Code nodes con rama interna: bridge usa los datos del forward (`body.question/item/buyer`, `body.message`) y lanza error claro si el forward es incompleto (pendiente en Yobot); nativo → fetch ML igual que antes.
  - Nodos de **envío** (`mercadolibre_answer_question`, `mercadolibre_post_answer`, 5× `send_*_reply_ml`, `send_to_ml`) → bridge: `POST {YOBOT_BRIDGE_URL}/api/bridge/send-answer|send-message` con HMAC (`BRIDGE_SECRET` + `X-Bridge-Signature` vía Code node); nativo → ML directo.
  - `refresh_token` → bridge: `/api/bridge/refresh-token`; el UPDATE de credenciales preserva `status='bridge'` (CASE WHEN `bridge_enabled`).
  - `context_assembler` → bridge: contexto de orden/envío desde `body.order`/`body.shipment` (sin ML).
  - `process_attachments` → bridge (2026-08-05): descarga desde las URLs de `body.attachments` del forward (sin token ML) y procesa con Vision/Tika/Whisper (misma lógica que nativo).
  - Chatwoot en `questions_main` (bridge): `chatwoot_search_contact`/`contact_create`/`conversation_create`/`add_message` son passthroughs que reusan la conversación/mensaje ya creados por `bridge_question` (sin duplicados). El controller `bridge_question` envía `topic: 'questions'` a n8n para el routing correcto.
  - Env vars n8n en docker-compose: `BRIDGE_SECRET`, `YOBOT_BRIDGE_URL` (vacías hasta configurar el bridge).
  - **Órdenes/ventas (2026-08-03)**: `reply_ai_orders_main.json` también es bridge-aware — `get_order_details` usa `body.order` del forward (o error claro), `get_action_guide` rutea bridge directo a `send_via_messages`, y `send_via_action_guide`/`send_via_messages` envían vía `{YOBOT_BRIDGE_URL}/api/bridge/send-message` para bridge (nativo: ML igual que antes). El controller `bridge_order` ahora dispara `orders_main` vía n8n (`topic: 'orders_v2'`) para el mensaje post-venta inicial bridgeado. Fix de entrada pre-venta: `bridge_question` apunta al webhook de `questions_main` (`9979f346-...`), no al de `questions_manual` (en producción `N8N_WEBHOOK_URL` debe apuntar a ese webhook).
  - Contrato pendiente de Yobot (forwards completos, execute-claim-action, adjuntos, sync productos): `docs/REQUERIMIENTOS_YOBOT.md`.
- **Env vars en n8n self-hosted**: n8n corre en docker compose (`n8n-main` + `n8n-worker`, modo queue). No hay UI de variables de entorno en la edición comunitaria — se configuran a nivel de proceso en `docker-compose.yaml` (servicio `n8n` → `environment`), en **ambos** servicios. Para que los Code nodes accedan a `$env` se requiere `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` (default: true). Vars configuradas: `OPENAI_API_KEY` (desde `.env`), `OPENAI_VISION_MODEL`, `OPENAI_WHISPER_MODEL`, `TIKA_URL=http://tika:9998`. Verificado con ejecución CLI de un workflow de test (Code node lee `$env` OK, 2026-08-03). Tras modificar env vars: `docker compose up -d n8n-main n8n-worker`.

#### 18.2.1 Migración custom

`custom/db/migrate/<ts>_add_conversation_lifecycle_to_meli_orders.rb`:

```ruby
add_column :meli_orders, :estado_conversacion, :string, default: 'activa'  # activa|cerrada|needs_human|bloqueada
add_column :meli_orders, :handoff_reason,       :string
add_column :meli_orders, :last_sentiment,       :string                    # POSITIVO|NEUTRAL|INSATISFECHO|ENOJADO
add_column :meli_orders, :consecutive_enojado,  :integer, default: 0
add_column :meli_orders, :repeat_count,         :integer, default: 0
add_column :meli_orders, :ultimos_mensajes_comprador, :jsonb, default: []  # últimos 3 textos del comprador
add_column :meli_orders, :blocked_substatus,    :string
add_column :meli_orders, :last_message_at,      :datetime
```

+ CHECK constraint `estado_conversacion IN ('activa','cerrada','needs_human','bloqueada')` + índice `[account_id, estado_conversacion]`.

#### 18.2.2 Modelo MeliOrder

- Scopes: `activas`, `needs_human`, `bloqueadas`, `concluidas`.
- Helpers: `cerrar!(razon:)`, `reabrir!`, `derivar_a_humano!(razon:)`, `bloquear!(substatus:)`, `actualizar_sentimiento!(valor)` (incrementa/decrementa `consecutive_enojado`), `registrar_adjunto!(info)`.

#### 18.2.3 Nodo dedicado de sentimiento (n8n)

Nuevo nodo `detect_sentiment` en `reply_ai_postsale_main.json` (entre `normalize_message` y `classify_intent`):

- POST a OpenAI (`pv_ia.model`, default `gpt-4o-mini`, temperature 0), respuesta JSON estricta:
  ```json
  { "sentiment": "POSITIVO|NEUTRAL|INSATISFECHO|ENOJADO", "requiere_humano": true|false, "motivo": "..." }
  ```
- Input: mensaje actual + historial reciente (mismo contexto que `classify_intent`).
- Persistencia: UPDATE `meli_orders` (`last_sentiment`, `consecutive_enojado`).
- `classify_intent` NO se modifica (solo intención). Sin keywords duplicadas.

#### 18.2.4 Ciclo de vida + handoff (n8n)

Máquina de estados (nodo Code + nodos Switch):

```
activa ──cortesía/problema resuelto──▶ cerrada
activa ──handoff─────────────────────▶ needs_human
activa ──claim dispute / ML bloqueo──▶ bloqueada
cerrada ──nuevo mensaje sustantivo───▶ activa (reapertura)
needs_human ──humano reanuda────────▶ activa
bloqueada ──claim cerrado────────────▶ activa
```

Reglas de handoff:

| # | Gatillo | Detección | Acción |
|---|---------|-----------|--------|
| H1 | Cliente pide humano explícito | Nodo sentimiento `requiere_humano` | `needs_human` |
| H2 | ENOJADO 2 turnos consecutivos | `consecutive_enojado >= 2` | `needs_human` |
| H3 | Loop (3+ mensajes repetidos) | `repeat_count >= 3` | `needs_human` |
| H4 | Menciones legales | Sentimiento/IA detecta (abogado, denuncia, defensa consumidor) | `needs_human` |
| H5 | Claim activo detectado | Claim en dispute (Fase 2) | `bloqueada` |
| H6 | Mensajería bloqueada por ML | `conversation_status` en payload del mensaje | `bloqueada` + `blocked_substatus` |

Handoff = UPDATE `estado_conversacion` + label `atencion-humana` (existente) + **nota privada** en la conversación de Chatwoot (motivo). No responde a ML. El gate `conversation_ai_gate` ya respeta labels/asignación/status — el humano toma la conversación de forma nativa.

Cortesía: nodo Code antes de la IA — mensaje ≤ 50 chars que matchea `^(gracias|ok|listo|genial|perfecto|dale|joya|bueno)(\W|$)` → cerrar sin responder (timeline: nota privada "cerrada por cortesía").

Cierre por IA: `classify_intent`/respuesta marca `problema_resuelto` → `resolve_conversation` (ya existe) + UPDATE `estado_conversacion = 'cerrada'`.

Reapertura: mensaje nuevo entrante con `estado_conversacion = 'cerrada'` y contenido sustantivo → Platform API `POST /conversations/:id/reopen` + UPDATE `activa`.

#### 18.2.5 Loop detection (n8n)

```javascript
// Nodo Code
const ultimos = $json.ultimos_mensajes_comprador || [];
const repetidos = ultimos.filter(m => m === $json.message).length;
const repeatCount = repetidos >= 2 ? (($json.repeat_count || 0) + 1) : 0;
// UPDATE meli_orders SET repeat_count = <valor>, ultimos_mensajes_comprador = [...ultimos, message].slice(-3)
// Si repeatCount >= 3 → handoff (H3)
```

#### 18.2.6 Auto-cierre nativo de Chatwoot (D5)

- En `create_account` (signup): setear `Account.auto_resolve_after` (ej. 4320 min = 72h) vía `update_columns`/API.
- En dashboard (`update_settings`): sección "Auto-cierre de conversaciones" (horas + mensaje opcional + ignore_waiting).
- Nota: también aplica a pre-venta (deseable: preguntas sin actividad se resuelven solas).

#### 18.2.7 Comprensión IA de adjuntos

- Nodo n8n nuevo (`process_attachments`) después de `get_message_details`: detectar `message_resources` con adjuntos (imagen / PDF / audio):
  - **Imagen**: descargar → base64 → inyectar en prompt con `OPENAI_VISION_MODEL` (default `gpt-4o-mini`).
  - **PDF**: enviar a `TIKA_URL` → texto plano.
  - **Audio**: enviar a Whisper API (`whisper-1`) → transcripción.
- Resultado inyectado en `context_assembler` como `attachment_context` ("ADJUNTO RECIBIDO: <descripción/transcripción>").
- Chatwoot mantiene almacenamiento y visualización nativos.
- Persistencia: `ultimo_adjunto_procesado` (jsonb) — opcional, para debug.

#### 18.2.8 UI (chips de estado)

- `post_venta.html.erb`: tabla de órdenes con chip de `estado_conversacion` (activa/cerrada/needs_human/bloqueada) + badge de handoff.
- Polling liviano existente se reutiliza; sin timeline custom (D6).

#### 18.2.9 Verificación Fase 1

- Migración aplicada (schema guard).
- Test manual: mensaje enojado ×2 → `needs_human` + label + nota privada, sin respuesta a ML; cortesía → cierre; mensaje nuevo en cerrada → reapertura; adjunto → contexto inyectado.
- `rails runner custom/verify.rb` sin fallos.

---

### 18.3 Fase 2 — Reclamos, Devoluciones y Cambios

**Impacto**: Muy alto (nuevo revenue stream, diferencial competitivo).  
**Dependencia**: Fase 1 funcionando (handoff para claims).  
**Estado**: IMPLEMENTADO (2026-08-03) — pendiente de validación en runtime con seller real (requiere scope Post Purchase en el token OAuth)

#### Checklist Fase 2

- [x] 2.1 Modelo `MeliClaim` + migración — `20260803100000_create_meli_claims.rb` (+ `agent_status`, `pending_action`, `agent_log`)
- [x] 2.2 Webhook de claims (`POST /claims_webhook`) + sync desde ML (`POST /dashboard/claims/sync` + `ClaimsSyncWorker` en OAuth)
- [x] 2.3 Helpers `ClaimMapper.map` + `parse_ml_error` (en `MeliApi`) — contratos verificados contra Yobot (claimsController.js, handleIncomingClaim.js)
- [x] 2.4 Motor agente ReAct: `ClaimAgentWorker` (Sidekiq, 8 tools reales, máx 5 iteraciones, modo supervisado → `pending_action` + `agent-execute/cancel/rerun`)
- [x] 2.5 Automatización determinista `ClaimAutomation` (PNR→evidencia `{tracking_number, carrier}`, PDD→devolución/reembolso con `reason_id`+`amount` de la oferta más baja, devolución simple, montos máx y tipos excluidos configurables)
- [x] 2.6 Endpoints claims (15) / returns (4) / changes (2) — contratos ML reales (`/post-purchase/v1/...`)
- [x] 2.7 UI dashboard de reclamos (`claims.html.erb` con tabla + polling, detalle con chat/evidencias/acciones/panel agente) + sección "Automatización de Reclamos" en post-venta
- [x] 2.8 Claim en `dispute` → `meli_orders.bloqueada` (y reabre al cerrarse)

**Notas de implementación Fase 2 (2026-08-03)**:
- Endpoints ML verificados contra Yobot: `actions/send-message` (body `{text}`), `expected-resolutions/refund|partial-refund|allow-return`, `partial-refund/available-offers` (respuesta `{offers: [...]}` con `reason_id`+`amount`), `actions/open-dispute`, `actions/evidences` (JSON o multipart `file`), `claims/search?seller_id=&status=opened` (array o `{results}`), returns en `/post-purchase/v2/claims/:id/returns` + `return-review`/`reviews`/`reasons`/`charges/return-cost`, changes en `/post-purchase/v1/claims/:id/changes` + `expected-resolutions/allow-replace`.
- `available_actions` de ML: campo `action` (ej: `add_shipping_evidence`, `allow_return`, `allow_partial_refund`).
- Evidencia PNR: body `{ tracking_number, carrier }` (tracking de la orden + `tracking_method`).
- Config: `custom_attributes.config.automatizacion_reclamos` (`enabled`, `autoEnviarEvidenciaPNR`, `autoAceptarDevolucionPDD`, `autoReembolsoParcial`, `autoAprobarDevolucionSimple`, `montoMaximoAuto`, `montoMaximoDevolucionAuto`, `modoAgenteSupervisado`, `tiposExcluidos`).
- `custom/verify.rb` extendido: tabla `meli_claims`, modelo, workers (ClaimAgentWorker, ClaimsSyncWorker), librerías (MeliApi, ClaimAutomation, ClaimMapper), asociación `has_many :meli_claims`.
- Sanity verificado en consola: mapper, upsert, PNR→send_evidence, handoff, límite de monto, dispute→bloqueada, 8 tools, pending/cancel del agente.
- Requisito de producción: token OAuth con **scope Post Purchase** (Claims API en `/post-purchase/v1/`) — solo para cuentas nativas.
- **Gating bridge (2026-08-03, actualizado 2026-08-05)**: `MeliCredential#bridge?` es el discriminador único. Las cuentas bridge NUNCA llaman a la API de ML: `meli_api_for`/`MeliApi.for` rutean a `BridgeApi` (`execute-claim-action` — 21 acciones, ver §7.10), `bridge_claim` completa el claim (get_claim/get_messages/automatización), `claims_sync`/`ClaimsSyncWorker`/`ClaimAgentWorker`/`ClaimAutomation` ejecutan vía bridge, y los syncs de productos/tiendas usan `sync-products`/`sync-official-stores`. El `reject_bridge_account` (422) se eliminó — ya no aplica. Contrato en `docs/REQUERIMIENTOS_YOBOT.md`.
- **Entrada de reclamos**: para sellers **bridgeados**, los reclamos entran vía `POST /api/bridge/claim` (Yobot forwardea la notificación de ML con `resource` = claim id; Reply-AI registra el claim mínimo con el envelope y **no llama a la API de ML**). La automatización/agente y las acciones del dashboard para bridgeados devuelven 422 con mensaje claro hasta que Yobot implemente `execute-claim-action` (ver `docs/REQUERIMIENTOS_YOBOT.md`). El webhook directo (`POST /claims_webhook`) es solo para cuentas nativas (ignora sellers bridgeados).

#### 18.3.1 Modelo `MeliClaim`

```ruby
# custom/app/models/meli_claim.rb
# Migración custom nueva
create_table :meli_claims do |t|
  t.bigint   :account_id, null: false
  t.bigint   :claim_id, null: false
  t.string   :resource              # order, shipment, payment
  t.bigint   :resource_id
  t.string   :claim_type            # mediations, return, fulfillment, etc.
  t.string   :stage                 # claim, dispute
  t.string   :status                # opened, closed
  t.string   :reason_id
  t.jsonb    :players, default: []
  t.jsonb    :expected_resolutions, default: []
  t.boolean  :affects_reputation, default: false
  t.bigint   :sale_id               # FK opcional a meli_orders
  t.string   :pending_action        # acción del agente que requiere confirmación (modo supervisado)
  t.jsonb    :raw_data, default: {} # Respuesta completa de ML
  t.timestamps
end
add_index :meli_claims, [:account_id, :claim_id], unique: true
add_index :meli_claims, [:account_id, :status]
```

#### 18.3.2 Webhook + Sync

- `POST /claims_webhook` (webhook ML, topics `claims` / `claims_actions`): `mapear_claim` → upsert → vincular `MeliOrder` por `resource_id` → si `stage=dispute` → `meli_orders.bloqueada` → evaluar automatización → si `handoff` → encolar `ClaimAgentWorker`.
- `POST /dashboard/claims/sync`: `GET /post-purchase/v1/claims/search` + upsert. Disparadores: signup TRIAL, activación de cuenta, botón en UI.
- Nota: la Claims API de ML está en `/post-purchase/v1/` — los tokens OAuth requieren scope Post Purchase.

#### 18.3.3 Motor agente (ReAct)

`custom/lib/reply_ai/claim_agent_worker.rb` — loop de hasta 5 iteraciones con OpenAI function calling (`gpt-4o-mini`):

| Tool | Descripción | Requiere confirmación |
|------|-------------|----------------------|
| `get_tracking_status` | Consulta REAL `/shipments/{id}` + análisis (entregado antes/después del reclamo, en plazo, ciudad distinta → escalar; nunca inventa estados) | No |
| `check_claim_policy` | Verificar políticas ML para el reclamo | No |
| `accept_return` | Aceptar devolución | Sí |
| `offer_partial_refund` | Ofrecer reembolso parcial | Sí |
| `send_evidence` | Enviar evidencia de envío (PNR) | No |
| `send_claim_message` | Enviar mensaje al comprador/mediador | No |
| `full_refund` | Reembolso total | Sí |
| `escalate_to_human` | Derivar a operador humano | No |

- Modo supervisado: tools con `requires_confirmation` → `pending_action` en BD + UI espera confirmación (`agent-execute` / `agent-cancel` / `agent-rerun`).
- Progreso del agente → eventos en la UI del dashboard (polling).

#### 18.3.4 Automatización determinista (sin IA, pre-agent)

| Regla | Disparador (`reason_id`) | Condiciones | Acción |
|-------|--------------------------|-------------|--------|
| PNR → evidencia | Empieza con `PNR` | Tracking existe + acción `add_shipping_evidence` disponible | POST tracking como evidencia |
| PDD → devolución | Empieza con `PDD` | `allow_return` disponible | POST `allow-return` |
| PDD → reembolso parcial | Empieza con `PDD` | `allow_partial_refund` disponible | Aceptar oferta más baja |
| Devolución simple | Tipo `return` + motivo simple (`REASON_BUYER_REGRET`, `DOESNT_FIT`, `CHANGED_MIND`, `WRONG_SIZE`, `WRONG_COLOR`, `DONT_LIKE_IT`, `FOUND_BETTER_PRICE`, `NOT_NEEDED`) | Toggle + monto ≤ máx | Aceptar automáticamente |
| Límite general | Cualquier tipo | Monto > `monto_maximo_auto` | Handoff humano |
| Tipos excluidos | Tipo en `tipos_excluidos[]` | — | Handoff humano |

Config en `custom_attributes.config.automatizacion_reclamos` (UI en dashboard post-venta).

#### 18.3.5 Endpoints

```
POST /claims_webhook                                → webhook ML
GET  /dashboard/claims                              → listado
GET  /dashboard/claims/:id                          → detalle (venta + historial comprador)
POST /dashboard/claims/:id/message                  → enviar mensaje
POST /dashboard/claims/:id/evidence                 → evidencia (texto o multipart)
POST /dashboard/claims/:id/refund                   → reembolso total
POST /dashboard/claims/:id/partial-refund           → reembolso parcial
GET  /dashboard/claims/:id/available-offers         → ofertas disponibles
POST /dashboard/claims/:id/allow-return             → aceptar devolución
POST /dashboard/claims/:id/open-dispute             → abrir mediación
GET  /dashboard/claims/:id/affects-reputation       → reputación
GET  /dashboard/claims/:id/agent-pending            → acciones pendientes del agente
POST /dashboard/claims/:id/agent-execute            → ejecutar acción pendiente
POST /dashboard/claims/:id/agent-cancel             → cancelar acción pendiente
POST /dashboard/claims/:id/agent-rerun              → re-ejecutar agente
POST /dashboard/claims/sync                         → sincronizar desde ML
GET  /dashboard/returns/:id                         → detalle devolución
POST /dashboard/returns/:id/review                  → revisar devolución (OK/falla)
GET  /dashboard/returns/:id/reasons                 → motivos de falla
GET  /dashboard/returns/:id/cost                    → costo de devolución
GET  /dashboard/changes/:id                         → detalle cambio
POST /dashboard/changes/:id/allow-replace           → ofrecer reemplazo
```

Todos protegidos con `verify_account_token` + session. Errores de ML mapeados con `parse_ml_error` (401 token/scope, 403 acción no permitida, 404 inexistente, 400 mensajes conocidos).

#### 18.3.6 UI

Tab "Reclamos" en el dashboard (`dashboard.html.erb` o vista nueva): listado con estado/stage/motivo humanizado (diccionario de códigos ML), detalle con chat del reclamo + evidencias + acciones disponibles (habilitadas según `available_actions` de ML), botón Sync, badge de pendientes con polling. Montos en moneda local del seller (`currency_id` de la venta).

#### 18.3.7 Verificación Fase 2

- Webhook de test PNR → evidencia automática; claim complejo → `pending_action` + confirmación UI; sync desde ML.
- `custom/verify.rb` sin fallos.

---

### 18.4 Fase 3 — Bridge Yobot ↔ Reply-AI

**Estado**: ✅ **Bridge completo (2026-08-05)** — Yobot implementó todos los contratos
(`docs/REQUERIMIENTOS_YOBOT.md`) y Reply-AI los consume:

| Item | Estado actual |
|------|---------------|
| Endpoints bridge en `LandingController` (`bridge_question`, `bridge_message`, `bridge_order`, `bridge_register`, `bridge_seller_status`, `bridge_claim`, `bridge_manual_response`) | ✅ Implementado |
| Autenticación HMAC (`bridge_auth.rb`, verificación sobre body crudo) | ✅ Implementado |
| `bridge_claim` completo (claim_data + get_claim + get_messages + automatización/agente) | ✅ Implementado (2026-08-05) |
| `bridge_message` con forward completo (order/shipment/conversation_status/pack_id/_id) | ✅ Implementado (2026-08-05) |
| `ReplyAi::BridgeApi` — 21 acciones de claims/returns/changes vía `execute-claim-action` + syncs | ✅ Implementado (2026-08-05) — reemplaza el `reject_bridge_account` (422) de claims/returns/changes |
| `ClaimAgentWorker` / `ClaimAutomation` / `ClaimsSyncWorker` en modo bridge | ✅ Implementado (2026-08-05): tools ejecutan vía `execute-claim-action` |
| Sync de productos/tiendas vía bridge (`sync-products`, `sync-official-stores`) | ✅ Implementado (2026-08-05) |
| Adjuntos bridge (URLs de `message_attachments` → `process_attachments` en n8n) | ✅ Implementado (2026-08-05) |
| Gating nativo/bridge (Rails + n8n) | ✅ Implementado |
| `TokenRefreshWorker` delegando a Yobot para cuentas bridge | ✅ Implementado |
| `bridge_manual_response` | ✅ Implementado (2026-08-05): nota privada en la conversación (pre-venta por `question_id`, post-venta por `pack_id`) |
| Migración de sellers Yobot (`YobotMigrator`) | ❌ Pendiente |
| **Mapeo de configuración Yobot → Reply** (prompts, delays, schedules, saludos por tienda, automatización de reclamos) | ✅ **Implementado y validado end-to-end (2026-08-07)**: `BridgeConfigMapper` + `BridgeConfigSyncWorker` + trigger en `bridge_register` + rake `reply_ai:sync_bridge_config[account_id]` + botón "Sincronizar config de Yobot"; campos nuevos (`post_venta_ia.delay`, `post_venta_ia.scheduledMode`, `automatizacion_reclamos.delayRespuesta`); `bot_active?scope=postventa`; n8n postsale_main con schedule PV y `Wait delay pv`. Endpoint `sync-config` de Yobot **implementado y verificado** (200 con firma real; sync real de TTEST25875 ejecutado — config mapeada y persistida). Detalle en `docs/REQUERIMIENTOS_YOBOT.md` |
| Piloto LOCAL con usuario real (modo `mirror`) | ⏳ Pendiente (Reply listo; falta configurar `REPLY_AI_BRIDGE_URL`/`BRIDGE_SECRET` del lado Yobot y marcar el usuario) |

### 18.5 Reglas de Implementación

1. **TODO el código nuevo va en `custom/`** — modelos, controladores, workers, vistas, migraciones.
2. **Workflows n8n en `n8n/`** — modificar existentes, crear nuevos.
3. **Endpoints nuevos en `LandingController`** o nuevos controladores en `custom/app/controllers/`.
4. **Workers Sidekiq en `custom/lib/reply_ai/`**.
5. **Migraciones en `custom/db/migrate/`** — nunca en `db/migrate/`.
6. **NUNCA modificar archivos en `app/` o `enterprise/`**.
7. **Variables de entorno nuevas** documentarlas en `.env.example` y este documento.
8. **Verificar integridad** con `rails runner custom/verify.rb` tras cada fase.

### 18.6 Verificación por Fase

- Tras cada fase: `rails runner custom/verify.rb` (58 checks actuales) + checks nuevos de la fase (tablas, workers, rutas, asociaciones).
- Testing manual del flujo afectado (webhook simulado / seller de test).
- Actualizar este documento (§18) al completar cada fase: marcar checklist y mover el detalle terminado a la sección correspondiente del documento.

---

### 18.8 Bandeja de Reclamos MercadoLibre en Chatwoot (implementado 2026-08-04)

**Visión**: la comunicación del reclamo vive en el inbox **"Reclamos (MercadoLibre)"** (1 conversación = 1 reclamo, `source_id = claim_id`). La conversación post-venta vinculada se etiqueta. El panel de gestión se embebe como Dashboard App nativa de Chatwoot. La tabla estilo Yobot sigue en `/dashboard/claims`.

#### Labels de reclamos

| Label | Cuándo | Dónde |
|---|---|---|
| `reclamo-abierto` | claim `opened` | conversación post-venta vinculada + conversación del reclamo |
| `reclamo-mediacion` | `stage = dispute` | conversación del reclamo → **banner flotante "los mensajes llegan a ML, no al comprador"** |
| `reclamo-cerrado` | claim `closed` (swap de abierto/mediacion) | ambas |
| `reclamo-pendiente-accion` | `pending_action` del agente IA | conversación del reclamo |
| `reclamo-derivado` | `escalate_to_human` | conversación del reclamo |

#### Flujos

- **Nativo** (`claims_webhook`): upsert → `refresh_claim_labels` (conversación del reclamo + labels + etiqueta post-venta) → `mirror_claim_messages` (mensajes del claim en Chatwoot con dedupe por `content_attributes.ml_message_id`, reabre la conversación si está resuelta). La automatización/agente sigue igual.
- **Bridge** (`bridge_claim`): registra el claim (envelope/`claim_data`) + `get_claim` (datos autoritativos) + `refresh_claim_labels` (conversación con contacto del complainant o fallback `ml_claim_<id>`) + mirror `get_messages` + automatización/agente vía `execute-claim-action` (2026-08-05).
- **Outbound** (`n8n/reply_ai_claims_outbound.json`, webhook `claims-outbound`): filtra `additional_attributes.type === 'reclamo'` + outgoing + no private + no espejos → nativo: `POST /post-purchase/v1/claims/{id}/actions/send-message`; bridge: `execute-claim-action send_message` (pendiente Yobot) → reabre la conversación (`toggle_status open`).
- **Cierre**: el reclamo se cierra cuando ML lo cierra (labels swap a `reclamo-cerrado`). La conversación la resuelve el agente **a mano** — sin auto-resolve para reclamos.
- **n8n postsale_main**: `persist_cw_conversation` escribe `meli_orders.cw_conversation_id` al crear/reusar la conversación post-venta (base del vínculo para etiquetar).

#### Dashboard App

- Registrada por cuenta en `setup_account_channels` (y backfill): título "Reclamo ML", iframe → `/dashboard/claim-panel?conversation_id={{conversation.id}}`.
- `claim_panel` resuelve el claim por `cw_conversation_id` o por `source_id` de la conversación y renderiza la vista compacta (`claim_panel.html.erb`): agente IA + acciones + chat + evidencias (mismos endpoints JSON).

#### Infraestructura

- Migración `20260804000000_add_cw_conversation_ids.rb`: `meli_claims.cw_conversation_id` + `meli_orders.cw_conversation_id`.
- Backfill cuentas existentes: `bundle exec rails reply_ai:backfill_claims_inbox` (inbox + labels + Dashboard App, idempotente).
- Webhook de cuenta nuevo: `N8N_CLAIMS_OUTBOUND_WEBHOOK_URL` (default `http://n8n-main:5678/webhook/claims-outbound`).
  **En producción definir las 4 URLs de webhook** (`N8N_WEBHOOK_URL`, `N8N_POSTSALE_WEBHOOK_URL`,
  `N8N_POSTSALE_OUTBOUND_WEBHOOK_URL`, `N8N_CLAIMS_OUTBOUND_WEBHOOK_URL`) apuntando a la instancia
  n8n pública — si no, las cuentas nuevas reciben webhooks muertos (`n8n-main:5678` es interno de docker).
  El backfill matchea por **nombre** (idempotente aunque las URLs difieran).
- **Auto-resolve eliminado de Reply** (2026-08-04): sin card en dashboard, sin default en cuentas; queda solo la configuración nativa de Chatwoot.

### 18.9 Perfil MIGRADO — trigger vía bridge + ejecución nativa en Reply (implementado 2026-08-07)

**Qué es**: usuarios de Yobot que se migran a Reply pero **no pueden autorizar la app de ML de Reply** (restricción comercial) — solo autorizan la app de Yobot. Las notificaciones de ML llegan a Yobot y este las forwardea a Reply (**trigger**); Reply **consulta y actúa directo en MercadoLibre** con el token del seller (emitido por la app de Yobot — funciona para llamadas directas; verificado con `GET /users/me` → 200). El refresh se hace **directo a ML con las credenciales de la app de Yobot** configuradas en `.env`. **Flag de Yobot obligatorio: `mode: "full"`** (nunca `mirror` → doble respuesta).

**Credencial del seller (`meli_credentials`)**:
- `status: 'active'` → ejecución nativa (`MeliApi` directo, ramas n8n nativas).
- `bridge_enabled: true` → marca "migrado" (trigger vía Yobot + refresh con credenciales de Yobot).
- Se conservan `access_token`/`refresh_token` vigentes (emitidos por la app de Yobot).

**Env vars nuevas (`.env` de Reply)**:

| Variable | Propósito |
|---|---|
| `YOBOT_ML_APP_ID` | client_id de la app de ML de Yobot (refresh directo de migrados) |
| `YOBOT_ML_SECRET_KEY` | client_secret de la app de ML de Yobot |

**Cambios de código en Reply (implementado 2026-08-07)**:
1. `TokenRefreshWorker` con 3 rutas: `bridge_enabled` + `YOBOT_ML_APP_ID` presente → refresh directo a ML con credenciales de Yobot; `bridge_enabled` sin las vars → vía `/api/bridge/refresh-token` (fallback bridge puro); nativo → `ML_APP_ID`/`ML_SECRET_KEY`. Verificado: refresh migrado real OK (token nuevo, `expires_at` +6h).
2. `ReplyAi::MeliApi.for`: resuelve por **credencial primaria** (`order(:id).first`) — primaria `bridge` → `BridgeApi`; `active` → `MeliApi`.
3. `find_bridge_account`: relajado a cualquier credencial con ese `ml_user_id` (HMAC intacto) — los forwards entran con credencial nativa.
4. Limpieza de credenciales bridge residuales: `777004` (cuenta 50) marcada `inactive`.
5. **Bug pre-existente corregido en `MeliApi#request`**: los GET enviaban `body: "null"` → ML responde `403` a GET con body (ej. `GET /messages/packs/...`). Ahora solo los POST llevan body. Verificado: `pack_messages` directo → 200 (10 mensajes).

**Procedimiento de migración de un usuario MIGRADO** (runbook validado en el piloto con `1367850269`; detalle en `docs/REQUERIMIENTOS_YOBOT.md` §4 del perfil):

1. **Yobot (Mongo)**: `db.users.updateOne({ ml_user_id: <ML_USER_ID> }, { $set: { bridge: { enabled: true, mode: "full" } } })` — `full` obligatorio (nunca `mirror`).
2. **Reply `.env`**: `YOBOT_ML_APP_ID` / `YOBOT_ML_SECRET_KEY` (app de ML de Yobot) → `docker restart chatwoot-rails-1 chatwoot-sidekiq-1`.
3. **Reply credencial**: `UPDATE meli_credentials SET status = 'active', bridge_enabled = true WHERE account_id = <id> AND ml_user_id = '<ML_USER_ID>';` (si es cuenta nueva: `POST /api/bridge/register` + INSERT con los tokens vigentes del seller de la BD de Yobot).
4. **Reply limpieza**: marcar `inactive` cualquier credencial bridge residual de la cuenta (`status = 'bridge' AND ml_user_id != '<ML_USER_ID>'`).
5. **Verificar**: `ReplyAi::MeliApi.for(Account.find(<id>)).class # => ReplyAi::MeliApi`; escenarios pregunta/mensaje/reclamo → respuestas **directas a ML** (en logs de Rails **no debe aparecer `/bridge/sign`**); refresh del worker con ruta `(migrado (app Yobot))` (forzar con `expires_at` pasado si se quiere probar).
6. **Rollback**: credencial → `status: 'bridge'` (+ Yobot `mirror`/`enabled: false` si retoma). Nota: tras un refresh de Reply el `refresh_token` de Yobot queda obsoleto (rotación de ML).

**Comparativa de perfiles**:

| | Nativo | **Migrado** | Bridge puro |
|---|---|---|---|
| Notificaciones | ML → Reply directo | Yobot → Reply (forward) | Yobot → Reply (forward) |
| Ejecución/consulta en ML | Reply directo (app Reply) | **Reply directo (token app Yobot)** | Vía Yobot |
| Refresh | App de Reply | **App de Yobot (vars en `.env`)** | Vía Yobot (`/api/bridge/refresh-token`) |
| Autorización ML del seller | App de Reply | Solo app de Yobot | Solo app de Yobot |
| Flag de Yobot | — | `full` | `mirror`/`full` |

### 18.10 Migración RAG Yobot → Reply (perfil MIGRADO, implementado 2026-08-08)

**Problema**: al migrar un usuario de Yobot, las configuraciones se sincronizan, pero los documentos RAG no — el seller no debe volver a subir miles de documentos.

**Fuente (verificada en Yobot)**: los chunks viven en **Supabase** (`pwooibyvhlimuhtgtpsu.supabase.co`), tabla `{ml_user_id}` (pre-venta) / `pv_{ml_user_id}` (post-venta): `id, content, metadata jsonb, embedding vector(1536)`. `metadata` tiene `level (global/category/product), item_id?, category_id?, item_name, doc_id, source` (+ `ambito: "postventa"` en PV). Modelo de Yobot: `text-embedding-3-small`.

**Por qué regenerar embeddings**: los vectores son por modelo — Yobot usa `3-small` y Reply `text-embedding-ada-002` → se migra **contenido + mapeo** y se regeneran los embeddings con el modelo de Reply vía los webhooks n8n existentes.

**Implementación**:
- Migración custom `20260808000000_add_yobot_chunk_id_to_rag_documents.rb`: columna `yobot_chunk_id` (string, **index único por account**) en `reply_ai_documents` y `reply_ai_pv_documents` → import idempotente (re-runs no duplican y re-emiten embeddings faltantes).
- `ReplyAi::YobotRagMigrator` (worker Sidekiq, `perform(account_id, ambito)` con `'pre'`/`'post'`): lee Supabase paginado (500/request) → mapea `global → 'global'/'global'`, `category → 'category'/category_id`, `product → 'product'/item_id` (nivel `sub` queda vacío — solo Reply lo llena; desconocidos se saltean) → inserta `find_or_create_by(account_id, yobot_chunk_id)` con `source: 'yobot'` → postea `{doc_id}` (pre, `N8N_EMBEDDING_WEBHOOK_URL`) / `{doc_id, doc_type: 'pv'}` (post, `N8N_PV_EMBEDDING_WEBHOOK_URL`) para regenerar el embedding (`ada-002`). Throttling `0.2s`/chunk (el webhook responde `onReceived`). Estado en `custom_attributes['syncing_rag_pre'/'post']`.
- Botones en el dashboard (tabs Documentos Pre-Venta y Post-Venta): "Importar documentos de Yobot" → `YobotRagMigrator` + `MeliSyncProductsWorker` (catálogo). Rutas: `POST /dashboard/migrate-rag-pre` y `POST /dashboard/migrate-rag-post`.
- Env vars: `SUPABASE_URL` + `SUPABASE_SERVICE_KEY` (`.env`). Sin cambios en Yobot ni n8n.

**Verificación**: rows por nivel con `embedding IS NOT NULL`; docs visibles en el dashboard por producto/categoría/global; pregunta pre-venta real con contexto del seller; mensaje post-venta real con RAG PV; re-run sin duplicados. **Rollback**: borrar filas con `source = 'yobot'` y reimportar.

---

### 18.11 Control de confianza pre-venta (implementado 2026-08-08)

**Qué es** (decisión D4 revisada): si la IA no tiene información suficiente para responder con
precisión, la pregunta se **retiene** (no se responde a ML, queda `UNANSWERED`) y un agente la
resuelve manualmente con la sugerencia de la IA. Mismo mecanismo que Yobot
(`requireRagOrConfidence` + `confidenceByCategory`, marcador `[SIN_INFORMACION]`).

**Configuración** (`Account.custom_attributes.config`, dashboard Pre-venta → Ajustes del bot):
- `requireRagOrConfidence` (bool global): retención activa para todas las categorías.
- `confidenceByCategory` (map `category_id → bool`): sobrescribe el global por categoría
  (sin marcar en la UI = usa el global).
- `BridgeConfigMapper` ya traduce ambas keys del `sync-config` de Yobot (2026-08-06).

**Implementación**:
- Migración custom `20260808000002_add_retention_to_meli_questions.rb`: `retained_due_lack_of_info`
  (boolean default false) + `suggested_answer` (text) en `meli_questions`.
- `update_settings` guarda el toggle global + `confidenceByCategory`; `setup_dashboard_vars`
  expone `@require_rag_or_confidence`/`@confidence_by_category`.
- Dashboard Pre-venta → Ajustes: card "Control de confianza" (toggle global + checkboxes por
  categoría master/sub).
- Informes → Pre-Venta: panel "Preguntas retenidas" (tabla pregunta/producto/sugerencia/fecha/
  conversación). Endpoint `GET /dashboard/confidence-report` (`confidence_report` en
  `LandingController`, SQL directo sobre `meli_questions`, join de conversación para el texto
  y producto por `ml_item_id`).
- Workflow `n8n/reply_ai_questions_main.json`:
  - `get_account_details`: SQL incluye `requireRagOrConfidence` + `confidenceByCategory`.
  - `context:assembler`: calcula `require_conf` efectivo (por categoría si existe override, si no global) y lo agrega a `ai_payload`.
  - `AI Agent` systemMessage: bloque condicional — si `require_conf` y la info del contexto no
    alcanza, responder exactamente `[SIN_INFORMACION] <sugerencia>`.
  - Nuevos nodos: `check_sin_info` (If, `output` contiene `[SIN_INFORMACION]`) → rama true:
    `update_meli_questions_retained` (status `UNANSWERED`, `retained_due_lack_of_info=true`,
    `suggested_answer` sin el marcador) → `chatwoot_retained_note` (nota privada con la sugerencia)
    → `chatwoot_add_manual_label` (`esperando_respuesta_manual`). Rama false: flujo normal
    (no cambia nada: delay, respuesta a ML, labels IA, cierre).

**Verificación**: toggle + categorías persisten vía `/dashboard/update`; UPDATE de retención
con `status=UNANSWERED` + `suggested_answer` limpio (sin `[SIN_INFORMACION]`); informe devuelve
las retenidas con pregunta/producto/sugerencia; workflow desplegado con bump de versión
(`check_sin_info` presente en `workflow_entity`). **Rollback**: desactivar el toggle en Ajustes
(o vaciar `confidenceByCategory`) — las preguntas nuevas vuelven al flujo normal; las retenidas
se resuelven manualmente desde la conversación (label `esperando_respuesta_manual`).

---
### 18.7 Bridge Yobot ↔ Reply-AI — Guía completa (Fase 3, pendiente)

> **Estado**: esta guía corresponde a la Fase 3 del plan (§18.4). La infraestructura básica ya está implementada en Reply-AI (endpoints + HMAC); el resto se completará al finalizar las Fases 1 y 2.

> **Motivación**: los sellers existentes de Yobot deben usar Reply-AI sin re-autorizar en MercadoLibre.
> Yobot actúa como proxy transparente de ML API. Reply-AI es la app que el seller usa a diario.

#### 18.7.1 Arquitectura

```
Seller usa reply-ai.com exclusivamente
        │
        ▼
┌─────────────────────────┐         ┌──────────────────┐
│       REPLY-AI          │         │      YOBOT       │
│     (Chatwoot)          │ bridge  │   (gateway ML)   │
│                         │◄───────▶│                  │
│  • Dashboard UI         │  HTTP   │  • Tokens OAuth  │
│  • n8n workflows        │  +HMAC  │  • Webhooks ML   │
│  • IA + RAG + pgvector  │         │  • Proxy ML API  │
│  • PostgreSQL           │         │  • Fallback IA   │
│                         │         │                  │
│  Llama a Yobot para:    │         │                  │
│  - enviar respuestas    │         │                  │
│  - sincronizar productos│         │                  │
│  - enviar mensajes p-v  │         │                  │
│  - ejecutar acciones    │         │                  │
└─────────────────────────┘         └────────┬─────────┘
                                             │
                                      ML API │
                                             ▼
                                       MercadoLibre
```

**Yobot es un proxy transparente de ML API + webhook forwarder. Reply-AI es la app que el seller usa.**

#### 18.7.2 Autenticación del seller en Reply-AI

El seller se autentica directamente en Reply-AI (no pasa por Yobot). Las credenciales se crean durante la migración:

| Campo Yobot | Destino Reply-AI |
|-------------|-----------------|
| `User.email` (del admin) | `User.email` (Chatwoot) |
| `User.nickname` | `User.name` |
| Password (nuevo) | Generado por Reply-AI, comunicado al seller por email |
| `mercadolibre.user.*` | `MeliCredential` (status: 'bridge') |
| `mercadolibre.authorization.*` | `MeliCredential` (tokens encriptados) |

El seller hace login en `reply-ai.com/login` con sus credenciales. El `LandingController` maneja la autenticación vía Devise.

#### 18.7.3 Seguridad del bridge

```
Yobot (VPS A)                                Reply-AI (VPS B)
     │                                              │
     │  Authorization: Bearer <BRIDGE_SECRET>       │
     │  X-Bridge-Signature: HMAC-SHA256(body, key)  │
     │──────────────────────────────────────────────▶│
```

- **`BRIDGE_SECRET`**: shared secret en ambos servidores (variable de entorno)
- **HMAC**: asegura que el body no fue alterado en tránsito
- **HTTPS**: obligatorio para todo el tráfico entre servidores
- **Rate limiting**: en Reply-AI, por si Yobot es comprometido
- **IP whitelist**: opcional, si la IP de Yobot es fija

#### 18.7.4 Endpoints del bridge

**Reply-AI → Yobot** (Reply-AI pide ejecutar algo contra ML API):

```
POST /api/bridge/send-answer
  Body: { ml_user_id, question_id, answer_text }
  → Yobot POST /answers a ML API

POST /api/bridge/send-message
  Body: { ml_user_id, pack_id, text, attachments? }
  → Yobot POST /messages/packs/{pack_id}/sellers/{seller_id} a ML API

POST /api/bridge/execute-claim-action
  Body: { ml_user_id, claim_id, action, params }
  → Yobot ejecuta POST a ML Claims API
  → Devuelve resultado de ML

POST /api/bridge/upload-attachment
  Body: { ml_user_id, file (multipart), pack_id }
  → Yobot POST /messages/attachments a ML API

GET /api/bridge/seller/:ml_user_id
  → Yobot devuelve { plan, status, site_id }

POST /api/bridge/refresh-token
  Body: { ml_user_id, refresh_token }
  → Yobot POST /oauth/token a ML
  → Devuelve { access_token, refresh_token, expires_in }
```

**Yobot → Reply-AI** (Yobot forwardea webhooks de ML):

```
POST /api/bridge/question
  Body: { ml_user_id, access_token, question: {...}, item: {...}, buyer: {...} }
  → Reply-AI crea conversación en Chatwoot, dispara n8n

POST /api/bridge/message
  Body: { ml_user_id, access_token, pack_id, sale_id, message: {...}, sale: {...} }
  → Reply-AI crea/actualiza MeliOrder, procesa con n8n

POST /api/bridge/order
  Body: { ml_user_id, access_token, order: {...} }
  → Reply-AI crea/actualiza MeliOrder, envía mensaje post-venta si aplica

POST /api/bridge/claim
  Body: { ml_user_id, access_token (null), resource (claim id), claim_data (envelope de la notificación) }
  → Reply-AI obtiene el claim de ML con el token de la credencial, upsert MeliClaim, vincula orden,
    dispute→bloqueada y evalúa automatización/agente

POST /api/bridge/manual-response
  Body: { ml_user_id, question_id, pack_id, text, answered_by: 'human' }
  → Reply-AI actualiza conversación en Chatwoot (crea nota privada)
  → Cancela respuesta IA pendiente para esa conversación
```

**Rutas en Reply-AI** (`LandingController` + `reply-ai_routes.rb`):

```ruby
# En LandingController:
#   before_action :verify_bridge_auth, only: bridge actions
#   skip_before_action :authenticate_user!, only: bridge actions

post 'api/bridge/question',          to: 'landing#bridge_question'
post 'api/bridge/message',           to: 'landing#bridge_message'
post 'api/bridge/order',             to: 'landing#bridge_order'
post 'api/bridge/claim',             to: 'landing#bridge_claim'
post 'api/bridge/manual-response',   to: 'landing#bridge_manual_response'
```

#### 18.7.5 Flujo pre-venta bridgeado

```
1. Comprador pregunta en ML
2. Webhook ML → Yobot (/api/notifications)
3. Yobot detecta seller bridgeado → NO procesa localmente
4. Yobot POST /api/bridge/question → Reply-AI
   Body: { ml_user_id, access_token, question, item, buyer }
5. Reply-AI: busca Account por ml_user_id
   → crea conversación en Chatwoot (vía Platform API)
   → dispara n8n vía webhook con los datos
6. n8n: busca MeliCredential para obtener config
   → rag_search (pgvector) para contexto RAG
   → arma prompt con custom_attributes
   → llama a OpenAI (gpt-4o-mini)
   → guarda respuesta en meli_questions (PG directo)
7. n8n: POST /api/bridge/send-answer → Yobot
   Body: { ml_user_id, question_id, answer_text }
8. Yobot: POST /answers → ML API
9. Comprador ve respuesta en ML
10. Seller ve todo en reply-ai.com/dashboard
```

#### 18.7.6 Flujo post-venta bridgeado

```
1. Comprador envía mensaje post-venta en ML
2. Webhook ML → Yobot (topic: messages)
3. Yobot POST /api/bridge/message → Reply-AI
4. Reply-AI: busca/crea MeliOrder
   → crea conversación en Chatwoot (si no existe)
   → dispara n8n
5. n8n: clasifica intención (saludo/logistica/soporte/reclamo/cierre)
   → busca RAG post-venta si es soporte
   → detecta sentimiento (keywords + IA)
   → evalúa handoff
   → genera respuesta con OpenAI
6. n8n: guarda timeline en meli_orders (PG directo)
7. n8n: POST /api/bridge/send-message → Yobot
8. Yobot: POST /messages/packs/{id}/sellers/{id} → ML API
9. Comprador ve respuesta en ML
```

#### 18.7.7 Productos: Reply-AI sincroniza solo

Reply-AI tiene `MeliSyncProductsWorker` para sincronizar productos. Con el bridge, el worker:

1. Obtiene `access_token` desde `MeliCredential` (desencriptado)
2. Si el token expiró → `POST /api/bridge/refresh-token` → Yobot → ML OAuth
3. Reply-AI persiste los tokens actualizados (encriptados)
4. Sincroniza productos normalmente (paginación, lotes de 20)
5. Guarda en `meli_products`

#### 18.7.8 Migración de sellers Yobot → Reply-AI

**Script**: `custom/lib/reply_ai/migration/yobot_migrator.rb`

```ruby
module ReplyAi
  module Migration
    class YobotMigrator
      def migrate_seller(ml_user_id)
        # 1. Leer datos de MongoDB (Yobot)
        yobot_user = MongoClient[:users].find(
          'mercadolibre.user.user_id': ml_user_id
        ).first
        return if already_migrated?(ml_user_id)

        # 2. Crear User + Account en Chatwoot (Platform API)
        account = create_account(yobot_user)

        # 3. Crear MeliCredential con tokens encriptados
        create_credential(yobot_user, account)

        # 4. Migrar configuración (prompts, delays, schedule)
        migrate_config(yobot_user, account)

        # 5. Migrar documentos RAG (Google Drive → ReplyAiDocument)
        migrate_documents(yobot_user, account)
      end
    end
  end
end
```

**Datos migrados:**

| Desde Yobot | Hacia Reply-AI | Campo |
|-------------|---------------|-------|
| `mercadolibre.user.user_id` | `MeliCredential.ml_user_id` | unique |
| `mercadolibre.authorization.access_token` | `MeliCredential.access_token` | encriptado |
| `mercadolibre.authorization.refresh_token` | `MeliCredential.refresh_token` | encriptado |
| `mercadolibre.user.nickname` | `Account.name` | — |
| `config.prompts.*` (14 campos) | `Account.custom_attributes.config.prompts` | JSONB |
| `config.chatGPTEnabled` | `Account.custom_attributes.config.chatGPTEnabled` | JSONB |
| `config.responseDelay` | `Account.custom_attributes.config.response_delay` | JSONB |
| `config.scheduledMode` | `Account.custom_attributes.config.scheduledMode` | JSONB |
| `config.postVentaChatGPTEnabled` | `Account.custom_attributes.config.post_venta_ia.enabled` | JSONB |
| `config.postVentaResponseDelay` | `Account.custom_attributes.config.post_venta_ia` | JSONB |
| `config.postVentaScheduledMode` | `Account.custom_attributes.config.post_venta_ia` | JSONB |
| Documentos RAG (Google Drive) | `ReplyAiDocument` + `ReplyAiPvDocument` | + embeddings |

**Datos NO migrados (Reply-AI genera solo):**

| Dato | Razón |
|------|-------|
| Productos | `MeliSyncProductsWorker` los sincroniza desde ML |
| Ventas | Se crean al recibir el primer webhook post-venta |
| Preguntas históricas | Solo en Yobot. Nuevas preguntas → Chatwoot. |
| OpenAI usage histórico | Reply-AI trackea el suyo propio |
| PayPal suscripción | Reply-AI implementa planes propios (fase 3) |

#### 18.7.9 Sincronización bidireccional

**Caso 1: Seller responde manualmente desde Chatwoot**

1. Agente escribe en Chatwoot → Reply-AI detecta mensaje saliente (webhook de Chatwoot)
2. Reply-AI: `POST /api/bridge/manual-response` → Yobot
3. Yobot: cancela respuesta IA pendiente para ese pack_id (si existe)
4. Yobot: no reenvía a ML (el mensaje de Chatwoot es interno, no va a ML)

**Caso 2: Seller responde manualmente desde Yobot (legacy)**

1. Yobot: `POST /api/bridge/manual-response` → Reply-AI
2. Reply-AI: crea nota privada en la conversación de Chatwoot
3. Reply-AI: actualiza timeline con `respuesta_manual`

**Caso 3: Seller desactiva el bot desde Reply-AI**

1. Seller cambia `chatGPTEnabled = false` en `/dashboard`
2. Reply-AI: `POST /api/bridge/seller/:ml_user_id/config` → Yobot
3. Yobot: actualiza flag interno. Si llega webhook, responde "bot desactivado" o ignora.

#### 18.7.10 Variables de entorno nuevas

| Variable | Dónde | Propósito |
|----------|-------|-----------|
| `BRIDGE_SECRET` | Ambos | Shared secret para autenticación y HMAC |
| `YOBOT_BRIDGE_URL` | Reply-AI | URL base de Yobot para enviar requests |
| `REPLY_AI_BRIDGE_URL` | Yobot | URL base de Reply-AI para forwardear webhooks |
| `YOBOT_MONGO_URI` | Reply-AI | Conexión a MongoDB de Yobot (solo para migración) |

#### 18.7.11 Plan de implementación del bridge

| Fase | Qué | Días | Archivos afectados |
|------|-----|------|-------------------|
| **0** | Endpoints del bridge en ambos lados + shared secret + autenticación HMAC | 2-3 | `landing_controller.rb`, `reply-ai_routes.rb`, `reply_ai/bridge_auth.rb` |
| **1** | Script de migración MongoDB → PostgreSQL | 2-3 | `custom/lib/reply_ai/migration/yobot_migrator.rb` |
| **2** | Bridge pre-venta (question → n8n → answer → Yobot → ML) | 3-4 | `n8n/reply_ai_questions_main.json` (nodo bridge), `landing_controller.rb` |
| **3** | Bridge post-venta (message → n8n → send → Yobot → ML) | 3-4 | `n8n/reply_ai_postsale_main.json`, `landing_controller.rb` |
| **4** | Dashboard y métricas para sellers bridgeados | 2-3 | `dashboard.html.erb`, `post_venta.html.erb` |
| **5** | Sync de productos vía bridge (Reply-AI autónomo) | 2 | `meli_sync_products_worker.rb` (modificar para usar bridge token) |
| **6** | Sincronización bidireccional (manual responses, status sync, config sync) | 2-3 | `landing_controller.rb`, webhooks de Chatwoot |

**Total**: ~16-20 días. Todo en `custom/`, `n8n/`, y `config/initializers/`. Cero modificación de `app/`.

#### 18.7.12 Guía de Activación del Bridge (Paso a Paso)

> **Estado actual**: infraestructura implementada en ambos lados para **pre-venta y post-venta**. Solo falta configurar `BRIDGE_SECRET` y activar el switch por seller.

##### A. Configuración de variables de entorno

**En Reply-AI** (`.env` o variables de entorno del sistema):

```bash
# Shared secret — MISMO valor en ambos servidores
BRIDGE_SECRET=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

# URL base de Yobot para enviar requests de respuesta
YOBOT_BRIDGE_URL=https://yobot.ejemplo.com
```

**En Yobot** (`backend/.env`):

```bash
# Shared secret — MISMO valor que en Reply-AI
BRIDGE_SECRET=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

# URL base de Reply-AI para forwardear webhooks
REPLY_AI_BRIDGE_URL=https://reply-ai.ejemplo.com
```

> **IMPORTANTE**: si `BRIDGE_SECRET` está vacío en Yobot, `isBridged()` retorna `false` siempre. Yobot funciona exactamente igual que antes. Cero riesgo.

##### A.1 Handlers con bridge guard implementados

| Handler Yobot | Topic ML | Bridge endpoint Reply-AI | Qué hace |
|---------------|----------|--------------------------|----------|
| `handleIncomingNotification.js:551` | `questions` | `POST /api/bridge/question` | Forwardea preguntas pre-venta |
| `handleIncomingMessage.js:237` | `messages` | `POST /api/bridge/message` | Forwardea mensajes post-venta |
| `handleIncomingSale.js:636` | `orders`, `orders_v2` | `POST /api/bridge/order` | Forwardea órdenes/ventas |
| `handleIncomingClaim.js:18` | `claims` | `POST /api/bridge/claim` | Forwardea reclamos |

##### B. Crear cuenta bridgeada en Reply-AI (manual, seller de prueba)

Desde la consola Rails en Reply-AI:

```ruby
# 1. Crear Account + User vía Platform API
platform_token = ENV['CHATWOOT_PLATFORM_TOKEN']
ml_user_id = 123456  # ID real del seller en MercadoLibre

account_res = RestClient.post(
  'http://localhost:3000/platform/api/v1/accounts',
  { name: 'Tienda de Prueba Bridge' }.to_json,
  { api_access_token: platform_token, content_type: :json, accept: :json }
)
account_data = JSON.parse(account_res.body)

user_res = RestClient.post(
  'http://localhost:3000/platform/api/v1/users',
  { name: 'Seller Bridge', email: "bridge-#{ml_user_id}@test.com", password: SecureRandom.hex(12) }.to_json,
  { api_access_token: platform_token, content_type: :json, accept: :json }
)
user_data = JSON.parse(user_res.body)

RestClient.post(
  "http://localhost:3000/platform/api/v1/accounts/#{account_data['id']}/account_users",
  { user_id: user_data['id'], role: 'administrator' }.to_json,
  { api_access_token: platform_token, content_type: :json, accept: :json }
)

# 2. Configurar Account
account = Account.find(account_data['id'])
account.update_columns(custom_attributes: LandingController.new.send(:default_reply_ai_config))

# 3. Crear MeliCredential con bridge activado
MeliCredential.create!(
  account: account,
  ml_user_id: ml_user_id,
  access_token: 'token-encrypted-placeholder',
  refresh_token: 'refresh-encrypted-placeholder',
  status: 'bridge',
  bridge_enabled: true
)

# 4. Crear inboxes (necesita token del usuario)
token = User.find(user_data['id']).access_token.token
['Pre-venta (MercadoLibre)', 'Post-venta (MercadoLibre)'].each do |name|
  RestClient.post(
    "http://localhost:3000/api/v1/accounts/#{account.id}/inboxes",
    { name: name, channel: { type: 'api', webhook_url: '' } }.to_json,
    { api_access_token: token, content_type: :json, accept: :json }
  )
end
```

##### C. Verificar que el bridge está activo

**Desde Yobot** (o cualquier cliente HTTP):

```bash
# Yobot consulta si el seller está bridgeado
curl http://localhost:3000/api/bridge/seller/123456

# Respuesta esperada:
# { "bridged": true, "ml_user_id": 123456, "account_id": 1, "status": "bridge" }
```

**Desde Reply-AI** (simulando una pregunta de Yobot):

```bash
# Calcular HMAC (ejemplo con openssl)
BODY='{"ml_user_id":123456,"access_token":"test","question":{"id":1,"text":"Hola","item_id":"ML123"},"item":{"id":"ML123","title":"Producto"},"buyer":{"id":111,"nickname":"Comprador"}}'
SIGNATURE=$(echo -n "$BODY" | openssl dgst -sha256 -hmac "$BRIDGE_SECRET" | awk '{print $2}')

curl -X POST http://localhost:3000/api/bridge/question \
  -H "Authorization: Bearer $BRIDGE_SECRET" \
  -H "X-Bridge-Signature: $SIGNATURE" \
  -H "Content-Type: application/json" \
  -d "$BODY"

# Respuesta esperada:
# { "conversation_id": 1, "message_id": 1, "status": "processing" }
```

##### D. Flujo end-to-end

**Pre-venta (questions)**:
```
1. Comprador pregunta en ML
2. Webhook ML → Yobot /api/notifications
3. Yobot: isBridged(idUsuario) → GET /api/bridge/seller/:id → { bridged: true }
4. Yobot: forwardToReplyAI('/api/bridge/question', payload) → Reply-AI
5. Reply-AI: bridge_question → crea Contact + Conversation + Message → dispara n8n
6. n8n: procesa pregunta (RAG → OpenAI → respuesta)
7. n8n: POST /api/bridge/send-answer → Yobot
8. Yobot: bridgeController.receiveAnswer → POST /answers → ML API
9. ✅ Comprador ve respuesta en ML
```

**Post-venta (messages)**:
```
1. Comprador envía mensaje post-venta en ML
2. Webhook ML → Yobot /api/notifications (topic: messages)
3. Yobot: isBridged(idUsuario) → { bridged: true }
4. Yobot: forwardToReplyAI('/api/bridge/message', payload) → Reply-AI
5. Reply-AI: bridge_message → crea/actualiza MeliOrder → dispara n8n
6. n8n: clasifica intención → RAG post-venta → OpenAI → respuesta
7. n8n: POST /api/bridge/send-message → Yobot
8. Yobot: bridgeController.receivePostVentaMessage → POST /messages/packs/:id/sellers/:id → ML API
9. ✅ Comprador ve respuesta en ML
```

**Órdenes (orders)**:
```
1. Comprador genera una orden en ML
2. Webhook ML → Yobot (topic: orders_v2)
3. Yobot: isBridged(idUsuario) → forwardToReplyAI('/api/bridge/order')
4. Reply-AI: bridge_order → crea/actualiza MeliOrder en PostgreSQL
5. ✅ Orden registrada para métricas y post-venta futura
```

**Reclamos (claims)**:
```
1. Comprador inicia reclamo en ML
2. Webhook ML → Yobot (topic: claims)
3. Yobot: isBridged(idUsuario) → forwardToReplyAI('/api/bridge/claim')
4. Reply-AI: bridge_claim → registra reclamo (procesamiento futuro con motor agente)
```

##### E. Desactivar el bridge para un seller

```ruby
# Rails console en Reply-AI
MeliCredential.find_by(ml_user_id: 123456).update(bridge_enabled: false)
```

El próximo webhook de ML hará que Yobot procese la pregunta con su pipeline normal (sin cambios).

##### F. Troubleshooting

| Problema | Causa probable | Solución |
|----------|---------------|----------|
| Yobot no forwardea preguntas | `BRIDGE_SECRET` vacío o distinto entre servidores | Verificar que `BRIDGE_SECRET` es idéntico en ambos `.env` |
| `isBridged()` retorna `false` | `REPLY_AI_BRIDGE_URL` incorrecta o Reply-AI no accesible desde Yobot | `curl` desde el servidor de Yobot al endpoint `/api/bridge/seller/:id` |
| Reply-AI responde 401 | HMAC no coincide | Verificar que el body se envía exactamente como se firmó (JSON sin espacios extra) |
| `bridge_question` falla con 500 | Account sin inbox pre-venta | Crear inbox 'Pre-venta (MercadoLibre)' manualmente |
| n8n no recibe el webhook | `N8N_WEBHOOK_URL` no configurado o inaccesible | Verificar que n8n está corriendo y el webhook URL es correcto |
| Cache muestra estado viejo | `bridgeCache` (60s TTL) no se actualizó | Esperar 60s o reiniciar Yobot para limpiar cache |

---

## 19. Modo Recepción Solamente (receive-only)

> **Implementado**: 2026-08-05. Propósito: validar el flujo de ingesta (preguntas, mensajes, reclamos → Chatwoot) con un usuario bridge real **sin que Reply-AI envíe nada** a MercadoLibre ni a Yobot. Es el modo de testing operacional antes de habilitar el bridge de envío.

### Semántica del flag

El modo se activa cuando **ambas** condiciones se cumplen:

1. `REPLY_RECEIVE_ONLY=true` (variable de entorno — **global**).
2. La cuenta tiene `custom_attributes.receive_only == true` (**por cuenta**).

Las cuentas no marcadas siguen respondiendo normal aunque el env esté en `true`.

### Dónde se define

- **`.env`**: `REPLY_RECEIVE_ONLY=false|true` (rails/sidekiq la leen vía `env_file`).
- **`docker-compose.yaml`**: `REPLY_RECEIVE_ONLY=${REPLY_RECEIVE_ONLY:-false}` en `n8n-main` **y** `n8n-worker` (n8n NO tiene `env_file` — la var se pasa explícita; los Code nodes la leen con `$env.REPLY_RECEIVE_ONLY`).
- Tras cambiar la var: `docker compose up -d rails n8n-main n8n-worker`.

### Marcado automático al bridgear

`bridge_register` (cuando el env está en `true`) crea la cuenta bridge con `custom_attributes.receive_only = true` — el usuario bridge de prueba queda marcado sin tocar nada manual. Para desmarcar:

```ruby
# Rails console
a = Account.find(<id>)
ca = a.custom_attributes.to_h
ca.delete('receive_only')
a.update!(custom_attributes: ca)
```

### Qué hace en receive-only

| Componente | Comportamiento |
|---|---|
| **Ingesta** (preguntas, mensajes, reclamos → Chatwoot) | **Normal**: conversaciones pre-venta/post-venta/Reclamos, mensajes incoming, labels, banner mediación |
| **RAG** (`/rag/search`, `/rag/pv_search`), bulk import, subida de docs, sync | Normal (lecturas/ingesta) |
| **Respuesta del bot** (questions_main y postsale_main) | Se genera igual pero **NO se envía** a ML/Yobot; se espeja a Chatwoot como **nota privada** (private: true) con el contenido que habría ido al comprador |
| **Cierre de conversación** | En receive-only la conversación **queda abierta** (questions_main: `toggle_status` → `open`; postsale_main: `auto_resolve?` forzado a `false`) |
| **Acciones de reclamos** (refund, partial_refund, send_message, send_evidence, allow_return, open_dispute, agent_execute/rerun, return_review, change_allow_replace) | Responden `200 { receive_only: true, accion_bloqueada: true }` sin llamar a ML/Yobot (before_action `reject_receive_only_write`) |
| **`ClaimAutomation`** | Evalúa la decisión pero no ejecuta: registra en `agent_log` como `automatizacion_receive_only` |
| **`ClaimAgentWorker`** | Corre en **dry-run**: el loop ReAct se ejecuta pero las tools que ejecutarían en ML se simulan (`{ok: true, receive_only: true, simulated: <tool>}`); `execute_pending!` devuelve `{receive_only: true, accion_bloqueada: true}` |
| **`TokenRefreshWorker`** y **acks HTTP a Yobot** (200) | Se mantienen (protocolo/auth, no son mensajes al comprador) |
| **`process_attachments`** | Sin gate: solo LEE adjuntos de ML (GET) para generar `attachment_context` |

### Gates implementados en n8n (6 workflows, 2026-08-05)

Todos los nodos de envío son Code nodes con el patrón bridge/nativo. El gate se inserta tras la línea `const isBridge = ...`:

```js
if ($env.REPLY_RECEIVE_ONLY === 'true' && account.receive_only === 'true') return { receive_only: true, skipped: true };
```

| Workflow | Nodos con gate |
|---|---|
| `questions_main` | `mercadolibre_answer_question` (+ `chatwoot_publish_answer_ai` con `private` condicional; `chatwoot_conversation_close` → status `open` condicional) |
| `postsale_main` | 5× `send_*_reply_ml` + `send_escalation_to_buyer_ml`; 4× `mirror_*_to_chatwoot` con `"private":{{ $env.REPLY_RECEIVE_ONLY === 'true' && $('get_account_details').item.json.receive_only === 'true' }}`; `auto_resolve?` → `false` condicional |
| `postsale_outbound` | `send_to_ml` |
| `orders_main` | `send_via_messages`, `send_via_action_guide` |
| `questions_manual` | `mercadolibre_post_answer` |
| `claims_outbound` | `send_claim_message` |

Los queries de account de los 6 workflows incluyen `custom_attributes->>'receive_only' as receive_only` (columna leída en los Code nodes como `account.receive_only === 'true'`).

### Uso operacional

```
1. .env:  REPLY_RECEIVE_ONLY=true
2. docker compose up -d rails n8n-main n8n-worker
3. Yobot bridgea el usuario de prueba → bridge_register lo marca receive_only automáticamente
4. Disparar pregunta / mensaje / reclamo reales → verificarlos en Chatwoot (inboxes correctos,
   respuesta del bot como nota privada, conversaciones abiertas)
5. Verificar cero outbound: logs de ejecución n8n (sin HTTP a api.mercadolibre.com/YOBOT_BRIDGE_URL
   en los nodos de envío) + acciones de reclamos respondiendo receive_only
6. Salir del modo: .env → false, docker compose up -d rails n8n-main n8n-worker, desmarcar la cuenta
```

### Verificación automatizada (usada en implementación)

- Acción de reclamo con cuenta marcada → `200 {"receive_only":true,...}`; sin marca → no bloquea.
- `rag_search`/`pv_search` siguen respondiendo 200 (ingesta intacta).
- Los 11 jsCode parcheados validados con `node --check` (envueltos en `async function` por el wrapper de n8n).

---

## 20. Operaciones n8n (importación, versiones, smoke tests)

Conocimiento operativo acumulado al trabajar los workflows (2026-08-05). Aplica a n8n 2.6.4 en modo queue (n8n-main + n8n-worker).

### Dónde vive un workflow

Tablas en la DB `n8n`:

- `workflow_entity`: fila del workflow (`id`, `name`, `active`, `nodes` json, `connections` json, `versionId`, `activeVersionId`...).
- `workflow_history`: **versiones** — n8n ejecuta la versión apuntada por `workflow_entity.activeVersionId` (FK `FK_08d6c67b...` RESTRICT). Sin `activeVersionId` → "Active version not found" al disparar un webhook.
- `shared_workflow`: ownership (`projectId` + role `workflow:owner`).
- `webhook_entity`: webhooks registrados de workflows activos (`webhookPath`, `method`, `workflowId`...).
- `execution_entity` + `execution_data` (columnas `executionId`, `data` en formato **referenciado** — los valores son índices a otras posiciones del array; para inspeccionar ejecuciones hay que resolver las referencias).

### Importar/actualizar un workflow (patrón probado)

El export del repo (`n8n/*.json`) puede no tener `id` (exports "flojos") — **nunca importar por CLI con id ausente** (duplica el workflow y rompe referencias como el nodo `Call reply_ai_postsale_main` de questions_main que apunta por `workflowId`). Patrón usado:

1. **Actualizar nodos/conexiones existentes**: UPDATE quirúrgico por `id` (`workflow_entity` + la versión activa en `workflow_history`).
2. **Bump de versión** (obligatorio: n8n cachea por `versionId` — con el mismo versionId no recarga el contenido nuevo):
   ```sql
   BEGIN;
   INSERT INTO workflow_history ("versionId","workflowId",authors,name,nodes,connections,autosaved)
     VALUES ($vid, $wfid, 'Guillermo Stizza', 'Version '||$vid, $nodes::json, $conns::json, true);
   UPDATE workflow_entity SET nodes=$nodes::json, connections=$conns::json,
     "versionId"=$vid::char(36), "activeVersionId"=$vid WHERE id=$wfid;
   COMMIT;
   ```
   (INSERT history **primero** — el UPDATE falla por FK RESTRICT si el versionId nuevo no existe.)
3. **Workflow nuevo** (ej. `reply_ai_pv_embedding_generator`): INSERT en `workflow_entity` + `workflow_history` + `shared_workflow` + `webhook_entity` (path, method POST, node 'Webhook', `pathLength` 1).
4. `docker compose restart n8n-main n8n-worker` (recarga workflows activos y registra webhooks).
5. Exportar el JSON canónico del repo desde la DB (`SELECT json_build_object('name',name,'active',active,'nodes',nodes::json,'connections',connections::json,...)`).

### Validar un workflow sin datos reales (smoke harness)

- Crear un workflow temporal `zz_*` con Webhook → Code (payload fijo) → nodo `executeWorkflow` (workflowId objetivo, `workflowInputs: {mappingMode: 'defineBelow', value: {}}`, `mode: each`, `waitForSubWorkflow: true`) → verificar en `execution_entity`/`execution_data` qué nodos corrieron (el `runData` referenciado se resuelve siguiendo índices).
- El sub-workflow recibe el item del caller **solo si** su trigger (`executeWorkflowTrigger`) tiene `"parameters": { "inputSource": "passthrough" }` — sin eso, `$input` llega vacío (las expresiones renderizan `undefined`, ej. `ms_undefined` en check_idempotency).
- Lección del smoke de postsale_main: con el grafo roto, las ejecuciones existían pero no corrían nodos; con el grafo restaurado la cadena completa se recorrió hasta el primer nodo que requiere datos reales de ML.

### Verificación de ejecuciones

```sql
-- Últimas ejecuciones por workflow (n8n DB)
SELECT w.name, count(e.id), max(e."startedAt")
FROM execution_entity e JOIN workflow_entity w ON w.id = e."workflowId"
GROUP BY w.name ORDER BY 3 DESC NULLS LAST;

-- Datos de una ejecución (formato referenciado)
SELECT "data"::text FROM execution_data WHERE "executionId" = <id>;
```

### Sandbox de Code nodes en n8n 2.6.4 (hallazgos 2026-08-06)

Los Code nodes de esta versión NO exponen `require('crypto')` ni `require('node:crypto')`
(`Module 'crypto' is disallowed`), NO exponen `fetch` global ni `crypto.subtle`. Lo disponible:
`this.helpers.httpRequest`/`this.helpers.request` (HTTP), `Buffer` global.

**Patrón adoptado (polyfill `fetch` v3)**: al inicio de cada Code node que haga HTTP:

```js
const __ra_helpers = this.helpers;
const __ra_toBuf = (b) => {
  if (Buffer.isBuffer(b)) return b;
  if (b && typeof b === 'object' && b.type === 'Buffer' && Array.isArray(b.data)) return Buffer.from(b.data);
  if (typeof b === 'string') return Buffer.from(b);
  if (b && typeof b === 'object') return Buffer.from(JSON.stringify(b));
  return Buffer.from(String(b));
};
const __ra_toText = (b) => __ra_toBuf(b).toString('utf8');
const fetch = (url, opts = {}) => (async () => {
  try {
    const res = await __ra_helpers.httpRequest({
      method: (opts.method || 'GET').toUpperCase(), url,
      headers: opts.headers || {}, body: opts.body,
      json: false, encoding: 'arraybuffer', returnFullResponse: true
    });
    return { ok: res.statusCode >= 200 && res.statusCode < 300, status: res.statusCode,
             json: async () => { const t = __ra_toText(res.body); try { return JSON.parse(t); } catch (e) { return t; } },
             text: async () => __ra_toText(res.body),
             arrayBuffer: async () => __ra_toBuf(res.body) };
  } catch (e) {
    return { ok: false, status: e.status || e.statusCode || 0, json: async () => ({}),
             text: async () => String(e.message || ''), arrayBuffer: async () => Buffer.alloc(0) };
  }
})();
```

**Claves del sandbox**:
- Con `returnFullResponse` + `encoding: 'arraybuffer'`, `res.body` llega como **objeto plano
  `{type:"Buffer",data:[…]}`** (el sandbox serializa los Buffers) — el polyfill lo decodifica
  (`__ra_toBuf`). Sin eso, `.toString()` da `[object Object]` y la firma queda vacía.
- Los errores HTTP de `httpRequest` llevan el código en `e.status` (no `e.statusCode`).
- El HMAC del bridge no se puede calcular en el nodo → se delega en `POST /bridge/sign` de Rails
  (auth `X-Bridge-Secret: <BRIDGE_SECRET>`; firma el string exacto a enviar).

### API de Chatwoot: display_id vs id (2026-08-06)

`Api::V1::Accounts::ConversationsController#conversation` resuelve por **`display_id`**
(`find_by!(display_id: params[:id])`), no por el id interno. **El serializer de la API expone
el `display_id` como `id` público** en las respuestas (create/show), por lo que los nodos n8n
que usan `created.id`/`$node[...].json.id` en URLs de la API **funcionan correctamente**
(validado end-to-end en el flujo post-venta bridgeado, 2026-08-06: `get_or_create_conversation`
creó la conversación y el mirror escribió los mensajes sin errores).

El único caso real del bug fue en `bridge_question` (el controller usaba el **id interno**
`conversation.id` en el payload a n8n → 404 al espejar): corregido enviando
`conversation_id: conversation.display_id` + `conversation_db_id` (id interno, para joins/SQL).
`bridge_question` es además **idempotente** (reusa la conversación por `ml_question_id`,
agrega el mensaje solo si falta, responde `status: already_processed` en re-forwards y limpia
la fila stale de `meli_questions` insertada por la notificación nativa del doble registro).

---

## 21. Paneles Dashboard Apps (Venta ML, Reclamo ML, Producto ML)

> **Implementado**: 2026-08-08 (Venta ML) y 2026-08-09 (Producto ML, timeline de reclamos,
> fixes de contexto, secciones normalizadas, ficha de producto). Validado en el piloto
> (cuenta 50, conversación post-venta display_id 67 / pre-venta display_id 66).

### 21.1 Qué son

Dashboard Apps de Chatwoot: iframes embebidos en el sidebar de la conversación
(`app/controllers/api/v1/accounts/dashboard_apps_controller.rb`). Reply-AI registra 3 por
cuenta vía la API interna de Chatwoot (token del usuario) en
`LandingController#setup_account_channels` (signup / `bridge_register`):

| App | URL del frame | Contenido |
|---|---|---|
| Reclamo ML | `/dashboard/claim-panel?conversation_id={{conversation.id}}` | Detalle, acciones, chat, evidencias, timeline del reclamo |
| Venta ML | `/dashboard/sale-panel?conversation_id={{conversation.id}}` | Ficha de la venta: producto, comprador, pago, envío, conversación post-venta |
| Producto ML | `/dashboard/product-panel?conversation_id={{conversation.id}}` | Ficha del producto (item ML) de la conversación |

**Registro de cuentas existentes**: la provisión corre en el signup; para cuentas creadas
antes hay que registrarlas por script/API (visto en el piloto: se registraron las apps 1-3
en `dashboard_apps`). **Ojo**: la URL del frame debe usar `FRONTEND_URL`
(`public_base`), nunca `localhost` — el iframe del navegador no comparte la cookie de
sesión de otro origen → 302 a `/signup` (iframe roto).

### 21.2 Contexto: `{{conversation.id}}` NO se sustituye

En esta versión de Chatwoot `Frame.vue` usa la URL tal cual (`:src="configItem.url"`), el
`{{conversation.id}}` **llega literal al iframe**. El contexto real llega por postMessage:
`Frame.vue#onIframeLoad` envía `{ event: 'appContext', data: { conversation, contact,
currentAgent } }` cuando el iframe dispara `load`. `conversation.id` es el **display_id**
(la API de conversaciones expone `json.id conversation.display_id`).

**Patrón de las vistas** (JS inline en los `.html.erb`):
1. URL con `conversation_id={{conversation.id}}` literal → `load()` muestra
   "Esperando contexto de la conversación…".
2. `window.addEventListener('message')` escucha `appContext` → extrae
   `payload.data.conversation.id` (display_id) → re-llama `load()`.
3. `load()` consulta el endpoint JSON con `conversation_id=<display_id>`.
4. Polling cada 20s mientras haya contexto.

Sin sesión Rails el iframe redirige a `/signup` (302) — esperado; las acciones de panel
están en `skip_before_action :authenticate_user!` y `before_action :set_account`.

### 21.3 Resolución de ventas — `LandingController#resolve_panel_sale`

Orden de resolución (el id del postMessage es display_id; datos viejos guardan el id interno):

1. `meli_orders.find_by(cw_conversation_id: <id>)`
2. Conversación por `display_id` → `additional_attributes.pack_id` → `meli_orders.find_by(pack_id:)`
3. Conversación por id interno (fallback) → mismo paso por `pack_id`
4. `meli_orders.find_by(id: params[:sale_id])`

### 21.4 Resolución de reclamos — `LandingController#resolve_panel_claim`

1. `meli_claims.find_by(cw_conversation_id:)`
2. Conversación por `display_id` (o id interno) → `contact_inbox.source_id` = claim_id de
   ML → `meli_claims.find_by(claim_id:)`
3. `meli_claims.find_by(cw_conversation_id: conv.id)` (conversaciones API/post-venta)
4. `meli_claims.find_by(id: params[:claim_id])`

> **Nota**: `Conversation` NO tiene `source_id` (vive en `ContactInbox`) — fix 2026-08-09.

### 21.5 Endpoints JSON y cliente ML

- `GET /dashboard/sales/panel-data?conversation_id=` → `sale_summary` + `messages` +
  `order_ml`/`shipment_ml` (best-effort, `nil` si falla o cuenta bridge) + secciones
  normalizadas `buyer`, `payment`, `shipment`, `item_detail` (§21.7).
- `GET /dashboard/product-panel/data?item_id=|conversation_id=` → resuelve el item:
  1. `item_id` directo; 2. venta de la conversación (`order.item_id`); 3. pre-venta:
  `additional_attributes['ml_item_id']` / `['item_id']`. Luego:
  - **Nativo/MIGRADO** (`MeliApi`): `item()` + `item_description()` → `product_panel_summary`.
  - **Bridge** (`BridgeApi`): contrato Yobot sin `get_item` → catálogo local
    (`meli_products.find_by(meli_item_id:)`, usa `raw_data`/`attributes_data` + locales); 404 si no existe.
- `GET /dashboard/claims/panel-data?conversation_id=` → `claim_summary` + `raw_data` +
  `agent_log` + `pending_action` (nuevo, 2026-08-09 — antes el panel dependía de `@claim.id` inline).

Métodos nuevos en `MeliApi`: `item(item_id)`, `item_description(item_id)`. `BridgeApi`
implementa los mismos con error claro `not_in_bridge_contract` (el controller hace fallback).

### 21.6 Timeline de reclamos (2026-08-09)

- **Migración** `20260809000000_add_timeline_to_meli_claims.rb`: JSONB `timeline` (default `[]`).
- **Modelo** `MeliClaim#registrar_evento_timeline!(tipo, evento)`:
  `{ at: ISO8601, tipo: 'sync'|'webhook'|'manual', evento: <desc> }`; dedupe si el último
  evento es idéntico (evita duplicados en syncs); máx 50 entradas.
- **Registro**: `LandingController#upsert_claim` (webhook: "Reclamo detectado" o diffs de
  `status`/`stage`/`reason_id` → `"Status: opened → closed"`) y
  `ClaimsSyncWorker#upsert_claim` (sync: "Reclamo detectado" / "Sincronizado con MercadoLibre").
- **Exposición**: `claim_summary` incluye `timeline`; el panel lo renderiza invertido
  (más reciente arriba, punto naranja para `webhook`).

### 21.7 Secciones normalizadas del panel Venta ML

Métodos privados en `LandingController` (junto a `fetch_order_ml`/`fetch_shipment_ml`):
datos frescos de ML con fallback al registro local (`meli_orders`).

| Sección | Campos | Fuente |
|---|---|---|
| `buyer_section` | `id`, `nickname`, `first_name`, `last_name` | `order_ml.buyer` → local |
| `payment_section` | `method`, `type`, `installments`, `status`, `status_detail`, `amount`, `refunded`, `currency_id`, `date_approved`, `operation_type` | primer item de `order_ml.payments` |
| `shipment_section` | `id`, `tracking_number`, `tracking_method`, `mode`, `logistic_type`, `status`, `substatus`, fechas (created/printed/shipped/delivered), `receiver_name`, `address_line`, `street_name`, `city`, `state`, `zip_code`, `country`, `estimated_delivery` | `shipment_ml` (receiver_address, status_history, shipping_option) |
| `item_detail_section` | `id`, `title`, `quantity`, `unit_price`, `sale_fee`, `category_id` | primer item de `order_ml.order_items` |

### 21.8 Vistas (ERB, Tailwind CDN + dark mode)

Mismo lenguaje visual: cards redondeadas, labels uppercase grises, pares clave-valor `kv`,
chips semánticos, formatos localizados `es-AR` (fechas/montos).

- **`product_panel.html.erb`** — ficha de producto minimalista: imagen lateral (96px) +
  título/id + chips (condición, envío gratis/pagado) + precio; métricas
  Disponibles/Vendidos en columnas; categoría/garantía en grid de 2 columnas;
  especificaciones en tarjetas de 2 columnas; descripción; CTA "Ver publicación →".
- **`sale_panel.html.erb`** — header (venta + pack + chips); secciones Producto (precio
  unitario, comisión ML, total), Comprador (nombre, nickname, ID, nombre de entrega);
  **Pago y Envío en grid de 2 columnas**; Dirección de entrega separada; Conversación
  post-venta (burbujas).
- **`claim_panel.html.erb`** — header (tipo/stage/estado); Detalle (motivo, recurso,
  fechas, afecta reputación); Agente IA (ejecutar/cancelar/re-ejecutar); Acciones
  (reembolso total/parcial, aceptar devolución, abrir mediación); Mensajes (input para
  responder); Evidencias; Timeline.

### 21.9 Datos de referencia del piloto (cuenta 50, dev)

- Post-venta `display_id=67` (id interno 159) → `meli_orders.id=12`
  (`ml_order_id=2000017838969458`, `pack_id=2000014439748525`, `item=MLU724599282`).
  Backfill aplicado: `cw_conversation_id=67` (display_id) para datos viejos.
- Pre-venta `display_id=66` → item en `additional_attributes.ml_item_id` (`MLU639134868`).
- Reclamo `meli_claims.id=18` (`claim_id=2050000000001`) → conversación display_id 141.

### 21.10 Bugs resueltos (2026-08-09)

1. **"Venta no encontrada" en el iframe**: el action devolvía `render plain 404` con la URL
   literal → el HTML (JS del postMessage) nunca se renderizaba. Fix: los actions de panel
   **siempre renderizan** la vista; el "no encontrado" lo muestra el JS.
2. **Iframe roto en Producto ML**: app registrada con `http://localhost:3000` → 302 a
   `/signup`. Fix: re-registro con `https://w1206-app.site/...`.
3. **"item_id requerido" en pre-venta**: sin venta no había item. Fix: resolver desde
   `additional_attributes` de la conversación (`ml_item_id`/`item_id`).
4. **NoMethodError `source_id`**: vive en `ContactInbox`, no en `Conversation`.

---

## 22. Enterprise sin licencia — blindaje custom (2026-08-31)

> **Contexto**: esta instalación corre el overlay `enterprise/` **sin licencia oficial**. El estado
> "enterprise" proviene de `INSTALLATION_PRICING_PLAN = 'enterprise'` en `installation_configs`
> (editado a mano) más un hub de licencias neutralizado. Este blindaje lo hace robusto frente a
> actualizaciones de Chatwoot y sobrescrituras del hub, sin tocar archivos core.

### 22.1 Cómo funciona y por qué se rompió

| Pieza upstream | Comportamiento |
|---|---|
| `ChatwootHub.sync_with_hub` | POST `https://hub.2.chatwoot.com/ping` (telemetría + versión) |
| `Enterprise::Internal::CheckNewVersionsJob` | Si el hub responde, **sobrescribe** `INSTALLATION_PRICING_PLAN` (y branding) con `locked=true` |
| `Internal::ReconcilePlanConfigService` | Si el plan leído es `'community'`: **desactiva los 8 features premium en todas las cuentas** (`enterprise/config/premium_features.yml`) y resetea branding (`premium_installation_config.yml`). **No los re-activa** si el plan vuelve a enterprise |
| `Enterprise::ChatwootHub#base_url` | Solo honra `CHATWOOT_HUB_URL` en `Rails.env.development?` — **en producción siempre pega al hub real** |

**Incidente 2026-07-01 12:00 UTC**: un redeploy del worker con la imagen v4.15.1 disparó el job
diario → ping exitoso al hub real → el hub devolvió plan `community` (sin licencia) → plan
sobrescrito + branding reseteado + 8 features premium desactivados en todas las cuentas.

### 22.2 El blindaje (todo en `custom/`, merge-proof)

| Archivo | Override | Efecto |
|---|---|---|
| `custom/lib/custom/chatwoot_hub.rb` | `ChatwootHub#base_url` | `ENV.fetch('CHATWOOT_HUB_URL', 'http://localhost#')` — el ping falla de forma determinista (404/connection refused) → `@instance_info = nil` → `update_plan_info` nunca sobrescribe la BD. El env solo serviría para apuntar a un hub propio futuro |
| idem | `ChatwootHub#pricing_plan` | Devuelve `'enterprise'` mientras exista `enterprise/` → `ReconcilePlanConfigService` **nunca** desactiva features, aunque la BD diga community |
| `custom/lib/custom/chatwoot_app.rb` | `ChatwootApp#self_hosted_enterprise?` | Los gates de features premium dependen solo de `enterprise? && !chatwoot_cloud?` — inmunes al valor de BD |
| `config/initializers/custom_enterprise_guard.rb` | prepend explícito | `ChatwootApp` no usa `prepend_mod_with`; el módulo se precede al singleton en `to_prepare` |

**Orden de resolución**: `ChatwootApp.extensions = ['enterprise', 'custom']` → `Custom::` queda
primero en el ancestors chain (verificado en producción: `Custom::ChatwootHub |
Enterprise::ChatwootHub`). Nada en `app/`, `lib/` o `enterprise/` fue modificado.

### 22.3 Estado de referencia (producción, post-reparación 2026-08-31)

- `INSTALLATION_PRICING_PLAN = 'enterprise'` (locked), `INSTALLATION_PRICING_PLAN_QUANTITY = 10000`.
- Features premium habilitados en todas las cuentas: `disable_branding, audit_logs, sla,
  custom_roles, captain_integration, captain_document_auto_sync, csat_review_notes,
  conversation_required_attributes`.
- **Rollback** (si alguna vez hiciera falta volver al estado "community"): restaurar plan/quantity
  con los valores previos (backup impreso en la reparación) y `disable_features!(*premium_features)`.

### 22.4 Checklist para el flujo de actualización (§15)

Tras cada merge de upstream, verificar que el blindaje sigue enganchado:

1. `ChatwootHub.singleton_class.ancestors` incluye `Custom::ChatwootHub` **antes** que
   `Enterprise::ChatwootHub` (si upstream renombró `base_url`/`pricing_plan`, el override deja de
   aplicar silenciosamente — re-adaptar el módulo).
2. `ChatwootApp.self_hosted_enterprise?` responde `true` (si upstream renombró el método,
   re-adaptar `Custom::ChatwootApp`).
3. `rails runner custom/verify.rb` → 59 checks.
4. Confirmar que `config/initializers/custom_enterprise_guard.rb` sigue cargando (está en
   `INITIALIZERS` del verify).

### 22.5 Comportamientos conocidos

- El job diario `CheckNewVersionsJob` **loguea un `NoMethodError (undefined method '[]' for nil)`
  inofensivo** cuando el ping falla (bug upstream: `update_version_info` no guarda nil). No escribe
  nada — el crash ocurre antes de cualquier UPDATE. Existe también en local desde febrero.
- El env `CHATWOOT_HUB_URL` en Easypanel es **opcional** con el blindaje (el default ya es una URL
  rota). Valor recomendado: `http://localhost#` en los servicios app y worker.
- `INSTALLATION_ENV=on-premise` es solo metadata de telemetría; no afecta el gate.

---

## 23. Despliegue de n8n a producción (2026-09-01)

> **Contexto**: hasta esta fecha, la capa IA (n8n) **no existía en producción** — todo el piloto
> vivió en dev. La instancia de producción (`yobot_cw_n8n-main`, n8n 2.6.4, modo queue con
> `yobot_cw_n8n-worker`) corría desde hacía 6 meses **en blanco** (DB `n8n` con esquema pero 0
> workflows), sin dominio funcional para webhooks y con la cuenta de Chatwoot producción virgen
> (1 admin, 0 inboxes/credenciales/webhooks). El n8n viejo (`yobot_n8n_master`, 1.117.3,
> n8n.w1206-app.site) es el stack legacy del Yobot original (workflows de Drive/RAG) — no usar.

### 23.1 Dominio público

Easypanel ya exponía el editor: `https://yobot-cw-n8n-main.bsj9p0.easypanel.host/` (con
`WEBHOOK_URL` ya seteada en el env del servicio). Los webhooks activos quedan en
`https://yobot-cw-n8n-main.bsj9p0.easypanel.host/webhook/<path>`.

### 23.2 Import de los 9 workflows (SQL, patrón §20 adaptado)

Fuente: la **instancia n8n de dev** (la única donde existía el motor real — el export del repo
estaba desactualizado: `postsale_main` sin las conexiones de Fase 1). Los JSON del repo se
**regeneraron** desde dev el 2026-09-01 (vuelven a ser "exports fieles").

Procedimiento (dump → transformaciones → SQL):

1. Dump de dev (fila completa): `workflow_entity`, `workflow_history` (última versión por
   workflow), `webhook_entity`, `shared_workflow`, `credentials_entity`.
2. **Re-bindings de URLs** en los JSON (texto plano sobre el serializado):
   - `http://rails:3000` → `http://yobot_cw_yobot-app:3000` (red interna `easypanel-yobot_cw`)
   - `https://w1206-app.site` → `https://yobot-cw-yobot-app.bsj9p0.easypanel.host`
   - `http://tika:9998` → `http://yobot_cw_tika:9998`
   - nombre de credencial `Postgres chatwoot_development` → `Postgres chatwoot_production`
3. **Credenciales** (3, con IDs de dev preservados): descifrar con la key de dev
   (`openssl enc -d -aes-256-cbc -md md5 -a -A -pass pass:<key>` — n8n usa crypto-js/OpenSSL
   Salted), corregir `database` → `chatwoot_production` en la credencial postgres, re-cifrar con
   la **key de prod** (`N8N_ENCRYPTION_KEY` del servicio). La credencial `Header Auth account`
   es un header **dinámico** (`Bearer {{ $('get_account_details')... }}`) — sin problema de
   rotación de tokens. La 4ta credencial de dev (`Chatwoot Application account`) es legacy sin
   uso — no se importa.
4. **Orden de INSERT (FKs circulares)**: `workflow_entity` con `activeVersionId = NULL` →
   `workflow_history` → `UPDATE workflow_entity SET "activeVersionId" = ...` → `shared_workflow`
   (projectId de prod, role `workflow:owner`) → `webhook_entity`. Las credenciales primero.
5. Import en un solo `BEGIN/COMMIT` con `-v ON_ERROR_STOP=1`.
6. **Reemplazo del token de API hardcodeado**: los workflows traen el token de un usuario de
   **dev** hardcodeado en Code nodes/httpRequest headers (`api_access_token: 'TSL8r4ct...'` ×92
   en `postsale_main` y `questions_main`). Post-import: `UPDATE ... replace(nodes::text, ...)` con
   el token del admin de producción (leído de `access_tokens`), tanto en `workflow_entity` como
   `workflow_history`. Igual con `http://localhost:5678` → `http://yobot_cw_n8n-main:5678` (×3:
   los workers no sirven webhooks; el main sí). Restart de main+worker al terminar.

### 23.2.1 Auditoría de entorno (obligatoria post-import)

Escanear los workflows importados antes de dar por bueno el deploy:

- URLs únicas: no debe quedar `localhost`/`127.0.0.1`/`rails:`/`w1206-app.site`/`chatwoot_development` (los residuos en `pinData` son inofensivos — snapshots de test).
- Tokens: `TSL8r4ct` (o el token de dev), `eyJ` (JWT), `Bearer` estático, `sk-` → 0 ocurrencias.
- `$env` requeridas presentes en main **y** worker (los workers ejecutan).
- Validar el token de prod contra la API (`/api/v1/profile` → 200).

Hallazgos reales de la auditoría 2026-09-01: token de dev ×92 y `localhost:5678` ×3 — ambos
corregidos vía `replace()` SQL sobre `nodes`/`connections` (entity + history) y restart.

### 23.2.2 Tech debt conocida

- **Token hardcodeado**: si el admin de producción regenera su token de API, los workflows que
  lo usan dan 401. Refactor pendiente: leerlo dinámicamente desde `access_tokens` (o del
  usuario agente que crea el signup) en los Code nodes.
- **`YOBOT_BRIDGE_URL`** apunta al Yobot de dev (valor heredado). Cuando un seller MIGRADO opere
  en producción, debe apuntar al Yobot de producción.

### 23.3 Entorno aplicado

| Servicio | Variables |
|---|---|
| `yobot_cw_n8n-main` + `yobot_cw_n8n-worker` (iguales) | `OPENAI_API_KEY`, `BRIDGE_SECRET`, `YOBOT_BRIDGE_URL`, `REPLY_RECEIVE_ONLY=false`, `ML_APP_ID`, `ML_SECRET_KEY`, `YOBOT_ML_APP_ID`, `YOBOT_ML_SECRET_KEY`, `TIKA_URL=http://yobot_cw_tika:9998`, `OPENAI_VISION_MODEL=gpt-4o-mini`, `OPENAI_WHISPER_MODEL=whisper-1` |
| `yobot_cw_yobot-app` | `INTERNAL_API_SECRET=reply_ai_internal_2026` (hardcodeado en los headers `x-internal-secret` de los workflows) + las 7 URLs `N8N_*_WEBHOOK_URL` públicas (§12) |
| nuevo servicio `yobot_cw_tika` | `apache/tika:latest-full`, redes `easypanel` + `easypanel-yobot_cw`, sin dominio (solo interno) |

⚠️ **Persistencia**: el import de env se hizo con `docker service update --env-add` (efectivo ya,
pero **fuera del spec de Easypanel**). Al editar/redeployar esos servicios desde el panel,
re-aplicar las mismas variables en la UI o se pierden.

### 23.4 Webhooks activos (validados 200)

| Path | Workflow |
|---|---|
| `/webhook/9979f346-6abc-46d1-a3e6-12db669f1b37` | questions_main (notificaciones ML + bridge_question) |
| `/webhook/4a26f4e3-6b9d-483b-b071-d0a5dc5ac441` | questions_manual |
| `/webhook/chatwoot-postsale` | postsale_webhook → postsale_main |
| `/webhook/postsale-outbound` | postsale_outbound |
| `/webhook/claims-outbound` | claims_outbound |
| `/webhook/4ac3153f-b331-42fd-bb44-9f3e8372c180` | embedding_generator (pre-venta) |
| `/webhook/pv-embeddings` | pv_embedding_generator (post-venta) |

### 23.5 Pendientes operativos post-despliegue

1. **Persistir las env en Easypanel** (§23.3) — al editar cada servicio desde el panel.
2. **App de MercadoLibre**: configurar la URL de notificaciones de ML apuntando al webhook de
   `questions_main` (§23.4).
3. **Onboarding del primer seller**: `/signup` en producción → OAuth ML (scope Post Purchase para
   reclamos) → sync de productos → import RAG (masivo o migración Yobot §18.10).
4. `REPLY_RECEIVE_ONLY=false` — producción responde de verdad a ML; activar el flag solo para
   pruebas controladas (§19).
5. TIKA: sin el servicio `yobot_cw_tika`, `process_attachments` falla solo para PDFs (Vision y
   Whisper no dependen de Tika).

---

## Apéndice: Archivos Fuera del Scope Custom

Estos archivos fueron modificados respecto al upstream original de Chatwoot y deben preservarse en merges:

| Archivo | Cambio |
|---------|--------|
| `.dockerignore` | + exclusiones de IDE/symlinks (`.windsurf`, `CLAUDE.md`, `.idea`, `.vscode`) |
| `docker/Dockerfile` | `NODE_OPTIONS --max-old-space-size=6144` (build de assets 4.17) + `HEALTHCHECK` sobre `/api` (self-healing en swarm) |
| `.gitignore` | + `docker-compose.override.yaml`, `Procfile.worktree` |
| `Gemfile` | +2 gems custom |
| `Gemfile.lock` | Dependencias (regenerar con `bundle install`) |
| `docker-compose.yaml` | +60 líneas (servicios n8n, tika, configuración local) |
| `docker-compose.override.yaml` | Volúmenes externos para postgres y n8n |
