# Reply-AI — Visión General de la Aplicación

> Documento fuente para NotebookLM. Versión de referencia: Chatwoot v4.18.0 + Reply-AI (actualizado 2026-10-06).

## 1. Qué es Reply-AI

Reply-AI es una plataforma de atención al cliente y automatización con inteligencia artificial para vendedores de **MercadoLibre**. Está construida como una capa propia sobre **Chatwoot** (la plataforma open-source de soporte omnicanal) y automatiza la comunicación con compradores en MercadoLibre: responde preguntas de pre-venta, mensajes de post-venta y reclamos, utilizando IA con técnicas RAG (Recuperación Aumentada por Generación) sobre la información del propio vendedor.

En esencia, un comprador escribe en MercadoLibre → la plataforma recibe la notificación → genera una respuesta con IA usando el conocimiento del vendedor → y devuelve la respuesta al comprador en MercadoLibre. Cuando se necesita una persona, la conversación queda en el chatwoot para que un agente humano responda desde allí.

## 2. Stack Tecnológico

| Capa | Tecnología |
|------|-----------|
| Backend | Ruby on Rails 7.2.3.1 / Ruby 3.4.4 |
| Frontend | Vue 3 (Composition API) + Vite, Tailwind CSS |
| Base de datos | PostgreSQL 16 + pgvector (búsqueda vectorial) |
| Cache / PubSub | Redis |
| Jobs de fondo | Sidekiq 7 |
| Automatización / flujos de IA | n8n 2.6.4 (modo cola: n8n-main + n8n-worker) |
| Modelos de IA | OpenAI (chat, embeddings `text-embedding-ada-002`, visión, Whisper) |
| Extracción de texto PDF | Apache Tika |
| Infraestructura dev | Docker Compose |
| Infraestructura producción | Docker Swarm vía Easypanel |
| CI/CD | GitHub Actions → GHCR (imagen) → webhook de Easypanel |

## 3. Arquitectura General

La aplicación tiene tres capas principales:

1. **Chatwoot core** (`app/`, `lib/`, `enterprise/`): la plataforma upstream — conversaciones, inboxes, agents, reports, widget, dashboard Vue. Se actualiza haciendo merge de los tags oficiales de Chatwoot **sin modificar nunca sus archivos**.
2. **Custom layer Reply-AI** (`custom/`): todo el código propio — modelos MercadoLibre, controlador principal (LandingController, ~2400 líneas), workers Sidekiq, vistas ERB, migraciones y librerías. Vive 100% en `custom/` + 7 initializers en `config/initializers/`.
3. **Flujos de IA en n8n** (`n8n/`): 9 workflows JSON que implementan los pipelines de IA (preguntas, post-venta, órdenes, reclamos, embeddings) y se comunican con Rails por webhooks y con MercadoLibre/Yobot por HTTP.

### Diagrama de flujo de negocio

```
Cliente pregunta en MercadoLibre
  → Webhook de ML notifica a n8n
    → n8n consulta la BD de Chatwoot (credenciales, docs RAG, custom_attributes)
      → n8n genera respuesta con OpenAI + contexto RAG
        → n8n crea/actualiza la conversación en Chatwoot (Platform API)
          → Si aplica: envía la respuesta automática a MercadoLibre (o Yobot bridge)
          → Si necesita humano: el agente responde desde Chatwoot
            → n8n detecta la respuesta humana y la reenvía a MercadoLibre
```

### Cómo el custom layer se extiende sin tocar el core

Chatwoot soporta nativamente un directorio `custom/`: al existir, `ChatwootApp.extensions` devuelve `['enterprise', 'custom']`. Reply-AI aprovecha ese mecanismo con initializers propios:

- **Modelos, controladores y librerías**: registrados en el autoloader con `Zeitwerk::Loader#push_dir`.
- **Vistas**: `ActionController::Base.prepend_view_path`.
- **Rutas**: `Rails.application.routes.prepend` (29+ rutas propias: `/dashboard`, `/rag/search`, `/api/bridge/*`, etc.).
- **Migraciones**: un "schema guard" agrega `custom/db/migrate/` y auto-aplica pendientes al arrancar.
- **Asociaciones**: `Account.class_eval` inyecta los `has_many` de los modelos custom.
- **Middleware**: `InjectCssMiddleware` inyecta CSS/JS en el dashboard para simplificar la UI de agentes.
- **Extensión de clases core**: overrides en `custom/lib/custom/` (por ejemplo el blindaje de `ChatwootHub`).

Un script de verificación (`custom/verify.rb`, 59 checks en 6 categorías) valida la integridad de todo el custom layer: directorios, autoloading de 24+ clases, 9 tablas en BD, schema guard, initializers y asociaciones.

## 4. Los tres modos de operación

