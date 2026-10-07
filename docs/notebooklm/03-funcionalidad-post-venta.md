# Funcionalidad Post-Venta — Mensajes post-compra, órdenes y reclamos

> Documento fuente para NotebookLM. Detalle del flujo post-venta de Reply-AI (Chatwoot v4.18.0): pipeline de IA, ciclo de vida de conversaciones, estados de lectura, reclamos y paneles.

## 1. Qué es la post-venta

La post-venta atiende todo lo que ocurre **después de la compra**: mensajes del comprador sobre el envío ("¿dónde está mi pedido?"), notificaciones de órdenes, y el ciclo completo de **reclamos, devoluciones y cambios**. Es un pipeline mucho más sofisticado que la pre-venta: mantiene un **ciclo de vida de la conversación** (activa, cerrada, derivada a humano, bloqueada), detecta **sentimiento** del comprador, hace **handoff automático** cuando la situación lo requiere, comprende **adjuntos** (imágenes, PDFs, audios) con IA, y gestiona los ✓✓ de estado de lectura de los mensajes.

Dos inboxes participan: **"Post-venta (MercadoLibre)"** (mensajes) y **"Reclamos (MercadoLibre)"** (reclamos formales).

## 2. Mensaje inicial de órdenes (workflow `orders_main`)

Cuando ML notifica una orden (compra confirmada):

1. El workflow escribe/actualiza la fila en `meli_orders` (orden, envío, ítem, pack, buyer).
2. Envía el **mensaje post-venta inicial** al comprador, según la configuración:
   - Mensaje de cortesía de bienvenida, o
   - Mensaje de guía de acción (instrucciones según `cap`/`already_sent`, por ejemplo coordinar el envío).
3. El envío respeta los perfiles nativo/bridge y el modo `receive_only`.

## 3. Pipeline principal de post-venta (workflow `postsale_main`)

El flujo completo (~77 nodos) procesa cada mensaje post-venta:

1. **Trigger por passthrough**: recibe el mensaje (webhook `chatwoot-postsale` nativo o forward `bridge_message` de Yobot) con el contexto (orden, envío, estado de conversación, `pack_id`).
2. **Idempotencia**: `check_idempotency` inserta en `meli_questions` con clave `ms_{_id}` — evita procesar el mismo mensaje dos veces.
3. **Normalización** (`normalize_message`): texto normalizado para el resto del pipeline.
4. **Comprensión de adjuntos** (`process_attachments`): si hay adjuntos, los descarga (GET de ML o URLs del forward), clasifica por MIME y los interpreta con IA:
   - **Imagen** → modelo Vision (`OPENAI_VISION_MODEL`, default `gpt-4o-mini`).
   - **PDF** → Apache Tika (extracción de texto).
   - **Audio** → Whisper (`whisper-1`) → transcripción.
   El resultado se inyecta como `attachment_context` en el prompt.
5. **Estado de la orden** (`get_order_state` + `check_lifecycle`): lee/evalúa el ciclo de vida (ver §4). Las acciones de sistema (cierre por cortesía, reapertura, bloqueo, handoff) corren **siempre**; la respuesta IA solo si el gate lo permite.
6. **Sentimiento** (`detect_sentiment`): nodo dedicado — POST a OpenAI (temperature 0) que devuelve `{sentiment: POSITIVO|NEUTRAL|INSATISFECHO|ENOJADO, requiere_humano, motivo}` usando el mensaje + historial reciente. Persiste `last_sentiment` y `consecutive_enojado` en `meli_orders`.
7. **Handoff** (`eval_handoff`): consolida las reglas H1–H6 (ver §4) → si aplica: `estado_conversacion = needs_human/bloqueada` + label `atencion-humana` + **nota privada** con el motivo, y **no responde a ML**.
8. **RAG post-venta**: `rag_search` → `POST /rag/pv_search` de Rails, que busca en `reply_ai_pv_documents` (base separada de la pre-venta) por embedding + `item_id` de la orden.
9. **Contexto** (`context_assembler`): arma el prompt final con historial, orden/envío (desde el forward en bridge), `attachment_context`, RAG y config.
10. **Clasificación de intención** (`classify_intent` + `normalize_intent`): OpenAI clasifica la intención (saludo, logística, soporte, cierre, etc.). `normalize_intent` quita tildes/puntuación para el matching (`Logística.` → `logistica`).
11. **Router de intención** (`intent_router`): enruta a la rama de respuesta correspondiente; fallback → nota privada `post_ai_unavailable_note` + label `atencion-humana` cuando la intención no matchea o la rama está deshabilitada en config.
12. **Ciclo de labels**: `set_bot_label` (`bot-procesando`) → respuesta → `respondida_con_ia` (o `atencion-humana`/`esperando_respuesta_manual` según el caso).
13. **Envío**: 5 nodos de envío (`send_*_reply_ml`) + escalación, todos Code nodes con rama bridge (`{YOBOT_BRIDGE_URL}/api/bridge/send-message` con HMAC) / nativa (ML directo).
14. **Espejo en Chatwoot** (`mirror_*_to_chatwoot`): publica la respuesta en la conversación (`source: n8n_ai`) con `content_attributes.ml_message_id` y la marca `delivered` (✓✓ gris).
15. **Persistencia**: `persist_cw_conversation` guarda `meli_orders.cw_conversation_id` (base para los paneles y los labels de reclamos).
16. **Auto-cierre**: si `auto_resolve` está activo, la conversación se cierra con el mecanismo nativo de Chatwoot.

