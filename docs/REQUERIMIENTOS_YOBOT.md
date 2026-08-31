# REQUERIMIENTOS YOBOT — Bridge de datos y acciones

> **Última actualización**: 2026-08-09 (todos los ítems implementados en `develop`; **Reply-AI ya consume el bridge completo** — pruebas manuales del usuario bridge `full` en curso; **perfil MIGRADO implementado en el piloto (2026-08-07)**: trigger vía bridge + ejecución nativa en Reply + refresh directo con credenciales de la app de Yobot; **migración RAG Yobot → Reply implementada (2026-08-08)**: import de chunks de Supabase con regeneración de embeddings — pendiente solo `SUPABASE_URL`/`SUPABASE_SERVICE_KEY` en Reply; **estado de lectura de mensajes implementado en ambos lados (2026-08-07)**: `get-pack-messages` + `message_id`/`ml_status` en Yobot, consumo con ticks `delivered`/`read` en Reply; **fixes del lado de Reply del 2026-08-07**: envíos con `ml_user_id` correcto y ciclo de labels post-venta; **401 en `refresh-token` diagnosticado y fix de verificación de firma implementado en Yobot** — ver §10; **control de confianza pre-venta validado en el piloto MIGRADO (2026-08-08)**: fixes de preguntas duplicadas (discriminador `bridge_enabled` en los 4 nodos Chatwoot de `questions_main`), burbuja de pregunta invisible (404 en `chatwoot_add_message_to_conversation`), credenciales y `cw_conversation_id` en la rama de retención, y 2 bugs de Rails (`to_unsafe_h` en `update_settings`, helper inexistente en el dashboard + lookup por display_id en `confidence_report`) — detalle en la sección "FIXES FLUJO PRE-VENTA PERFIL MIGRADO (2026-08-08)" al final del documento; **flujo post-venta MIGRADO validado (2026-08-08)**: fix de `intent_router` (leía `$json.intent` de un httpRequest intermedio sin el campo → fallback `post_ai_unavailable_note`) y de `context_assembler` (discriminador `bridge_enabled` para usar order/shipment del forward) — IA activada y desactivada verificadas, detalle en la sección "FIXES FLUJO POST-VENTA PERFIL MIGRADO (2026-08-08)"; **flujo post-venta NATIVO validado (2026-08-08)**: fix de `get_message_details` (discriminador `bridge_enabled` → MIGRADO usa `body.message` del forward, sin 404) y de `get_or_create_conversation` (fallback `findBySourceId` por pack_id a nivel cuenta → reusa la conversación existente, sin 422) — reclamos MIGRADO y NATIVO verificados, detalle en la sección "FIXES FLUJO POST-VENTA NATIVO (2026-08-08)"; **ventas post-venta y mejoras pre-venta (2026-08-08/09)**: sub-pestaña "Ventas" con tabla y cruce de preguntas pre-venta por item+buyer, Dashboard App "Venta ML" (panel embebido con postMessage), doble tick `delivered` en respuestas pre-venta (IA y manual), y estética de la nota privada "DETALLES DEL PRODUCTO" (imagen 50%, tipografía de burbuja, sin emojis/itálicas, bordes redondeados) — detalle en la sección "VENTAS POST-VENTA Y MEJORAS PRE-VENTA (2026-08-08/09)"; **fix venta real + polling (2026-08-09)**: bug de precedencia en `bridge_order` (`find_bridge_account and return if performed?` → nunca resolvía la cuenta → 500 "Account must exist" con la primera venta real) corregido a `find_bridge_account; return if performed?`; tabla de ventas con polling de 30s (auto-refresh sin recargar) — detalle en la sección "FIX VENTA REAL + POLLING TABLA DE VENTAS (2026-08-09)")
> **Contexto**: Reply-AI tiene dos tipos de usuarios:
> 1. **Nativos**: registrados en la app de Reply — Reply habla directo con la API de MercadoLibre.
> 2. **Bridgeados**: usuarios de Yobot — **Reply NUNCA llama a la API de ML** para estos usuarios
>    (no están registrados en la app de ML de Reply y sus tokens solo se refrescan con las
>    credenciales de la app de Yobot). Todo el tráfico ML se gestiona a través de Yobot (bridge).
>
> Este documento define **qué debe implementar/forwardear Yobot** para que el flujo bridgeado
> de Reply-AI funcione completo. **Desde 2026-08-05 Reply-AI consume todos los contratos**
> (forwards completos, `execute-claim-action` 21 acciones, syncs, adjuntos por URL); el lado
> de Reply ya no degrada ni bloquea cuentas bridge (ver §3 y §8.5).

---

## 0. Modo de operación del bridge (implementado 2026-08-05)

El flag "bridgeado" vive en **`User.bridge` de la BD de Yobot** (se setea a mano en Mongo, sin UI):

```js
bridge: { enabled: true, mode: "mirror" | "full" }
```

- **`mirror`** (piloto/auditoría): Yobot forwardea la notificación completa a Reply **Y SIGUE procesando normalmente** (el usuario no nota nada). Reply recibe todo para auditar sus flujos.
- **`full`** (bridge real): Yobot forwardea y **salta su procesamiento** (Reply queda a cargo).
- Sin flag (`enabled` ausente/false) o sin `BRIDGE_SECRET`: bridge 100% inerte.

Implementación: `helpers/bridgeClient.js` (`bridgeMode()`, `isBridged()` con caché 60s, `logBridge()`, `forwardToReplyAI()`, `verifyBridgeRequest()`) + `helpers/bridgePayloads.js` (builders de forwards completos).

---

## 1. Estado actual del bridge en Yobot (verificado en código 2026-08-05)

> **Reply-AI consume todo esto desde 2026-08-05**: `ReplyAi::BridgeApi` (mismo contrato que
> MeliApi) rutea las 21 acciones de reclamos/devoluciones/cambios, los syncs de
> productos/tiendas y el completado de claims; los forwards completos alimentan los workflows
> n8n (preguntas, mensajes post-venta con adjuntos por URL, órdenes).

| Endpoint Yobot | Estado | Uso desde Reply |
|---|---|---|
| `POST /api/bridge/send-answer` (bridgeController.js `receiveAnswer`) | ✅ Implementado | Respuesta a preguntas pre-venta (workflow `questions_main` y `questions_manual`) |
| `POST /api/bridge/send-message` (bridgeController.js `receivePostVentaMessage`, acepta `attachments`) | ✅ Implementado | Envío de mensajes post-venta (workflow `postsale_main` y `postsale_outbound`) |
| `POST /api/bridge/refresh-token` (bridgeController.js `refreshBridgeToken`) | ✅ Implementado | Refresco de tokens (`TokenRefreshWorker` de Rails y nodo `refresh_token` en n8n) |
| `POST /api/bridge/execute-claim-action` | ✅ **Implementado (2026-08-05)** | Todas las acciones de reclamos/devoluciones/cambios para usuarios bridgeados (21 acciones, ver §2) |
| Forwards completos (question/message/claim/order) | ✅ **Implementado (2026-08-05)** | Payloads completos según §3, con modo `mirror`/`full` por usuario |
| Sync de productos/tiendas vía bridge | ✅ **Implementado (2026-08-05)** | `POST /api/bridge/sync-products` + `POST /api/bridge/sync-official-stores` (§5) |
| Adjuntos del comprador vía bridge | ✅ **Implementado (2026-08-05)** | URLs de `message_attachments` incluidas en el forward de `bridge_message` (§4) |

**Auth del bridge**: ya implementada en ambos lados (`Authorization: Bearer BRIDGE_SECRET` +
`X-Bridge-Signature: HMAC-SHA256(body)`). Todos los endpoints usan `verifyBridgeRequest`
de `backend/helpers/bridgeClient.js`. `execute-claim-action` y los syncs validan además
`isBridged(ml_user_id)` → **403** si el seller no está bridgeado.

**Auditoría**: cada forward (out) y cada llamada entrante (in) se registra en la colección
`BridgeLog` (modelo `models/BridgeLog.js`). Consulta: `GET /api/debug/bridge-logs?ml_user_id=&direction=&limit=`
(con `authUsuarioApp`).

---

## 2. `POST /api/bridge/execute-claim-action` (IMPLEMENTADO 2026-08-05)

### Request
```json
{
  "ml_user_id": 123456,
  "claim_id": 987654,
  "action": "get_claim",
  "params": { }
}
```

### Respuesta genérica
- Éxito: `200` con el body crudo que devuelve la API de ML (Reply lo pasa tal cual).
- Error de ML: `502` con `{ error: <detalle> }` (Reply muestra el mensaje).
- `401` si la firma no es válida.

### Acciones requeridas (contratos ML verificados en Yobot)

| `action` | Llamada a ML que Yobot debe ejecutar | params |
|---|---|---|
| `get_claim` | `GET /post-purchase/v1/claims/{claim_id}` | — |
| `search_claims` | `GET /post-purchase/v1/claims/search?seller_id={ml_user_id}&status=opened` | — |
| `get_messages` | `GET /post-purchase/v1/claims/{claim_id}/messages` | — |
| `send_message` | `POST /post-purchase/v1/claims/{claim_id}/actions/send-message` body `{ text }` | `{ text }` |
| `get_evidences` | `GET /post-purchase/v1/claims/{claim_id}/evidences` | — |
| `add_evidence` | `POST /post-purchase/v1/claims/{claim_id}/actions/evidences` body `{ tracking_number, carrier }` (evidencia PNR) o multipart `file` | `{ tracking_number, carrier }` o `file` |
| `refund` | `POST /post-purchase/v1/claims/{claim_id}/expected-resolutions/refund` body `{}` | — |
| `partial_refund` | `POST /post-purchase/v1/claims/{claim_id}/expected-resolutions/partial-refund` body `{ reason_id, amount }` | `{ reason_id, amount }` |
| `available_offers` | `GET /post-purchase/v1/claims/{claim_id}/partial-refund/available-offers` | — |
| `allow_return` | `POST /post-purchase/v1/claims/{claim_id}/expected-resolutions/allow-return` body `{}` | — |
| `open_dispute` | `POST /post-purchase/v1/claims/{claim_id}/actions/open-dispute` body `{}` | — |
| `affects_reputation` | `GET /post-purchase/v1/claims/{claim_id}/affects-reputation` | — |
| `get_returns` | `GET /post-purchase/v2/claims/{claim_id}/returns` | — |
| `review_return` | `POST /post-purchase/v1/returns/{return_id}/return-review` body `{ status }` | `{ return_id, status }` |
| `get_reviews` | `GET /post-purchase/v1/returns/{return_id}/reviews` | `{ return_id }` |
| `get_return_reasons` | `GET /post-purchase/v1/returns/reasons?flow=seller_return_failed&claim_id={claim_id}` | — |
| `get_return_cost` | `GET /post-purchase/v1/claims/{claim_id}/charges/return-cost` | — |
| `get_changes` | `GET /post-purchase/v1/claims/{claim_id}/changes` | — |
| `allow_replace` | `POST /post-purchase/v1/claims/{claim_id}/expected-resolutions/allow-replace` body `{}` | — |
| `get_tracking` | `GET /shipments/{shipment_id}` | `{ shipment_id }` |
| `get_order` | `GET /orders/{order_id}` | `{ order_id }` |

> Nota: `get_tracking` y `get_order` los usa el agente de reclamos (Reply) para analizar
> evidencia PNR y contexto de la orden.

---

## 3. Forwards completos (IMPLEMENTADO 2026-08-05 — modo mirror/full)

Comportamiento actual: cuando una notificación de un usuario bridgeado entra en cualquiera de los
4 pipelines de Yobot (preguntas, ventas, mensajes, reclamos), Yobot construye el **payload completo**
(según los shapes de las secciones 3.1-3.4, usando `helpers/bridgePayloads.js`) y lo envía a
`POST /api/bridge/{question,order,message,claim}` de Reply con `access_token: null`. En modo
`mirror` Yobot además sigue procesando normalmente; en modo `full` salta su pipeline.

Los shapes que Reply consume en cada workflow:

### 3.1 `POST /api/bridge/question` (pre-venta)

El payload debe incluir:
```json
{
  "ml_user_id": 123456,
  "access_token": null,
  "resource": "<question_id>",
  "topic": "questions",
  "question": {
    "id": 987654,
    "text": "¿Hacen envíos a Córdoba?",
    "status": "UNANSWERED",
    "item_id": "MLA123",
    "from": { "id": 555, "nickname": "comprador" }
  },
  "item": {
    "id": "MLA123",
    "title": "Producto X",
    "price": 15000,
    "currency_id": "ARS",
    "available_quantity": 10,
    "sold_quantity": 3,
    "condition": "new",
    "category_id": "MLA1234",
    "permalink": "https://...",
    "thumbnail": "https://...",
    "pictures": [],
    "attributes": [],
    "shipping": { "mode": "me2", "logistic_type": "drop_off", "tags": [] },
    "warranty": "...",
    "description": "texto de la ficha técnica (si está disponible)",
    "catalog_listing": false
  },
  "buyer": { "id": 555, "nickname": "comprador" }
}
```
> **Qué hace Reply con esto hoy (2026-08-05)**: el workflow `questions_main` usa `body.question`
> para el pipeline (RAG + OpenAI) y `body.item` para el contexto del producto y la detección de tipo
> de envío. `bridge_question` crea la conversación pre-venta y reenvía el forward completo a n8n
> (`question`/`item`/`buyer` + `resource` + `_id`).

### 3.2 `POST /api/bridge/message` (post-venta)

El payload debe incluir el mensaje completo (el mismo shape que devuelve
`GET /messages/{resource}?tag=post_sale`):
```json
{
  "ml_user_id": 123456,
  "access_token": null,
  "resource": "<message_id>",
  "message": {
    "id": 111,
    "text": "¿Dónde está mi pedido?",
    "from": { "user_id": 555, "nickname": "comprador" },
    "to": { "user_id": 123456 },
    "status": "delivered",
    "message_resources": [
      { "id": "200000", "name": "packs" },
      { "id": "300000", "name": "orders" }
    ]
  },
  "order": { "id": 300000, "status": "paid", "currency_id": "ARS", "total_amount": 15000,
             "order_items": [{ "item": { "id": "MLA123", "title": "Producto X" } }],
             "shipping": { "id": 400000, "tracking_number": "TRACK123", "tracking_method": "OTRA" } },
  "shipment": { "id": 400000, "status": "shipped", "tracking_number": "TRACK123",
                "estimated_delivery_time": { "date": "2026-08-10T12:00:00-03:00" } },
  "conversation_status": { "status": "available", "substatus": null }
}
```
> **Qué hace Reply con esto hoy (2026-08-05)**: `bridge_message` registra `MeliOrder` desde
> `body.order`/`pack_id` (ml_buyer_id, item_id, order_status) y reenvía a n8n el forward completo
> (`message` + `order` + `shipment` + `conversation_status` + `pack_id` + `attachments` + `_id`).
> `context_assembler` usa `body.order`/`body.shipment` para el contexto del pedido (sin ML) y
> `check_idempotency` deduplica con `body._id` (`message.id`).
> **Adjuntos**: `process_attachments` (n8n) descarga desde las URLs de `body.attachments`
> (sin token de ML) y genera `attachment_context` (Vision/Tika/Whisper).

### 3.3 `POST /api/bridge/claim` (reclamos)

El payload debe incluir el claim completo (el shape de `GET /post-purchase/v1/claims/{id}`):
```json
{
  "ml_user_id": 123456,
  "access_token": null,
  "resource": "<claim_id>",
  "claim_data": {
    "id": 987654,
    "resource": "order",
    "resource_id": 300000,
    "type": "mediations",
    "stage": "claim",
    "status": "opened",
    "reason_id": "PNR_OTHER",
    "players": [
      { "role": "respondent", "available_actions": [ { "action": "add_shipping_evidence" } ] }
    ],
    "expected_resolutions": [ { "amount": 15000 } ],
    "affects_reputation": false
  }
}
```
> **Qué hace Reply con esto hoy (2026-08-05)**: `bridge_claim` registra el claim (envelope +
> `claim_data` completo: status/stage/raw_data), refresca los datos autoritativos vía
> `execute-claim-action get_claim` (si el bridge está configurado), crea la conversación del
> reclamo en la bandeja **Reclamos (MercadoLibre)**, espeja los mensajes (`get_messages`) y evalúa
> la automatización/agente (que ejecutan acciones vía `execute-claim-action`).
> Los `players` con `user_id` del complainant se usan para el contacto correcto de la conversación.

### 3.4 `POST /api/bridge/order` (ventas — forward completo)

El payload debe incluir la orden completa (el shape de `GET /orders/{id}`):
```json
{
  "ml_user_id": 123456,
  "access_token": null,
  "resource": "<order_id>",
  "order": {
    "id": 300000,
    "status": "paid",
    "currency_id": "ARS",
    "total_amount": 15000,
    "date_created": "2026-08-03T12:00:00-03:00",
    "buyer": { "id": 555, "nickname": "comprador" },
    "order_items": [
      { "item": { "id": "MLA123", "title": "Producto X", "category_id": "MLA1234",
                  "price": 15000, "currency_id": "ARS", "condition": "new",
                  "quantity": 1 } }
    ],
    "shipping": { "id": 400000, "mode": "me2", "status": "ready_to_ship",
                  "tracking_number": "TRACK123", "tracking_method": "OTRA" },
    "payments": [ { "id": 900000, "status": "approved", "total_paid_amount": 15000 } ]
  },
  "pack_id": "200000"
}
```
> **Qué hace Reply con esto hoy (2026-08-05)**: `bridge_order` registra `MeliOrder` (id, buyer,
> item, status desde `body.order`) y dispara el workflow `orders_main` vía n8n (`topic: 'orders_v2'`,
> payload `order` completo) para el mensaje post-venta inicial. El workflow es bridge-aware: usa
> `body.order` y envía el mensaje vía `POST /api/bridge/send-message` (Yobot).

> **Nota webhook postsale**: el flujo de mensajes post-venta (nativo y bridge) entra por el webhook
> `chatwoot-postsale` de la instancia n8n (workflow no versionado en el repo) que llama a
> `reply_ai_postsale_main`. Verificar que exista en la instancia n8n.

---

## 4. Adjuntos del comprador (IMPLEMENTADO 2026-08-05)

Opción elegida: **incluir las URLs en el forward de `bridge_message`** — el builder
`buildMessagePayload` (`helpers/bridgePayloads.js`) incluye `attachments` con el array
`message_attachments` que devuelve ML (URLs de descarga). Reply puede descargar desde esas
URLs sin llamar a la API de ML.

---

## 5. Sync de productos y tiendas (IMPLEMENTADO 2026-08-05)

Implementado en `controllers/bridgeSyncController.js`:

**Opción elegida**: exponer endpoints en Yobot —
- `POST /api/bridge/sync-products` `{ ml_user_id }` → Yobot obtiene el catálogo
  (`fetchAllProducts` con `search_type=scan` + `fetchProductDetails` en lotes de 75) y responde
  `{ ml_user_id, total, items[] }`; Reply los persiste en `meli_products`/`meli_categories`.
- `POST /api/bridge/sync-official-stores` `{ ml_user_id }` → reutiliza `fetchOfficialStoresFromML`
  (`/users/{id}/brands`) y responde `{ ml_user_id, total, stores[] }`.

---

## 6. Orden de implementación en Yobot (COMPLETADO 2026-08-05)

1. ✅ **Forwards completos** (sección 3) — pre-venta y post-venta bridgeados procesan.
2. ✅ **`execute-claim-action`** (sección 2) — reclamos/devoluciones/cambios bridgeados
   (automatización PNR/PDD + agente IA + acciones del dashboard).
3. ✅ **Adjuntos** (sección 4) — multimedia bridgeado (URLs en el forward).
4. ✅ **Sync de productos** (sección 5) — catálogo en el dashboard bridgeado.

Cada ítem es independiente: Reply degrada con mensajes claros hasta que Yobot lo implemente.

---

## 7. Próximos pasos

- **Piloto LOCAL**: marcar una cuenta de prueba en la BD local (`bridge: { enabled: true, mode: "mirror" }`),
  apuntar `REPLY_AI_BRIDGE_URL` a Reply dev, recibir webhooks reales de ML de cuentas de prueba vía túnel.
  Validar: Reply recibe los forwards completos, Yobot sigue procesando normal, `BridgeLog` registra status 200.
- **Reply-AI listo para el piloto (2026-08-05)**: `BRIDGE_SECRET`/`YOBOT_BRIDGE_URL` seteadas en `.env`
  (Rails) y propagadas a docker-compose (n8n); webhook `chatwoot-postsale` creado (entrada del flujo
  de mensajes post-venta); `bridge_register` marca la cuenta `receive_only` si el env de testing
  está activo; todas las acciones de reclamos y los syncs rutean por el bridge; `bridge_manual_response`
  registra nota privada en la conversación.
- **Producción**: solo después de que el piloto local sea exitoso. Marcar el usuario real en la BD de producción.

---

# RESPUESTA DE YOBOT A LOS REQUERIMIENTOS DE REPLY-AI

> **Documento de entrega** para validación del equipo de Reply-AI — 2026-08-05.
> **Estado**: todo lo solicitado está **implementado** en el código de Yobot (rama `develop`).
> **Pendiente**: piloto en LOCAL con cuentas de prueba de ML. **Nada está desplegado a producción todavía.**
> Base de esta respuesta: implementación real verificada en el código de Yobot (referencias a archivos incluídas).
>
> **Validación de Reply-AI (2026-08-05)**: todos los contratos de esta sección fueron consumidos
> por Reply-AI (ver "RESULTADO DE LA IMPLEMENTACIÓN EN REPLY-AI — VALIDACIÓN PARA YOBOT" al final
> del documento). Ningún contrato requirió cambios del lado de Yobot.