Cada cuenta (vendedor) tiene hasta tres inboxes de MercadoLibre, creados automáticamente en el registro:

| Inbox | Flujo |
|-------|-------|
| **Pre-venta (MercadoLibre)** | Preguntas de compradores sobre productos → IA responde con RAG pre-venta |
| **Post-venta (MercadoLibre)** | Mensajes post-compra (envíos, reclamos de entrega, seguimiento) → IA responde con RAG post-venta y máquina de estados |
| **Reclamos (MercadoLibre)** | Reclamos, devoluciones y cambios → bandeja de gestión con automatización y agente IA |

## 5. Perfiles de cuenta: cómo llegan los eventos de MercadoLibre

Existen tres perfiles de integración, discrimados por la credencial OAuth (`meli_credentials`):

| Perfil | Notificaciones | Ejecución en ML | Refresh del token |
|--------|----------------|------------------|-------------------|
| **Nativo** | MercadoLibre → Reply directo | Reply directo (app propia de ML) | App de Reply |
| **Migrado** (de Yobot, sin re-autorizar) | Yobot → Reply (forward) | Reply directo con el token del seller (app de Yobot) | Credenciales de la app de Yobot (`YOBOT_ML_APP_ID/SECRET`) |
| **Bridge** (Yobot proxy) | Yobot → Reply (forward) | Vía Yobot (API del bridge con firma HMAC) | Vía endpoint `/api/bridge/refresh-token` |

**Yobot** es la app legacy (Node.js/MongoDB) en producción con sellers reales; el bridge permite que esos sellers usen Reply-AI sin volver a autorizar su cuenta en MercadoLibre. La autenticación entre Yobot y Reply-AI usa **HMAC** (`BRIDGE_SECRET` + header `X-Bridge-Signature` verificado sobre el body crudo).

Adicionalmente existe el **modo receive-only** (bandera `REPLY_RECEIVE_ONLY=true` por entorno + marca `receive_only` por cuenta): la ingesta funciona completo (todo llega a Chatwoot) pero **nada se envía** a MercadoLibre — las respuestas del bot quedan como notas privadas y las acciones de reclamos responden "bloqueado". Es el modo de testing operacional antes de habilitar el envío real.

## 6. Componentes principales del custom layer

### LandingController (`custom/app/controllers/landing_controller.rb`)

El controlador central (~2400 líneas) con todos los endpoints propios:

- **Públicos**: landing `/`, `/signup` (registro que provisiona la cuenta completa), `/callback` (OAuth de MercadoLibre), `/go_to_chats` (SSO al dashboard).
- **Dashboard de configuración** `/dashboard`: productos pre-venta, documentos RAG, ajustes del bot (prompts, delays, horarios), post-venta, reclamos, importación masiva.
- **Endpoints para n8n**: `/bot_active` (¿debe responder el bot?), `/conversation_ai_gate` (kill-switch de IA), `/rag/search` y `/rag/pv_search` (búsqueda vectorial pre/post-venta), todos protegidos con `x-internal-secret`.
- **Bridge Yobot**: `/api/bridge/*` (question, message, order, claim, register, manual-response, message-status, sync-conversation-reads, sign).
- **Dashboard Apps**: `/dashboard/sale-panel`, `/dashboard/product-panel`, `/dashboard/claim-panel` + sus endpoints JSON.

### Modelos y base de datos custom (10 tablas)

| Tabla | Contenido |
|-------|-----------|
| `meli_credentials` | Tokens OAuth de ML por cuenta (status, bridge_enabled) |
| `meli_products` | Catálogo de productos ML (~30 columnas, JSONB de fotos/atributos) |
| `meli_categories` | Jerarquía de categorías ML |
| `meli_official_stores` | Tiendas oficiales (con saludo custom por tienda) |
| `meli_orders` | Órdenes post-venta + campos de ciclo de vida de la conversación |
| `meli_questions` | Deduplicación de preguntas + retención por falta de información |
| `meli_claims` | Reclamos (etapa, estado, acciones pendientes del agente, timeline) |
| `reply_ai_documents` / `reply_ai_pv_documents` | Documentos RAG con embeddings vectoriales (pgvector) |
| `reply_ai_pre_memory` | Memoria de sesiones pre-venta para mantener contexto |

### Workers Sidekiq (12+)

- **TokenRefreshWorker** (cada 5 min): refresca tokens OAuth de ML; para cuentas migradas usa las credenciales de la app de Yobot.
- **MeliSyncProductsWorker / MeliSyncOfficialStoresWorker**: sincronizan catálogo y tiendas desde ML.
- **DocumentProcessorWorker / PvDocumentProcessorWorker**: procesan documentos RAG subidos (extracción de texto con Tika, notificación a n8n para embedding).
- **BulkImportWorker**: importa documentos desde CSV/XLSX (gem `roo`).
- **ClaimsSyncWorker / ClaimAgentWorker / ClaimAutomation**: motor de reclamos (ver documento de post-venta).
- **MessageReadSyncWorker** (cada 1 min): sincroniza los ✓✓ azules (estado "leído") de los mensajes post-venta.
- **BridgeConfigSyncWorker**: sincroniza la configuración del seller desde Yobot.
- **YobotRagMigrator**: migra los documentos RAG de Yobot (Supabase) a Reply-AI re-generando embeddings.