### Configuración y gates

- `bot_active_pv?` (schedule + toggle de post-venta, endpoint `/bot_active?scope=postventa`): apagado → `set_manual_label` (`esperando_respuesta_manual`), sin respuesta IA.
- Delays: `Wait delay pv` con `post_venta_ia.delay` y modo horario (`scheduledMode`) — configurables por seller.
- `conversation_ai_gate` y labels de atención humana cortan la intervención de la IA.

## 4. Ciclo de vida de la conversación (máquina de estados)

Estado persistido en `meli_orders.estado_conversacion` (`activa` | `cerrada` | `needs_human` | `bloqueada`):

```
activa ──cortesía/problema resuelto──▶ cerrada
activa ──handoff─────────────────────▶ needs_human
activa ──claim/dispute o bloqueo ML──▶ bloqueada
cerrada ──mensaje nuevo sustantivo───▶ activa (reapertura vía Platform API)
needs_human ──humano reanuda────────▶ activa
bloqueada ──claim cerrado────────────▶ activa
```

### Reglas de handoff (H1–H6)

| # | Gatillo | Detección | Acción |
|---|---------|-----------|--------|
| H1 | El cliente pide humano | Nodo de sentimiento `requiere_humano` | `needs_human` |
| H2 | Enojado 2 turnos seguidos | `consecutive_enojado >= 2` | `needs_human` |
| H3 | Loop (mensajes repetidos) | `repeat_count >= 3` | `needs_human` |
| H4 | Menciones legales | Sentimiento/IA (abogado, denuncia, defensa del consumidor) | `needs_human` |
| H5 | Claim activo | Etapa `dispute` | `bloqueada` |
| H6 | Mensajería bloqueada por ML | `conversation_status` en el payload | `bloqueada` + `blocked_substatus` |

Handoff = UPDATE del estado + label `atencion-humana` + nota privada con el motivo; la IA deja de responder (el gate lo asegura) y el humano toma la conversación de forma nativa.

- **Cortesía**: mensajes ≤50 chars que matchean (`gracias`, `ok`, `listo`, `perfecto`, `dale`…) → la conversación se cierra **sin responder** (cierre nativo + nota privada).
- **Reapertura**: mensaje nuevo sustantivo en una conversación `cerrada` → `POST /conversations/:id/reopen` + estado `activa`.
- **Loop detection**: guarda los últimos 3 mensajes del comprador (`ultimos_mensajes_comprador`) y cuenta repeticiones (`repeat_count`) → handoff en ≥3.
- **Bloqueo por reclamos**: un claim en `dispute` marca la orden `bloqueada`; al cerrarse el claim, vuelve a `activa`.

## 5. Salida manual y estados de lectura (el "tick azul")

- **`postsale_outbound`**: cuando un agente escribe en Chatwoot, el webhook lo envía a ML/Yobot → aplica `respondida_manualmente` (reemplaza `esperando_respuesta_manual`) y marca el mensaje `delivered` (✓✓ gris) persistiendo `ml_message_id`.
- **Ticks**: los mensajes salientes de inboxes API reflejan `message.status` en la burbuja — `sent` (✓), `delivered` (✓✓ gris), `read` (✓✓ azul).
- **`MessageReadSyncWorker`** (cada **1 minuto**): consulta el pack de mensajes (`MeliApi#pack_messages` nativo / `BridgeApi` bridge) y marca como `read` los mensajes del vendedor cuyo `message_date.read` existe en ML → ✓✓ azul. Corre cada minuto (no cada 5) porque la API de ML tarda >30s en reflejar la lectura.
- **`sync-conversation-reads`**: marca los mensajes del comprador como leídos en ML cuando el agente los ve (✓✓ azul hacia ML).

## 6. Reclamos, devoluciones y cambios

### Bandeja de reclamos en Chatwoot

- Inbox **"Reclamos (MercadoLibre)"**: 1 conversación = 1 reclamo (`source_id = claim_id`), con mensajes espejados del claim (dedupe por `ml_message_id`) y reapertura automática si estaba resuelta.
- **Labels**: `reclamo-abierto`, `reclamo-mediacion` (con banner "los mensajes llegan a ML, no al comprador"), `reclamo-cerrado`, `reclamo-pendiente-accion`, `reclamo-derivado`.
- **Outbound** (`claims_outbound`): mensajes de la bandeja → `POST /post-purchase/v1/claims/{id}/actions/send-message` (nativo) o `execute-claim-action` (bridge). El cierre lo hace ML; la conversación se resuelve a mano (sin auto-resolve).

### Sincronización y webhook