## 8.1 Resumen ejecutivo

| Requerimiento de Reply | Estado en Yobot | Referencia |
|---|---|---|
| `POST /api/bridge/send-answer` | ✅ Implementado (existente) | `controllers/bridgeController.js` |
| `POST /api/bridge/send-message` (con `attachments`) | ✅ Implementado (existente) | `controllers/bridgeController.js` |
| `POST /api/bridge/refresh-token` | ✅ Implementado (existente) | `controllers/bridgeController.js` |
| `POST /api/bridge/execute-claim-action` (todas las acciones) | ✅ **Implementado (2026-08-05)** | `controllers/bridgeActionsController.js` |
| Forwards completos (question/message/claim/order) | ✅ **Implementado (2026-08-05)** | `helpers/bridgePayloads.js` + guards en los 4 pipelines |
| Adjuntos del comprador | ✅ **Implementado (2026-08-05)** — URLs incluidas en `bridge_message` | `buildMessagePayload` |
| Sync productos / tiendas oficiales | ✅ **Implementado (2026-08-05)** | `controllers/bridgeSyncController.js` |
| Auditoría del bridge | ✅ Implementado — colección `BridgeLog` + `GET /api/debug/bridge-logs` | `models/BridgeLog.js` |

## 8.2 Contratos de endpoints (Reply → Yobot)

**Base URL**: el host de Yobot (se define por entorno; en el piloto local se usa el tunnel/URL de Yobot dev).

**Autenticación** (todos los endpoints, igual en ambos lados):
- Header `Authorization: Bearer BRIDGE_SECRET`
- Header `X-Bridge-Signature: HMAC-SHA256(body)` donde el HMAC se calcula como
  `crypto.createHmac('sha256', BRIDGE_SECRET).update(JSON.stringify(body)).digest('hex')`
  sobre el **objeto JSON del body** (el mismo que se envía; el orden de las claves importa).
- Respuestas de error comunes: `401` firma inválida · `400` faltan campos · `502` error de la API de ML (con `{ error: <detalle crudo de ML> }`).

### 8.2.1 `POST /api/bridge/send-answer`
```json
// request
{ "question_id": 987654, "answer_text": "Hola, sí hacemos envíos a Córdoba...", "ml_user_id": 123456 }
// success 200
{ "status": "sent", "question_id": 987654 }
```
Yobot envía la respuesta a ML (`POST /answers`) y además emite el evento Socket.IO `'respuestas'` al
dashboard del vendedor (el operador ve la respuesta en tiempo real).

### 8.2.2 `POST /api/bridge/send-message`
```json
// request
{ "pack_id": "200000", "text": "Tu pedido está en camino...", "ml_user_id": 123456,
  "attachments": [ "<attachment_id>" ] }        // attachments opcional
// success 200
{ "status": "sent", "pack_id": "200000" }
```
Yobot envía a `POST /messages/packs/{pack_id}/sellers/{ml_user_id}?tag=post_sale`.

### 8.2.3 `POST /api/bridge/refresh-token`
```json
// request
{ "ml_user_id": 123456, "refresh_token": "<refresh_token>" }
// success 200 → body crudo de la respuesta de ML (access_token, refresh_token, expires_in, ...)
```
Además de devolver la respuesta de ML, Yobot **actualiza los tokens en su propia BD** (el User de ese
seller queda con el token nuevo, para que los pipelines de Yobot sigan funcionando).

### 8.2.4 `POST /api/bridge/execute-claim-action`
```json
// request
{ "ml_user_id": 123456, "claim_id": 987654, "action": "refund", "params": { } }
```
- `200`: body crudo de ML (Reply lo pasa tal cual a su UI/agente).
- `403`: el seller no figura como bridgeado en la BD de Yobot (protección extra: Yobot solo ejecuta
  acciones mutantes sobre usuarios bridgeados).
- `404`: acción desconocida. `502`: error de ML o de autenticación con ML.

**Acciones soportadas (21)** — columna "params" = lo que Reply debe enviar en `params`:

| `action` | params de Reply | Notas de implementación |
|---|---|---|
| `get_claim` | — | GET claim completo |
| `search_claims` | — | `GET claims/search?seller_id={ml_user_id}&status=opened` (status fijo `opened`) |
| `get_messages` | — | Mensajes del claim |
| `send_message` | `{ text }` | POST a ML con `{ text }` |
| `get_evidences` | — | Evidencias del claim |
| `add_evidence` | `{ tracking_number, carrier }` **o** `{ file_base64, file_name, mime_type }` | Con tracking: Yobot envía a ML `{ evidence: { tracking_number, carrier } }` (contrato real de ML). Con `file_base64`: Yobot arma multipart con el archivo y lo sube |
| `refund` | — | Reembolso total |
| `partial_refund` | `{ reason_id, amount }` | Reembolso parcial |
| `available_offers` | — | Ofertas de reembolso parcial |
| `allow_return` | — | Aceptar devolución |
| `open_dispute` | — | Abrir mediación |
| `affects_reputation` | — | Consulta de reputación |
| `get_returns` | — | Devoluciones del claim (v2) |
| `review_return` | `{ return_id, status }` | Revisión de devolución |
| `get_reviews` | `{ return_id }` | Revisiones de la devolución |
| `get_return_reasons` | — | Motivos de falla (`flow=seller_return_failed&claim_id=`) |
| `get_return_cost` | — | Costo de devolución |
| `get_changes` | — | Cambios del claim |
| `allow_replace` | — | Ofrecer reemplazo |
| `get_tracking` | `{ shipment_id }` | Tracking real de ML |
| `get_order` | `{ order_id }` | Orden completa de ML |

### 8.2.5 `POST /api/bridge/sync-products`
```json
// request
{ "ml_user_id": 123456 }
// success 200
{ "ml_user_id": 123456, "total": 42, "items": [ { "id": "MLA123", "title": "...", "price": 15000,
  "currency_id": "ARS", "available_quantity": 10, "sold_quantity": 3, "thumbnail": "...",
  "secure_thumbnail": "...", "permalink": "...", "status": "active", "listing_type_id": "...",
  "category_id": "MLA1234", "category_name": "MLA1234", "seller_id": 123456,
  "pictures": [ "..." ], "catalog_listing": false, "has_variations": false, "variation_count": 0,
  "shipping": { "mode": "me2", "free_shipping": true, "logistic_type": "drop_off", "tags": [] } } ] }
```
Yobot escanea el catálogo completo con `search_type=scan` (sin límite de 1000) y trae los detalles
en lotes de 75 con reintentos (misma lógica que el dashboard de Yobot). Nota: `category_name` es un
placeholder igual al `category_id` (como en el dashboard); Reply puede resolver nombres con su propia
lógica o pedir la extensión del contrato.

### 8.2.6 `POST /api/bridge/sync-official-stores`
```json
// request
{ "ml_user_id": 123456 }
// success 200
{ "ml_user_id": 123456, "total": 2, "stores": [ { "official_store_id": 123, "name": "...",
  "normalized_name": "...", "status": "...", "permalink": "...", "customGreeting": "" } ] }
```
Fuente: `GET /users/{ml_user_id}/brands` de ML (misma lógica que Yobot usa en Tiendas Oficiales).

## 8.3 Forwards (Yobot → Reply): qué recibe Reply y cuándo

**Cuándo**: cada notificación de ML (webhook `POST /api/notifications`) de un usuario **bridgeado**
dispara un forward a `POST {REPLY_AI_BRIDGE_URL}/api/bridge/{question|order|message|claim}` con el
payload completo, siempre con `access_token: null` (Reply NO llama a ML).

| Pipeline de Yobot | Endpoint de Reply | Payload enviado (campos top-level) |
|---|---|---|
| Preguntas (`handleIncomingNotification.js`) | `/api/bridge/question` | `ml_user_id, access_token, resource, topic: "questions", question, item, buyer` |
| Ventas (`handleIncomingSale.js`) | `/api/bridge/order` | `ml_user_id, access_token, resource, topic: "orders_v2", order, pack_id` |
| Mensajes post-venta (`handleIncomingMessage.js`) | `/api/bridge/message` | `ml_user_id, access_token, resource, topic: "messages", message, order, shipment, conversation_status, pack_id, attachments` |
| Reclamos (`handleIncomingClaim.js`) | `/api/bridge/claim` | `ml_user_id, access_token, resource, topic: "claims", claim_data` |

**Modos de operación** (flag `User.bridge` en la BD de Yobot, se setea a mano en Mongo, sin UI):
- `mirror` (piloto): Yobot forwardea **y sigue procesando la notificación con su pipeline completo** —
  el usuario bridgeado no nota ninguna diferencia. Reply recibe todo para auditar.
- `full` (bridge real): Yobot forwardea y salta su pipeline (Reply queda a cargo).
- Sin flag o sin `BRIDGE_SECRET`: el bridge está **100% inerte** (comportamiento actual de producción).

**Detalles de los payloads**:
- `question.item` incluye: id, title, price, currency_id, available_quantity, sold_quantity,
  condition, category_id, permalink, thumbnail, pictures, attributes, shipping (mode/logistic_type/tags),
  warranty, `description` (texto de la ficha técnica cuando está disponible) y `catalog_listing`.
- `message.order`/`message.shipment`: shapes crudos de `GET /orders/{id}` y `GET /shipments/{id}` de ML.
- `message.conversation_status`: `{ status, substatus }` del pack (información de bloqueos).
- `message.attachments`: array `message_attachments` tal cual lo devuelve ML (URLs de descarga) —
  **opción elegida para adjuntos** (en vez de un endpoint `get-attachment`). Reply puede descargar
  desde esas URLs. Si Reply prefiere un proxy de descarga, lo evaluamos (ver 8.5).
- `claim.claim_data`: shape crudo de `GET /post-purchase/v1/claims/{id}`, incluye `players` con
  `user_id` del complainant (requerido para crear la conversación del reclamo con el contacto correcto).
- `order.pack_id`: presente cuando ML lo expone en la orden.

**Tolerancia a fallos**: si Reply no responde o falla la construcción del payload, el forward se
loguea (error + status) y **en modo `mirror` el pipeline de Yobot continúa igual** — Reply caído no
rompe la atención del vendedor.

## 8.4 Notas y decisiones relevantes para la integración

1. **Fuente de verdad del flag "bridgeado"**: pasó a ser la **BD de Yobot** (`User.bridge.enabled`).
   Yobot ya no consulta `GET /api/bridge/seller/{ml_user_id}` de Reply (lo hacía la versión previa).
   Reply puede conservar ese endpoint para su propio bookkeeping, pero no es necesario para el bridge.
   Para el piloto, el usuario de prueba se marca desde la consola de Mongo de Yobot.
2. **Tiempos**: los forwards usan timeout de 15s (fire-and-forget con log desde el lado de Yobot).
3. **`refresh-token`**: la llamada de Reply **actualiza también los tokens en Yobot**, de modo que
   ambos sistemas quedan sincronizados (evita que un refresh solo de Reply deje a Yobot con token vencido).
4. **Errores de ML**: todos los endpoints devuelven `502` con el **detalle crudo de ML**
   (`{ error: <data de ML o mensaje> }`) para que Reply lo muestre tal cual.
5. **Seguridad**: `execute-claim-action` y los syncs validan además que el seller esté bridgeado (403).
   Ningún endpoint bridge usa la auth de la app (JWT de Yobot): es exclusivamente HMAC con `BRIDGE_SECRET`.
6. **Auditoría**: cada forward (out) y cada llamada entrante (in) queda en la colección `BridgeLog` de
   Yobot con status, error y preview del payload. Consulta: `GET /api/debug/bridge-logs?ml_user_id=&direction=&limit=`
   (requiere auth de la app de Yobot; disponible para debugging conjunto durante el piloto).
7. **Despliegue**: el código está en `develop` de Yobot, sin desplegar. Para el piloto se levanta Yobot
   local apuntando `REPLY_AI_BRIDGE_URL` a la instancia dev de Reply, con el mismo `BRIDGE_SECRET` en ambos lados.

## 8.5 Confirmaciones de Reply (respondidas 2026-08-05)

1. **Formato de firma**: ✅ compatible. Reply verifica el HMAC sobre el **body crudo del request**
   (`request.body.read`, `OpenSSL::HMAC.hexdigest('SHA256', BRIDGE_SECRET, body)` con
   `secure_compare`) — como Yobot firma `JSON.stringify(body)` del objeto que envía, ambos
   coinciden byte a byte (el orden de claves no importa: se firma el string exacto que viaja).
   Del lado saliente, Reply (BridgeApi y los Code nodes de n8n) firma el string que envía.
2. **Adjuntos**: ✅ las URLs de `message_attachments` alcanzan. `process_attachments` (n8n)
   descarga desde esas URLs en la rama bridge (sin token de ML) y genera `attachment_context`
   con Vision/Tika/Whisper. No se necesita `get-attachment`.
3. **`add_evidence` con archivo**: ✅ Reply envía `{ file_base64, file_name, mime_type }` para
   cuentas bridge (el multipart real queda solo para cuentas nativas).
4. **`search_claims`**: ✅ `status=opened` fijo es suficiente (Reply solo sincroniza abiertos).
   Si más adelante se necesitan filtros, se extiende el contrato.
5. **`sync-products` shape**: ✅ suficiente para el piloto. Reply persiste los campos disponibles
   (`category_name` se ignora; las categorías se resuelven con la lógica propia de Reply).
   Extensiones (warranty/description/attributes) se pueden pedir después si el dashboard bridge
   las necesita.
6. **21 acciones**: ✅ cubren todos los flujos (automatización PNR/PDD, agente IA, dashboard de
   reclamos, bandeja). Reply rutea todas las acciones de claims/returns/changes vía
   `execute-claim-action` para cuentas bridge (`ReplyAi::BridgeApi` con la misma interfaz que
   `MeliApi`).
7. **URLs de entorno**: para el piloto: `REPLY_AI_BRIDGE_URL` → instancia dev de Reply
   (túnel público) y `BRIDGE_SECRET` compartido en ambos `.env`. En Reply, las vars son
   `BRIDGE_SECRET` y `YOBOT_BRIDGE_URL` (`.env` para Rails + docker-compose para n8n).

---

# RESULTADO DE LA IMPLEMENTACIÓN EN REPLY-AI — VALIDACIÓN PARA YOBOT

> **Documento de entrega de Reply-AI** — 2026-08-05.
> **Resumen**: Reply-AI implementó el consumo completo de todos los contratos del bridge
> que Yobot entregó en la sección anterior (§8). Los contratos de Yobot se validaron contra
> el código de Reply y quedaron **compatibles sin cambios del lado de Yobot**.
> **Pendiente para el piloto**: configuración de URLs/secret compartido y marcado del usuario
> de prueba (nada del código bloquea el arranque).

## 9.1 Qué validó Reply-AI de la implementación de Yobot

| Contrato de Yobot | Resultado de la validación en Reply |
|---|---|
| HMAC (`Authorization: Bearer` + `X-Bridge-Signature` sobre `JSON.stringify(body)`) | ✅ **Compatible byte a byte**. Reply verifica la firma sobre el body crudo del request (`request.body.read` + `secure_compare`); al firmar Yobot el string exacto que envía, ambas partes coinciden sin importar el orden de claves. Reply firma del mismo modo sus requests salientes (BridgeApi y Code nodes de n8n) |
| `POST /api/bridge/send-answer` (`{ml_user_id, question_id, answer_text}`) | ✅ Reply envía exactamente ese shape desde `questions_main`/`questions_manual` |
| `POST /api/bridge/send-message` (`{ml_user_id, pack_id, text, attachments?}`) | ✅ Reply envía ese shape desde `postsale_main` (5 nodos), `postsale_outbound`, `orders_main` |
| `POST /api/bridge/refresh-token` | ✅ Consumido por `TokenRefreshWorker` y el nodo `refresh_token` de n8n |
| `POST /api/bridge/execute-claim-action` (21 acciones, §8.2.4) | ✅ **Todas cubiertas**: Reply implementó `ReplyAi::BridgeApi` con las 21 acciones mapeadas 1:1 a los métodos que ya usaba el agente/automatización/dashboard (interfaz idéntica a `MeliApi`). `add_evidence` con archivo → `{file_base64, file_name, mime_type}` |
| Forwards completos (§8.3): `question`, `order`, `message` (+`attachments`), `claim` | ✅ Reply consume cada shape: `bridge_question`, `bridge_order`, `bridge_message` y `bridge_claim` reenvían los payloads completos a los workflows n8n, que usan `body.question/item`, `body.order/shipment`, `body.message/_id`, `body.claim_data` |
| `POST /api/bridge/sync-products` / `sync-official-stores` | ✅ Consumidos por `MeliSyncProductsWorker` y `MeliSyncOfficialStoresWorker` (rama bridge) |
| Auditoría `BridgeLog` + `GET /api/debug/bridge-logs` | ✅ Disponible para el piloto conjunto |

## 9.2 Qué implementó Reply-AI para consumir el bridge (2026-08-05)

1. **`ReplyAi::BridgeApi`** (`custom/lib/reply_ai/bridge_api.rb`): cliente HMAC del bridge con las
   21 acciones de claims/returns/changes + `sync-products`/`sync-official-stores`. Misma interfaz
   pública que `MeliApi`; `ReplyAi::MeliApi.for(account)` rutea cuentas bridge → `BridgeApi` y
   nativas → `MeliApi` (el controller, la automatización, el agente y el sync usan el factory).
2. **Acciones de reclamos/devoluciones/cambios**: se eliminó el bloqueo que existía para cuentas
   bridge (`reject_bridge_account` 422). Ahora todas las acciones del dashboard rutean por
   `execute-claim-action` para cuentas bridgeadas (mismos contratos ML vía Yobot).
3. **Agente IA de reclamos (`ClaimAgentWorker`)**: las tools (`get_claim`, `get_messages`,
   `send_message`, `add_evidence`, `accept_return`, `partial_refund`, `full_refund`,
   `get_tracking`, `get_order`, ...) ejecutan vía `execute-claim-action` en cuentas bridge.
4. **Automatización PNR/PDD (`ClaimAutomation`)**: ejecuta sus decisiones (evidencia, devolución,
   reembolso parcial) vía bridge.
5. **`bridge_claim` completo**: registra `claim_data`, refresca datos autoritativos con
   `get_claim`, crea la conversación en la bandeja Reclamos, espeja mensajes con `get_messages`
   y evalúa automatización/agente.
6. **`bridge_message` con forward completo**: registra `MeliOrder` desde `body.order`/`pack_id`
   (buyer, item, status) y reenvía a n8n `order`/`shipment`/`conversation_status`/`attachments`/
   `_id` — el workflow post-venta bridgeado ya construye contexto de pedido real y deduplica
   mensajes con `body._id`.
7. **Adjuntos bridge**: el nodo `process_attachments` de n8n descarga desde las URLs de
   `body.attachments` (sin token de ML) y procesa con Vision/Tika/Whisper igual que nativo.
8. **Sync de catálogo y tiendas**: los workers usan `sync-products`/`sync-official-stores` para
   cuentas bridge y persisten en `meli_products`/`meli_official_stores`.
9. **Entrada del flujo de mensajes post-venta (`reply_ai_postsale_webhook`, n8n)**: se creó el
   workflow webhook `chatwoot-postsale` → `Execute Workflow` → `postsale_main` (passthrough),
   referenciado por `N8N_POSTSALE_WEBHOOK_URL`. Es el punto de entrada de las notificaciones de
   mensajes nativas **y** de los forwards de `bridge_message` (antes no existía y los mensajes
   post-venta no entraban a n8n). Verificado end-to-end: `bridge_message` → webhook 200 →
   `postsale_main` ejecuta la cadena (8 nodos: trigger → check_idempotency → is_new_message? →
   get_account_details → get_message_details → normalize_message → is_incoming_from_buyer? →
   get_buyer_details) con `check_idempotency` deduplicando por `ms_<message.id>`.
10. **`bridge_manual_response` implementado** (antes solo acusaba recibo): registra una **nota
    privada** en la conversación correspondiente (pre-venta por `question_id`, post-venta por
    `pack_id`) con el texto de la respuesta manual, para auditoría del flujo bridgeado.
11. **Env vars cableadas para el piloto**: `BRIDGE_SECRET`/`YOBOT_BRIDGE_URL` se pasan desde
    `.env` a `n8n-main`/`n8n-worker` vía docker-compose (`${VAR:-}`) — se configuran una sola vez
    en `.env` y alcanzan para Rails, n8n y los Code nodes.

## 9.3 Bugs corregidos del lado de Reply (no afectan los contratos de Yobot)

| Bug | Corrección |
|---|---|
| `bridge_message` leía campos del envelope viejo (`sale`/`buyer`/`item`) que el forward completo no trae | Mapea `order`/`shipment`/`conversation_status`/`pack_id`/`attachments` (ver §3.2) |
| `_id` se tomaba de `message._id` y el forward manda `message.id` → `check_idempotency` armaba `ms_undefined` | Se envía `_id: message.id` (el contrato de Yobot §3.2 es correcto) |
| `params[:claim_data].is_a?(Hash)` fallaba en Rails 7.1 (`ActionController::Parameters`) — el envelope nunca se persistía | Se convierte con `to_unsafe_h` (bug pre-existente de Reply) |

## 9.4 Verificaciones realizadas (smoke tests con HMAC real)

- `POST /api/bridge/message` (shape §3.2) → `200 {"order_id":..,"status":"processing"}` —
  `MeliOrder` creada con `ml_buyer_id`, `item_id`, `order_status` del forward ✓
