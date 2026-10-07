# Guía de Migración de Cuentas de Yobot a Reply-AI

> Documento fuente para NotebookLM. Proceso completo para migrar un seller (vendedor) desde Yobot (app legacy Node.js/MongoDB) hasta Reply-AI (Chatwoot + Rails). Fuentes: `TECHNICAL.md` §18.7, §18.9, §18.10 y `docs/REQUERIMIENTOS_YOBOT.md`.

## 1. Qué significa migrar una cuenta de Yobot a Reply-AI

Yobot es la plataforma legacy en producción con sellers reales conectados a MercadoLibre. Reply-AI es la evolución sobre Chatwoot. Migrar una cuenta significa que el seller **pasa a operar su atención al cliente en Reply-AI** sin tener que volver a autorizar su cuenta de MercadoLibre (restricción comercial: algunos sellers solo pueden autorizar la app de ML de Yobot).

La migración se apoya en el **bridge Yobot ↔ Reply-AI**: Yobot actúa como proxy de las notificaciones de MercadoLibre — forwardea los eventos (preguntas, mensajes, órdenes, reclamos) a Reply-AI con firma HMAC, y en algunos casos también ejecuta las respuestas en ML del lado de Yobot.

### Tres perfiles posibles para la cuenta migrada

| | **Nativo** | **Migrado** | **Bridge puro** |
|---|---|---|---|
| Notificaciones de ML | ML → Reply directo | Yobot → Reply (forward) | Yobot → Reply (forward) |
| Ejecución/consulta en ML | Reply directo (app propia) | **Reply directo con el token del seller** (app de Yobot) | Vía Yobot (`send-answer`, `send-message`) |
| Refresh del token | App de Reply | **App de Yobot** (`YOBOT_ML_APP_ID/SECRET`) | Vía `/api/bridge/refresh-token` |
| Autorización ML del seller | App de Reply | Solo app de Yobot | Solo app de Yobot |
| Flag en Yobot | — | `bridge: { enabled: true, mode: "full" }` | `mode: "mirror"` o `"full"` |
| `meli_credentials` | `status: active`, `bridge_enabled: false` | **`status: active`, `bridge_enabled: true`** | `status: "bridge"`, `bridge_enabled: true` |

- **Nativo** = seller que autoriza la app de ML de Reply (objetivo final ideal).
- **Migrado** = seller que autorizó solo la app de Yobot: Reply recibe el forward de Yobot pero **responde y consulta directo en ML** con el token del seller (verificado con `GET /users/me` → 200). Es el perfil más común de la migración.
- **Bridge puro** = Reply delega todas las llamadas a ML en Yobot.

> **Regla crítica**: el flag en Yobot debe ser `mode: "full"` (nunca `mirror`) para sellers migrados — en `mirror`, Yobot sigue procesando con su pipeline propio y se generan **doble respuesta y conversaciones duplicadas** (incidente real, 2026-08-06).

## 2. Prerequisitos (configuración única, antes de migrar cualquier cuenta)

### 2.1 Variables de entorno en Reply-AI (`.env`)

| Variable | Propósito |
|----------|-----------|
| `BRIDGE_SECRET` | Clave compartida HMAC — **idéntica** a la de Yobot. Verificación sobre el body crudo (`X-Bridge-Signature`) |
| `YOBOT_BRIDGE_URL` | URL base de Yobot para envíos (`send-answer`, `send-message`, `execute-claim-action`, `refresh-token`, `sync-products`). ⚠️ En producción debe apuntar al Yobot de producción (hoy arrastra un valor de dev — tech debt) |
| `YOBOT_ML_APP_ID` / `YOBOT_ML_SECRET_KEY` | Credenciales de la **app de ML de Yobot** — para refrescar los tokens de sellers migrados (el token lo emitió la app de Yobot; solo esa app puede refrescarlo) |
| `SUPABASE_URL` / `SUPABASE_SERVICE_KEY` | Proyecto Supabase de Yobot — para migrar los documentos RAG |
| `N8N_*_WEBHOOK_URL` (7 URLs) | Webhooks públicos de n8n (entrada de preguntas, post-venta, salidas manuales, reclamos, embeddings) |
| `REPLY_RECEIVE_ONLY` | Durante la migración: `true` (modo audición); al terminar: `false` |