- `POST /claims_webhook` (nativo) o `POST /api/bridge/claim` (bridge): upsert del claim en `meli_claims` → vínculo con la orden → si `stage=dispute` → orden `bloqueada` → evaluar automatización → encolar agente si corresponde.
- `ClaimsSyncWorker` + botón "Sync": `GET /post-purchase/v1/claims/search` (requiere token OAuth con **scope Post Purchase**). Disparado en signup/activación.
- Timeline de eventos (`meli_claims.timeline`): historial de syncs, webhooks y acciones manuales (máx 50 entradas, dedupe).

### Automatización determinista (sin IA, previa al agente)

| Regla | Disparador | Acción |
|-------|-----------|--------|
| PNR → evidencia | `reason_id` empieza con `PNR` | Envía el tracking como evidencia de envío |
| PDD → devolución | `reason_id` empieza con `PDD` | Acepta devolución o reembolso parcial (oferta más baja) |
| Devolución simple | Motivos como `REASON_BUYER_REGRET`, `DOESNT_FIT`… | Acepta automáticamente si toggle + monto ≤ máximo |
| Límite de monto | Monto > `monto_maximo_auto` | Handoff humano |
| Tipos excluidos | Tipo en `tipos_excluidos[]` | Handoff humano |

Configuración en `custom_attributes.config.automatizacion_reclamos` (UI en el dashboard post-venta).

### Agente IA de reclamos (motor ReAct)

`ClaimAgentWorker` (Sidekiq): loop de hasta 5 iteraciones con OpenAI function calling (`gpt-4o-mini`) y **8 tools**:

| Tool | Confirmación requerida |
|------|------------------------|
| `get_tracking_status` (consulta real de envíos + análisis) | No |
| `check_claim_policy` | No |
| `accept_return` | **Sí** |
| `offer_partial_refund` | **Sí** |
| `send_evidence` (PNR) | No |
| `send_claim_message` | No |
| `full_refund` | **Sí** |
| `escalate_to_human` | No |

- **Modo supervisado** (default): las tools que mueven dinero/devoluciones quedan como `pending_action` en BD → el operador confirma desde la UI (`agent-execute`, `agent-cancel`, `agent-rerun`).
- En modo receive-only corre en **dry-run** (tools simuladas).

### UI de reclamos

- Tabla de reclamos estilo Yobot en `/dashboard/claims` (estado, etapa, motivo humanizado, polling con badge de pendientes) + detalle con chat del reclamo, evidencias, acciones (habilitadas según `available_actions` de ML) y panel del agente.
- 21 endpoints de acciones (mensajes, evidencias, reembolsos totales/parciales, ofertas, aceptar devolución, abrir mediación, revisión de devoluciones, cambios/allow-replace) — todos con sesión + token, y mapeo de errores de ML (`parse_ml_error`).
- Acciones bloqueadas con `200 {receive_only: true}` en modo testing.

## 7. Paneles Dashboard Apps (contexto embebido en la conversación)

Tres iframes registrados por cuenta en el sidebar de la conversación; reciben el contexto por `postMessage` (evento `appContext`) y hacen polling cada 20s:

- **Venta ML** (`/dashboard/sale-panel`): ficha de la venta — producto, comprador, pago, envío, mensajes de la conversación. Resolución: `cw_conversation_id` → `pack_id` → id de venta.
- **Producto ML** (`/dashboard/product-panel`): ficha del item (nativo: `GET /items/:id` directo; bridge: catálogo local `meli_products` porque el contrato de Yobot no expone items).
- **Reclamo ML** (`/dashboard/claim-panel`): detalle compacto del reclamo — agente IA + acciones + chat + evidencias + timeline.

## 8. Configuración disponible (dashboard `/dashboard` → Post-Venta)

- Prompt y modelo, delay de respuesta y modo horario (`scheduledMode`).
- Documentos RAG post-venta (subida, importación masiva con wizard propio, migración desde Yobot).
- Automatización de reclamos (toggles y montos máximos).
- Sync de tokens y de config desde Yobot (cuentas bridge).

## 9. Datos clave

- `meli_orders`: orden/envío/pack/buyer + ciclo de vida (`estado_conversacion`, `handoff_reason`, `last_sentiment`, `consecutive_enojado`, `repeat_count`, `ultimos_mensajes_comprador`, `blocked_substatus`, `last_message_at`) + panel (`cw_conversation_id`, `item_title`, `buyer_nickname`, `total_amount`…).
- `reply_ai_pv_documents`: RAG post-venta (misma estructura que pre-venta, tabla y endpoint propios).
- `meli_claims`: etapa/estado, `players`, `expected_resolutions`, `pending_action`, `agent_status`, `agent_log`, `timeline`.
- `messages.content_attributes`: `ml_message_id` para dedupe y ticks de lectura (almacenado doble-encodificado — el match se hace con el accessor de Rails, no con SQL `->>`).

## 10. Auto-cierre nativo

`Account.auto_resolve_after` (minutos) + mensaje/label de auto-resolución, procesado por el job nativo `Conversations::ResolutionJob`. El vendedor lo activa en Settings → Conversation Workflows de Chatwoot (la card se eliminó de Reply). Aplica a pre-venta y post-venta por igual.
