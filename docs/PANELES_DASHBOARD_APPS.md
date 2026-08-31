# PANELES DASHBOARD APPS (Venta ML, Reclamo ML, Producto ML)

> **Última actualización**: 2026-08-09 — Tres Dashboard Apps de Chatwoot implementadas y
> funcionando en el piloto (cuenta 50): **Venta ML**, **Reclamo ML** y **Producto ML**.
> Incluyen: resolución de contexto por `postMessage appContext` (la URL del iframe llega sin
> sustituir `{{conversation.id}}` en esta versión de Chatwoot), secciones normalizadas con
> datos frescos de ML (order/shipment/item), ficha de producto, timeline de reclamos y
> resolución de items en conversaciones pre-venta.

---

## 1. Qué son

Dashboard Apps de Chatwoot: iframes embebidos en el sidebar de la conversación
(`app/controllers/api/v1/accounts/dashboard_apps_controller.rb`). Reply-AI registra 3 por
cuenta (vía API interna de Chatwoot con el token del usuario):

| App | URL del frame | Contenido |
|---|---|---|
| Reclamo ML | `/dashboard/claim-panel?conversation_id={{conversation.id}}` | Detalle, acciones, chat, evidencias, timeline del reclamo |
| Venta ML | `/dashboard/sale-panel?conversation_id={{conversation.id}}` | Ficha de la venta: producto, comprador, pago, envío, conversación post-venta |
| Producto ML | `/dashboard/product-panel?conversation_id={{conversation.id}}` | Ficha del producto (item ML) de la conversación |

Registro: `LandingController#setup_account_channels` (3 bloques `RestClient.post` a
`/api/v1/accounts/:id/dashboard_apps`, uno por app) — corre en el signup/provisión de cuenta.
Para cuentas existentes se registró vía script `rails runner` + API.

**Importante**: el `{{conversation.id}}` de la URL **NO se sustituye** en esta versión de
Chatwoot (`Frame.vue` usa la URL tal cual). El contexto real llega por postMessage:
Chatwoot envía `{ event: 'appContext', data: { conversation, contact, currentAgent } }`
cuando el iframe dispara `load`; `conversation.id` es el **display_id** (la API de
conversaciones expone `json.id conversation.display_id`).

## 2. Arquitectura de resolución de contexto

Todas las vistas siguen el mismo patrón (JS inline en el `.html.erb`):

1. La URL llega con `conversation_id={{conversation.id}}` (literal) → `load()` detecta el
   literal y muestra "Esperando contexto de la conversación…".
2. `window.addEventListener('message')` escucha `appContext`, extrae
   `payload.data.conversation.id` (display_id) y re-llama `load()`.
3. `load()` consulta el endpoint JSON con `conversation_id=<display_id>`.
4. Polling cada 20s mientras haya contexto.

Fallo por ausencia de sesión: el iframe va con la cookie de Chatwoot (mismo dominio); sin
sesión Rails redirige a `/signup` (302) — comportamiento esperado e idéntico en las 3 apps.

## 3. Backend (todo en `custom/`)

### 3.1. Rutas (`config/initializers/reply-ai_routes.rb`)

```ruby
# Dashboard Apps (2026-08-08/09)
get '/dashboard/sale-panel'            => 'landing#sale_panel',         as: :sale_panel
get '/dashboard/sales/panel-data'      => 'landing#sale_panel_data',    as: :sale_panel_data
get '/dashboard/sales/:id'             => 'landing#sale_detail',        as: :sale_detail
get '/dashboard/product-panel'         => 'landing#product_panel',      as: :product_panel
get '/dashboard/product-panel/data'    => 'landing#product_panel_data', as: :product_panel_data
get '/dashboard/claim-panel'           => 'landing#claim_panel',        as: :claim_panel
get '/dashboard/claims/panel-data'     => 'landing#claim_panel_data',   as: :claim_panel_data
```

Todas las acciones están en `skip_before_action :authenticate_user!` y en
`before_action :set_account` (el panel debe poder servirse dentro del iframe autenticado).

### 3.2. Resolución de ventas — `LandingController#resolve_panel_sale`

Resuelve la venta en este orden:

1. `meli_orders.find_by(cw_conversation_id: <id>)` — el id llega como display_id vía
   postMessage; antes del fix (2026-08-09) n8n guardaba el id **interno** en
   `cw_conversation_id`, por eso se mantiene el paso 3 como fallback.
2. `conversations.find_by(display_id:)` → por `pack_id` en `additional_attributes`.
3. `conversations.find_by(id:)` (id interno, datos viejos) → por `pack_id`.
4. Fallback final: `meli_orders.find_by(id: params[:sale_id])`.

### 3.3. Endpoints JSON

- **`sale_panel_data`** → `sale_summary(order)` + `messages` (conversación post-venta) +
  `order_ml` y `shipment_ml` (best-effort desde ML, `nil` si falla o cuenta bridge) +
  secciones normalizadas: `buyer`, `payment`, `shipment`, `item_detail`.
- **`product_panel_data`** → si viene `item_id`, lo usa directo. Si viene `conversation_id`:
  primero intenta la venta de la conversación (`order.item_id`); si no hay venta (pre-venta)
  lee `additional_attributes['ml_item_id']` o `['item_id']` de la conversación. Luego:
  - **Nativo/MIGRADO** (`MeliApi`): `item(item_id)` + `item_description` → `product_panel_summary`.
  - **Bridge** (`BridgeApi`): el contrato Yobot no expone `get_item` → fallback al catálogo
    local `meli_products.find_by(meli_item_id:)` (usa `raw_data`/`attributes_data` + campos
    locales). Si no está en catálogo → 404.
- **`claim_panel_data`** → `resolve_panel_claim` + `claim_summary` + `raw_data`/`agent_log`/
  `pending_action`.

### 3.4. Resolución de reclamos — `LandingController#resolve_panel_claim`

1. `meli_claims.find_by(cw_conversation_id:)` (id interno que persiste el webhook).
2. Conversación por `display_id` (o id interno) → `contact_inbox.source_id` = claim_id de ML
   (conversaciones del inbox de reclamos) → `meli_claims.find_by(claim_id:)`.
3. `meli_claims.find_by(cw_conversation_id: conv.id)` (conversaciones API/post-venta
   vinculadas al reclamo).
4. Fallback: `meli_claims.find_by(id: params[:claim_id])`.

**Nota**: las conversaciones de Chatwoot NO tienen `source_id` (vive en `ContactInbox`) —
fix aplicado 2026-08-09.

### 3.5. Cliente ML — métodos nuevos (`custom/lib/reply_ai/meli_api.rb`, `bridge_api.rb`)

```ruby
# MeliApi (nativo/MIGRADO)
def item(item_id)                    # GET /items/:id
def item_description(item_id)        # GET /items/:id/description

# BridgeApi — el contrato Yobot NO incluye get_item; estos métodos lanzan un error claro
# (404 not_in_bridge_contract) y el controller hace fallback a catálogo local + permalink.
```

## 4. Secciones normalizadas del panel Venta ML (2026-08-09)

Métodos privados en `LandingController` que arman hashes con datos frescos de ML y fallback
al registro local (`meli_orders`):

| Sección | Campos | Fuente |
|---|---|---|
| `buyer_section` | `id`, `nickname`, `first_name`, `last_name` | `order_ml.buyer` → `meli_orders` |
| `payment_section` | `method`, `type`, `installments`, `status`, `status_detail`, `amount`, `refunded`, `currency_id`, `date_approved`, `operation_type` | primer item de `order_ml.payments` |
| `shipment_section` | `id`, `tracking_number`, `tracking_method`, `mode`, `logistic_type`, `status`, `substatus`, fechas (`date_created`, `date_first_printed`, `date_shipped`, `date_delivered`), `receiver_name`, `address_line`, `street_name`, `city`, `state`, `zip_code`, `country`, `estimated_delivery` | `shipment_ml` (receiver_address, status_history, shipping_option) |
| `item_detail_section` | `id`, `title`, `quantity`, `unit_price`, `sale_fee`, `category_id` | primer item de `order_ml.order_items` |

Los métodos están al lado de `fetch_order_ml`/`fetch_shipment_ml` en `landing_controller.rb`.

## 5. Timeline de reclamos (2026-08-09)

- **Migración** `custom/db/migrate/20260809000000_add_timeline_to_meli_claims.rb`: columna
  JSONB `timeline` (default `[]`) en `meli_claims`.