### 2.2 Variables de entorno en Yobot (`backend/.env`)

| Variable | Propósito |
|----------|-----------|
| `BRIDGE_SECRET` | Mismo valor que en Reply |
| `REPLY_AI_BRIDGE_URL` | URL pública de Reply-AI (producción: `https://w1206-app.site`) |

> Si `BRIDGE_SECRET` está vacío en Yobot, `isBridged()` retorna `false` siempre → Yobot funciona exactamente igual que antes. **Cero riesgo** de dejarlo desconfigurado.

### 2.3 Infraestructura

- Instancia n8n activa con los 9 workflows importados y el webhook `chatwoot-postsale` operativo.
- Handlers de bridge en Yobot (implementados): `handleIncomingNotification` → `/api/bridge/question`, `handleIncomingMessage` → `/api/bridge/message`, `handleIncomingSale` → `/api/bridge/order`, `handleIncomingClaim` → `/api/bridge/claim`.
- Verificación de conectividad: `curl {REPLY_AI_BRIDGE_URL}/api/bridge/seller/<ml_user_id>` desde el servidor de Yobot debe responder (401 sin firma = auth activa, correcto).

## 3. Paso a paso de la migración de una cuenta

### Paso 0 — Modo seguro: receive-only

Activar `REPLY_RECEIVE_ONLY=true` en Reply-AI (`.env` de rails/sidekiq **y** explícita en `docker-compose` para `n8n-main`/`n8n-worker`, porque n8n no usa `env_file`). En este modo:

- Todo lo entrante llega normal a Chatwoot (conversaciones, labels, RAG, syncs).
- **Nada se envía a ML/Yobot**: las respuestas del bot quedan como notas privadas, las acciones de reclamo devuelven `200 {receive_only: true}`, el agente corre en dry-run.
- Las cuentas registradas con el env activo quedan marcadas `receive_only` automáticamente.

Permite auditar el flujo completo antes de habilitar el envío real.

### Paso 1 — Marcar el seller en Yobot (MongoDB)

```javascript
db.users.updateOne(
  { "mercadolibre.user.user_id": <ML_USER_ID> },
  { $set: { bridge: { enabled: true, mode: "full" } } }
)
```

Con esto Yobot pasa a forwardear los eventos de ML a Reply-AI. Desde este momento el seller **ya no debe estar activo en el pipeline de respuesta de Yobot** (por eso `full`, no `mirror`).

### Paso 2 — Crear la cuenta en Reply-AI (`bridge_register`)

Yobot (o el operador) llama a `POST /api/bridge/register` (autenticado con HMAC). Reply-AI ejecuta `setup_account_channels`, que provisiona **todo** lo necesario:

- User + Account (con `custom_attributes` por defecto) y vínculo como administrador.
- 2 equipos: "Pre-Venta" y "Post-Venta".
- 3 inboxes API: "Pre-venta (MercadoLibre)", "Post-venta (MercadoLibre)" y "Reclamos (MercadoLibre)".
- 14 labels: 9 del ciclo IA/post-venta (`procesando_con_ia`, `respondida_con_ia`, `atencion-humana`, `esperando_respuesta_manual`, `bot-procesando`, `mensajeria-bloqueada`…) + 5 de reclamos (`reclamo-abierto`, `reclamo-mediacion`, `reclamo-cerrado`, `reclamo-pendiente-accion`, `reclamo-derivado`).
- 4 webhooks hacia n8n (salida manual pre-venta, post-venta entrada/salida, reclamos salida).
- 3 Dashboard Apps: Venta ML, Reclamo ML, Producto ML.
- Si `REPLY_RECEIVE_ONLY=true`: la cuenta se marca `receive_only` automáticamente.
- Dispara la **sincronización de configuración** desde Yobot (ver Paso 4).

