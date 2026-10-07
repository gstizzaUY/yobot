# Funcionalidad Pre-Venta — Respuesta IA a preguntas de MercadoLibre

> Documento fuente para NotebookLM. Detalle del flujo de pre-venta de Reply-AI (Chatwoot v4.18.0).

## 1. Qué es la pre-venta

La pre-venta atiende las **preguntas que los compradores hacen sobre productos antes de comprar** en MercadoLibre ("¿llega a Montevideo?", "¿talla 40?", "¿tiene garantía?"). Un bot con IA responde automáticamente usando la base de conocimiento RAG del vendedor (documentos organizados por producto, categoría o globales), con delays configurables y horarios de atención. Si el vendedor activa el control de confianza y la IA no tiene información suficiente, la pregunta se **retiene** para que un humano la resuelva con la sugerencia de la IA.

Todo vive en el inbox **"Pre-venta (MercadoLibre)"** de Chatwoot: cada pregunta genera (o reutiliza) una conversación donde el agente humano puede ver el intercambio y tomar el control.

## 2. Provisionamiento del flujo

Al registrarse el vendedor (`/signup`) o al registrar la cuenta por bridge, se crea automáticamente:

- Inbox API "Pre-venta (MercadoLibre)".
- Equipo "Pre-Venta" con el usuario.
- Labels del ciclo IA: `procesando_con_ia`, `respondida_con_ia`, `respondida_manualmente`, `bot-procesando`, `atencion-humana`, `esperando_respuesta_manual`, `esperando_tiempo_retraso_programado`, `atencion-pendiente-accion`, `mensajeria-bloqueada`, entre otras.
- Webhooks de salida hacia n8n (flujo manual y flujo IA).
- Dashboard App "Producto ML" para ver la ficha del producto en la conversación.

## 3. Flujo completo de una pregunta (workflow `questions_main`)

1. **Webhook de MercadoLibre**: ML notifica una nueva pregunta → llega al webhook de `questions_main` en n8n (también pueden entrar forwards desde Yobot vía `POST /api/bridge/question`).
2. **Resolución de credenciales**: n8n consulta `meli_credentials` y `accounts.custom_attributes` (prompts, delays, horarios, flags de confianza, `receive_only`) — con orden determinista (`ORDER BY id ASC`) para cuentas con varias credenciales.
3. **Deduplicación**: la pregunta se registra en `meli_questions` (clave = `question_id`); si ya existe, el flujo se detiene (idempotencia).
4. **Conversación en Chatwoot**: se busca/crea el contacto y la conversación en el inbox pre-venta (la Platform API de Chatwoot). En cuentas bridge la conversación ya la creó `bridge_question` y el flujo la reutiliza.
5. **Contexto del producto**: se obtiene el item/categoría de la pregunta (`item_id`, `category_id`) para elegir los documentos RAG relevantes.
6. **Búsqueda RAG**: n8n llama a `POST /rag/search` de Rails con el embedding de la pregunta; Rails busca en `reply_ai_documents` con pgvector (cosine distance) filtrando por cuenta y nivel (global / categoría / subcategoría / producto).
7. **Generación de respuesta**: OpenAI responde con el system prompt configurado por el vendedor + el contexto RAG recuperado.
8. **Control de confianza** (si está activo, ver §5): si la IA detecta que no tiene información, responde con el marcador `[SIN_INFORMACION]` → la pregunta se **retiene** y no se envía a ML.
9. **Delay programado**: si hay delay configurado, el flujo espera (`Wait delay`) antes de responder — simula comportamiento humano.
10. **Envío a MercadoLibre**: nodo de envío (Code node con rama nativa/bridge):
    - **Nativo**: `POST /questions/{id}/answer` directo a la API de ML.
    - **Bridge/Migrado**: `POST {YOBOT_BRIDGE_URL}/api/bridge/send-answer` con firma HMAC.
11. **Espejo en Chatwoot**: la respuesta se publica como mensaje en la conversación (`source: n8n_ai`) con los labels del ciclo (`respondida_con_ia`), y la conversación se cierra.
12. **Respuesta manual** (si el agente responde primero): el webhook de salida dispara `questions_manual`, que reenvía el texto del agente a ML/Yobot y aplica `respondida_manualmente`.

### Gates que pueden detener la respuesta

- **`GET /bot_active`**: consulta central si el bot está activo — respeta el toggle global y el horario (schedule) del vendedor. Apagado → no se responde con IA.
- **`GET|POST /conversation_ai_gate`** (kill-switch por conversación): la IA no interviene si la conversación está asignada a un humano, tiene el label `atencion-humana`, está resuelta, o la IA está deshabilitada.
- **Modo receive-only**: la respuesta se genera igual pero se espeja como **nota privada** en Chatwoot; no se envía a ML y la conversación queda abierta.

### Ciclo de labels de pre-venta

`procesando_con_ia` / `bot-procesando` mientras genera → `respondida_con_ia` al enviar → o `esperando_respuesta_manual` si el bot está apagado/horario fuera → `respondida_manualmente` cuando un humano responde → `atencion-humana` cuando se deriva a una persona (por ejemplo por el control de confianza o el gate).

## 4. Base de conocimiento RAG (pre-venta)

### Almacenamiento