- **Modelo** `MeliClaim#registrar_evento_timeline!(tipo, evento)`:
  `{ at: ISO8601, tipo: 'sync'|'webhook'|'manual', evento: <desc> }`. Dedupe: no registra
  si el último evento es idéntico (evita duplicados en syncs repetidos). Máx 50 entradas.
- **Registro de eventos**:
  - `LandingController#upsert_claim` (webhook): "Reclamo detectado" (nuevo) o diffs de
    `status`/`stage`/`reason_id` → `"Status: opened → closed"` etc.
  - `ReplyAi::ClaimsSyncWorker#upsert_claim` (sync): "Reclamo detectado" (nuevo) o
    "Sincronizado con MercadoLibre".
- **Exposición**: `claim_summary` incluye `timeline`; el panel lo renderiza invertido
  (más reciente arriba) con punto naranja para eventos `webhook`.

## 6. Vistas (ERB, Tailwind CDN + dark mode)

Todas en `custom/app/views/landing/`. Mismo lenguaje visual: cards redondeadas, labels
uppercase grises, pares clave-valor (`kv`), chips semánticos de estado, formatos
localizados `es-AR` (fechas y montos), dark mode con `html.dark`.

- **`product_panel.html.erb`** — ficha de producto minimalista: imagen lateral (96px) +
  título/id + chips (condición, envío gratis/pagado) + precio; métricas Disponibles/Vendidos
  en columnas; categoría/garantía en grid de 2 columnas; especificaciones en tarjetas de 2
  columnas; descripción; CTA "Ver publicación →".
- **`sale_panel.html.erb`** — header (venta + pack + chips estado); secciones Producto
  (precio unitario, comisión ML, total), Comprador (nombre, nickname, ID, nombre de
  entrega); **Pago y Envío en grid de 2 columnas**; Dirección de entrega separada;
  Conversación post-venta (mensajes con burbujas).
- **`claim_panel.html.erb`** — header (tipo/stage/estado); Detalle (motivo, recurso,
  fechas, afecta reputación); Agente IA con acciones (ejecutar/cancelar/re-ejecutar);
  Acciones (reembolso total/parcial, aceptar devolución, abrir mediación); Mensajes del
  reclamo (input para responder); Evidencias; Timeline.

## 7. Datos de referencia en el piloto (cuenta 50, dev)

- Conversación post-venta `display_id=67` (id interno 159) → venta `meli_orders.id=12`
  (`ml_order_id=2000017838969458`, `pack_id=2000014439748525`, `item=MLU724599282`).
  Backfill aplicado: `cw_conversation_id=67` (display_id) para datos guardados con el id
  interno.
- Conversación pre-venta `display_id=66` → item en `additional_attributes.ml_item_id`
  (`MLU639134868`).
- Reclamo `meli_claims.id=18` (`claim_id=2050000000001`) → conversación display_id 141.
- Dashboard Apps en BD: `dashboard_apps` ids 1 (Reclamo ML), 2 (Venta ML), 3 (Producto ML),
  todas con URL `https://w1206-app.site/dashboard/*` (FRONTEND_URL). **Ojo**: no registrar
  con `localhost` — el iframe del navegador no comparte la cookie de sesión → 302/signup.

## 8. Diagnósticos de bugs resueltos (2026-08-09)

1. **"Venta no encontrada" en el iframe**: el action devolvía `render plain 404` al recibir
   `conversation_id={{conversation.id}}` literal → el HTML (con el JS que escucha
   postMessage) nunca se renderizaba. Fix: los actions de panel **siempre renderizan** la
   vista; el mensaje de "no encontrado" lo muestra el JS.
2. **Iframe roto en Producto ML**: la app quedó registrada con `http://localhost:3000`
   (sin cookie → 302 a `/signup`). Fix: re-registro vía API con
   `https://w1206-app.site/...`.
3. **"item_id requerido" en pre-venta**: sin venta asociada no había item. Fix: resolver
   el item desde `additional_attributes` de la conversación (`ml_item_id`/`item_id`).
4. **NoMethodError `source_id`**: `Conversation` no tiene `source_id` — vive en
   `contact_inbox`. Fix en `resolve_panel_claim`.
