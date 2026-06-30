# Chatwoot + Reply-AI — Documentación Técnica Unificada

> **Versión**: Chatwoot 4.15.1 + Reply-AI / Meli  
> **Última actualización**: 2026-06-30  
> **Propósito**: Referencia completa para agentes IA y desarrolladores.

---

## Tabla de Contenidos

1. [Resumen del Proyecto](#1-resumen-del-proyecto)
2. [Stack Tecnológico](#2-stack-tecnológico)
3. [Arquitectura General](#3-arquitectura-general)
4. [Custom Layer (Reply-AI / Meli)](#4-custom-layer-reply-ai--meli)
5. [Modelos Custom](#5-modelos-custom)
6. [LandingController (1018 líneas)](#6-landingcontroller-1018-líneas)
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
│   │   ├── controllers/     ← LandingController
│   │   ├── models/          ← 7 modelos Meli/ReplyAi
│   │   └── views/landing/   ← 12 vistas ERB
│   ├── lib/
│   │   ├── custom.rb        ← Módulo Custom (placeholder)
│   │   └── reply_ai/        ← 7 workers + middleware CSS
│   ├── db/migrate/          ← 8 migraciones custom
│   └── verify.rb            ← Script de verificación
├── config/initializers/     ← Incluye 7 initializers custom
├── n8n/                     ← 6 workflows JSON
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
│   │   └── landing_controller.rb          (1018 líneas)
│   ├── models/
│   │   ├── meli_credential.rb             (7 líneas)
│   │   ├── meli_product.rb                (6 líneas)
│   │   ├── meli_category.rb               (3 líneas)
│   │   ├── meli_official_store.rb         (8 líneas)
│   │   ├── meli_order.rb                  (9 líneas)
│   │   ├── reply_ai_document.rb           (17 líneas)
│   │   └── reply_ai_pv_document.rb        (17 líneas)
│   └── views/landing/
│       ├── index.html.erb
│       ├── signup.html.erb
│       ├── setup_meli.html.erb
│       ├── meli_error.html.erb
│       ├── welcome.html.erb
│       ├── dashboard.html.erb             (2854 líneas)
│       ├── post_venta.html.erb            (552 líneas)
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
│       └── pv_document_processor_worker.rb (35 líneas)
├── db/migrate/                            ← 8 migraciones
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
Tracking de órdenes para post-venta. Campos: `ml_order_id`, `ml_buyer_id`, `item_id`, `pack_id`, `order_status`, `shipping_mode`, `message_sent`, `message_sent_at`, `message_error`, `had_questions`, `ai_answered`, `questions_count`, `conversion_checked_at`.

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

## 6. LandingController (1018 líneas)

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

### Flujo de signup

1. Usuario completa formulario en `/signup` (name, email, password, account_name)
2. `create_account`:
   - Crea User vía `POST /platform/api/v1/users`
   - Crea Account vía `POST /platform/api/v1/accounts`
   - Vincula User como administrator vía `POST /platform/api/v1/accounts/:id/account_users`
   - Crea 2 API-channel inboxes: "Pre-venta (MercadoLibre)" y "Post-venta (MercadoLibre)"
   - Crea equipo "Agentes" y agrega al usuario
   - Configura `custom_attributes` con defaults para la cuenta
   - Crea labels relevantes (8 labels)
   - Crea 3 webhooks para integración con n8n
   - Inicia sesión Devise y redirige a OAuth de MercadoLibre

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
**Cron**: Cada hora (minuto 0).  
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
**Función**: Importa documentos desde CSV/XLSX. Parsea archivo, crea `ReplyAiDocument` o `ReplyAiPvDocument` por fila, notifica a n8n para embeddings. Soporta CSV (con detección de encoding y separador) y XLSX (vía gem `roo`).

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

### Tablas (9 total)

| Tabla | Columnas clave | Propósito |
|-------|---------------|-----------|
| `meli_credentials` | `account_id`, `ml_user_id` (unique), `access_token`, `refresh_token`, `expires_at`, `status` | Tokens OAuth ML |
| `meli_products` | `account_id`, `meli_item_id` (unique), `title`, `thumbnail`, `status`, `category_id`, `price`, `sold_quantity`, `pictures` (jsonb), `attributes_data` (jsonb), `raw_data` (jsonb), +20 campos más | Catálogo ML |
| `meli_categories` | `account_id`, `meli_category_id`, `name`, `parent_id`, `level` | Categorías ML |
| `meli_official_stores` | `account_id`, `meli_store_id` (unique), `name`, `status`, `logo`, `custom_greeting` | Tiendas oficiales |
| `meli_orders` | `account_id`, `ml_order_id` (unique), `ml_buyer_id`, `item_id`, `pack_id`, `order_status`, `message_sent`, `had_questions`, `ai_answered`, `questions_count` | Órdenes post-venta |
| `meli_questions` | `question_id` (PK text), `account_id`, `cw_conversation_id`, `status` | Deduplicación de preguntas |
| `reply_ai_documents` | `account_id`, `level`, `reference_id`, `file_name`, `content`, `embedding` (vector(1536)), `source` | Docs RAG pre-venta |
| `reply_ai_pv_documents` | Igual que arriba | Docs RAG post-venta |
| `reply_ai_pre_memory` | — (tabla auxiliar) | Memoria de pre-venta |

### Migraciones (8 archivos en `custom/db/migrate/`)

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

---

## 11. n8n Workflows

6 workflows JSON en `n8n/`:

| Archivo | Función |
|---------|---------|
| `reply_ai_questions_main.json` | **Pre-venta**: Recibe webhook de ML → busca credenciales → crea conversación en Chatwoot → busca docs RAG → genera respuesta con OpenAI → envía a ML |
| `reply_ai_questions_manual.json` | **Pre-venta manual**: Cuando un humano responde en Chatwoot, reenvía la respuesta a ML |
| `reply_ai_orders_main.json` | **Post-venta**: Recibe notificación de orden → escribe `meli_orders` → envía mensaje post-venta |
| `reply_ai_postsale_main.json` | **Post-venta IA**: Similar a questions_main pero para inbox post-venta |
| `reply_ai_postsale_outbound.json` | **Post-venta outbound**: Respuestas humanas de Chatwoot → ML |
| `reply_ai_embedding_generator.json` | **Embeddings**: Recibe webhook con doc_id → extrae texto → genera embedding con OpenAI → guarda en BD |

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
GET    /go_to_chats                         landing#go_to_chats
PATCH  /dashboard/stores/:store_id/greeting landing#update_store_greeting
POST   /dashboard/stores/refresh            landing#refresh_official_stores
GET    /bot_active                          landing#bot_active
GET|POST /conversation_ai_gate              landing#conversation_ai_gate
GET    /dashboard/post-venta                landing#post_venta
POST   /dashboard/post-venta/update         landing#update_post_venta
POST   /dashboard/pv-upload                 landing#pv_upload_document
DELETE /dashboard/pv-docs/:id               landing#pv_destroy_document
POST   /rag/pv_search                       landing#pv_rag_search
POST   /dashboard/bulk-import/preview       landing#bulk_import_preview
POST   /dashboard/bulk-import               landing#bulk_import
GET    /dashboard/docs                      landing#product_docs_list
DELETE /dashboard/docs/:id/ajax             landing#destroy_document_ajax
DELETE /dashboard/pv-docs/:id/ajax          landing#pv_destroy_document_ajax
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
| `N8N_EMBEDDING_WEBHOOK_URL` | Webhook de n8n para generar embeddings (pre-venta) |
| `N8N_PV_EMBEDDING_WEBHOOK_URL` | Webhook de n8n para embeddings post-venta |
| `TIKA_URL` | URL de Apache Tika (extracción de texto) |
| `OPENAI_API_KEY` | API key de OpenAI (usada por n8n, referenciada en config) |

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
# Deben salir todos ✓ (48 checks)

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
- `config/initializers/reply-ai_routes.rb`
- `config/initializers/reply_ai_account_associations.rb`
- `config/initializers/reply_ai_cron.rb`
- `config/initializers/reply_ai_middleware.rb`
- `config/initializers/reply_ai_schema_guard.rb`
- `config/initializers/custom_error_codes.rb`
- `n8n/` (workflows)
- `TECHNICAL.md` (este documento)

---

## 16. Script de Verificación

`custom/verify.rb` — 48 checks en 6 categorías:

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
| 5 | Initializers | 7 archivos presentes, sin duplicado |
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

## Apéndice: Archivos Fuera del Scope Custom

Estos archivos fueron modificados respecto al upstream original de Chatwoot y deben preservarse en merges:

| Archivo | Cambio |
|---------|--------|
| `.gitignore` | + `docker-compose.override.yaml`, `Procfile.worktree` |
| `Gemfile` | +2 gems custom |
| `Gemfile.lock` | Dependencias (regenerar con `bundle install`) |
| `docker-compose.yaml` | +60 líneas (servicios n8n, tika, configuración local) |
| `docker-compose.override.yaml` | Volúmenes externos para postgres y n8n |