> Las cuentas creadas a mano (no vía `bridge_register`) pueden backfilleándose con `rails reply_ai:backfill_claims_inbox` (idempotente, crea inbox + labels + Dashboard Apps).

### Paso 3 — Credenciales de MercadoLibre (`meli_credentials`)

Tres variantes según el perfil:

**Perfil MIGRADO** (Reply ejecuta directo en ML con el token del seller):
1. Copiar de la BD de Yobot (Mongo) los tokens vigentes del seller (`mercadolibre.authorization.access_token` / `refresh_token`).
2. Crear/actualizar la credencial: `status = 'active'`, `bridge_enabled = true`, con esos tokens.
3. Asegurar `YOBOT_ML_APP_ID` / `YOBOT_ML_SECRET_KEY` en el `.env` de Reply (reinicio de rails + sidekiq) — el `TokenRefreshWorker` refrescará con esas credenciales (ruta "migrado (app Yobot)").
4. Limpiar credenciales bridge residuales de la cuenta (`status = 'bridge'` con otro `ml_user_id` → `inactive`).

**Perfil bridge puro**: `status = 'bridge'`, `bridge_enabled = true` (placeholders de token; el refresh es vía `/api/bridge/refresh-token`).

**Perfil nativo** (solo si el seller puede autorizar la app de Reply): OAuth normal por `/callback`.

**Discriminador único**: `ReplyAi::MeliApi.for(account)` resuelve por la **credencial primaria** (`order(:id).first`) — primaria `bridge` → `BridgeApi`, `active` → `MeliApi`. El gating es automático en Rails **y** en los 6 workflows de n8n (ramas bridge/nativo en todos los nodos de envío).

### Paso 4 — Migrar la configuración del seller

La configuración de Yobot se traduce a `Account.custom_attributes` con `BridgeConfigMapper`:

| Desde Yobot | Hacia Reply-AI |
|-------------|---------------|
| `config.prompts.*` (14 campos) | `custom_attributes.config.prompts` |
| `config.chatGPTEnabled` | `config.chatGPTEnabled` |
| `config.responseDelay` | `config.response_delay` |
| `config.scheduledMode` | `config.scheduledMode` |
| `config.postVentaChatGPTEnabled` / `postVentaResponseDelay` / `postVentaScheduledMode` | `config.post_venta_ia.*` (enabled, delay, scheduledMode) |
| Saludos por tienda | `meli_official_stores.custom_greeting` |
| Automatización de reclamos | `config.automatizacion_reclamos` (+ `delayRespuesta`) |
| `requireRagOrConfidence` / `confidenceByCategory` | Control de confianza pre-venta |

**Cómo ejecutarla** (validado end-to-end con sync real):
- Automática: `bridge_register` dispara `BridgeConfigSyncWorker`.
- Manual: botón "Sincronizar config de Yobot" en el dashboard, o `rails reply_ai:sync_bridge_config[<account_id>]`.
- El endpoint `sync-config` de Yobot responde 200 con firma real.

### Paso 5 — Migrar los documentos RAG

Los chunks viven en **Supabase de Yobot** (tabla `{ml_user_id}` para pre-venta y `pv_{ml_user_id}` para post-venta, con `embedding vector(1536)` del modelo `text-embedding-3-small`).

Proceso (`YobotRagMigrator`, implementado):

1. Desde el dashboard → Documentos → botón **"Importar documentos de Yobot"** (`POST /dashboard/migrate-rag-pre` y `/dashboard/migrate-rag-post`).
2. El worker lee Supabase paginado (500/petición) → mapea niveles (`global→global`, `category→category_id`, `product→item_id`) → inserta en `reply_ai_documents` / `reply_ai_pv_documents` con `source: 'yobot'` e idempotencia por `yobot_chunk_id` (index único por cuenta — re-ejecutar no duplica).
3. Por cada chunk notifica el webhook de embeddings (`N8N_EMBEDDING_WEBHOOK_URL` / `N8N_PV_EMBEDDING_WEBHOOK_URL`) para **regenerar el embedding con el modelo de Reply** (`text-embedding-ada-002`) — los vectores de Yobot usan otro modelo y no se reutilizan. Throttling de 0.2s por chunk.
4. Estado visible en `custom_attributes.syncing_rag_pre/post`.