- Tabla `reply_ai_documents`: `account_id`, `level` (`global` | `category` | `sub` | `product`), `reference_id` (id de categoría o producto), `content`, `embedding vector(1536)`, `source`.
- Búsqueda con **pgvector** (`neighbors`, cosine distance) en `ReplyAiDocument.search_for(account:, embedding:, reference_ids:, limit:)`.

### Formas de alimentarla

1. **Subida de documentos** (`POST /dashboard/upload`): PDF/DOCX/TXT. Un worker extrae el texto (Apache Tika para PDF/DOCX) y notifica a n8n para generar el embedding con OpenAI (`text-embedding-ada-002`) vía el webhook `embedding_generator`.
2. **Importación masiva** (`POST /dashboard/bulk-import`): archivos CSV o XLSX (detección de encoding y separador) → `BulkImportWorker` crea un documento por fila y dispara los embeddings en lote.
3. **Migración desde Yobot** (`POST /dashboard/migrate-rag-pre`): `YobotRagMigrator` lee los chunks desde Supabase de Yobot (paginado), los inserta con `source: 'yobot'` e idempotencia por `yobot_chunk_id`, y re-genera los embeddings con el modelo de Reply (los vectores de Yobot usan otro modelo, no son reutilizables). Requiere `SUPABASE_URL` / `SUPABASE_SERVICE_KEY`.

Los documentos se gestionan desde el dashboard `/dashboard` (tab Pre-Venta → Documentos), con tabla por producto, subida por nivel (global/categoría/producto) e informe de confianza.

## 5. Control de confianza (retención por falta de información)

Implementación del requisito `requireRagOrConfidence` de Yobot: si la IA no tiene información suficiente, **no arriesga una respuesta** — retiene la pregunta y deja la sugerencia para el agente.

- **Configuración** (dashboard Pre-venta → Ajustes del bot → "Control de confianza"):
  - `requireRagOrConfidence` (toggle global).
  - `confidenceByCategory` (mapa `category_id → bool`): sobrescribe el global por categoría (master/sub).
- **Flujo**: el prompt de OpenAI incluye el bloque condicional; si `require_conf` está activo y la información no alcanza, la IA responde exactamente `[SIN_INFORMACION] <sugerencia>`. El workflow detecta el marcador y:
  1. Marca la pregunta en `meli_questions` con `status = UNANSWERED` y `retained_due_lack_of_info = true`, guardando `suggested_answer` (sin el marcador).
  2. Crea una **nota privada** en la conversación con la sugerencia de la IA.
  3. Aplica el label `esperando_respuesta_manual`.
  4. **No envía nada a MercadoLibre** (la pregunta queda sin responder para el comprador hasta que un humano actúe).
- **Informe**: panel "Preguntas retenidas" en Informes → Pre-Venta (`GET /dashboard/confidence-report`): pregunta, producto, sugerencia, fecha y conversación.
- **Rollback**: desactivar el toggle (las preguntas nuevas vuelven al flujo normal).

## 6. Configuración disponible para el vendedor (dashboard `/dashboard`)

- **Ajustes del bot**: prompt del sistema, delay de respuesta, horario de atención (schedule), toggle global del bot, control de confianza (global + por categoría).
- **Productos**: catálogo sincronizado desde ML (tabla ordenable con SKU, precio, ventas), estado de sincronización.
- **Documentos**: gestión RAG por nivel + importación masiva CSV/XLSX + botón de migración desde Yobot.
- **Tiendas oficiales**: saludo personalizado por tienda (`custom_greeting`) + refresh de sync.
- **Auto-cierre**: configuración nativa de Chatwoot (`auto_resolve_after`) para conversaciones inactivas.
- **Syncs**: refresh de tokens, sync de productos/tiendas, sync de config desde Yobot (cuentas bridge).

## 7. Trabajos de fondo relacionados

- **MeliSyncProductsWorker**: pagina la API de ML (`/users/{id}/items/search` + `/items?ids=`), crea/actualiza `meli_products` (~30 campos) y sincroniza categorías; actualiza `custom_attributes.syncing_products` para el polling del dashboard.
- **TokenRefreshWorker** (cada 5 min): refresca tokens próximos a expirar. Tres rutas: nativo (app Reply), migrado (credenciales de la app de Yobot), bridge (vía `/api/bridge/refresh-token`).
- **MeliSyncOfficialStoresWorker**: tiendas oficiales del vendedor.

## 8. Variaciones por perfil de cuenta

| Aspecto | Nativo | Migrado | Bridge |
|---------|--------|---------|--------|
| Entrada de la pregunta | Webhook directo de ML | Forward de Yobot (`/api/bridge/question`) | Forward de Yobot |
| Envío de la respuesta | API de ML directa | API de ML con token del seller | `send-answer` vía bridge (HMAC) |
| Datos del item/comprador | Fetch directo a ML | Fetch directo (token app Yobot) | Datos del forward (si falta → error claro) |
| `receive_only` | Gate en n8n | Gate en n8n | Gate en n8n |

## 9. Datos clave en base de datos

- `meli_questions`: dedupe (`question_id`), vínculo con la conversación (`cw_conversation_id`), retención (`retained_due_lack_of_info`, `suggested_answer`), idempotencia de respuestas IA (`ai_answered`).
- `reply_ai_pre_memory`: memoria por `session_id` — mantiene el contexto entre varias preguntas del mismo cliente (usada por el workflow `questions_main`).
- `accounts.custom_attributes`: toda la configuración del bot (prompts, delays, schedule, flags de confianza).