- `POST /api/bridge/claim` (shape §3.3) → `200 {"status":"ok",...}` — claim con `status`,
  `stage` y `raw_data` persistidos ✓ (con `YOBOT_BRIDGE_URL` vacía degrada a claim mínimo y
  continúa 200 — el piloto con URL real completará `get_claim`/`get_messages`)
- `POST /api/bridge/question` (shape §3.1) → `200 {"conversation_id":..,"message_id":..}` —
  conversación pre-venta creada ✓
- **Cadena completa de mensajes post-venta**: `bridge_message` → webhook `chatwoot-postsale`
  (n8n) → `postsale_main` ejecuta la cadena principal (8 nodos, dedupe por `ms_<message.id>`) ✓
- `custom/verify.rb` (49 checks, incl. `ReplyAi::BridgeApi`) todo verde; dashboard render 200;
  n8n healthy (webhook `chatwoot-postsale` activo).

## 9.5 Puntos de validación que pedimos a Yobot

1. Confirmar que la firma de los forwards out (Yobot → Reply) se calcula sobre el **body exacto
   que se envía** (ya validamos que es compatible con nuestra verificación sobre body crudo).
2. Confirmar que `execute-claim-action` responde el **body crudo de ML** en 200 (Reply lo pasa
   tal cual a la UI/agente) y `502 {error: <detalle>}` en fallos (ya lo esperamos así).
3. Validar en el piloto: `BridgeLog` registrando los forwards (out) y las llamadas entrantes (in)
   con status 200, en modo `mirror` y luego `full`.
4. Confirmar que `sync-products` devuelve el catálogo completo (`search_type=scan`) para
   sellers con miles de publicaciones (es el caso de uso del dashboard bridge).
5. Confirmar que en modo `mirror` Yobot sigue procesando aunque Reply tarde en responder
   (timeout 15s fire-and-forget) — es la tolerancia a fallos que esperamos.
6. Confirmar el formato de las notificaciones de **mensajes nativas** que llegarán al webhook
   `chatwoot-postsale` (`topic: messages_v2`, con `_id` del mensaje y `user_id` del seller) —
   es el mismo shape que `check_idempotency` de `postsale_main` espera (`body._id`/`body.user_id`).

## 9.6 Pendientes para el piloto (requiere acción conjunta)

| Ítem | Responsable | Estado |
|---|---|---|
| `BRIDGE_SECRET` compartido (mismo valor en Yobot y Reply) | Conjunto | En Reply ya está seteado (`yobot_bridge_dev_secret` en `.env` dev — **cambiar por el real para el piloto**; ya se propaga a n8n vía docker-compose) |
| `REPLY_AI_BRIDGE_URL` apuntando a Reply dev (túnel) | Yobot | ✅ **Seteado (2026-08-05)**: `https://w1206-app.site` (verificado: Reply responde 401 a request sin firma — host alcanzable, auth activa) |
| `YOBOT_BRIDGE_URL` apuntando a Yobot dev (túnel) | Reply | Pendiente (vacía hoy — BridgeApi degrada con error claro; la ingesta sí funciona) |
| Marcar el usuario de prueba en Mongo de Yobot (`bridge: {enabled: true, mode: "mirror"}`) | Yobot | Pendiente |
| `REPLY_RECEIVE_ONLY` (modo recepción) | Reply | Activo (`true`) — correcto para el piloto en `mirror` (Reply audita sin enviar); se apaga al pasar a `full` |
| Migración de sellers Yobot (`YobotMigrator`) | Reply | Pendiente (no bloquea el piloto) |

---

# ENTREGA A REPLY-AI — CONEXIÓN PARA EL PILOTO (2026-08-05)

> Documento de entrega del lado de Yobot para completar la conexión del piloto.
> Estado: **todo implementado y verificado del lado de Yobot**; queda 1 dato pendiente (URL dev de Reply).

## 1. Estado de Yobot (listo)

| Ítem | Estado |
|---|---|
| Código del bridge completo (forwards completos, `execute-claim-action` 21 acciones, `sync-products`/`sync-official-stores`, `BridgeLog` + `GET /api/debug/bridge-logs`) | ✅ Implementado en `develop` |
| Hardening `messages_v2` (alias del topic en `routes/notifications.js` + `handleIncomingMessage.js`) | ✅ Implementado |
| Fix de lectura de env vars (lectura diferida de `BRIDGE_SECRET`/`REPLY_AI_BRIDGE_URL` — antes el bridge quedaba inerte en runtime real) | ✅ Corregido y verificado |
| Usuario de prueba `TTEST25875` (ML user_id `1367850269`, site MLU, plan MAX) | ✅ Marcado bridgeado en `mode: "mirror"` (BD local `PruebaYoBot`) |
| Verificación end-to-end local | ✅ `isBridged=true`, `bridgeMode=mirror`, firma HMAC válida/inválida verificada |
| `BRIDGE_SECRET` en `.env` local de Yobot | ✅ Seteado (mismo valor que el punto 2) |

## 2. Clave compartida (BRIDGE_SECRET)

```
6dbbf0ed0d9d7c6517a20d5defa291a92fa806cff4c3e2674e6a53b413e3aec6
```

> Mismo valor en ambos lados. Tratarla como secreto; una vez usado el piloto, se puede rotar.

## 3. Pasos del lado de REPLY para completar la conexión

1. **`.env` de Rails** — setear:
   - `BRIDGE_SECRET=6dbbf0ed0d9d7c6517a20d5defa291a92fa806cff4c3e2674e6a53b413e3aec6` (reemplaza el placeholder `yobot_bridge_dev_secret`)
   - `YOBOT_BRIDGE_URL=<URL del túnel público apuntando al backend local de Yobot>` (ej. ngrok → `http://localhost:4000`)
2. **Reiniciar Rails y los contenedores de n8n** (las vars ya se propagan vía docker-compose `${VAR:-}`).
3. **Confirmar** `REPLY_RECEIVE_ONLY=true` (piloto en `mirror`: Reply audita sin enviar; se apaga al pasar a `full`).
4. **Confirmar** webhook `chatwoot-postsale` activo en la instancia n8n.
5. ~~Pasar a Yobot la URL del túnel de Reply dev~~ ✅ **Hecho (2026-08-05)**: `REPLY_AI_BRIDGE_URL=https://w1206-app.site` ya está seteada y verificada en Yobot.

## 4. Pendientes de conexión

**Lado de Yobot — completado (2026-08-05)**:
- `BRIDGE_SECRET` ✅ seteado en `.env` local.
- `REPLY_AI_BRIDGE_URL` ✅ seteado (`https://w1206-app.site`), verificado host alcanzable y auth activa (401 sin firma).
- Usuario de prueba ✅ bridgeado en `mirror`.

**Lado de Reply — pendiente**:
- `BRIDGE_SECRET` = `6dbbf0ed0d9d7c6517a20d5defa291a92fa806cff4c3e2674e6a53b413e3aec6` (reemplaza el placeholder `yobot_bridge_dev_secret` en `.env` de Rails). ✅ Hecho (2026-08-05).
- `YOBOT_BRIDGE_URL` = URL del túnel público apuntando al backend local de Yobot. ✅ Hecho (2026-08-05): `http://host.docker.internal:4000` (los contenedores no alcanzan `localhost:4000`).
- Reiniciar Rails + contenedores n8n tras el cambio de vars. ✅ Hecho (2026-08-05).
- **Bloqueante en validación**: `401` en `POST /api/bridge/refresh-token` — ver sección "SOLICITUD DE VALIDACIÓN A YOBOT" al final del documento (respuestas de Yobot pendientes).

## 5. Cronología propuesta del piloto

1. Reply setea sus vars (punto 3) y reinicia Rails/n8n. Yobot ya tiene `REPLY_AI_BRIDGE_URL` cargada (si el backend local está corriendo, reiniciarlo para tomar el `.env` actualizado).
2. Disparar 1 pregunta + 1 mensaje post-venta de la cuenta de prueba → ambos lados deberían recibir los forwards completos.
3. Validar `BridgeLog` (Yobot: `GET /api/debug/bridge-logs?ml_user_id=1367850269`) + auditoría de Reply; repetir con un reclamo y una venta.
4. Probar `execute-claim-action` (`get_claim`, `get_messages`) y `sync-products`/`sync-official-stores` con firma real.
5. Cuando esté OK: pasar el usuario a `mode: "full"` en Mongo de Yobot y Reply apaga `REPLY_RECEIVE_ONLY`.

> **Nota**: el usuario de prueba tiene catálogo chico — la validación de `sync-products` a gran escala queda para la fase pre-producción con el primer usuario real.

---

# SOLICITUD DE VALIDACIÓN A YOBOT — 401 en `POST /api/bridge/refresh-token` (2026-08-05)

> **Bloqueante para el piloto**: el nodo `refresh_token` del workflow `questions_main` corre en
> cada pregunta bridgeada; su 401 detiene todo el pipeline pre-venta (la ejecución de n8n termina
> en error antes de llegar al agente IA).
> **Estado del lado de Reply**: conectividad OK, `execute-claim-action` con la misma firma/HMAC
> **funciona** (respuesta real de Yobot), pero `refresh-token` responde `401 {"error":"No autorizado"}`.

## Evidencia recopilada del lado de Reply

1. **`execute-claim-action` autentica OK** (misma firma HMAC, mismo secret):
   `BridgeApi.get_claim(999999999)` → `502 {"code":404,"error":"not_found_error","message":"Claim not found. claimId: 999999999"}` — Yobot ejecutó la acción contra ML y devolvió el error de ML → **la firma fue aceptada**.
2. **`refresh-token` rechaza con 401**, incluso firmando el body exacto que se envía:

   - Body enviado (exacto, compacto): `{"ml_user_id":"1367850269","refresh_token":"test-refresh-token-placeholder"}`
   - Headers: `Authorization: Bearer 6dbbf0ed0d9d7c6517a20d5defa291a92fa806cff4c3e2674e6a53b413e3aec6` + `X-Bridge-Signature: 0a1370c4ec5c1df08f483a240d3951df84a7c97c0022d3b91d20fbf12bf4ed06`
   - Respuesta: `401 {"error":"No autorizado"}`
   - La firma `0a1370c4...` fue calculada con `crypto.createHmac('sha256', BRIDGE_SECRET).update(body).digest('hex')` sobre ese body exacto.

3. **Cómo firma Reply** (para que Yobot lo contraste):
   - **Rails (`BridgeApi`)**: `OpenSSL::HMAC.hexdigest('SHA256', BRIDGE_SECRET, body_string)` donde `body_string` es el string JSON exacto que viaja en el request.
   - **n8n (Code nodes)**: n8n 2.x no permite `require('crypto')` ni `fetch` global → los nodos delegan la firma en `POST /bridge/sign` de Rails (auth `X-Bridge-Secret: <BRIDGE_SECRET>`), que firma el mismo string que luego se envía a Yobot.

## Qué necesitamos de Yobot (para destrabar)

| # | Pregunta / confirmación | Por qué importa |
|---|---|---|
| 1 | **Valor exacto de `BRIDGE_SECRET` en el `.env` local de Yobot** (copiar el valor literal, incluidos espacios/newline). ¿Es exactamente `6dbbf0ed0d9d7c6517a20d5defa291a92fa806cff4c3e2674e6a53b413e3aec6`? | Si difiere (espacios, valor distinto, variable leída con `trim()` en un lado y sin él en el otro), toda firma válida para Reply es rechazada por Yobot. Pero el punto 1 (execute-claim-action OK) sugiere que el secret SÍ coincide — ver #2/#3. |
| 2 | **Cómo valida `verifyBridgeRequest` la firma**: ¿sobre el **raw body** del request, o re-parsea y re-serializa (`JSON.parse` + `JSON.stringify`)? ¿hex lowercase? ¿`crypto.timingSafeEqual`? | Si Yobot re-serializa el body con **otro orden de claves o espaciado** que el string que viajó, el HMAC no coincide → 401. El orden de claves de nuestro body es `{ml_user_id, refresh_token}` (el documentado en §8.2.3). |
| 3 | **¿`refresh-token` tiene validación adicional además del HMAC?** (ej: el `refresh_token` debe existir/coincidir con el usuario en la BD de Yobot, o el usuario debe estar bridgeado con `isBridged`). | `execute-claim-action` (misma firma) NO da 401 → el 401 de refresh-token puede venir de una validación extra del handler, no de la firma. |
| 4 | **¿Qué responde Yobot si el `refresh_token` no es válido en ML?** ¿401 o 502 `{error: <detalle ML>}`? | Si ML rechaza el token (nuestro placeholder `test-refresh-token-placeholder` es inválido), esperaríamos 502 según §8.2.3/8.4.4 — si Yobot responde 401 en ese caso, es un comportamiento a confirmar. |
| 5 | **BridgeLog del fallo**: `GET /api/debug/bridge-logs?ml_user_id=1367850269&direction=in&limit=5` (requiere token de la app de Yobot) — ¿qué muestra para el refresh-token del 2026-08-05? | El log de Yobot diría si el 401 fue por firma, por `isBridged`, o por otro motivo. |
| 6 | **Host de escucha de Yobot**: ¿el backend escucha en `0.0.0.0` (no solo `localhost`)? | Reply lo alcanza desde los contenedores vía `http://host.docker.internal:4000` (verificado: responde 302 en `/`). Si Yobot solo escucha en `127.0.0.1`, conviene confirmarlo igual. |

## Impacto y plan

- **Bloqueante**: hasta resolver el 401, el flujo de preguntas bridgeadas muere en `refresh_token` (y `TokenRefreshWorker` de Reply tampoco puede refrescar tokens bridge).
- **Mitigación posible del lado de Reply (no bloqueante de Yobot)**: en modo receive-only, `refresh_token` podría saltearse (no se envía nada igual); lo evaluamos si el 401 tarda.
- **Pendiente del lado de Reply ya resuelto**: conectividad host→Yobot (host.docker.internal), firma vía `/bridge/sign` (n8n no puede usar crypto), `chatwoot-postsale` activo, credencial `1367850269` marcada bridge, `REPLY_RECEIVE_ONLY=true`.
- **Confirmación pedida**: respuestas a las 6 preguntas de la tabla → con eso Reply completa el sanity del piloto (pregunta/mensaje/reclamo/venta reales).

---

# RESPUESTA DE YOBOT — 401 en `POST /api/bridge/refresh-token` (RESUELTO 2026-08-06)

> Respuestas a las 6 preguntas de la sección anterior, con verificación en código, BD y pruebas
> end-to-end locales contra el backend de Yobot. **Además se implementó una mejora en Yobot**
> que elimina la causa raíz más probable del 401 (ver §10.3).

## 10.1 Respuestas a las 6 preguntas

| # | Pregunta | Respuesta de Yobot (verificada) |
|---|---|---|
| 1 | Valor exacto de `BRIDGE_SECRET` en `.env` de Yobot | Exactamente `6dbbf0ed0d9d7c6517a20d5defa291a92fa806cff4c3e2674e6a53b413e3aec6` (64 chars, sin espacios ni newline — verificado byte a byte). **Y está funcionando**: BridgeLog registra `execute-claim-action` autenticado OK (00:50 y 01:02 del 06-08) con la misma instancia |
| 2 | ¿Cómo valida `verifyBridgeRequest` la firma? | **Antes del fix**: HMAC sobre `JSON.stringify(req.body)` (body parseado y re-serializado), hex lowercase, comparación `===`. **Después del fix (§10.3)**: HMAC sobre el **raw body** (string exacto recibido) **o** sobre `JSON.stringify(body)` — acepta cualquiera de los dos. Bearer normalizado (`/^Bearer\s+/i` + trim) |
| 3 | ¿`refresh-token` tiene validación extra además del HMAC? | No. Flujo: firma (401) → campos faltantes (400) → usuario no encontrado (404) → ML (502). Sin `isBridged`. El 401 era exclusivamente la verificación de firma |
| 4 | ¿Qué responde si el `refresh_token` es inválido en ML? | **502** con el detalle crudo de ML (verificado en el test: `{"message":"Error validating grant. Your authorization code or refresh..."}`). Nunca 401 |
| 5 | BridgeLog del fallo | Consultamos la BD: **no había registros de refresh-token** (ni 401 ni éxito). Causa: los 3 handlers originales (`send-answer`, `send-message`, `refresh-token`) **no logueaban nada**. Gap corregido en §10.3 — ahora TODO (401 con motivo, 200, 400, 404, 502) queda en `BridgeLog` |
| 6 | Host de escucha de Yobot | `0.0.0.0` (confirmado en `app.js`: `server.listen(PORT, '0.0.0.0')`) — el acceso vía `host.docker.internal:4000` es correcto |

## 10.2 Diagnóstico: por qué fallaba la firma de refresh-token

Computamos el HMAC con el secret compartido sobre **9 variantes** del body documentado
(compacto, orden invertido, con espacios, `ml_user_id` numérico, con newline, y con secrets
viejos/vacíos): **ninguna produce la firma `0a1370c4...` que Reply reporta**. El HMAC correcto
del body exacto que documentan es:

```
693cef9972f7ca04624e46c3b2fac079ed5487f7b8222e5f7b65a08b8c2ac7c9
```

Como `execute-claim-action` **sí autentica** contra la misma instancia y el mismo secret
(evidencia en BridgeLog), el secret de Yobot es correcto. Las causas probables del 401 están
del lado del firmante del refresh-token:

1. **El nodo n8n firma con un secret distinto**: el Code node delega en `POST /bridge/sign`
   de Rails con header `X-Bridge-Secret`. Si ese header quedó con el valor viejo
   (`yobot_bridge_dev_secret`) o hardcodeado, la firma se genera con otro secret → 401.
   (`execute-claim-action` va por Rails directo, que lee el env correcto → pasa.)
2. **El body firmado ≠ el body recibido** (espacios, orden de claves, o valor del
   `refresh_token` distinto entre lo que se firmó y lo que se envió). Yobot re-serializaba
   el body parseado y cualquier diferencia rompía el HMAC.

**Prueba sugerida a Reply**: calcular el HMAC de
`{"ml_user_id":"1367850269","refresh_token":"test-refresh-token-placeholder"}` con su
`BRIDGE_SECRET` actual y compararlo con `693cef99...`. Si difiere → el secret que usan al
firmar (o el body) no es el compartido.

## 10.3 Mejoras implementadas en Yobot (2026-08-06)

1. **Verificación de firma robusta**: `app.js` captura el **raw body** en `req.rawBody`
   (`express.json({ verify })`) y `verifyBridgeRequest` acepta la firma si coincide con el
   HMAC del raw body **o** del `JSON.stringify(body)` → Yobot ya no rompe por diferencias de
   formato/espacios entre el string firmado y el recibido. Bearer tolerante a mayúsculas/espacios.
2. **Auditoría completa de llamadas entrantes**: los 5 handlers inbound (`send-answer`,
   `send-message`, `refresh-token`, `execute-claim-action`, syncs) registran en `BridgeLog`
   TODAS las llamadas: 401 con motivo (`firma inválida`), 400, 404, 502 (con detalle de ML,
   serializado a string) y 200. `BridgeLog.ml_user_id` ahora es opcional (permite loguear
   401 sin body válido).
3. **Evidencia de la prueba end-to-end local** (misma firma/HMAC que Reply usa):

   | Caso | Resultado |
   |---|---|
   | Body compacto + firma compacta | **502** (firma OK → ML rechaza el token placeholder) |
   | Body con espacios + firma con espacios | **502** (firma OK) |
   | Body con espacios + firma compacta (caso que rompía antes) | **502** (firma OK — fix funcionando) |
   | Firma incorrecta | **401** (logueado en BridgeLog como `firma inválida`) |

## 10.4 Acciones pedidas a Reply para destrabar

1. Confirmar que el `.env` de Rails tiene `BRIDGE_SECRET` **byte a byte** igual al compartido
   (sin comillas, espacios ni saltos de línea).