**Rollback**: borrar las filas con `source = 'yobot'` y reimportar.

### Paso 6 — Sincronizar productos y tiendas

`MeliSyncProductsWorker` + `MeliSyncOfficialStoresWorker` — en cuentas bridge ejecutan vía `BridgeApi` (`sync-products`, `sync-official-stores` en Yobot, que hace el llamado a ML con su token). **Los productos NO se migran**: Reply-AI los sincroniza solo desde ML. Se disparan en el OAuth/registro o por botón en el dashboard.

### Paso 7 — Verificar el flujo (todavía en receive-only)

1. **Estado del bridge**: `GET /api/bridge/seller/<ml_user_id>` → `{ bridged: true, account_id, status }`.
2. Disparar 1 pregunta + 1 mensaje post-venta + 1 reclamo + 1 venta reales de la cuenta de prueba.
3. Verificar en Chatwoot: conversaciones creadas en los inboxes correctos, **respuestas del bot como nota privada** (no mensajes públicos), conversaciones abiertas, labels aplicados.
4. Verificar **cero outbound**: en los logs de ejecución de n8n no deben aparecer llamadas a `api.mercadolibre.com` ni a `YOBOT_BRIDGE_URL` en los nodos de envío; las acciones de reclamo responden `receive_only: true`.
5. En Yobot: `GET /api/debug/bridge-logs?ml_user_id=<id>` → forwards con status 200 (si hay `BridgeLog`).
6. Para perfil MIGRADO: en los logs de Rails **no debe aparecer `/bridge/sign`** (ejecución directa) y el refresh debe mostrar la ruta "migrado (app Yobot)"; forzar refresh pasando `expires_at` a valor vencido.
7. Probar `execute-claim-action` (`get_claim`, `get_messages`) y `sync-products` con firma real.

### Paso 8 — Salir del modo seguro

1. Yobot queda en `mode: "full"` (ya en Paso 1).
2. Reply-AI: `.env` → `REPLY_RECEIVE_ONLY=false` → reiniciar `rails`, `sidekiq`, `n8n-main`, `n8n-worker`.
3. Desmarcar la cuenta si quedó `receive_only` (borrar la clave de `custom_attributes`).
4. Repetir una pregunta/mensaje reales → la respuesta debe llegar **al comprador en MercadoLibre**.

## 4. Qué se migra y qué no

**Sí se migra:**

| Dato | Mecanismo |
|------|-----------|
| Cuenta, usuario, inboxes, labels, webhooks, Dashboard Apps | `bridge_register` + `setup_account_channels` |
| Tokens OAuth del seller | Copia desde Mongo de Yobot → `meli_credentials` |
| Configuración (prompts, delays, schedules, saludos, automatización) | `BridgeConfigMapper` / sync-config |
| Documentos RAG pre y post-venta | `YobotRagMigrator` (Supabase → Reply, embeddings regenerados) |
| Catálogo de productos y tiendas | Sync desde ML (`sync-products` / `sync-official-stores`) |

**NO se migra (Reply-AI lo genera por su cuenta o no aplica):**

| Dato | Razón |
|------|-------|
| Productos | Los sincroniza `MeliSyncProductsWorker` desde ML |
| Ventas | Se crean al recibir el primer webhook post-venta |
| Preguntas/historial de conversaciones | Quedan en Yobot; las conversaciones nuevas nacen en Chatwoot |
| Uso histórico de OpenAI | Reply-AI trackea el suyo propio |
| Suscripción PayPal de Yobot | Reply-AI no implementa pagos (decisión D2) |