### UI embebida: Middleware y paneles

- **InjectCssMiddleware**: simplifica el dashboard para agentes (oculta menús, macros, etiquetas; en inboxes MercadoLibre oculta emoji/adjuntos/micrófono; inyecta el link "Configuración Bot" y detecta el inbox activo).
- **Dashboard Apps (3 paneles embebidos)** en la barra lateral de cada conversación: **Venta ML** (ficha de la venta: producto, comprador, pago, envío), **Producto ML** (ficha del item) y **Reclamo ML** (detalle, acciones, chat, evidencias, timeline). Se comunican con el iframe por `postMessage` (evento `appContext`).

## 7. Capa n8n: los 9 workflows

| Workflow | Función |
|----------|---------|
| `questions_main` | **Pre-venta**: recibe preguntas de ML, crea conversación, busca RAG, genera y envía la respuesta |
| `questions_manual` | Reenvía a ML la respuesta que un humano escribe en Chatwoot (pre-venta) |
| `orders_main` | Óredenes: escribe `meli_orders` y envía el mensaje inicial de post-venta |
| `postsale_main` | **Post-venta IA**: pipeline completo (idempotencia, sentimiento, ciclo de vida, RAG, clasificación de intención, respuestas, labels, ticks de lectura) |
| `postsale_outbound` | Respuestas humanas de Chatwoot → ML (post-venta) |
| `claims_outbound` | Mensajes de la bandeja de reclamos → ML/Yobot |
| `embedding_generator` / `pv_embedding_generator` | Generan los embeddings con OpenAI para los docs RAG pre y post-venta |
| `postsale_webhook` | Entrada/webhook de los mensajes post-venta hacia `postsale_main` |

Cómo interactúa n8n con Chatwoot: **nodos PostgreSQL** para leer directo (`meli_credentials`, `custom_attributes` de la cuenta, `meli_orders`, `meli_questions`, `meli_official_stores`) y la **Platform API** de Chatwoot para crear contactos, conversaciones, mensajes, cambiar estados y manejar labels.

## 8. Provisionamiento de cuentas (signup)

El registro (`/signup`) crea todo automáticamente vía Platform API:

1. Usuario + Cuenta + login Devise → redirección al OAuth de MercadoLibre.
2. 2 equipos (Pre-Venta, Post-Venta), 3 inboxes API (Pre-venta, Post-venta, Reclamos).
3. 14 labels (9 de ciclo IA/post-venta + 5 de reclamos).
4. 4 webhooks hacia n8n (salida manual pre-venta, post-venta entrada/salida, reclamos salida).
5. 3 Dashboard Apps (Venta ML, Reclamo ML, Producto ML).
6. Configuración inicial de `custom_attributes` (prompts, delays, etc.).

Tras el OAuth (`/callback`): se guardan los tokens, se detecta el país del vendedor y se disparan los syncs de productos y tiendas.

## 9. Seguridad y operación

- **Blindaje enterprise (§22)**: el código enterprise de Chatwoot exige licencia; overrides en `custom/` hacen que `ChatwootHub.pricing_plan` devuelva `enterprise` y que los gates premium dependan solo de existir el overlay `enterprise/` — inmune a updates y a la BD. Verificado en v4.18.0 (`self_hosted_paid? = true`).
- **Secrets**: `INTERNAL_API_SECRET` (n8n → Rails), `BRIDGE_SECRET` (HMAC con Yobot), OAuth de ML.
- **CI/CD**: cada push a `master` construye la imagen (`docker/Dockerfile`) y la sube a GHCR, luego dispara el deploy de Easypanel por webhook.
- **Healthcheck**: la imagen define `HEALTHCHECK` sobre `/api` (los tasks wedged de swarm se reemplazan solos).
- **Actualizaciones de Chatwoot**: merge del tag de release (no `develop`), regeneración de `schema.rb`, verify 59 checks, con convención de migraciones custom en rango `2099...` para evitar colisiones de timestamp.

## 10. Estados de validación

- Todas las fases del plan (1: post-venta IA, 2: reclamos, 3: bridge) están **implementadas**; quedan pendientes de validación con sellers reales y algunas tareas operativas — detalladas en el documento *Funcionalidades Futuras*.
- Producción (2026-10-06): Chatwoot v4.18.0 desplegado, verify 59/59 ✓, migraciones al día, blindaje activo.