2. Verificar el valor de `X-Bridge-Secret` que usa el Code node de n8n al llamar a
   `POST /bridge/sign` (candidato #1: quedó con `yobot_bridge_dev_secret`).
3. Recalcular el HMAC del body documentado con su secret actual y comparar con
   `693cef99...` — si difiere, el secret o el body al firmar no son los compartidos.
4. Con eso, reintentar `refresh-token` → debería devolver 502 (token placeholder inválido en
   ML) o 200 con token real; nunca más 401.
5. La próxima falla quedará visible en `GET /api/debug/bridge-logs?direction=in` con el motivo.

## 10.5 Validación de Reply (RESUELTO — 2026-08-06)

Ejecutadas las 5 acciones de §10.4. Resultados:

| Acción | Resultado |
|---|---|
| 1. `BRIDGE_SECRET` byte a byte | ✅ Coincide (`6dbbf0ed…`, verificado en rails, n8n-main y n8n-worker) |
| 2. `X-Bridge-Secret` en los Code nodes | ✅ Usa `$env.BRIDGE_SECRET` (no hardcodeado) — env correcto en los 3 contenedores |
| 3. HMAC del body documentado | ✅ **Coincide exactamente con el de Yobot**: `693cef9972f7ca04624e46c3b2fac079ed5487f7b8222e5f7b65a08b8c2ac7c9` |
| 4. `refresh-token` reintentado | ✅ **502** `{"error":{"message":"Error validating grant…","error":"invalid_grant","status":400}}` — firma OK, ML rechaza el token (esperado: el token de la credencial de Reply pertenece a la app de ML de Reply, no a la de Yobot) |
| 5. `BridgeLog` | ✅ Disponible para el piloto (requiere token de la app de Yobot) |

**Conclusión**: el 401 quedó resuelto con el fix de Yobot (§10.3, acepta raw body **o** re-serializado) más los ajustes del lado de Reply: `bridge_sign` (endpoint de firma para los Code nodes de n8n, que no pueden usar `require('crypto')` ni `fetch` global) y el polyfill `fetch` basado en `this.helpers.httpRequest` (el body de la respuesta llega como Buffer serializado `{type:"Buffer",data:[…]}` en el sandbox de n8n — el polyfill lo decodifica).

**Validación end-to-end del flujo de preguntas bridgeado (receive-only)**:

- `POST /api/bridge/question` (forward completo con firma real) → `200 {"conversation_id":..,"status":"processing"}`
- Ejecución n8n `questions_main` → **SUCCESS** (cadena completa: check_idempotency → refresh_token → SQL guard → get_queston_details → RAG → context:assembler → mirror Chatwoot)
- En Chatwoot: conversación pre-venta con la pregunta (incoming), **respuesta del bot como nota privada** (`private: true` — receive-only: no se envió nada a ML/Yobot) y label de espera
- Correcciones aplicadas durante la validación: `refresh_token` ahora es **best-effort** (si Yobot responde 502 porque el token no es válido para la app de Yobot, el flujo continúa; el UPDATE de credenciales solo corre si `refreshed: true`; el `expires_in` usa `|| 0` para que la query siempre parsee)
- **Hallazgo adicional (follow-up)**: la API v1 de Chatwoot resuelve conversaciones por **`display_id`** (no por el `id` interno — `ConversationsController#conversation` usa `find_by!(display_id:)`). Se corrigió en `bridge_question` (payload con `conversation_id: display_id` + `conversation_db_id`). **Pendiente de revisar**: el mismo patrón en `postsale_main` (`get_or_create_conversation` usa el id interno del serializer en las URLs de la API) — afecta el espejado post-venta (nativo y bridge).

---

# PRUEBA DEL FLUJO OUT (Yobot ? Reply) � RESULTADO (2026-08-06)

> Yobot emiti� la primera notificaci�n real (pregunta 13597140007, item MLU639134868, buyer TTEST95491)
> y Reply respond�a **500 �4**. **Resuelto por Reply**: la causa era la validaci�n de Chatwoot sobre
> dditional_attributes con valores num�ricos = 10 d�gitos.

## S�ntoma y causa ra�z

- Log de Rails: Validation failed: Additional attributes ml_question_id value should be < 9999999999`n- La pregunta real tiene id 13597140007 (11 d�gitos) y ridge_question lo guardaba como **n�mero**
  en dditional_attributes.ml_question_id ? Chatwoot rechaza (500). Los tests sint�ticos usaban ids chicos.

## Fix aplicado en Reply

- ridge_question: ml_question_id, ml_item_id y ml_buyer_id se guardan como **strings**
  (question['id'].to_s, item['id'].to_s, uyer['id'].to_s) � los ids de ML siempre como texto en
  dditional_attributes (Chatwoot valida n�meros < 9999999999).

## Verificaci�n con el payload real

- Repro local con el payload real (question/item/buyer completos) + envelope (ml_user_id: 1367850269,
  ccess_token: null, 
esource, 	opic: 'questions') ? **200** {conversation_id, message_id, status: processing}.
- Conversaci�n creada con dditional_attributes en string ?; pregunta incoming ?.
- Ejecuci�n n8n questions_main ? **SUCCESS** (cadena completa; respuesta IA espejada como
  **nota privada** � modo receive-only, nada enviado a ML/Yobot) ?.

## Nota para Yobot (payload capturado)

- El archivo ridge-question-payload.json (18.982 bytes) solo contiene question/item/uyer �
  sin ml_user_id/
esource/	opic/ccess_token. El repro us� el envelope (los 4 intentos reales
  dieron 500, no 404, as� que el forward real s� lo trae). Confirmar que BridgeLog.payload_full**n  incluye el envelope completo para el siguiente reintento.**n
## Pr�ximo paso

- Reintentar el mismo webhook de la pregunta ? deber�a quedar en **200**. Luego probar los otros 3
  pipelines (venta, mensaje, reclamo) con resources reales.

## Incidente: conversaciones duplicadas (2026-08-06)

- **S�ntoma**: al probar con la pregunta real 13636451742 se crearon 2 conversaciones
  (display 33 y 34) con el mismo ml_question_id.
- **Causa**: Yobot re-envi� el forward **2 veces** (2 POST id�nticos a /api/bridge/question,
  misma IP, 10s de diferencia � 09:27:46 y 09:27:56 UTC) y ridge_question **no deduplicaba**
  (creaba conversaci�n nueva en cada llamada).
- **Fix en Reply**: ridge_question ahora es **idempotente** � reusa la conversaci�n existente
  (busca por dditional_attributes.ml_question_id) y solo agrega el mensaje incoming si no existe.
  Verificado: 2 env�os del mismo payload ? misma conversaci�n y mismo message_id.
- **Nota (ruido nativo)**: el seller de prueba est� registrado en las apps de ML de Reply y de Yobot
  (doble registro) ? la notificaci�n nativa tambi�n llega directo al webhook de questions_main y corre
  la rama bridge de n8n con datos incompletos (error controlado en la ejecuci�n, sin efectos). En
  producci�n bridge real esto no ocurre (los sellers bridgeados no autorizan la app de Reply).
- **Consulta a Yobot**: �el re-forward del mismo resource es intencional (ML notific� 2 veces) o hay
  un retry? Con el fix de Reply es inofensivo, pero conviene saberlo para otros pipelines.

## Incidente: falta la nota privada de detalles del producto (2026-08-06)

- **Síntoma**: en las pruebas bridge la conversación mostraba solo el mensaje incoming; la nota
  privada "DETALLES DEL PRODUCTO" (que el flujo nativo sí genera) no aparecía.
- **Causa**: la notificación **nativa** de ML (doble registro de apps en el piloto) llega primero
  al webhook de `questions_main`, inserta la idempotencia (`meli_questions`) con datos incompletos
  (sin `body.question`) y muere en la rama bridge. Cuando llega el forward de Yobot (completo),
  n8n ve la pregunta ya procesada (`is_new_question? = false`) y termina **sin generar la nota
  privada ni la respuesta IA**.
- **Fix en Reply**: `bridge_question` ahora (a) **limpia la fila stale de `meli_questions`** para
  el question_id antes de postear a n8n (el forward bridge es la fuente autoritativa para cuentas
  bridge) y (b) no reprocesa re-forwards (si la conversación y el mensaje ya existían →
  `status: already_processed`).
- **Verificación**: secuencia completa replicada (nativo primero inserta idempotencia → forward
  bridge después) → ejecución n8n **SUCCESS**, conversación con pregunta + **nota privada** + label. ✓
- **Nota**: la conversación 38 (real) no recupera la nota retroactivamente; las próximas preguntas
  bridgeadas sí la tendrán.
---

# DISEÑO DEL BRIDGE: CONTROL, CONFIGURACIÓN Y PLAN DE MAPEO YOBOT → REPLY (2026-08-06)

> Respuesta a la consulta: ¿cuándo se dispara el bridge, quién controla la config y por qué
> las configuraciones del usuario (prompts, delays, saludos) no están mapeadas en Reply?

## 1. ¿Cuándo se dispara el bridge (proceso)?

1. **Marcado del usuario en Yobot**: se setea a mano en Mongo (`User.bridge = { enabled: true, mode: "mirror"|"full" }` — sin UI). Ahí empieza todo: Yobot consulta ese flag por notificación.
2. **Alta de la cuenta en Reply**: vía `POST /api/bridge/register` (o manual, como en el piloto actual: la credencial `1367850269` se marcó `status: 'bridge'`). `bridge_register` crea Account + User + inboxes/equipos/labels/webhooks y setea `default_reply_ai_config` (DEFAULTS, no la config real del seller).
3. **En runtime** (cada notificación ML):
   - Yobot: `isBridged(ml_user_id)` → si bridgeado, arma el forward completo → `POST /api/bridge/{question|message|order|claim}` → en `mirror` además procesa normal; en `full` salta su pipeline.
   - Reply: el forward entra → `find_bridge_account` (credencial `status: 'bridge'`) → procesa con sus workflows n8n (que leen la config de `Account.custom_attributes`).

## 2. ¿Quién controla? (diseño previsto en la documentación)

- **FULL (bridge real)**: Yobot forwardea y **salta su procesamiento** → **Reply queda a cargo de la respuesta** (usa la config de Reply: prompts, delays, RAG, post-venta) y envía vía `send-answer`/`send-message`; Yobot solo ejecuta contra ML (proxy). El seller opera a diario en el **dashboard de Reply** (D11 del plan: config por seller en `Account.custom_attributes`).
- **MIRROR (piloto actual)**: Yobot responde con SU config y Reply audita (receive-only). Por eso ahora se ven las configs de Yobot sin mapear: **en mirror no afecta la respuesta**, pero **en full SÍ**: Reply respondería con prompts vacíos y delays por defecto.

**Conclusión**: el control es de Reply en full; el mapeo de config Yobot → Reply **es requerido** para full (y para que el dashboard de Reply muestre la config real del seller). Estaba **previsto como pendiente** en el plan (§18.4: "Sync bidireccional (manual responses, config sync)" ❌) pero **no implementado**.

## 3. Plan de mapeo Yobot → Reply

### 3.1 Contrato: endpoint en Yobot (nuevo)

`POST /api/bridge/sync-config` `{ ml_user_id }` → `200` con la config completa del User
(prompts, delays, toggles, scheduledMode, officialStores con customGreeting, automatizacionReclamos).
Auth: misma firma HMAC; `isBridged` → 403 si no.

### 3.2 Mapeo campo a campo

| Yobot (`User.config`) | Reply (`Account.custom_attributes`) | Notas |
|---|---|---|
| `chatGPTEnabled` | `config.chatGPTEnabled` | 1:1 |
| `responseDelay` | `config.response_delay` | 1:1 (`enabled`/`seconds`) |
| `prompts.precio, mediosPago, garantia, envios, condicionProducto, otros, saludoGeneral` | `config.prompts.*` (mismos nombres) | 1:1 |
| `prompts.enviosMe1/Me2/Full/RetiroLocal/Custom` | → `config.prompts.envios` (consolidar) o extender schema | Decisión: extender Reply con los 5 subtipos (recomendado) o consolidar |
| `prompts.instruccionesEntrega` | `config.shipping_instructions` | 1:1 |
| `prompts.promptPostVenta` | `config.post_venta_ia.prompts.soporte` | 1:1 (post-venta general) |
| `postVentaChatGPTEnabled` | `config.post_venta_ia.enabled` | 1:1 |
| `postVentaResponseDelay` | `config.post_venta_ia.delay` (nuevo campo) | Falta campo delay en post_venta_ia |
| `scheduledMode` | `config.scheduledMode` (`workDays` → `days`, `holidays` → `overrides`) | Mapeo de forma |
| `postVentaScheduledMode` | `config.post_venta_ia.scheduledMode` (nuevo) | Opcional (fase 2) |
| `agenteConversacionesEnabled` | `config.post_venta_ia.agente` (nuevo) | Opcional |
| `automatizacionReclamos` | `config.automatizacion_reclamos` | 1:1 (mismos campos) |
| `officialStores[].customGreeting` | `meli_official_stores.custom_greeting` | 1:1 (campo ya existe) |
| `requireRagOrConfidence`, `confidenceByCategory` | `config.requireRagOrConfidence`, `config.confidenceByCategory` | 1:1 — implementado (decisión D4 revisada 2026-08-08; ver TECHNICAL.md §18.11) |

### 3.3 Implementación en Reply (propuesta)

1. `ReplyAi::BridgeConfigSync` (service/worker): llama a `POST /api/bridge/sync-config`, mapea y persiste en `Account.custom_attributes` + `meli_official_stores.custom_greeting`.
2. Trigger: en `bridge_register` (sync inicial al dar de alta) + rake/worker `reply_ai:sync_bridge_config[account_id]` para refrescar a demanda (botón en dashboard).
3. Dirección: **1-way Yobot → Reply** al bridgear; la fuente de verdad pasa a Reply en full (ediciones posteriores desde el dashboard de Reply). Un sync 2-way (Reply → Yobot) solo aplicaría si algún modo sigue usando la config de Yobot (mirror) — se evalúa después.
4. Verificación: mapear la cuenta de prueba TTEST25875 y validar prompts/delays/saludos en el dashboard y en una respuesta generada por Reply.

## 4. Pendiente de Yobot

- Implementar `POST /api/bridge/sync-config` con el shape de §3.1 (los campos del User están en `backend/models/User.js`).
---

# PLAN DE INTEGRACIÓN — MAPEO DE CONFIGURACIÓN YOBOT → REPLY (para bridge FULL) (2026-08-06)

> Objetivo: en modo FULL, la lógica y las respuestas se manejan desde Reply (Yobot solo
> ejecuta contra ML). Por lo tanto Reply debe tener las mismas configuraciones del seller
> que hoy viven en Yobot. Este documento define el mapa de propiedades y el plan de
> integración; el contrato del endpoint lo implementa Yobot, el mapeo lo implementa Reply.

## 1. Arquitectura (clarificación)

- **MIRROR** (solo prueba): Yobot procesa y responde con SU config; Reply audita (receive-only).
  Ya validado (2026-08-06) — la config no necesita mapearse.
- **FULL** (bridge real): Yobot forwardea y **salta su pipeline** → **Reply genera la
  respuesta/acciones usando la config de Reply** y la envía vía send-answer / send-message /
  execute-claim-action; Yobot ejecuta contra ML. El seller opera en el dashboard de Reply.
  → **Requerido**: mapear la config del User de Yobot a `Account.custom_attributes` de Reply.

## 2. Mapa de propiedades Yobot → Reply

### 2.1 Pre-venta

| Yobot (`User.config`) | Reply (`Account.custom_attributes`) | Estado |
|---|---|---|
| `chatGPTEnabled` | `config.chatGPTEnabled` | 1:1 — campo existe |
| `responseDelay` `{enabled, seconds}` | `config.response_delay` `{enabled, seconds}` | 1:1 — campo existe |
| `prompts.precio, mediosPago, garantia, envios, condicionProducto, otros, saludoGeneral` | `config.prompts.*` (mismos nombres) | 1:1 — campo existe |
| `prompts.enviosMe1, enviosMe2, enviosFull, enviosRetiroLocal, enviosCustom` | `config.shipping_instructions.{me1, me2, full, pickup, custom}` | Mapeo 1:1 — n8n ya resuelve por `logistic_type` con fallback a `prompts.envios` |
| `prompts.instruccionesEntrega` | `config.shipping_instructions.default` | Mapeo (fallback general) |
| `prompts.promptPostVenta` | `config.post_venta_ia.prompts.soporte` | 1:1 |
| `scheduledMode` `{enabled, timezone, workDays[{day, active, schedule[{start,end,botEnabled}]}], holidays[{date, botEnabled}]}` | `config.scheduledMode` `{enabled, timezone, days{day:[{start,end,active}]}, overrides{date:{mode}}}` | Traducción de forma: `workDays[day].schedule[] → days[day][]` con `active = botEnabled`; día inactivo → sin slots; `holidays → overrides` (`mode: always_off`); `botEnabled` en holidays → `always_on` |
| `theme` | `config.theme` | 1:1 |
| `officialStores[].customGreeting` | `meli_official_stores.custom_greeting` | 1:1 — campo existe |
| `requireRagOrConfidence`, `confidenceByCategory` | `config.requireRagOrConfidence`, `config.confidenceByCategory` | 1:1 — implementado (decisión D4 revisada 2026-08-08; ver TECHNICAL.md §18.11) |

### 2.2 Post-venta

| Yobot | Reply | Estado |
|---|---|---|
| `postVentaChatGPTEnabled` | `config.post_venta_ia.enabled` | 1:1 — campo existe |
| `postVentaResponseDelay` `{enabled, seconds}` | `config.post_venta_ia.delay` `{enabled, seconds}` | **Campo nuevo en Reply** |
| `postVentaScheduledMode` `{enabled, timezone, workDays[], holidays[{date, name}]}` | `config.post_venta_ia.scheduledMode` `{enabled, timezone, days, overrides}` | **Campo nuevo en Reply** (misma traducción de forma que pre-venta) |
| `automatizacionReclamos.enabled, autoEnviarEvidenciaPNR, autoAceptarDevolucionPDD, autoReembolsoParcial, autoAprobarDevolucionSimple, montoMaximoAuto, montoMaximoDevolucionAuto, modoAgenteSupervisado, tiposExcluidos[]` | `config.automatizacion_reclamos.*` (mismos nombres) | 1:1 — campo existe |
| `automatizacionReclamos.delayRespuesta` | `config.automatizacion_reclamos.delayRespuesta` | **Campo nuevo en Reply** |
| `agenteConversacionesEnabled` | — | NO mapear (Reply no tiene equivalente; el ClaimAgentWorker es de reclamos, no de conversaciones) |
| Mensaje de venta inicial (¿existe en Yobot?) | `config.post_sale {enabled, message}` (aviso ME1 de Reply) | **CONSULTA A YOBOT** — ver §4 |

## 3. Contrato — endpoint en Yobot (a implementar por Yobot)

```
POST /api/bridge/sync-config
Body: { "ml_user_id": 123456 }
Auth: Authorization: Bearer BRIDGE_SECRET + X-Bridge-Signature (HMAC estándar)
Validaciones: isBridged(ml_user_id) → 403 si no; 400 si faltan campos.

200 → { "config": <User.config completo — shape de backend/models/User.js> }
```

El shape debe incluir todos los campos de §2 (prompts, delays, scheduledMode,
postVentaScheduledMode, automatizacionReclamos, officialStores con customGreeting, theme,
toggles). Puede devolverse el objeto `config` crudo del User (Reply hace el mapeo).

## 4. Consulta a Yobot

**RESPONDIDA (2026-08-06) — ver sección "RESPUESTA DE YOBOT — PLAN DE MAPEO DE
CONFIGURACIÓN YOBOT → REPLY"**: sí existe el mensaje inicial de venta:
`handleIncomingSale.js` envía `prompts.instruccionesEntrega` automáticamente cuando
`shipping.mode === 'me1'` y el prompt no está vacío (sin toggle; solo ME1).
**Mapeo acordado**: `post_sale.enabled = (instruccionesEntrega no vacío)`,
`post_sale.message = instruccionesEntrega`.

## 5. Plan de implementación del lado Reply (APROBADO por Yobot — 2026-08-06)

> **Estado: IMPLEMENTADO en Reply (2026-08-06)** — `ReplyAi::BridgeConfigMapper` +
> `BridgeConfigSyncWorker` (llama a `POST /api/bridge/sync-config` con firma HMAC), trigger en
> `bridge_register`, rake `reply_ai:sync_bridge_config[account_id]`, botón "Sincronizar config
> de Yobot" en el dashboard post-venta, campos nuevos persistidos (`post_venta_ia.delay`,
> `post_venta_ia.scheduledMode`, `automatizacion_reclamos.delayRespuesta`), `bot_active` con
> `scope=postventa` y postsale_main con schedule PV (`check_bot_active_pv`) + `Wait delay pv`.
> Verificado con fixture realista (prompts, 5 modos de envío, post_sale desde
> instruccionesEntrega, workDays Number/String → days, holidays → overrides, delay, stores).
> **Pendiente del lado Yobot**: implementar el endpoint `sync-config`. → ✅ **IMPLEMENTADO
> (2026-08-07)**: `POST /api/bridge/sync-config` devuelve `{ml_user_id, config, sync_at}`
> con la config cruda del User (defaults aplicados para usuarios legacy); validado localmente
> (200 con firma real, 401 sin firma, 403 no bridgeado).

1. **`ReplyAi::BridgeConfigMapper`**: función pura `(yobot_config) → custom_attributes`
   (tabla §2, incluye traducción de schedules y shipping_instructions). Consideraciones de la
   respuesta de Yobot incorporadas:
   - **Día de la semana**: `scheduledMode.workDays[].day` es **Number** (convención JS,
     0 = Domingo); `postVentaScheduledMode.workDays[].day` es **String** → el mapper normaliza
     ambos y usa una convención única en `days{}` (0 = Domingo).
   - **camelCase → snake_case**: normalizar nombres de prompts (`mediosPago`,
     `condicionProducto`, `saludoGeneral`, `enviosRetiroLocal`, `enviosCustom`,
     `promptPostVenta`).
   - **`post_sale`**: mapear desde `prompts.instruccionesEntrega` (ver §4).
   - **`shipping_instructions`**: `enviosMe1/Me2/Full/RetiroLocal/Custom →
     {me1, me2, full, pickup, custom}` (RetiroLocal → pickup) + fallback `prompts.envios`.
2. **`ReplyAi::BridgeConfigSyncWorker`** (Sidekiq): llama `POST /api/bridge/sync-config`
   (respuesta `{ml_user_id, config, sync_at}`), mapea, persiste en `custom_attributes` +
   `meli_official_stores.custom_greeting`.
3. **Triggers**: sync inicial en `bridge_register` + rake `reply_ai:sync_bridge_config[account_id]`.
4. **Campos nuevos en Reply**: `post_venta_ia.delay`, `post_venta_ia.scheduledMode`,
   `automatizacion_reclamos.delayRespuesta` (+ UI en dashboard post-venta).
5. **n8n**: `bot_active` con `scope=postventa` (lee `post_venta_ia.scheduledMode`, fallback
   `scheduledMode`); `postsale_main` aplica `post_venta_ia.delay` (patrón del response_delay pre-venta).
6. **Verificación**: sync de TTEST25875 → diff campo a campo; pregunta real con prompts del
   seller (saludo + envío por modo); mensaje post-venta con delay y horario; `verify.rb` + render.
7. **Dirección**: 1-way Yobot → Reply al bridgear; la fuente de verdad pasa a Reply en FULL.
   Decisiones aceptadas: `agenteConversacionesEnabled` no se mapea (se pierde en full — a futuro),
   D4 **revisado (2026-08-08)**: el control de confianza SÍ se implementa en Reply (ver TECHNICAL.md §18.11),
   docs RAG del seller fuera de alcance (proyecto aparte — migración RAG implementada, ver §18.10).

## 6. Pendientes

| Ítem | Responsable | Estado |
|---|---|---|
| Endpoint `POST /api/bridge/sync-config` (`{ml_user_id, config, sync_at}`) | Yobot | ✅ **Implementado (2026-08-07)** — validado local (200/401/403) |
| Respuesta a la consulta del mensaje de venta inicial (§4) | Yobot | ✅ Respondida — mapeo acordado |
| Mapeo + worker + triggers + campos nuevos + n8n (§5) | Reply | ✅ **Implementado (2026-08-06)** — falta validación con el endpoint real de Yobot |
---

# PRUEBA DEL FLUJO OUT — MENSAJE POST-VENTA (RESULTADO 2026-08-06)

> Se probó un mensaje post-venta real ("Buenos días") desde una compra de prueba en ML.
> Resultado: flujo completo OK del lado de Reply (en modo mirror + receive-only).

## Evidencia

- **Orden registrada** (`meli_orders`): `ml_order_id/pack_id = 2000007795263609`,
  `ml_buyer_id = 1368182436`, `item_id = MLU639134868`, `order_status = paid` — mapeada del
  forward completo de `bridge_message` (order/shipment/pack_id).
- **Conversación post-venta** creada por `postsale_main.get_or_create_conversation` con
  `additional_attributes {type: post-venta, pack_id, order_id}` y mensajes:
  1. incoming "Buenos días" ✓
  2. label `bot-procesando` ✓
  3. **respuesta IA como nota privada** (`private: true` — receive-only: no se envió nada
     a ML/Yobot; Yobot respondió al comprador normalmente en mirror) ✓
- **Ejecución n8n**: `reply_ai_postsale_main` **SUCCESS** — cadena completa (23 nodos):
  trigger → check_idempotency (`ms_<id>`) → get_message_details → normalize →
  get_or_create_conversation → chatwoot_add_incoming_message → check_ai_gate → rag_search
  (RAG post-venta) → context_assembler → classify_intent → saludo → generate_saludo_response
  → **send_saludo_reply_ml (gate receive-only: skip)** → **mirror_saludo_to_chatwoot
  (nota privada)** ✓
- **Ruido esperado**: las ejecuciones error simultáneas (6) murieron en `check_idempotency`
  (`ms_undefined` / `account_id null`) — son las **notificaciones nativas** de ML llegando
  directo al webhook `chatwoot-postsale` (doble registro de apps del seller de prueba).
  Sin efectos; en producción bridge real no ocurre.

## Conclusión

El pipeline post-venta bridgeado está validado end-to-end (orden, conversación, RAG,
receive-only). Nota: `get_or_create_conversation` de n8n usa el `id` público (display_id) que
devuelve la API — correcto; el bug de display_id era solo del controller `bridge_question`
(corregido, ver incidentes anteriores).

---

# RESPUESTA DE YOBOT — PLAN DE MAPEO DE CONFIGURACIÓN YOBOT → REPLY (2026-08-06)

> Respuesta al "PLAN DE INTEGRACIÓN — MAPEO DE CONFIGURACIÓN YOBOT → REPLY (para bridge FULL)".
> **Veredicto: APROBADO**, con la respuesta a la consulta §4 y 3 observaciones para el mapper.

## 1. Veredicto

El plan es correcto, completo y alineado con el esquema real de `backend/models/User.js`
(verificados: los 14 prompts, delays, scheduledMode, postVentaScheduledMode,
automatizacionReclamos con sus 9 campos, officialStores con customGreeting). Aprobados:
- **Contrato del endpoint**: devolver el `User.config` **crudo** (Reply hace el mapeo) — decisión correcta.
- **Dirección 1-way** Yobot → Reply al bridgear; fuente de verdad = Reply en FULL.
- **Triggers** (bridge_register + rake a demanda) y campos nuevos identificados
  (`post_venta_ia.delay`, `post_venta_ia.scheduledMode`, `automatizacion_reclamos.delayRespuesta`).

## 2. Respuesta a la consulta §4 — mensaje inicial de venta: SÍ existe en Yobot

Verificado en `backend/controllers/handleIncomingSale.js` (líneas ~520-536):

- Cuando una venta nueva tiene `shipping.mode === 'me1'` **y** `prompts.instruccionesEntrega`
  no está vacío, Yobot envía automáticamente ese mensaje al comprador (con guard atómico
  `message_sent: false → true`).
- **No hay toggle `enabled`**: el envío es automático si el prompt está cargado. Solo aplica a
  envíos **ME1** (me2/full no envían mensaje inicial).
- El texto del mensaje = `prompts.instruccionesEntrega`.

**Mapeo sugerido para Reply**: `post_sale.enabled = (prompts.instruccionesEntrega no vacío)`,
`post_sale.message = prompts.instruccionesEntrega` (consistente con su tabla, que ya lo mapea a
`shipping_instructions.default`).

> Nota: `prompts.enviosMe1` es OTRa cosa — se usa en **pre-venta** para responder preguntas sobre
> envíos ME1 (`handleIncomingNotification.js:155`), no para el mensaje inicial de venta.

## 3. Observaciones técnicas para el mapper de Reply

1. **Formato de `day` en schedules**: `scheduledMode.workDays[].day` es **Number** (convención JS,
   0 = Domingo); `postVentaScheduledMode.workDays[].day` es **String** (diferente en Yobot). El
   mapper debe contemplar ambos formatos y confirmar la convención de día (0=domingo vs 1=lunes)
   en su traducción `days{}`/`overrides{}`.
2. **Nombres de prompts en camelCase**: Yobot usa `mediosPago`, `condicionProducto`,
   `saludoGeneral`, `enviosRetiroLocal`, `enviosCustom`, `promptPostVenta`. Confirmar que el
   mapper normaliza camelCase → snake_case si `custom_attributes` los espera así.
3. **`shipping_instructions`**: los 5 subtipos de envío de Yobot son `enviosMe1`, `enviosMe2`,
   `enviosFull`, `enviosRetiroLocal`, `enviosCustom` — el mapeo a `{me1, me2, full, pickup, custom}`
   es correcto (RetiroLocal → pickup), y el fallback a `prompts.envios` que describe Reply
   coincide con el comportamiento de Yobot.

## 4. Decisiones a visibilizar como aceptadas (no bloquean, pero quedan escritas)

| Decisión | Implicación en FULL |
|---|---|
| `agenteConversacionesEnabled` → **NO mapeado** | El agente de conversaciones con tools de Yobot **se pierde** en full (Reply no tiene equivalente; su agente es solo de reclamos). Aceptado; se puede planificar a futuro |
| D4: `requireRagOrConfidence` / `confidenceByCategory` → **SÍ (revisado 2026-08-08)** | El control de confianza de Yobot (retención por falta de info) se implementa en Reply: toggle global + por categoría, `[SIN_INFORMACION]` en el prompt del AI Agent, retención con nota privada + label `esperando_respuesta_manual` e informe en el dashboard (TECHNICAL.md §18.11) |
| **Docs RAG** fuera de alcance | La base de conocimiento del seller (DocumentV2/DocumentPostVenta) no migra; en full Reply responde con su propio RAG (vacío hasta cargar). Proyecto aparte |
| **1-way** | Tras el sync, el seller configura en Reply; la config de Yobot queda inerte para usuarios full. En mirror Yobot sigue siendo fuente |

## 5. Compromiso de Yobot (al aprobarse)

Implementar `POST /api/bridge/sync-config`:
- Request `{ ml_user_id }` · Auth: `verifyBridgeRequest` (401) + `isBridged` (403) + `logBridge` (in).
- Respuesta 200: `{ "ml_user_id", "config": <User.config crudo con defaults aplicados para usuarios legacy>, "sync_at" }`.
- Sin llamadas a ML (solo lectura de BD) — mismo patrón que `sync-products`.
- Tests locales: 200 con firma real, 401 sin firma, 403 no-bridgeado, shape verificado contra `User.js`.

> ✅ **IMPLEMENTADO (2026-08-07)**: `POST /api/bridge/sync-config` operativo y validado localmente
> (200 con firma real, 401 sin firma, 403 no bridgeado). Contract: `{ml_user_id, config, sync_at}`
> con `config` = `User.config` crudo + defaults para usuarios legacy.

---

# REQUERIMIENTOS DE YOBOT PARA EL PASO A FULL BRIDGE (2026-08-07)

> Objetivo: pasar al usuario de prueba `TTEST25875` (`1367850269`) a **`mode: "full"`**.
> En full: Yobot envía la notificación a Reply → **Reply aplica su lógica** (config de Reply) →
> devuelve a Yobot (`send-answer` / `send-message` / `execute-claim-action`) → **Yobot ejecuta en ML**.
> Este documento lista lo que Yobot necesita de Reply antes del cambio de flag, los compromisos de
> Yobot, la secuencia, los criterios de aceptación y el rollback.

## 1. Estado actual (lo que Yobot ya tiene y garantiza)

- Forwards completos en los 4 pipelines + modos `mirror`/`full` por usuario (`User.bridge`, sin UI).
  **El paso a full es solo un cambio de flag en Mongo — cero cambios de código.**
- Inbound operativo y auditado: `send-answer`, `send-message`, `refresh-token` (con token guardado),
  `execute-claim-action` (21 acciones), `sync-products`, `sync-official-stores`, `sync-config`
  (2026-08-07) — todos con HMAC (`verifyBridgeRequest` sobre raw body) + `isBridged` (403) +
  `BridgeLog` completo (200/401/403/502 con detalle).
- Validado en mirror con recursos reales: pregunta, venta y mensaje → **200** de Reply; reclamo con
  `claim_data: null` por ser claim de prueba (el forward transporta OK).

## 2. Requerimientos a Reply (checklist previo al cambio de flag)

| # | Requerimiento | Por qué |
|---|---|---|
| 1 | **`REPLY_RECEIVE_ONLY = false`** | En full, Reply DEBE responder vía Yobot; si queda receive-only, el comprador no recibe nada |
| 2 | **`YOBOT_BRIDGE_URL` operable** (Rails + contenedores n8n) | Reply → Yobot inbound (send-answer/send-message/execute-claim-action/refresh-token/syncs) |
| 3 | **Fix del dashboard**: `NameError: bridge_sync_config_path` (falta la ruta en `routes.rb` de Reply) | Necesario para operar el dashboard y el botón de sync |
| 4 | **Ejecutar `sync_bridge_config` para TTEST25875 y verificar campo a campo** (prompts, delays, saludos, horarios, automatización, stores) | En full, Reply responde con su config — debe ser la del seller |
| 5 | **Definir la CONFIG OBJETIVO del test ANTES del sync** (ver §3) | El sync copia los toggles actuales de Yobot; si quedan off, el full no responde en post-venta |
| 6 | **Protocolo de prueba acordado** (escenarios + criterios de aceptación, §6) | Validar el full sin sorpresas |
| 7 | **Ventana y roles de observación**: BridgeLog de Yobot (`GET /api/debug/bridge-logs`) + logs de Reply | Detectar fallos en tiempo real durante la prueba |

## 3. ⚠️ Punto crítico — config objetivo del usuario de prueba

El sync copia la config **actual** de Yobot. Para TTEST25875 hoy:

- `chatGPTEnabled: true` ✅ (pre-venta responde)
- `postVentaChatGPTEnabled: false` ❌ → **en full, Reply no respondería mensajes post-venta** (respeta el toggle)
- `automatizacionReclamos.enabled: false` ✅ (no se ejecutan acciones automáticas — deseable para el test)
- `requireRagOrConfidence: true` (se mapea — decisión D4 revisada 2026-08-08)

**Acción**: antes del sync, decidir la config objetivo del test. Recomendación: activar
`postVentaChatGPTEnabled: true` en Yobot (se propaga a Reply vía sync) y dejar
`automatizacionReclamos` en **OFF** durante el piloto full (evita mutaciones reales — evidencia,
devoluciones, reembolsos — sobre reclamos de prueba).

## 4. Compromisos de Yobot (al pasar a full)

- El flag se cambia a `mode: "full"` en Mongo (rollback = volver a `mirror` o `enabled: false`).
- Yobot ejecuta cada `send-answer` / `send-message` / `execute-claim-action` contra ML con el token
  del seller y audita todo en BridgeLog (200/401/403/502 con detalle).
- Bridge inerte para cualquier usuario no bridgeado (sin cambios de comportamiento).
- **Comportamiento esperado del seller en full**: el dashboard de Yobot deja de recibir updates en
  vivo de ese usuario (Yobot salta su pipeline — sockets inertes); el seller opera en el dashboard
  de Reply.

## 5. Secuencia del cambio (propuesta)

1. Reply completa los puntos 1-4 del checklist y confirma.
2. Yobot ajusta la config objetivo del test (recomendado: IA post-venta ON) → Reply re-ejecuta
   `sync_bridge_config`.
3. Reply confirma el diff campo a campo.
4. Yobot cambia el flag a `full`.
5. Prueba por escenarios (tabla §6) con observación conjunta.
6. Al terminar: decidir quedarse en full, volver a mirror, o dejar el usuario de prueba en off.

## 6. Criterios de aceptación por escenario

| Escenario | Disparador | Criterio de éxito |
|---|---|---|
| Pregunta pre-venta | TTEST95491 pregunta en un item de TTEST25875 | Reply responde con el prompt del seller; el comprador ve la respuesta en ML; BridgeLog: `out question` 200 + `in send-answer` 200 |
| Venta (order) | Compra de prueba entre cuentas test | Reply registra la orden y procesa `orders_main`; mensaje inicial (si aplica) enviado vía `send-message`; BridgeLog: `out order` 200 + `in send-message` 200 |
| Mensaje post-venta | Comprador escribe en el pack | Reply responde con su pipeline (delay + horario); BridgeLog: `out message` 200 + `in send-message` 200 |
| Reclamo | Reclamo de prueba real en ML | Reply recibe el forward (`out claim` 200), completa con `get_claim`/`get_messages` (in 200); sin acciones automáticas (automatización OFF) |
| Token | Sesión larga | `refresh-token` in 200 con token real |

## 7. Rollback

- Manual: `User.bridge.mode = "mirror"` (Yobot retoma el control total) o `enabled: false` (bridge off).
- Criterios de disparo: 2 escenarios fallidos sin resolución en 30 min, o error 5xx sostenido en
  `send-answer`/`send-message`.

# PLAN DE MIGRACIÓN A FULL BRIDGE - INTEGRADO (REPLY + YOBOT) (2026-08-07)

> Este es el plan final consensuado entre Reply-AI y Yobot. Integra los requerimientos de Yobot
> (sección anterior) con el plan de Reply. Usuario objetivo: `TTEST25875` (`1367850269`) → `mode: "full"`.
> En full: Yobot forwardea la notificación → Reply aplica su lógica → devuelve a Yobot
> (`send-answer` / `send-message` / `execute-claim-action`) → Yobot ejecuta en ML.
> El seller deja de operar en el dashboard de Yobot (sockets inertes) y pasa a operar en el de Reply.

## 1. Estado del lado Reply (verificado 2026-08-07)

| Área | Estado | Evidencia |
|---|---|---|
| Forwards Yobot→Reply (question/message/claim/order) | ✅ | Validados con payloads reales (200) |
| Ingesta post-venta (conv por pack_id + idempotencia + filtro de `message_created`) | ✅ | Fix aplicado y verificado E2E (mensaje en conv, ejecuciones n8n success) |
| Envíos Reply→Yobot: `send-answer` (questions_main, questions_manual), `send-message` (postsale_main ×5, postsale_outbound, orders_main ×2) | ✅ | Rama bridge implementada en todos los nodos de envío (HMAC + BRIDGE_SECRET) |
| Reclamos: `execute-claim-action` (21 acciones, `ReplyAi::BridgeApi`), ClaimAutomation, ClaimAgentWorker | ✅ | Ruteado vía bridge; gates de receive-only desactivan la ejecución |
| `sync-config` Yobot→Reply (mapper + worker + botón dashboard) | ✅ | Sync real validado (200) |
| Refresh-token vía Yobot | ✅ | Fix 401 aplicado (08-06) |
| RAG pre-venta y post-venta (PV) | ✅ | Webhooks y flujos operativos |
| `bot_active`: pre-venta (`chatGPTEnabled=true`) y post-venta (`post_venta_ia.enabled=true`) | ✅ | Ambos activos hoy |
| Ruta del dashboard `bridge_sync_config_path` | ✅ | Existe (`config/initializers/reply-ai_routes.rb:37`); dashboard renderiza 200; botón de sync operativo (el 500 sin sesión es el guard de auth normal, no un bug) |
| `YOBOT_BRIDGE_URL` / `BRIDGE_SECRET` (Rails + n8n) | ✅ | Operativos |
| `verify.rb` | ✅ | 49 checks verdes |

## 2. Checklist previo al cambio (acordado con Yobot)

| # | Requerimiento (de Yobot) | Estado en Reply |
|---|---|---|
| 1 | `REPLY_RECEIVE_ONLY = false` | ⚠️ Se ejecuta **en la misma ventana que el cambio de flag** (ver §4): en mirror, apagar el gate antes haría que Reply responda **además** de Yobot → doble respuesta al comprador |
| 2 | `YOBOT_BRIDGE_URL` operable (Rails + n8n) | ✅ Verificado |
| 3 | Fix `NameError: bridge_sync_config_path` | ✅ Verificado — no aplica: la ruta y el helper existen; el dashboard renderiza sin NameError |
| 4 | Ejecutar `sync_bridge_config` para TTEST25875 y verificar campo a campo | ✅ Mapper implementado; se re-ejecuta tras definir la config objetivo (paso 2 de la secuencia) |
| 5 | Definir la CONFIG OBJETIVO del test ANTES del sync (§3) | ✅ **APLICADA (2026-08-07)**: `postVentaChatGPTEnabled: true` seteado en Yobot (verificado antes/después) — Reply re-ejecuta `sync_bridge_config` y confirma el diff |
| 6 | Protocolo de prueba acordado (§6 criterios) | ✅ Acordado (tabla de Yobot) |
| 7 | Ventana y roles de observación (BridgeLog + logs de Reply) | ✅ Acordado |

## 3. Config objetivo del test (ANTES del sync)

| Toggle (Yobot) | Valor objetivo | Efecto en Reply (vía sync) |
|---|---|---|
| `chatGPTEnabled` | `true` (ya está) | Pre-venta responde |
| `postVentaChatGPTEnabled` | **`true`** ✅ **APLICADO (2026-08-07)** | `post_venta_ia.enabled=true` → post-venta responde |
| `automatizacionReclamos.enabled` | **`false` durante la fase 1** (recomendación de Yobot) | Evita mutaciones reales (evidencia, devoluciones, reembolsos) sobre reclamos de prueba; **fase 2 opcional: activar** |
| `requireRagOrConfidence` | Se mapea a `config.requireRagOrConfidence` (decisión D4 revisada 2026-08-08) | Implementado |

> Nota: la activación de la IA post-venta se hace **del lado de Yobot** (el sync copia sus toggles y
> sobreescribiría cualquier valor puesto a mano en Reply). La automatización de reclamos queda OFF en
> la fase 1 de la prueba (alineado con Yobot) y se propone activarla como fase 2 si la prueba es
> satisfactoria — antes de activarla, Reply confirma `modoAgenteSupervisado` según la política del seller.

## 4. Secuencia del cambio (ventana coordinada)

1. **Reply**: pre-flight completo (§1) y `sync_bridge_config` con la config objetivo ya ajustada por Yobot.
2. **Yobot**: activa `postVentaChatGPTEnabled: true` → Reply re-ejecuta `sync_bridge_config` y confirma el diff campo a campo (prompts, delays, saludos, horarios, automatización, stores).
3. **Ventana de cambio (misma operación, minutos)**: Yobot setea `mode: "full"` en Mongo **y** Reply apaga `REPLY_RECEIVE_ONLY` (env global → `false`) y quita el flag `receive_only` de la cuenta 50. Hacerlo en este orden evita: (a) doble respuesta si el gate se apaga antes del flag, (b) ventana sin respuesta si el flag cambia antes de apagar el gate.
4. **Prueba por escenarios** (§6 de Yobot) con observación conjunta:
   - Reply: `docker compose logs rails --since 10m` (forwards), ejecuciones n8n (sin `error`), mensajes en las conversaciones.
   - Yobot: `GET /api/debug/bridge-logs?ml_user_id=1367850269&limit=50` (200 en `out` y `in`).
5. **Cierre**: decidir quedarse en full, volver a mirror, o dejar el usuario de prueba en off.

## 5. Escenarios y criterios de aceptación (tabla de Yobot, acordada)

| Escenario | Disparador | Criterio de éxito |
|---|---|---|
| Pregunta pre-venta | TTEST95491 pregunta en un item de TTEST25875 | Reply responde con el prompt del seller; el comprador ve la respuesta en ML; BridgeLog: `out question` 200 + `in send-answer` 200 |
| Venta (order) | Compra de prueba entre cuentas test | Reply registra la orden y procesa `orders_main`; mensaje inicial (si aplica) enviado vía `send-message`; BridgeLog: `out order` 200 + `in send-message` 200 |
| Mensaje post-venta | Comprador escribe en el pack | Reply responde con su pipeline (delay + horario); BridgeLog: `out message` 200 + `in send-message` 200 |
| Reclamo | Reclamo de prueba real en ML | Reply recibe el forward (`out claim` 200), completa con `get_claim`/`get_messages` (in 200); sin acciones automáticas (automatización OFF en fase 1) |
| Respuesta manual del operador | El agente responde desde Chatwoot | `postsale_outbound`/`questions_manual` envían vía Yobot (send-message/send-answer) y el comprador ve la respuesta en ML |
| Token | Sesión larga | `refresh-token` in 200 con token real |

## 6. Rollback

- Manual: `User.bridge.mode = "mirror"` (Yobot retoma el control total) o `enabled: false` (bridge off).
- Reply (si hay que volver a modo recepción): restaurar `REPLY_RECEIVE_ONLY=true` + marcar la cuenta `receive_only`.
- Criterios de disparo: 2 escenarios fallidos sin resolución en 30 min, o error 5xx sostenido en
  `send-answer`/`send-message`.

## 7. Decisiones registradas

1. **Fallback en full si Reply cae**: silencio (el mensaje queda visible al humano en Chatwoot; Yobot no responde ni deriva). Yobot no requiere cambios.
2. **Solo migra `1367850269`**: la credencial bridge `777004` queda como está.
3. **Automatización de reclamos OFF en fase 1** (recomendación de Yobot, evita mutaciones reales en reclamos de prueba); se evalúa activarla como fase 2.
4. **IA post-venta ON** vía el toggle de Yobot (`postVentaChatGPTEnabled`) — se propaga con el sync; no se setea a mano en Reply.
5. **`REPLY_RECEIVE_ONLY` y flag `receive_only` se apagan en la misma ventana que el flag de Yobot** (evita doble respuesta en mirror).

## 8. Estado actual y aviso para Reply (2026-08-07)

**Listo del lado de Yobot (verificado en vivo):**

- ✅ `postVentaChatGPTEnabled: true` **aplicado** en la BD local para `1367850269` (antes/después
  verificado: `false → true`). `chatGPTEnabled: true`, `automatizacionReclamos.enabled: false`
  (fase 1), flag `bridge: {enabled: true, mode: "mirror"}`.
- ✅ Backend local operativo + túnel `https://thomson-equality-neck-ear.trycloudflare.com`
  (configurado en ML, estable, responde 200 — levantado por el owner). Duplicados locales de
  cloudflared eliminados (queda 1 proceso sin permisos de kill, inofensivo, sirve una URL sin uso).
- ✅ Reply accede a Yobot vía `http://localhost:4000` (misma máquina) — verificado el modelo.

**Texto para enviar a Reply (siguiente paso):**

> Config objetivo aplicada en Yobot para `1367850269`: `postVentaChatGPTEnabled: true`
> (IA post-venta ON; `automatizacionReclamos.enabled` queda OFF en fase 1). Re-ejecutá
> `sync_bridge_config` para TTEST25875 y confirmá el diff campo a campo (prompts, delays,
> saludos, horarios, automatización, stores). Con el diff confirmado, coordinamos la ventana
> del cambio a FULL: Yobot setea `mode: "full"` y Reply apaga `REPLY_RECEIVE_ONLY` +
> `receive_only` de la cuenta 50 en el mismo minuto. Después, prueba por escenarios con
> observación conjunta (BridgeLog de Yobot: `out`/`in` 200; logs de Rails y n8n de Reply).

**Pendiente solo de Reply:** re-sync + confirmación del diff + ventana coordinada.

## 9. Resultado de las pruebas Reply (2026-08-07, ventana full abierta)

Reply ejecutó los 5 escenarios simulando los forwards con payloads reales (seller `1367850269`,
receive_only apagado, `YOBOT_BRIDGE_URL` operable). Resultados:

| Escenario | Resultado del flujo Reply | Envío a Yobot / ML |
|---|---|---|
| Pregunta pre-venta | ✅ Completo (ingesta, RAG, IA, labels, conv creada) | `send-answer` → Yobot 200 → ML `502 Question not found` (pregunta ficticia; con pregunta real responde 200) |
| Venta (`bridge_order`) | ✅ Orden guardada + `orders_main` success | — |
| Mensaje post-venta | ✅ Completo (ingesta en conv, gates, RAG, delay, IA, labels) | `send-message` → Yobot → **ML `400 The field 'from.user_id' is required`** (Yobot devuelve 502 con detalle crudo) |
| Reclamo (`bridge_claim`) | ✅ Claim guardado + conversación Reclamos + label `reclamo-abierto` | `get_claim` → ML 502 (claim ficticio, esperado) |
| Respuesta manual (postsale_outbound) | ✅ Completo (webhook → filtro → forward) | `send-message` → **mismo 400 de ML (`from.user_id`)** |

### ⚠️ Bloqueante para el full real — pendiente de Yobot

**`send-message` no completa `from.user_id`** (y probablemente `to.user_id`) en el body que Yobot
envía a ML. ML responde `400 bad_request: The field 'from.user_id' is required` y Yobot lo devuelve
como 502. Afecta: respuesta de IA post-venta, respuesta manual del operador y mensaje inicial de
venta. Reply envía el shape acordado (`{ml_user_id, pack_id, text, attachments?}` — §8.2.2); el
completado de `from`/`to` queda del lado de Yobot (tiene el `ml_user_id` del seller y el buyer del
contexto del forward).

### Nota de Reply (no bloqueante)

`meli_claims.claim_id` es columna **integer** — los claim ids de ML son numéricos (OK), pero los
**returns** usan ids alfanuméricos (`RT...`): si en el futuro se persisten returns como claims,
habrá que migrar la columna a string.

## 10. Reintentos con el fix de Yobot (send-message from/to) — RESULTADO 2026-08-07

Yobot aplicó el fix (`send-message` completa `from.user_id`/`to.user_id`). Reply reintentó los
escenarios:

| Escenario | Resultado |
|---|---|
| Respuesta IA post-venta | ✅ **Completo**: ingesta → IA → `send-message` → Yobot `{"status":"sent"}` → espejo nota en Chatwoot + labels (`respondida_con_ia`) — ejecución n8n sin errores |
| Respuesta manual (postsale_outbound) | ✅ **Completo**: webhook → filtro → `send-message` → sent — ejecución success |
| Mensaje inicial de venta | ✅ send-message validado (200 sent con pack real); `orders_main` success |

**Fix adicional aplicado por Reply (workflow n8n `reply_ai_postsale_main`)** — 2 bugs propios
encontrados durante la validación:

1. **`normalize_message`**: el `pack_id` solo se obtenía de `message.message_resources` (ML no lo
   incluye en todos los mensajes) → `send-message` fallaba con 400. Ahora hace fallback al
   `pack_id` del top-level del forward (Yobot lo manda siempre).
2. **Nodos `mirror_*_to_chatwoot`** (logistics/support/close/saludo): el `jsonBody` insertaba el
   texto de la IA sin escapar → si contenía comillas dobles (ej. `"ready_to_ship"`) fallaba con
   "JSON parameter needs to be valid JSON". Ahora construyen el body con `JSON.stringify`.

**Verificado el ciclo completo en vivo (comportamiento correcto del full)**: el mensaje de la IA
enviado a ML genera la notificación del mensaje del vendedor → Yobot la forwardea → `postsale_main`
la clasifica `seller_to_buyer` y corta en `is_incoming_from_buyer?` sin procesarla como entrante.

---

# VALIDACIÓN MANUAL FULL BRIDGE — FIXES DEL LADO DE REPLY (2026-08-07)

> Cambios aplicados por Reply durante las pruebas manuales del usuario bridge `1367850269`
> (modo `full`). **Ninguno requiere cambios del lado de Yobot**: no se tocaron contratos,
> payloads ni firma del bridge. Evidencia esperada en BridgeLog para cada fix.

## 1. Envíos salientes con `ml_user_id` correcto (777004 → 1367850269)

- **Síntoma (reportado por Yobot)**: `send-message` y `refresh-token` llegaban con
  `ml_user_id: 777004` → `404` (Yobot solo conoce al User `1367850269`); el mensaje manual
  nunca llegaba a ML.
- **Causa raíz (lado Reply)**: la cuenta 50 tiene 2 credenciales bridge (id 33 =
  `1367850269` — el seller migrado; id 41 = `777004` — la credencial bridge interna del
  piloto). La resolución usaba `LIMIT 1` **sin `ORDER BY`** en `get_ml_credentials`
  (`postsale_outbound`) y `.first` sin orden en Rails (`BridgeApi`, `MeliApi`,
  `ClaimsSyncWorker`, `BridgeConfigSyncWorker`, `claims_sync`) → Postgres devolvía una fila
  arbitraria (cambió cuando `TokenRefreshWorker` actualizó la fila 41 — cada 5 min al fallar
  el refresh de `777004`).
- **Fix**: `ORDER BY c.id ASC LIMIT 1` en `get_ml_credentials` (n8n) + `.order(:id).first`
  en los 5 puntos de Rails. Todo el tráfico saliente usa `1367850269`.
- **Verificación en Yobot**: BridgeLog `in send-message` / `refresh-token` con
  `ml_user_id: 1367850269` → `200` (o `502` de ML con token de prueba; nunca más `404` por
  usuario desconocido). La credencial `777004` queda intacta (no se borró), pero no se usa
  en ningún envío.

## 2. Etiquetado de conversaciones post-venta (Reply side)

Ciclo de labels corregido en `reply_ai_postsale_main` (+ `reply_ai_postsale_outbound`):

- `bot-procesando` solo se aplica cuando la IA va a responder de verdad (después de la
  clasificación de intent y los gates `bot_active`/`conversation_ai_gate`).
- **Todas las ramas terminan con un label terminal**: `respondida_con_ia`
  (saludo/logística/soporte/cierre), `atencion-humana` (+ `atencion-prioritaria`)
  (handover: reclamo, clasificación no matcheada, rama deshabilitada).
- Con **IA desactivada o fuera de horario** → `esperando_respuesta_manual` (mismo patrón
  que pre-venta) — reemplaza cualquier `bot-procesando` previo.
- **Respuesta manual desde Chatwoot** (`postsale_outbound`): tras envío exitoso a ML/Yobot
  → `respondida_manualmente` (reemplaza `esperando_respuesta_manual`). Si el envío falla,
  la etiqueta de espera se conserva (el agente debe reintentar).
- `normalize_intent`: la clasificación tolera tildes/puntuación (`Logística.` → `logistica`);
  si no matchea ninguna intent → handover con nota privada, nunca muerte silenciosa con
  etiqueta pegada.
- **Backfill**: las conversaciones del piloto que quedaron con `bot-procesando` (display 32
  y 41) se re-etiquetaron a `esperando_respuesta_manual` en la BD.

## 3. Sin cambios de contrato

Ningún endpoint, payload ni formato de firma del bridge cambió. Pendientes para Yobot:
ninguno nuevo derivado de estas pruebas.

---

# REQUERIMIENTO A YOBOT — ESTADO DE LECTURA DE MENSAJES POST-VENTA (2026-08-07)

> **Qué busca Reply**: que las burbujas de Chatwoot reflejen el estado real de los mensajes en
> ML: **✓✓ gris (`delivered`)** = ML recibió el mensaje del vendedor, **✓✓ azul (`read`)** = el
> comprador lo leyó, y que los mensajes del comprador se marquen como **leídos en ML** cuando
> el operador los atiende desde Chatwoot (así el comprador ve "Visto" y se limpian los
> "pendientes de leer" del seller).
>
> **Por qué hace falta Yobot**: en modo `full`, Yobot salta su pipeline → nadie consulta el pack
> de mensajes ni marca lecturas → los ticks de Reply quedan siempre en ✓ y los mensajes del
> comprador quedan "no leídos" en ML. Reply no puede llamar a ML para cuentas bridgeadas
> (sin token) → necesita que Yobot ejecute la consulta del pack, igual que con
> `execute-claim-action`/syncs.

## 1. Contexto (mecanismo verificado)

- **Yobot ya lo hace en su dashboard**: `getPostSaleMessages`
  (`GET /messages/packs/{id}/sellers/{id}?limit=N`, soporta `mark_as_read`) y muestra
  ✓ gris (`message_date.read === null`) o ✓✓ azul (`read !== null`) usando los datos de ML
  (ver `RESUMEN_TECNICO_YOBOT.md` — "Ticks de lectura").
- **Chatwoot ya tiene el mecanismo de ticks**: para inboxes API, la burbuja refleja
  `message.status` (`sent` ✓ / `delivered` ✓✓ / `read` ✓✓ azul) y se actualiza en vivo con
  `PATCH /api/v1/accounts/{account_id}/conversations/{conversation_id}/messages/{message_id}`
  con `{ "status": "read" }`. Hoy los mensajes quedan en `sent` porque nada sincroniza el
  estado de lectura desde ML.
- **ML (docs "Mensajes pendientes")**: el GET del pack
  (`/messages/packs/{pack_id}/sellers/{seller_id}?tag=post_sale`) marca los mensajes del
  comprador como leídos por defecto; `mark_as_read=false` solo consulta. Cada mensaje trae
  `message_date.read` (cuándo el destinatario lo leyó).

## 2. Endpoint requerido: `POST /api/bridge/get-pack-messages`

### Request
```json
{ "ml_user_id": 123456, "pack_id": "200000", "mark_as_read": true }
```
- `mark_as_read` opcional, **default `true`**.

### Comportamiento
Yobot ejecuta contra ML: `GET /messages/packs/{pack_id}/sellers/{ml_user_id}?tag=post_sale`
(con `&mark_as_read=false` solo si `mark_as_read === false`):
- `mark_as_read=true` (default): ML marca los mensajes del comprador como leídos (el
  comprador ve "Visto"; limpia los "pendientes de leer" del seller).
- `mark_as_read=false`: solo consulta, no marca.

### Respuesta `200`
```json
{
  "ml_user_id": 123456,
  "pack_id": "200000",
  "messages": [
    {
      "id": "2c92808469fea23a0169febf14580001",
      "from": { "user_id": "415458330", "name": "..." },
      "to": { "user_id": "..." },
      "status": "delivered",
      "text": "...",
      "message_date": { "received": "...", "read": "..." },
      "message_attachments": []
    }
  ]
}
```
`messages` = el array `messages` de la respuesta cruda de ML (Reply lo consume tal cual;
necesita al menos `id`, `from.user_id`, `text` y `message_date.read`).

### Errores
- `401` firma inválida · `400` faltan campos (`ml_user_id`/`pack_id`) · `403` no bridgeado ·
  `502` error de ML (detalle crudo, mismo formato que los demás endpoints).

### Notas de implementación
- Reutilizar el helper existente `getPostSaleMessages` (misma llamada a ML, mismo manejo de
  errores `order_belong_pack`/404/403).
- Auth: `verifyBridgeRequest` + `isBridged(ml_user_id)` → `403` (mismo patrón que
  `sync-products`/`sync-official-stores`).
- Auditoría: `logBridge` (in) como los demás endpoints entrantes.
- Paginación: alcanza con el limit por defecto para el piloto (opcional `limit=50`).

## 3. (REQUERIDO) `POST /api/bridge/send-message` devuelve `message_id` + `ml_status`

La respuesta `200` de `send-message` debe incluir el `id` del mensaje creado en ML y su status:
```json
{ "status": "sent", "pack_id": "200000", "message_id": "<id_ml>", "ml_status": "available" }
```
- `message_id` → correlación **exacta** entre el mensaje de Chatwoot y el de ML para el sync de
  lectura (sin esto, Reply matchea por texto + orden — funciona, pero menos robusto con textos
  repetidos).
- `ml_status` (status de ML en la respuesta del POST, ej. `available`) → Reply marca la burbuja
  de Chatwoot como **`delivered`** (doble tick gris ✓✓) apenas se envía, reflejando que ML
  recibió el mensaje.
- Ambos campos vienen de la respuesta cruda de ML al POST (`response.data.id` / `.status`) —
  verificado en la implementación de Yobot.

## 4. Qué hará Reply cuando exista (a implementar por Reply)

**Ticks de los mensajes salientes (vendedor → comprador):**

1. **Doble tick gris (✓✓ `delivered`)** — al enviar: cuando `send-message` responde con
   `message_id` + `ml_status`, Reply setea el mensaje de Chatwoot a `status: "delivered"`
   (el mensaje llegó a ML).
2. **Doble tick azul (✓✓ `read`)** — cuando el comprador lo lee: ML setea
   `message_date.read` en el mensaje del vendedor. Reply lo detecta consultando
   `get-pack-messages` con `mark_as_read=false` (no marca nada, solo consulta) y, para cada
   mensaje del vendedor con `message_date.read` presente → `PATCH` del mensaje de Chatwoot
   correspondiente a `status: "read"` (match por `message_id`).
   - **Gatillos del sync de lectura**: (a) cada forward de `bridge_message` (mensaje nuevo
     del comprador) y (b) sync periódico mientras la conversación esté activa (ej. cada 5
     min, solo conversaciones con mensajes salientes sin `read` en Chatwoot).

**Mensajes entrantes (comprador → vendedor):**

3. Al procesar cada forward de `bridge_message`: `get-pack-messages` con `mark_as_read=true`
   (default) → los mensajes del comprador quedan leídos en ML (el comprador ve "Visto" y se
   limpian los "pendientes de leer" del seller).

- Cuentas **nativas**: Reply hace las mismas llamadas directo a ML (sin bridge), mismo flujo.
- **Verificación esperada**: BridgeLog `in get-pack-messages` 200 con firma real y `in
  send-message` con `message_id`; en Chatwoot la burbuja pasa a ✓✓ gris al enviar y a
  ✓✓ azul después de que el comprador lee el mensaje en ML; los "pendientes de leer" de ML
  se limpian al procesar el forward.

## 5. Checklist para Yobot

| Ítem | Responsable | Estado |
|---|---|---|
| Endpoint `POST /api/bridge/get-pack-messages` (`{ml_user_id, pack_id, mark_as_read?}` → `{ml_user_id, pack_id, messages[]}`) | Yobot | ✅ **Implementado (2026-08-07)** — validado local: 200 con firma real (47 mensajes con `message_date.read`), 401 sin firma, 403 no bridgeado, 400 sin `pack_id`, 200 con `messages:[]` en pack inexistente |
| `send-message` devuelve `message_id` + `ml_status` (REQUERIDO, §3) | Yobot | ✅ **Implementado (2026-08-07)** — `{status:'sent', pack_id, message_id, ml_status}` validado con pack real (`message_id` y `ml_status` de la respuesta cruda de ML) |
| Consumo en Reply: ticks delivered/read + marcar leídos (sync por forward + periódico, §4) | Reply | ✅ **Implementado (2026-08-07)** — ver sección "RESPUESTA DE REPLY" §3 |

> **Además (2026-08-07)**: `isBridged` (403) agregado a `send-answer`, `send-message` y
> `refresh-token` — alinea los 8 endpoints inbound con el contrato ("los mutantes validan
> `isBridged`"). Verificado: 403 para usuarios no bridgeados en los 3.

---

# RESPUESTA DE REPLY — CONFIRMACIÓN DEL CONTRATO DE ESTADO DE LECTURA (2026-08-07)

> Respuesta de Reply a las correcciones de Yobot sobre el requerimiento de estado de lectura
> de mensajes post-venta (§2-§5 anteriores).
> **Conclusión: Yobot NO necesita implementar nada distinto a su propuesta ya documentada.**
> El alcance para Yobot queda cerrado en el checklist §5 (ítems 1 y 2).

## 1. Correcciones de Yobot — aceptadas

| Corrección de Yobot | Decisión de Reply |
|---|---|
| `send-message` devuelve `message_id` (REQUERIDO, no opcional) | ✅ Aceptado — correlación **exacta** entre el mensaje de Chatwoot y el de ML; elimina el match por texto |
| `send-message` devuelve `ml_status` (ej. `available`) | ✅ Aceptado — Reply marca la burbuja de Chatwoot como `delivered` (✓✓ gris) al enviar |
| `get-pack-messages` con `mark_as_read=false` para las consultas de lectura | ✅ Aceptado — el sync de `read` no debe marcar como leídos los mensajes del comprador |
| Gatillos del sync: cada forward de `bridge_message` + sync periódico cada 5 min | ✅ Aceptado — el periódico lo implementa Reply como worker Sidekiq (cron `*/5`) |

## 2. Alcance cerrado para Yobot (implementar tal cual está documentado)

1. **`POST /api/bridge/get-pack-messages`** (§2): request `{ml_user_id, pack_id, mark_as_read?}`
   (default `true`) → `200 {ml_user_id, pack_id, messages[]}` con el shape crudo de ML (Reply
   consume `id`, `from.user_id`, `text`, `message_date.read`). Errores: `401`/`400`/`403`
   (`isBridged`)/`502` (detalle crudo). Auditoría `logBridge` (in). Reutilizar
   `getPostSaleMessages`.
2. **`send-message` → `message_id` + `ml_status`** (§3): `200 {status: "sent", pack_id,
   message_id, ml_status}` (campos de la respuesta cruda de ML al POST — verificado por Yobot).

No se requiere nada adicional. Validación local sugerida (igual que en contratos anteriores):
`200` con firma real, `401` sin firma, `403` no bridgeado, `BridgeLog` registrando las llamadas
entrantes (`direction=in`).

## 3. Qué implementó Reply (2026-08-07)

> Implementado, desplegado (Rails + n8n) y **validado en vivo con el usuario bridge
> `1367850269`**: burbuja ✓✓ gris al enviar, ✓✓ azul cuando el comprador lee (sync por
> worker ≤1 min, ver nota de lag), y los mensajes del comprador quedan marcados como
> leídos en ML al procesarlos en Chatwoot.
>
> **Nota de lag de ML (2026-08-07)**: la API de ML tarda **>30 s** en reflejar el
> `message_date.read` de un mensaje del vendedor tras la lectura del comprador — el sync
> por forward (`sync_message_reads`, corre en el momento del mensaje entrante) puede
> consultar antes y no verlo. Por eso el worker periódico corre **cada 1 minuto**
> (garantiza el tick azul en ≤1 min desde que ML registra la lectura).

- **Endpoints custom** (Rails, auth `x-internal-secret`):
  - `POST /api/bridge/message-status` `{account_id, message_id, status, ml_message_id?}` →
    actualiza `status` del mensaje de Chatwoot (broadcast websocket → tick en vivo) y persiste
    `content_attributes.ml_message_id`. Verificado: `200` + mensaje `delivered` con
    `ml_message_id` (preservando `source: n8n_ai`).
  - `POST /api/bridge/sync-conversation-reads` `{account_id, conversation_id}` (display_id) →
    `ReplyAi::MessageReadSync.perform(mark_as_read: true)`.
- **`ReplyAi::MessageReadSync`** (servicio): `pack_messages(pack_id, mark_as_read:)` vía
  `MeliApi` (nativa → ML directo) / `BridgeApi` (bridge → `get-pack-messages`); por cada
  mensaje del vendedor con `message_date.read` → PATCH `read` al mensaje de Chatwoot con ese
  `ml_message_id`.
- **`ReplyAi::MessageReadSyncWorker`** (cron `*/5` en `config/schedule.yml`): conversaciones
  post-venta abiertas con mensajes salientes sin `read` → consulta `mark_as_read=false` (no
  marca nada en ML) → PATCH `read`.
- **n8n `postsale_main`**:
  - Los 4 nodos `mirror_*_to_chatwoot` ahora son Code nodes: crean el mensaje con
    `content_attributes: {source: 'n8n_ai', ml_message_id}` (de la respuesta de
    `send-message`: `message_id`/`id`) y marcan `delivered` (✓✓ gris) vía `message-status`
    (excepto receive-only; best-effort).
  - Nuevo nodo `sync_message_reads` tras la ingesta de cada mensaje del comprador → llama a
    `sync-conversation-reads` (`mark_as_read=true`: marca sus mensajes como leídos en ML, el
    comprador ve "Visto") + sincroniza ticks `read`. Best-effort (no bloquea el pipeline).
- **n8n `postsale_outbound`** (respuesta manual): `send_to_ml` extrae `message_id`/`ml_status`
  de la respuesta y llama a `message-status` con el id del mensaje de Chatwoot (del payload
  del webhook) → burbuja `delivered` + `ml_message_id` para el sync de `read`.
- **Validación esperada (conjunta)**: BridgeLog `in get-pack-messages` 200 y `in send-message`
  con `message_id`; en Chatwoot la burbuja pasa a ✓✓ gris al enviar y a ✓✓ azul cuando el
  comprador lee en ML (vía forward o worker ≤5 min); los "pendientes de leer" de ML se limpian
  al procesar cada forward.
---

# PERFIL DE USUARIO MIGRADO — TRIGGER VÍA BRIDGE + EJECUCIÓN NATIVA EN REPLY (2026-08-07)

> **Contexto comercial**: Reply es la nueva versión de Yobot. Hay usuarios que se quedan en
> Yobot y otros que se **migran** a Reply (los "bridgeados"). Los usuarios migrados **NO
> pueden autorizar la app de ML de Reply** (restricción comercial) — solo autorizan la app de
> Yobot. Por eso: las notificaciones de ML llegan a Yobot (que las forwardea a Reply =
> **trigger**), pero Reply **consulta y actúa directo en MercadoLibre** con el token del seller
> (emitido por la app de Yobot — funciona para llamadas directas; verificado con
> `GET /users/me` → `200` para `1367850269`). El refresh del token se hace **directo a ML con
> las credenciales de la app de Yobot** configuradas en Reply (`.env`), sin depender del
> endpoint `/api/bridge/refresh-token`.
>
> ⚠️ **El flag de Yobot para estos usuarios es `mode: "full"` — NUNCA `mirror`** (en `mirror`
> Yobot seguiría respondiendo → doble respuesta con Reply).

## 1. Cómo queda cada lado

| Capa | Yobot | Reply |
|---|---|---|
| Notificaciones | ML → Yobot (webhook normal) → forward a `/api/bridge/*` (sin cambios) | Entran por los controllers bridge (HMAC, sin cambios) |
| Procesamiento | Salta su pipeline (`full`) | Procesa con su lógica (n8n + Rails) |
| Consulta/acción en ML | No participa | **Directo a ML** con el token del seller (`MeliApi`) |
| Refresh de token | No participa (su token puede quedar obsoleto — irrelevante en `full`) | **Directo a ML** con `YOBOT_ML_APP_ID` / `YOBOT_ML_SECRET_KEY` |
| Auditoría | `BridgeLog` (forwards out) | Logs de Rails/n8n |

## 2. Cómo tiene que quedar el usuario en Yobot (para migrar)

1. **Mongo**: `User.bridge = { enabled: true, mode: "full" }` para el `ml_user_id` del seller.
2. El seller **conserva su autorización de la app de ML de Yobot** (nada cambia en ML).
3. **Sin cambios de código en Yobot**: los forwards completos ya existen (preguntas, mensajes,
   ventas, reclamos).
4. **Nota**: en `full`, el refresh directo de Reply rota el `refresh_token` → el token guardado
   en la BD de Yobot queda **obsoleto**. Es irrelevante (Yobot no procesa a este usuario); si
   algún día se vuelve a `mirror`, hay que re-sincronizar el token o volver al refresh por bridge.

## 3. Cómo tiene que quedar en Reply (para migrar)

### 3.1 `.env` de Reply (nuevas variables)

```
YOBOT_ML_APP_ID=<client_id de la app de ML de Yobot>
YOBOT_ML_SECRET_KEY=<client_secret de la app de ML de Yobot>
```

### 3.2 Credencial del seller (`meli_credentials`)

| Campo | Valor | Efecto |
|---|---|---|
| `status` | `'active'` | Reply ejecuta nativo: `MeliApi` directo y ramas n8n nativas |
| `bridge_enabled` | `true` | Marca "migrado": trigger vía Yobot + refresh con credenciales de Yobot |
| `access_token` / `refresh_token` | vigentes (emitidos por la app de Yobot) | Sirven para llamadas directas a ML |

### 3.3 Cambios de código en Reply (implementado 2026-08-07)

1. **`TokenRefreshWorker`** con 3 rutas: `bridge_enabled` + `YOBOT_ML_APP_ID` presente → refresh
   **directo a ML** con las credenciales de Yobot (verificado en el piloto: token nuevo,
   `expires_at` +6h); `bridge_enabled` sin las vars → vía `/api/bridge/refresh-token` (fallback
   para bridge puro); nativo → `ML_APP_ID`/`ML_SECRET_KEY`.
2. **`ReplyAi::MeliApi.for`**: resuelve por **credencial primaria** (`order(:id).first`) — si la
   primaria es `bridge` → `BridgeApi`; si `active` → `MeliApi`.
3. **`find_bridge_account`**: relajado a **cualquier credencial** con ese `ml_user_id` (el HMAC de
   Yobot se mantiene) — los forwards entran con credencial nativa.
4. **Limpiadas las credenciales bridge residuales**: `777004` (cuenta 50) marcada `inactive`.
5. **Bug pre-existente corregido en `MeliApi#request`**: los GET enviaban `body: "null"` → ML
   responde `403` a GET con body (ej. `GET /messages/packs/...`). Solo los POST llevan body.
   Verificado: `pack_messages` directo → `200`.

## 4. Procedimiento de migración de un usuario MIGRADO (paso a paso)

> **Perfil confirmado (2026-08-07)**: este es el perfil que se usará para migrar usuarios de
> Yobot a Reply. El procedimiento se validó en el piloto con `1367850269` (cuenta 50).

### Paso 0 — Prerrequisitos

- Reply: `.env` con `YOBOT_ML_APP_ID` / `YOBOT_ML_SECRET_KEY` (credenciales de la **app de ML
  de Yobot** — las provee el equipo de Yobot). Si no están, el refresh de migrados no funciona
  (cae al fallback bridge, ver §3.3).
- El seller **solo autoriza la app de Yobot** (no la de Reply) — no se toca nada en ML.
- Yobot con los forwards completos desplegados (preguntas/mensajes/ventas/reclamos).

### Paso 1 — Yobot: marcar el usuario

En la BD de Mongo de Yobot (ej. `PruebaYoBot` en local / la de producción):

```js
db.users.updateOne(
  { ml_user_id: <ML_USER_ID> },
  { $set: { bridge: { enabled: true, mode: "full" } } }
)
```

Verificar:

```js
db.users.findOne({ ml_user_id: <ML_USER_ID> }, { bridge: 1 })
// → { bridge: { enabled: true, mode: "full" } }
```

⚠️ **`mode: "full"` obligatorio** — nunca `mirror` (Yobot seguiría respondiendo → doble
respuesta con Reply). Yobot sigue recibiendo los webhooks de ML normalmente y los forwardea;
salta su pipeline. **Sin cambios de código en Yobot.**

### Paso 2 — Reply: credencial del seller

**Si la cuenta ya existe** (caso del piloto: la credencial estaba `bridge`), migrarla:

```sql
UPDATE meli_credentials
SET status = 'active', bridge_enabled = true, updated_at = NOW()
WHERE account_id = <ACCOUNT_ID> AND ml_user_id = '<ML_USER_ID>';
```

**Si es una cuenta nueva**: crearla con `POST /api/bridge/register` (o el flujo de alta
existente) y luego insertar la credencial con los tokens vigentes del seller (los que tiene
Yobot en su BD — access_token/refresh_token emitidos por la app de Yobot):

```sql
INSERT INTO meli_credentials (account_id, ml_user_id, access_token, refresh_token, expires_at, status, bridge_enabled, created_at, updated_at)
VALUES (<ACCOUNT_ID>, '<ML_USER_ID>', '<ACCESS_TOKEN>', '<REFRESH_TOKEN>', '<EXPIRES_AT>', 'active', true, NOW(), NOW());
```

> Los tokens los emite la app de Yobot y **funcionan para llamadas directas a ML** (verificado:
> `GET /users/me` → 200). El refresh los mantiene vigentes con `YOBOT_ML_APP_ID`/`SECRET_KEY`.

### Paso 3 — Reply: limpiar credenciales bridge residuales

Si la cuenta tiene otras credenciales `bridge` (residuales, ej. `777004` en la cuenta 50),
marcarlas inactivas — si no, el factory `MeliApi.for` podría resolver `BridgeApi`:

```sql
UPDATE meli_credentials
SET status = 'inactive', bridge_enabled = false
WHERE account_id = <ACCOUNT_ID> AND status = 'bridge' AND ml_user_id != '<ML_USER_ID>';
```

### Paso 4 — Reply: reiniciar y verificar la resolución

```bash
docker restart chatwoot-rails-1 chatwoot-sidekiq-1
```

```ruby
ReplyAi::MeliApi.for(Account.find(<ACCOUNT_ID>)).class   # => ReplyAi::MeliApi (NO BridgeApi)
ReplyAi::MeliApi.for(Account.find(<ACCOUNT_ID>)).ml_user_id  # => "<ML_USER_ID>"
```

### Paso 5 — Verificación funcional (escenarios)

| Escenario | Criterio de éxito |
|---|---|
| Pregunta pre-venta | Comprador pregunta → forward de Yobot entra (`out question` 200) → Reply responde **directo a ML** → el comprador ve la respuesta |
| Mensaje post-venta | Mensaje del comprador → conversación + respuesta IA **directa a ML** → ticks ✓✓ gris/azul → `BridgeLog` `out message` 200 |
| Respuesta manual | Operador responde desde Chatwoot → **directo a ML** (sin `send-message` bridge) |
| Reclamo | Forward `out claim` 200 → Reply consulta/actúa **directo** (`MeliApi`) |
| Token | Worker refresca con la ruta `(migrado (app Yobot))` en el log de sidekiq (o forzar: `UPDATE meli_credentials SET expires_at = NOW() - interval '1 hour' WHERE id = <id>` y correr el worker) |
| Evidencia de ejecución nativa | En logs de Rails **no debe aparecer `/bridge/sign`** en la ventana del envío (solo las ramas bridge lo usan) |

### Paso 6 — Rollback

- **Reply** (volver a bridge puro):

```sql
UPDATE meli_credentials SET status = 'bridge', bridge_enabled = true WHERE account_id = <ACCOUNT_ID> AND ml_user_id = '<ML_USER_ID>';
```

- **Yobot** (si además se quiere que retome): `bridge.mode` → `"mirror"` (o `enabled: false`).
- Nota: tras un refresh de Reply, el `refresh_token` en la BD de Yobot queda obsoleto
  (ML rota) — si se vuelve a `mirror`, hay que re-sincronizar el token o re-OAuth.

## 5. Comparativa de perfiles

| | Nativo | **Migrado** | Bridge puro |
|---|---|---|---|
| Notificaciones | ML → Reply directo | Yobot → Reply (forward) | Yobot → Reply (forward) |
| Ejecución/consulta en ML | Reply directo (app Reply) | **Reply directo (token app Yobot)** | Vía Yobot |
| Refresh | App de Reply | **App de Yobot (vars en `.env` de Reply)** | Vía Yobot (`/api/bridge/refresh-token`) |
| Autorización ML del seller | App de Reply | Solo app de Yobot | Solo app de Yobot |
| Flag de Yobot (`User.bridge`) | — | **`full`** | `mirror`/`full` |

---

# MIGRACIÓN RAG DE YOBOT A REPLY (2026-08-08) — PERFIL MIGRADO

> **Contexto**: al migrar un usuario de Yobot a Reply, las configuraciones se sincronizan, pero
> los **documentos RAG** no — y no se le puede pedir al seller que vuelva a subir miles de
> documentos. Reply importa los chunks directamente desde Supabase (la fuente de Yobot) y
> regenera los embeddings con su modelo (`text-embedding-ada-002`; los de Yobot son
> `text-embedding-3-small` → no reutilizables).
>
> **Sin cambios en Yobot**: Reply lee Supabase vía REST con `SUPABASE_URL` +
> `SUPABASE_SERVICE_KEY` (service role key del proyecto `pwooibyvhlimuhtgtpsu.supabase.co`).
> Si el equipo de Yobot prefiere no compartir la key, puede exportar los chunks a JSON
> (alternativa manual).

## Qué lee Reply de Supabase

- Tablas: `{ml_user_id}` (pre-venta) y `pv_{ml_user_id}` (post-venta) — el nombre de la tabla
  usa el `ml_user_id` del seller.
- Columnas: `id, content, metadata jsonb` (embedding NO se usa — se regenera).
- `metadata`: `level (global/category/product), item_id?, category_id?, item_name, doc_id,
  source` (+ `ambito: "postventa"` en PV).

## Mapeo a Reply

| Yobot (Supabase) | Reply (`reply_ai_documents` / `reply_ai_pv_documents`) |
|---|---|
| `level: global` | `level: 'global'`, `reference_id: 'global'` |
| `level: category` + `category_id` | `level: 'category'`, `reference_id: category_id` |
| `level: product` + `item_id` | `level: 'product'`, `reference_id: item_id` |
| `sub` y otros | **Se saltean** — el nivel `sub` de Reply queda vacío (solo Reply lo llena) |
| `item_name` | `file_name` |
| — | `source: 'yobot'`, `yobot_chunk_id: <id del chunk>` (idempotencia: re-importar no duplica) |

## Cómo se dispara

- Botones en el dashboard de Reply (tabs Documentos Pre-Venta y Post-Venta, independientes):
  "Importar documentos de Yobot" → importa los chunks + regenera embeddings (`ada-002` vía
  webhook n8n) + dispara el sync de productos.
- Idempotente: re-ejecutar no duplica y re-emite embeddings faltantes.

## Pedido a Yobot (para habilitar la migración de un seller)

1. Proporcionar a Reply: `SUPABASE_URL` (`https://pwooibyvhlimuhtgtpsu.supabase.co`) y la
   `SUPABASE_SERVICE_KEY` (o un rol con SELECT sobre las tablas de chunks). Se guardan en el
   `.env` de Reply (no versionado).
2. Confirmar el `ml_user_id` del seller (el nombre de la tabla) y que sus documentos estén
   cargados en Supabase (pre y/o post-venta).
3. Nada más: no se requieren cambios de código en Yobot ni endpoints nuevos.

---

# FIXES FLUJO PRE-VENTA PERFIL MIGRADO (2026-08-08) — control de confianza

> **Contexto**: al implementar el control de confianza pre-venta (retención por falta de
> información, decisión D4 revisada — ver TECHNICAL.md §18.11) se rompió el flujo de
> preguntas para el perfil **MIGRADO** (`status: 'active'` + `bridge_enabled: true`):
> preguntas duplicadas, burbuja de la pregunta invisible, dashboard 500 y errores de
> credenciales en la rama de retención. Ningún contrato del bridge cambió — todo es del
> lado de Reply (Rails + workflow n8n `reply_ai_questions_main`).

## 1. Bugs del lado Rails (custom/)

| Bug | Síntoma | Fix |
|---|---|---|
| `update_settings` — `(params[:confidence_categories] \|\| {}).to_unsafe_h` | `NoMethodError (undefined method 'to_unsafe_h' for an instance of Hash)` al guardar la config cuando el form no envía `confidence_categories` (checkbox desmarcado no se envía) → **500 al guardar** | Manejo robusto: `conf_cats.is_a?(ActionController::Parameters) ? conf_cats.to_unsafe_h : (conf_cats \|\| {})` (mismo patrón que `bridge_claim`) |
| `dashboard.html.erb` (panel Informes → Pre-Venta) | `ActionView::Template::Error (undefined local variable or method 'reply_ai_marketing_root')` → **500 en TODO el dashboard** (cualquier tab) | El link a la conversación usa la URL real de Chatwoot: `/app/accounts/{account_id}/conversations/{display_id}` con `target="_blank"` |
| `confidence_report` — buscaba la conversación por `id` interno | Informe mostraba Pregunta/Producto/Conversación vacíos aunque la fila retenida existiera | `cw_conversation_id` se persiste con el **display_id** (id público del serializer) → buscar con `find_by(display_id:)` + fallback del attribute `item_id` (pre-venta nativa usa `item_id`, bridge usa `ml_item_id`) |

## 2. Bugs del workflow n8n `reply_ai_questions_main`

| Bug | Síntoma | Fix |
|---|---|---|
| `chatwoot_add_message_to_conversation` usaba `$input.first().json.id` como `conversationId` | **404 `Chatwoot message create`** — su input es `chatwoot_private_note_create` (devuelve el **mensaje** recién creado, id ej. 942, no la conversación) → la burbuja con la pregunta del comprador no aparecía | Usar `$('chatwoot_conversation_create').item.json.id` (mismo patrón que `chatwoot_private_note_create`, que sí funcionaba) |
| Discriminador de rama en los 4 nodos Chatwoot (`chatwoot_search_contact`, `chatwoot_contact_create`, `chatwoot_conversation_create`, `chatwoot_add_message_to_conversation`): `isBridge = status === 'bridge' && bridge_enabled` | **`false` en MIGRADO** (`status: 'active'`) → la notificación nativa del doble registro corría la rama nativa completa y creaba **su propia conversación** además de la de `bridge_question` (2 conversaciones por pregunta) + `422 Chatwoot conversation create` (source_id duplicado) | Discriminador → `account.bridge_enabled === true` (cubre bridge puro **y** MIGRADO: ambos reusan la conversación/contacto/mensaje ya creados por `bridge_question`) + guard en `chatwoot_conversation_create`: sin `conversation_id` en el trigger → `return null` (**la notificación nativa muere sin efectos** — el forward de Yobot es la fuente autoritativa, alineado con el incidente del 2026-08-06) |
| `update_meli_questions_retained` (rama de retención del control de confianza) **sin credenciales postgres** | `Node does not have any credentials set` cuando la IA respondía `[SIN_INFORMACION]` → la rama de retención moría y la conversación quedaba sin nota ni label | Se agregó `credentials.postgres` (misma credencial que `check_idempotency`: "Postgres chatwoot_development") |
| `update_meli_questions_retained` no persistía `cw_conversation_id` | El informe de control de confianza mostraba Pregunta/Producto/Conversación vacíos (el controller no podía resolver la conversación) | Se agregó `cw_conversation_id = $('chatwoot_conversation_create').item.json.id` (display_id) al UPDATE — mismo campo que el UPDATE de status `completed` del flujo normal |

> **Nota del discriminator**: con `bridge_enabled === true`, los nodos Chatwoot de
> `questions_main` reusan los ids del forward (`trigger.contact_id`, `trigger.conversation_id`,
> `trigger.message_id` — que `bridge_question` envía al postear a n8n). Los nodos de **fetch
> ML** (`get_queston_details`, `get_item_details`, descripciones, `get_buyer_details`) y de
> **envío** (`mercadolibre_answer_question`) mantienen el discriminador original
> (`status === 'bridge'`): en MIGRADO corren la rama nativa (Reply ejecuta directo contra ML
> con el token del seller — comportamiento correcto según el perfil). `refresh_token` ya
> distinguía `isMigrado`.

## 3. Despliegue y verificación

- **Despliegue**: bump de versión en `workflow_history` + `workflow_entity` (patrón §20 de
  TECHNICAL.md), `docker compose restart n8n-main n8n-worker`, export canónico regenerado en
  `n8n/reply_ai_questions_main.json` desde la DB.
- **Backfill puntual**: la fila retenida de la prueba (`13637216723`) se actualizó a mano con
  `cw_conversation_id = '59'` (display_id) para que el informe mostrara sus datos; las
  retenciones nuevas ya persisten el campo solas.
- **Verificación end-to-end con pregunta real** (comprador TTEST95491 → seller `1367850269`,
  perfil MIGRADO, IA activada):
  - ✅ **1 sola conversación** (sin duplicados), con la pregunta del comprador visible,
    nota privada `### 📦 DETALLES DEL PRODUCTO` y label `procesando_con_ia`
  - ✅ **Retención por control de confianza**: la IA respondió `[SIN_INFORMACION]` → UPDATE
    `status=UNANSWERED` + `retained_due_lack_of_info=true` + `suggested_answer` limpio →
    nota privada "Pregunta retenida por control de confianza…" con la sugerencia → label
    `esperando_respuesta_manual` (reemplaza `procesando_con_ia`)
  - ✅ **Informe** `GET /dashboard/confidence-report`: pregunta, producto (resuelto por
    `ml_item_id`), sugerencia, fecha y link a la conversación (`#59`)
  - ✅ `custom/verify.rb` sin errores; dashboard renderiza 200 con la card "Control de
    confianza" y el panel de retenidas
- **Sin cambios del lado de Yobot**: ningún contrato, payload ni firma del bridge se modificó.
- **Pendiente de observar en las próximas pruebas**: confirmar que el ciclo completo
  (pregunta → retención → agente responde manualmente → la pregunta se cierra) funciona igual
  en bridge puro (`status: 'bridge'`), que sigue cubierto por el mismo discriminador.

---

# FIXES FLUJO POST-VENTA PERFIL MIGRADO (2026-08-08) — intent router y contexto de pedido

> **Contexto**: al probar el flujo de mensajes post-venta con el perfil **MIGRADO**
> (`status: 'active'` + `bridge_enabled: true`) y la IA activada, el mensaje del comprador
> llegaba a Chatwoot con el etiquetado correcto (`bot-procesando` → labels finales) pero **no
> se respondía**: el workflow caía al fallback `post_ai_unavailable_note`
> ("⚠️ Respuesta automática no disponible") con `atencion-humana`/`atencion-prioritaria` y
> el contexto del pedido aparecía como "(Sin datos de pedido)". Misma clase de bug que los
> del pre-venta (discriminador MIGRADO + lectura de output equivocado). Todo es del lado de
> Reply (workflow n8n `reply_ai_postsale_main`) — sin cambios de contratos de Yobot.

## 1. Bugs del workflow n8n `reply_ai_postsale_main`

| Bug | Síntoma | Fix |
|---|---|---|
| `intent_router` (switch) leía `$json.intent` del input directo — pero su nodo anterior es `set_bot_label`, un **httpRequest** (POST labels) cuyo output es la respuesta de la API **sin el campo `intent`** | El intent calculado por la IA (`classify_intent` → OpenAI devolvió `"saludo"`, verificado en el runData de la ejecución) **nunca llegaba al router** → `$json.intent` = `undefined` → ninguna rama matcheaba → fallback `post_ai_unavailable_note` + labels `atencion-humana`/`atencion-prioritaria` | Las 5 condiciones del switch (`saludo`, `logistica`, `soporte`, `reclamo`, `cierre`) leen ahora `$('normalize_intent').first().json.intent` — el Code node que calcula el intent normalizado, no el output del httpRequest intermedio |
| `context_assembler` usaba `account.status === 'bridge' && account.bridge_enabled === true` para tomar `order`/`shipment` del forward | **`false` en MIGRADO** (`status: 'active'`) → intentaba fetch directo a ML con `orderId` (= pack_id) → fallaba → `order_context` = "(Sin datos de pedido)" y `shipment_context` = "(Sin datos de envío)" (la nota de fallback los mostraba vacíos) | Discriminador → `account.bridge_enabled === true` (cubre bridge puro **y** MIGRADO): ambos usan el `order`/`shipment` completos que trae el forward de `bridge_message` (mismo patrón que el fix de `questions_main`) |

> **Regla de oro para futuros cambios en los workflows bridge**: el discriminador de los
> nodos que **leen datos del forward de Yobot** (conversación, contexto, deduplicación) debe
> ser `account.bridge_enabled === true` (cubre bridge puro Y MIGRADO); el discriminador de los
> nodos de **fetch y envío a ML** debe seguir siendo `account.status === 'bridge'` (en MIGRADO
> Reply ejecuta directo contra ML con el token del seller). Y los switches deben leer campos
> de los **Code nodes** que los producen (ej. `$('normalize_intent')...`), nunca de
> httpRequests intermedios cuyo output no incluye esos campos.

## 2. Despliegue y verificación

- **Despliegue**: bump de versión en `workflow_history` + `workflow_entity` (versión
  `2a5169a5-…`, workflow `ryXMiGxGs0CBpknCbzpFB`), `docker compose restart n8n-main
  n8n-worker`, export canónico regenerado en `n8n/reply_ai_postsale_main.json` desde la DB.
- **Verificación end-to-end con mensaje real** (comprador TTEST95491 → seller `1367850269`,
  perfil MIGRADO):
  - ✅ **IA post-venta activada**: "HOLA BUENAS TARDES" → `classify_intent` = `saludo` →
    respuesta generada con contexto de pedido real (order/shipment del forward) y enviada a ML
  - ✅ **IA post-venta desactivada** (`post_venta_ia.enabled = false`): etiquetado correcto
    (`esperando_respuesta_manual`), sin respuesta — comportamiento esperado del toggle
  - ✅ Ciclo de labels post-venta intacto (`bot-procesando` → terminal según rama)
  - ✅ `send_*_reply_ml` conservan `status === 'bridge'` (MIGRADO envía directo a ML)
- **Sin cambios del lado de Yobot**: ningún contrato, payload ni firma del bridge se modificó.

---

# FIXES FLUJO POST-VENTA NATIVO (2026-08-08) — ingesta, reuso de conversación y discriminador MIGRADO

> **Contexto**: tras arreglar los bugs del flujo post-venta MIGRADO (intent router y contexto
> de pedido — sección anterior), se probaron los 4 escenarios de mensajes post-venta y
> reclamos en los perfiles **MIGRADO** y **NATIVO**. El flujo NATIVO (cuenta `status:
> 'active'` + `bridge_enabled: false`) tenía 3 bugs en `reply_ai_postsale_main` que impedían
> la ingesta y el etiquetado. Todo es del lado de Reply (workflow n8n) — sin cambios de
> contratos de Yobot.

## 1. Bugs del workflow n8n `reply_ai_postsale_main`

| Bug | Síntoma | Fix |
|---|---|---|
| `get_message_details` usaba `account.status === 'bridge' && bridge_enabled === true` como discriminador | **`false` en MIGRADO** (`status: 'active'`) → corría la rama nativa (fetch directo a ML con `trigger.resource` = **id crudo** del forward, ej. `019e91a8...`, sin el prefijo `/messages/`) → **404 `ML message fetch`** → el forward bridgeado moría en la ingesta (ejecución 1800 error) | Discriminador → `account.bridge_enabled === true` (cubre bridge puro **y** MIGRADO): ambos usan la rama bridge con `body.message` del forward (que `bridge_message` postea completo a n8n) — mismo patrón que `context_assembler`. La rama nativa (fetch directo con `resource = /messages/<id>`) queda solo para cuentas NATIVAS |
| `get_or_create_conversation` (rama nativa) creaba la conversación con `source_id = pack_id` sin buscar la existente a nivel cuenta | **`422 Chatwoot conversation create`** cuando el `source_id` (pack_id) ya existía en un contact_inbox (ej. la conversación fue creada antes por el flujo MIGRADO con otro contacto): el search de contacto nativo devuelve **2 contactos** para el mismo buyer (`ml_buyer_<id>` del bridge y `<id>` del setup) y toma el primero, que no tiene la conversación → intentaba crear → chocaba con el unique constraint | Fallback `findBySourceId` en `get_or_create_conversation`: si no encuentra la conversación por el contacto del search, consulta `POST /api/v1/accounts/{id}/contact_inboxes/filter` con `{inbox_id, source_id: packId}` → obtiene el **contacto dueño** del contact_inbox → busca sus conversaciones por pack_id → **reusa la existente**. Solo crea si no existe en ningún lado. Se agregó `apiPostSafe` (captura errores del filter sin romper el flujo) |

> **Regla de oro reforzada**: en los nodos que **leen datos del forward de Yobot**, el
> discriminador debe ser `account.bridge_enabled === true` (MIGRADO incluido); los nodos de
> **fetch/envío a ML** siguen con `account.status === 'bridge'` (MIGRADO ejecuta directo). Y
> las operaciones de creación en Chatwoot deben **reusar por source_id/pack_id a nivel
> cuenta** antes de crear, para tolerar conversaciones preexistentes creadas por el otro
> perfil.

## 2. Despliegue y verificación

- **Despliegues**: bump de versión en `workflow_history` + `workflow_entity` (versiones
  `b4f3aa43-…` para `get_message_details` y `22900b58-…` para `get_or_create_conversation`,
  workflow `ryXMiGxGs0CBpknCbzpFB`), `docker compose restart n8n-main n8n-worker`, export
  canónico regenerado en `n8n/reply_ai_postsale_main.json` desde la DB.
- **Verificación end-to-end con mensaje real** ("hola", comprador TTEST95491 → seller
  `1367850269`):
  - ✅ **Post-venta MIGRADO** (forward `bridge_message` con HMAC real): Rails 200 →
    ejecución **SUCCESS** — ingesta con rama bridge, conversación reusada, mensaje visible,
    gate `bot_active_pv?` → label `esperando_respuesta_manual` (IA post-venta off)
  - ✅ **Post-venta NATIVO** (webhook `chatwoot-postsale` con shape ML, credencial
    temporalmente nativa): ejecución **SUCCESS** — ingesta, `findBySourceId` reusó la
    conversación 153 (sin 422), mensaje visible, mismo label terminal
  - ✅ **Reclamos MIGRADO** (`POST /api/bridge/claim` HMAC): claim registrado + conversación
    conservada + `get_claim` degradado correcto con claim ficticio
  - ✅ **Reclamos NATIVO** (`POST /claims_webhook`): llamada directa a ML con error mapeado
    (422 "Claim not found" — no hay crash); `ReplyAi::MeliApi.for` → `MeliApi` directo
  - ⚠️ Ruido esperado e inofensivo: el webhook de Chatwoot de vuelta (`message_created` sin
    `_id` de ML) muere en `check_idempotency` con `ms_undefined`
- **Sin cambios del lado de Yobot**: ningún contrato, payload ni firma del bridge se modificó.

---

# VENTAS POST-VENTA Y MEJORAS PRE-VENTA (2026-08-08/09)

> **Contexto**: tres bloques de trabajo sobre el dashboard post-venta y el flujo pre-venta:
> (1) tabla de ventas con preguntas relacionadas, (2) Dashboard App "Venta ML" embebida en la
> conversación post-venta, (3) mejoras de UX en pre-venta: doble tick `delivered` en las
> respuestas y estética de la nota privada "DETALLES DEL PRODUCTO". Todo es del lado de Reply
> (custom/, config/initializers/, lib/tasks/, n8n/) — sin cambios de contratos de Yobot ni
> archivos core.

## 1. Tabla de Ventas (sub-pestaña "Ventas" en dashboard → Post-Venta)

**Problema**: no existía un listado de ventas; `meli_orders` solo persistía ids (ml_order_id,
ml_buyer_id, item_id, pack_id, order_status) sin el detalle (título, comprador, total, fecha).

**Implementación**:
- **Migración custom** `20260808220000_add_sale_fields_to_meli_orders.rb`: agrega a
  `meli_orders` → `item_title`, `buyer_nickname`, `total_amount` (decimal), `currency_id`,
  `quantity`, `date_created` (fecha de la venta).
- **Persistencia del detalle** en 3 puntos:
  - `bridge_order` (`landing_controller.rb`): mapea los campos del forward §3.4
    (`order_items[0].item.title/quantity`, `buyer.nickname`, `total_amount`, `currency_id`,
    `date_created`)
  - `bridge_message`: mismo mapeo desde `order`
  - n8n `upsert_order` (`reply_ai_orders_main.json`): INSERT extendido (desplegado con bump
    de versión)
- **Endpoint** `GET /dashboard/sales/data` → `sales_list`: JSON de las órdenes + `questions`
  con `{count, conversation_display_id}` — cruza por **item_id + ml_buyer_id** en conversaciones
  pre-venta (`additional_attributes.ml_item_id`/`ml_buyer_id`), equivalente Reply del cruce de
  Yobot (`Question.find({item_id, 'from.id': buyer.id})`). Link directo a la conversación
  (`/app/accounts/{id}/conversations/{display_id}`).
- **UI** (`dashboard.html.erb`): botón "Ventas" en subtabs post-venta, panel
  `panel-postventa-ventas` con tabla (Fecha/ID/Producto/Comprador/Cant./Total/Estado/
  Preguntas con link), registrado en `PANEL_MAP`, `TAB_TITLES` y `LEGACY_PANEL`, `loadSales()`
  con polling.

## 2. Dashboard App "Venta ML" (Fase 2)

- **Endpoints** (`landing_controller.rb` + `reply-ai_routes.rb`):
  - `GET /dashboard/sale-panel` → `sale_panel` (HTML standalone)
  - `GET /dashboard/sales/panel-data?conversation_id=` → `sale_panel_data` (JSON)
  - `GET /dashboard/sales/:id` → `sale_detail` (JSON con mensajes)
- **Resolución de la venta por conversación** (`resolve_panel_sale`): primero por
  `meli_orders.cw_conversation_id` (id interno), fallback por `pack_id` de
  `conversations.additional_attributes`.
- **Vista `sale_panel.html.erb`** (solo lectura): header de la venta (ID, estado, conversación),
  producto, comprador, resumen (total/fecha), chat de la conversación post-venta. **Soporta
  postMessage `appContext`** de Chatwoot: la URL del iframe lleva `{{conversation.id}}` que
  Chatwoot 4.15 NO sustituye (bug latente del claim_panel) — el panel escucha el evento y
  resuelve el `conversation.id` real antes de cargar.
- **Registro**: `setup_account_channels` crea la Dashboard App "Venta ML"
  (`/dashboard/sale-panel?conversation_id={{conversation.id}}`); backfill en
  `lib/tasks/reply_ai.rake` **por título** (no choca con "Reclamo ML").
- **Bug preexistente corregido**: `Account` no tenía `has_many :meli_orders` ni
  `meli_official_stores` en `reply_ai_account_associations.rb` (faltaban) → se agregaron.
- **Bug preexistente corregido**: las actions nuevas quedaron inicialmente en la sección
  privada del controller → `ActionNotFound`; se movieron a la sección pública.

## 3. Doble tick (✓✓ delivered) en respuestas pre-venta

**Problema**: la burbuja de la respuesta IA/manual quedaba con 1 tick (`sent`) aunque ML
hubiera confirmado la entrega.

**Implementación** (mismo mecanismo que post-venta — endpoint existente
`POST /api/bridge/message-status` con `x-internal-secret`):
- `n8n/reply_ai_questions_main.json`: nuevo nodo `chatwoot_mark_delivered` entre
  `chatwoot_publish_answer_ai` y `chatwoot_remove_processing_label1` — tras el envío exitoso a
  ML (200 de `mercadolibre_answer_question`), marca el mensaje recién publicado como
  `delivered` vía `message-status`. Skip en receive-only.
- `n8n/reply_ai_questions_manual.json`: mismo nodo después de `mercadolibre_post_answer`,
  marcando el mensaje del agente (`body.message.id` del webhook de Chatwoot).
- Confirmación de entrega: el 200 de `send-answer` (Yobot ejecutó contra ML) o de
  `POST /answers` (nativo) — no hay `message_id` de ML en pre-venta (a diferencia de
  `send-message` post-venta que devuelve `message_id`).
- El ✓✓ azul (`read`) NO aplica en pre-venta: ML no expone estado de lectura para preguntas.
- Ambos workflows desplegados con bump de versión (`78eaba18-…`, `cb7feed6-…`).

## 4. Estética de la nota privada "DETALLES DEL PRODUCTO" (pre-venta)

`n8n/reply_ai_questions_main.json` (nodo `context:assembler` → `product_note_markdown`):
- **Imagen al 50%**: la URL de la imagen lleva `?cw_image_width=50%25` (o `&` si ya trae
  query) — el renderer nativo de Chatwoot (`MessageFormatter.js`, `imgResizeManager`) aplica
  `width: 50%` desde ese query param (sin tocar core).
- **Tipografía del tamaño de las burbujas**: se eliminaron los `###` (heading h3 → más
  grande) y los blockquotes `>` (estilo cita con itálica). Ahora texto plano con `**bold**`.
- **Sin emojis**: eliminados todos (📦🆔🔢💰🔥📦📈🛠️📂🔗).
- **Sin tachado**: `~~precio~~` → `(oferta: ...)`.
- **Bordes redondeados (8px)**: regla CSS inyectada por `ReplyAi::InjectCssMiddleware`
  (`custom/lib/reply_ai/inject_css_middleware.rb`): `img[src*="cw_image_width"] { border-radius: 8px; }`
  — selector único (solo imágenes de la nota), no afecta adjuntos/avatares.
- Workflow desplegado con bump de versión (`03629737-…` para la imagen 50% y
  `ec56735a-…` para la tipografía/emojis). Aplica a preguntas nuevas; las notas existentes
  conservan el formato viejo.

## 5. Verificación

- `custom/verify.rb` sin errores; dashboard renderiza 200 con la sub-tab Ventas;
  `sales/data` 200 (5 ventas, preguntas con link display 60); `sale-panel`/`panel-data` 200;
  `bridge_message-status` probado con mensaje real (sent → delivered → burbuja ✓✓ gris);
  CSS inyectado verificado en `/app/accounts/50/conversations`.
- Regresión OK: confidence-report, claims, claim-panel, post-venta.
- **Sin cambios del lado de Yobot**: ningún contrato, payload ni firma del bridge se modificó.

---

# FIX VENTA REAL + POLLING TABLA DE VENTAS (2026-08-09)

> **Contexto**: al probar con una **venta real de MercadoLibre** (forward de Yobot
> `POST /api/bridge/order`, orden `2000017838969458`, colchón UYU 124500, comprador TTEST95491)
> el endpoint respondía **500 `Validation failed: Account must exist`** (3 reintentos). Además,
> la tabla de ventas del dashboard no se refrescaba sola (había que recargar la página). Ambos
> corregidos — sin cambios de contratos de Yobot ni archivos core.

## 1. Bug de precedencia en `bridge_order` → "Account must exist"

**Síntoma**: el forward de la venta real entraba a `bridge_order` y fallaba con
`Validation failed: Account must exist` → `MeliOrder` nunca se registraba.

**Causa raíz**: en `bridge_order` la línea era `find_bridge_account and return if performed?`.
En Ruby, el modificador `if` tiene **menor precedencia** que `and`, así que se interpreta como
`(find_bridge_account and return) if performed?` — como `performed?` es `false` al inicio del
request, **`find_bridge_account` NUNCA se ejecutaba** → `@account` quedaba `nil`. Los demás
endpoints bridge (`bridge_question`, `bridge_message`, `bridge_claim`) usan
`find_bridge_account` como línea suelta (correcto) — solo `bridge_order` tenía el patrón roto
(bug preexistente que nunca se había disparado porque no se probaban ventas reales).

**Fix** (`custom/app/controllers/landing_controller.rb`, solo `bridge_order`):
```ruby
find_bridge_account
return if performed?
```

**Verificación**: repro con el forward real (curl + HMAC) → **200**
`{"order_id":12,"status":"saved"}`. Orden 12 registrada con los campos de venta nuevos:
`item_title` ("Colchón De Espuma En Caja Freestyle Box 2 Plazas Item Prueba"),
`buyer_nickname` (TTEST95491), `total_amount` 124500, `currency_id` UYU, `quantity` 1,
`pack_id` 2000014439748525. Ejecución n8n `orders_main` (1898) **SUCCESS** (`upsert_order` +
`check_post_sale_enabled`). `message_sent=false` (orden `d2c`, no ME1 → no aplica mensaje
inicial — comportamiento correcto).

> **Nota menor observada**: `shipping_mode` quedó con el literal `undefined` en la orden 12
> (el INSERT de n8n escribe `shipping?.logistic_type` que no viene en forwards `d2c`). No
> bloquea; anotado para una futura limpieza del template si molesta en la UI.

## 2. Polling de la tabla de ventas (actualización automática)

**Problema**: la tabla de la sub-tab "Ventas" solo cargaba al entrar o al recargar la página.

**Fix** (`custom/app/views/landing/dashboard.html.erb`):
- `startSalesPolling()`: `setInterval` cada **30s** que recarga `loadSales()` **solo si el
  panel de ventas está visible** (sin requests en segundo plano en otras pestañas).
- `stopSalesPolling()`: limpia el timer al salir del panel.
- En `showSubTab`: al entrar a `postventa > ventas` arranca el polling; en cualquier otra
  sub-pestaña lo detiene. Timer único con flag (no se superponen al cambiar de tab).
- Mismo patrón que la tabla de reclamos (`setInterval(loadClaims, 15000)`).

**Verificación**: spec de request — dashboard 200 con `startSalesPolling`/`stopSalesPolling`/
`30000` presentes, sin regresiones. Aplica sin reiniciar Rails (vista ERB).