## 5. Automatización pendiente: `YobotMigrator`

Está diseñado (§18.7.8) pero **aún no implementado** — hoy la migración se hace con los pasos manuales/semiautomáticos anteriores. El script planeado (`custom/lib/reply_ai/migration/yobot_migrator.rb`) haría por seller:

1. Leer el usuario de MongoDB (`mercadolibre.user.user_id`).
2. Crear User + Account vía Platform API (idempotente: saltar si ya migró).
3. Crear `MeliCredential` con tokens encriptados.
4. Migrar la configuración (14 prompts + flags + delays).
5. Migrar los documentos RAG (+ embeddings).

Pasos 1, 2, 4 y 5 ya existen como piezas sueltas (`bridge_register`, copia de credenciales, `BridgeConfigMapper`, `YobotRagMigrator`); el orquestador es lo que falta.

## 6. Desactivación y rollback

- **Deshabilitar bridge para un seller**: `MeliCredential.find_by(ml_user_id: <id>).update(bridge_enabled: false)` → el próximo webhook lo procesa Yobot con su pipeline normal (si vuelve a `mirror`/`enabled` en Mongo).
- **Rollback de perfil MIGRADO**: credencial → `status: 'bridge'` (+ flag en Yobot). Ojo: tras un refresh hecho por Reply, el `refresh_token` de Yobot queda obsoleto (rotación de ML) — habría que recopilar tokens frescos.
- **Rollback de RAG**: borrar filas `source = 'yobot'`.
- **Cuentas nuevas sin riesgo**: sin `BRIDGE_SECRET` en Yobot, nada se bridgea.

## 7. Troubleshooting

| Problema | Causa probable | Solución |
|----------|---------------|----------|
| Yobot no forwardea | `BRIDGE_SECRET` vacío o distinto | Verificar que es idéntico en ambos `.env` |
| `isBridged()` → false | `REPLY_AI_BRIDGE_URL` mal o Reply inaccesible | `curl` al endpoint `/api/bridge/seller/:id` desde el servidor de Yobot |
| Reply responde 401 | HMAC no coincide | El body debe firmarse y enviarse byte a byte igual (JSON sin espacios extra) |
| 401 en `/api/bridge/refresh-token` | Firma calculada sobre body re-serializado | Firmar el body crudo (incidente resuelto 2026-08-06 con verificación sobre el body crudo) |
| Doble respuesta / conversaciones duplicadas | Yobot en `mode: "mirror"` con seller migrado | Pasar a `mode: "full"` (incidente 2026-08-06) |
| `bridge_question` → 500 | Cuenta sin inbox pre-venta | Crear el inbox "Pre-venta (MercadoLibre)" (o backfill) |
| Refresh de migrado falla | Faltan `YOBOT_ML_APP_ID/SECRET` | Setearlas y reiniciar rails + sidekiq |
| GET a ML → 403 | Bug corregido: los GET enviaban `body: "null"` | Ya resuelto en `MeliApi#request` (solo POST llevan body) |
| Productos no sincronizan | Cuenta bridge sin `sync-products` en Yobot | Probar el endpoint con firma real |
| n8n no procesa | Webhook mal configurado o n8n caído | Verificar `N8N_*_WEBHOOK_URL` y estado de n8n |

## 8. Cronología recomendada del piloto

1. Setear vars en ambos lados + reiniciar rails/n8n.
2. Marcar el seller de prueba en Yobot (`bridge.enabled`, mode `mirror` solo para la primera recepción; luego `full`).
3. `bridge_register` → verificar cuenta creada con todo provisionado.
4. Credenciales + config + RAG + productos.
5. Disparar pregunta, mensaje, reclamo y venta reales → auditar en receive-only.
6. Pass checks de §7 (cero outbound, refresh OK, logs sin `/bridge/sign` para migrado).
7. Apagar `REPLY_RECEIVE_ONLY` → primera respuesta real al comprador.
8. Recién entonces migrar sellers reales, uno por uno.
