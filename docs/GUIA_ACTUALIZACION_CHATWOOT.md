# Guía de actualización de Chatwoot — análisis de impacto y alineación

> **Propósito**: documento vivo para actualizar Chatwoot sin romper la capa Reply-AI / MercadoLibre.
> **Última revisión**: 2026-10-27
> **Estado del repo**: Chatwoot **v4.18.0**
> **Última versión analizada**: **v4.19.1** (análisis hecho el 2026-10-27; **no aplicada todavía**)
> **Referencias**: `TECHNICAL.md` §15 y §24, `docs/PANELES_DASHBOARD_APPS.md`, `docs/REQUERIMIENTOS_YOBOT.md`, `AGENTS.md`.

---

## 0. Regla de oro

Un upgrade **no termina** cuando el merge compila. Termina cuando:

1. El tag de release está mergeado.
2. Las migraciones corren y el schema conserva las tablas custom.
3. `custom/verify.rb` y los smokes críticos pasan.
4. Producción reporta la versión nueva.
5. **La documentación quedó actualizada**: `TECHNICAL.md`, esta guía y los documentos de las áreas afectadas.

Si cualquiera de esos puntos falta, el upgrade está incompleto.

---

## 1. Principios

- **Mergear siempre el tag de release** (`vX.Y.Z`), nunca `upstream/develop`.
- **No tocar** `app/`, `lib/` ni `enterprise/` para código Reply-AI. Todo lo custom vive en `custom/`, initializers custom y `n8n/`.
- **No usar** `db:reset`, `db:schema:load`, `db:drop` ni `db:create` en una base con datos.
- **`custom/verify.rb` es estructural, no funcional**: valida autoloading, tablas, migraciones e initializers, pero no prueba flujos. Siempre complementarlo con smoke tests. Cobertura actual: 9 tablas (falta `reply_ai_pre_memory`) y 6 asociaciones (faltan `meli_orders` y `meli_official_stores`); no confundir “verify OK” con “todo cubierto”.
- **El deploy de producción es un push/merge a `master`**: GitHub Actions construye la imagen y dispara los webhooks de Easypanel para app y worker. Un push a una rama no despliega.
- **n8n no se despliega por git**: los JSON del repo son respaldo/versión de referencia; producción n8n se gestiona aparte.
- **Preservar los cambios custom del Dockerfile**: `NODE_OPTIONS --max-old-space-size=6144` y el `HEALTHCHECK` con fallback a SidekiqAlive `:7433`.

---

## 2. Qué mirar de entrada (pre-flight)

Antes de tocar una rama, revisar **todos los tags intermedios**, no solo el target. Ejemplo: de `v4.18.0` a `v4.19.1` hay que leer `v4.19.0` y `v4.19.1`.

### 2.1 Checklist rápido

- [ ] ¿Cuál es el tag actual y cuál el target?
- [ ] ¿Es patch, minor o major?
- [ ] ¿Cambian Rails, Ruby, Node o pnpm?
- [ ] ¿Hay migraciones nuevas? ¿Colisionan con `custom/db/migrate/`?
- [ ] ¿Cambian `Gemfile`, `Gemfile.lock`, `package.json` o `pnpm-lock.yaml`?
- [ ] ¿Cambian `app/controllers/concerns/access_token_auth_helper.rb`, `api/base_controller.rb`, `platform_controller.rb`, `conversations_controller.rb` o `messages_controller.rb`?
- [ ] ¿Cambian `Frame.vue`, `SidepanelSwitch.vue`, `ChannelLeaf.vue`, `ReplyBottomPanel.vue`, `ReplyTopPanel.vue`, `LabelBox.vue`, `AccordionItem.vue`, `Macros/List.vue`, `ContactInfo.vue`, `Sidebar.vue` o las rutas de Informes/Ajustes?
- [ ] ¿Cambian `lib/chatwoot_app.rb`, `lib/chatwoot_hub.rb`, `enterprise/config/premium_features.yml` o el reconcile de Enterprise?
- [ ] ¿Cambian los contratos que usa n8n (API, tablas, labels, assignments, mensajes, webhooks)?
- [ ] ¿Cambia el Dockerfile y podemos perder el healthcheck o el heap de 6144?
- [ ] ¿La documentación actual (TECHNICAL.md, esta guía, docs de paneles/bridge) sigue siendo válida?

### 2.2 Dónde mirar primero

| Área | Archivos upstream a revisar | Qué nos afecta |
|---|---|---|
| Versión/build | `VERSION_CW`, `.ruby-version`, `Gemfile`, `Gemfile.lock`, `package.json`, `pnpm-lock.yaml`, `docker/Dockerfile` | Rails/Ruby/Node, gems, assets, healthcheck |
| Migraciones | `db/migrate/`, `db/schema.rb` | Colisiones, tablas custom, datos |
| Auth/API | `app/controllers/concerns/access_token_auth_helper.rb`, `app/controllers/api/base_controller.rb`, `app/controllers/platform_controller.rb`, `app/controllers/api/v1/accounts/conversations_controller.rb`, `.../conversations/messages_controller.rb`, `.../dashboard_apps_controller.rb` | n8n, Platform API, SSO, conversaciones, mensajes |
| UI / middleware | `app/javascript/dashboard/components/widgets/DashboardApp/Frame.vue`, `components-next/Conversation/SidepanelSwitch.vue`, `components-next/sidebar/ChannelLeaf.vue`, `components/widgets/WootWriter/ReplyBottomPanel.vue`, `ReplyTopPanel.vue`, `Editor.vue`, `routes/dashboard/conversation/labels/LabelBox.vue`, `ContactPanel.vue`, `contact/ContactInfo.vue`, `components/Accordion/AccordionItem.vue`, `Macros/List.vue`, `components-next/sidebar/Sidebar.vue`, `routes/dashboard/settings/reports/reports.routes.js`, `settings/account/account.routes.js` | CSS/JS inyectado, restricciones de agentes, paneles, menús |
| Enterprise | `lib/chatwoot_app.rb`, `lib/chatwoot_hub.rb`, `enterprise/config/premium_features.yml`, `enterprise/app/services/internal/reconcile_plan_config_service.rb`, `enterprise/app/models/enterprise/account.rb` | Blindaje sin licencia, features premium, gates |
| n8n | `n8n/*.json`, endpoints `/api/v1/accounts/...`, tablas `meli_*`, `reply_ai_*`, `accounts`, `conversations`, `messages`, `labels`, `teams`, `inboxes`, `users`, `webhooks` | Ingreso/egreso de mensajes, labels, assignments, ticks, adjuntos |
| RAG | `custom/lib/reply_ai/text_chunker.rb`, process workers, tablas `reply_ai_*`, endpoints `/rag/*` | Chunking, embeddings, búsqueda |
| Bridge/Yobot | `custom/lib/reply_ai/bridge_*`, acciones `bridge_*` del `LandingController` | HMAC, forward de ML, sync de config, token refresh |
| Reclamos | `custom/lib/reply_ai/claim_*`, `MeliClaim`, inbox de reclamos, `claims_outbound` | Automatización, agente, paneles |
| Docker/CI | `docker/Dockerfile`, `docker/dockerfiles/*`, `.github/workflows/yobot-deploy.yml`, `bin/validate_push` | Build, healthcheck, deploy app + worker |

---

## 3. Mapa de impacto detallado

### 3.1 Build, versiones y dependencias

**Upstream a mirar**

- `VERSION_CW`
- `.ruby-version`
- `Gemfile` / `Gemfile.lock`
- `package.json` / `pnpm-lock.yaml`
- `docker/Dockerfile`
- `docker/dockerfiles/rails.Dockerfile` y `vite.Dockerfile`

**Nuestro código**

- `VERSION_CW` (lo actualiza upstream).
- Dockerfile custom: heap de 6144 y `HEALTHCHECK`.
- `Gemfile` custom: `roo` para importación masiva.
- `.dockerignore` e `.gitignore` custom.

**Qué verificar**

- Rails/Ruby/Node/pnpm esperados.
- Que `roo` siga en `Gemfile` y `Gemfile.lock`.
- Que el Dockerfile conserve el healthcheck y el heap.
- `pnpm install`/build de assets.
- `zeitwerk:check` si cambia Zeitwerk.

### 3.2 Migraciones y schema

**Upstream**: `db/migrate/`, `db/schema.rb`.

**Nuestro código**: `custom/db/migrate/`, `reply_ai_schema_guard.rb`, tablas `meli_*` / `reply_ai_*`.

**Qué verificar**

- Colisión exacta de timestamps entre migraciones nuevas de upstream y las custom.
- Que ninguna migración upstream toque `meli_*` o `reply_ai_*`.
- Que `db/schema.rb` regenerado incluya las tablas custom.
- Backup de DB antes de producción.
- No ejecutar `db:reset`/`db:schema:load`.

### 3.3 Auth, API y Platform API

**Upstream a mirar**

- `app/controllers/concerns/access_token_auth_helper.rb`
- `app/controllers/api/base_controller.rb`
- `app/controllers/platform_controller.rb`
- `app/controllers/api/v1/accounts/conversations_controller.rb`
- `app/controllers/api/v1/accounts/conversations/messages_controller.rb`
- `app/controllers/api/v1/accounts/dashboard_apps_controller.rb`
- `app/policies/report_policy.rb`

**Nuestro código**

- `LandingController#create_account`, `bridge_register` (Platform API).
- `user_from_auth_cookie`, `go_to_chats`, `logout` (Devise/token).
- Todos los endpoints que consume n8n con `api_access_token`.
- `ensure_reply_assignment`, `bridge_*`, `claim_*`.

**Qué verificar**

- Que `api_access_token` legacy siga funcionando; v4.19.0 agrega Bearer pero mantiene el header legacy.
- Que `Current.user`/`Current.account` se seteen bien en los endpoints de n8n.
- Que `team_id`/`assignee_id` al crear conversaciones sigan siendo válidos (v4.19.0 agrega validación).
- Que `messages_controller` no cambie `source_id` en inboxes API (nuestros inboxes son `Channel::Api`).
- Que la traducción automática no se active si no hay hook de Google Translate.
- Que `ReportPolicy` y `DashboardAppsController` sigan iguales.

### 3.4 UI inyectada y selectores del middleware

**Upstream a mirar**

- `Frame.vue` (Dashboard Apps / `postMessage`)
- `SidepanelSwitch.vue`
- `ChannelLeaf.vue`
- `ReplyBottomPanel.vue`, `ReplyTopPanel.vue`, `WootWriter/Editor.vue`
- `LabelBox.vue`
- `ContactPanel.vue`, `contact/ContactInfo.vue`
- `AccordionItem.vue`, `Macros/List.vue`
- `Sidebar.vue`
- `reports.routes.js`, `account.routes.js`

**Nuestro código**

- `custom/lib/reply_ai/inject_css_middleware.rb`
- `custom/app/views/landing/*`
- `custom/lib/reply_ai/bridge_*` y paneles.

**Selectores/atributos que hoy usa el middleware**

- `.sidebar-labels-wrap`
- `[data-test-id="channel-identifier"]`
- `[data-test-id="channel-leaf-label"] > span[aria-hidden="true"]`
- `.reply-box .left-wrap` + iconos `i-ph-smiley-sticker`, `i-ph-microphone`, `i-ph-signature`, `i-ph-paperclip`
- `.file-uploads`
- `i-ph-sparkle-fill`
- `.absolute.top-36.ltr:right-2.!z-20` (`SidepanelSwitch`)
- `i-lucide-pen-line`
- `#toggleConversationFilterButton`
- `sidebar-labels-wrap`, `AccordionItem` y texto `Macros`
- `i-ph-chat-circle-dots`, `i-ph-pencil-simple`, `i-ph-arrows-merge`, `i-ph-trash`
- `img[src*="cw_image_width"]`

**Qué verificar**

- Que los selectores sigan existiendo.
- Que las rutas de Informes/Ajustes conserven los nombres que parchea el middleware.
- Que las nuevas secciones (Monitors, label suggestions, companies, traducción, bulk macros) no aparezcan para agentes por accidente.
- Que `Frame.vue` siga enviando `appContext` por `postMessage`.
- Prueba visual como agente y como administrador.

### 3.5 Dashboard Apps

**Upstream**: `Frame.vue`, `DashboardAppsController`, serializers de conversación.

**Nuestro código**: `setup_account_channels` (3 apps), vistas `sale_panel`, `product_panel`, `claim_panel`.

**Qué verificar**

- `{{conversation.id}}` sigue llegando literal.
- `postMessage`/`appContext` sigue funcionando.
- Resolución por `display_id`/id interno.
- URL absoluta con `FRONTEND_URL` (no `localhost`).

### 3.6 Enterprise / blindaje sin licencia

**Upstream a mirar**

- `lib/chatwoot_app.rb`
- `lib/chatwoot_hub.rb`
- `enterprise/config/premium_features.yml`
- `enterprise/app/services/internal/reconcile_plan_config_service.rb`
- `enterprise/app/models/enterprise/account.rb`

**Nuestro código**

- `custom/lib/custom/chatwoot_app.rb`
- `custom/lib/custom/chatwoot_hub.rb`
- `config/initializers/custom_enterprise_guard.rb`

**Qué verificar**

- `ChatwootHub.pricing_plan == 'enterprise'`.
- `ChatwootApp.self_hosted_paid? == true`.
- `ChatwootApp.self_hosted_enterprise? == true`.
- `Custom::ChatwootHub` precede a `Enterprise::ChatwootHub` en el ancestor chain.
- `ReconcilePlanConfigService` no desactiva features.
- Las features nuevas de Enterprise no se auto-habilitan en self-hosted; decidir si se necesitan.

### 3.7 n8n

**Upstream a mirar**

- Cambios en `app/controllers/api/v1/accounts/*` (conversations, messages, labels, assignments, contacts).
- Cambios en `app/controllers/platform/*`.
- Cambios en modelos/tablas que n8n consulta directo por SQL.
- Webhooks (`message_created`, `conversation_updated`, etc.).

**Nuestro código**

- `n8n/*.json`
- `custom/app/controllers/landing_controller.rb` (endpoints que n8n llama).
- `custom/lib/reply_ai/*`.

**Qué verificar**

- `api_access_token` en todos los HTTP nodes.
- Creación de contactos/conversaciones (`team_id`, `assignee_id`, `source_id`).
- Asignaciones (`/assignments`).
- Labels (`POST/DELETE /labels`).
- Mensajes y adjuntos (multipart).
- `content_attributes` (`source: 'n8n_ai'`, `ml_message_id`).
- Ticks `delivered`/`read`.
- URLs y tokens hardcodeados que deban actualizarse.
- Que `postsale_main` siga leyendo bien `meli_orders`, `meli_questions`, `accounts.custom_attributes`.

### 3.8 RAG

**Upstream**: cambios en `neighbor`, `pgvector`, ActiveStorage, Tika no son de upstream pero impactan.

**Nuestro código**: `TextChunker`, `DocumentProcessorWorker`, `PvDocumentProcessorWorker`, `ReplyAiDocument`, `ReplyAiPvDocument`, endpoints `/rag/search` y `/rag/pv_search`, workflows de embeddings.

**Qué verificar**

- Chunking (`source_doc_id`, `chunk_index`) y borrado de chunks.
- `search_for` con `reference_ids` y jerarquía de categorías.
- Webhooks de embeddings y `N8N_*_EMBEDDING_WEBHOOK_URL`.
- Docs sin embedding vs docs padre.
- Que los uploads/destroys sigan funcionando.

### 3.9 Bridge Yobot

**Nuestro código**: `BridgeApi`, `BridgeAuth`, `BridgeConfigMapper`, `BridgeConfigSyncWorker`, `TokenRefreshWorker`, acciones `bridge_*`, `YobotRagMigrator`.

**Qué verificar**

- HMAC sobre body crudo.
- `find_bridge_account` y perfiles nativo/migrado/bridge.
- `bridge_question`, `bridge_message`, `bridge_order`, `bridge_claim`, `bridge_manual_response`.
- `bridge_register` y `setup_account_channels`.
- Refresh de tokens en sus 3 rutas.
- `receive_only`.
- Que las migraciones/features nuevas no cambien el contrato de `api_access_token` ni assignments.

### 3.10 Reclamos

**Nuestro código**: `MeliApi`, `BridgeApi`, `ClaimMapper`, `ClaimAutomation`, `ClaimAgentWorker`, `ClaimsSyncWorker`, `MeliClaim`, inbox de reclamos, `claims_outbound`, paneles.

**Qué verificar**

- Webhook nativo y `bridge_claim`.
- `ClaimMapper` contra el shape real de ML.
- Automatización y modo supervisado.
- Labels `reclamo-*` y asignación de agente/equipo.
- `mirror_claim_messages` y timeline.
- Panel `claim_panel` y `claim_panel_data`.
- Presentación de adjuntos y acciones.

### 3.11 Docker, CI y deploy

**Upstream a mirar**: `docker/Dockerfile`, `docker/dockerfiles/*`, `package.json`, `.github/workflows/yobot-deploy.yml`.

**Nuestro código**: Dockerfile custom, `.dockerignore`, workflow de deploy.

**Qué verificar**

- Heap 6144 y `HEALTHCHECK`.
- Node 24.x y pnpm.
- Build de assets.
- Que el workflow siga disparando **app y worker**.
- `bin/validate_push` bloquea push directo a `master`; usar PR/merge.
- Monitorear Actions y ambos webhooks de Easypanel.

---

## 4. Comandos de análisis (read-only)

```bash
cd /home/gstizza/desarrollos/chatwoot

# Tag actual y target
cat VERSION_CW
git describe --tags --always

# Bajar tags
git fetch upstream --tags

# Diff de áreas de impacto (ejemplo v4.18.0 -> v4.19.1)
git diff --stat v4.18.0 v4.19.1 -- \
  Gemfile Gemfile.lock package.json pnpm-lock.yaml docker/Dockerfile \
  app/controllers/concerns/access_token_auth_helper.rb \
  app/controllers/api/base_controller.rb \
  app/controllers/platform_controller.rb \
  app/controllers/api/v1/accounts/conversations_controller.rb \
  app/controllers/api/v1/accounts/conversations/messages_controller.rb \
  app/controllers/api/v1/accounts/dashboard_apps_controller.rb \
  app/policies/report_policy.rb \
  lib/chatwoot_app.rb lib/chatwoot_hub.rb \
  enterprise/config/premium_features.yml \
  app/javascript/dashboard/components \
  app/javascript/dashboard/routes

# Migraciones nuevas y colisiones
git diff --name-only --diff-filter=A v4.18.0 v4.19.1 -- db/migrate/
git diff --name-only --diff-filter=A v4.18.0 v4.19.1 -- db/migrate/ \
  | awk -F/ '{print substr($NF,1,14)}' | sort -u > /tmp/upstream_versions.txt
ls custom/db/migrate | cut -c1-14 | sort -u > /tmp/custom_versions.txt
comm -12 /tmp/upstream_versions.txt /tmp/custom_versions.txt

# Buscar cambios en selectores/contratos que usamos
rg -n "left-wrap|i-ph-smiley-sticker|i-ph-microphone|i-ph-signature|i-ph-paperclip|i-ph-sparkle-fill|sidebar-labels-wrap|data-test-id=\"channel-identifier\"|i-lucide-pen-line|toggleConversationFilterButton" app/javascript/dashboard
rg -n "api_access_token|Authorization|Bearer" app/controllers/concerns/access_token_auth_helper.rb app/controllers/api/base_controller.rb app/controllers/platform_controller.rb n8n custom
rg -n "team_id|assignee_id|assignments" n8n app/controllers/api/v1/accounts/conversations_controller.rb
rg -n "captain|Captain" custom n8n
rg -n "premium_features|pricing_plan|self_hosted" custom enterprise lib
```

---

## 5. Procedimiento de upgrade

El paso a paso operativo vive en `TECHNICAL.md` §15 y §24. Resumen:

1. Backup: branch/tag `pre-upgrade-vX.Y.Z`.
2. `git fetch upstream --tags`.
3. Rama `update/upstream-vX.Y.Z` desde `master`.
4. `git merge --no-ff vX.Y.Z`.
5. Resolver conflictos preservando Dockerfile custom, `schema.rb`, `.dockerignore`, `.gitignore`, `.env.example`, `Gemfile` custom y `AGENTS.md`/docs.
6. Chequear colisiones de migraciones.
7. Rebuild local (`docker compose build rails sidekiq vite` si cambió Dockerfile/deps) y recrear servicios.
8. `bundle install` / `pnpm install` según corresponda.
9. `db:migrate`.
10. `rails zeitwerk:check` y `custom/verify.rb`.
11. Smoke tests críticos (sección 6).
12. Actualizar documentación (sección 7).
13. Commit, PR y merge a `master`.
14. Verificar Actions, ambos deploys de Easypanel, `/api`, migraciones y smokes en producción.

> **Nota**: `bin/validate_push` impide el push directo a `master`; el camino correcto es rama + PR + merge.

---

## 6. Checklist de verificación

### Build/versión
- [ ] `/api` reporta la versión esperada.
- [ ] `queue_services` y `data_services` en `ok`.
- [ ] Build de assets OK.
- [ ] `zeitwerk:check` OK.
- [ ] `custom/verify.rb` OK (hoy 60 checks; confirmar el conteo real de la salida).

### Auth/API
- [ ] `api_access_token` funciona en contactos, conversaciones, mensajes, labels y assignments.
- [ ] Bearer no rompe el flujo de dashboard/SSO.
- [ ] `team_id`/`assignee_id` válidos al crear conversaciones.
- [ ] `source_id` se conserva en inboxes API.
- [ ] Platform API (signup/bridge_register) funciona.

### UI
- [ ] Agente vs administrador.
- [ ] Menús de Informes/Ajustes.
- [ ] Labels, Macros, acciones de contacto.
- [ ] ReplyBox: emoji, mic, firma, clip, Copilot.
- [ ] Panel lateral y `SidepanelSwitch`.
- [ ] Nuevas secciones (Monitors, suggestions, companies, traducción) no filtradas a agentes.
- [ ] Dashboard Apps: Venta, Producto y Reclamo + `postMessage`.

### Flujos
- [ ] Pre-venta (`questions_main` / `questions_manual`).
- [ ] Post-venta (`postsale_main` / `postsale_outbound`).
- [ ] Reclamos (`claims_webhook` / `bridge_claim` / `claims_outbound`).
- [ ] Bridge (`bridge_*`, HMAC, refresh de tokens).
- [ ] RAG pre/post, chunking y embeddings.
- [ ] Adjuntos de entrada/salida y ticks `delivered`/`read`.

### Enterprise
- [ ] `ChatwootHub.pricing_plan == 'enterprise'`.
- [ ] `ChatwootApp.self_hosted_paid? == true`.
- [ ] `ChatwootApp.self_hosted_enterprise? == true`.
- [ ] Ancestor chain con `Custom::ChatwootHub` antes de `Enterprise::ChatwootHub`.
- [ ] Features premium deseadas habilitadas.

### Producción
- [ ] Backup de DB verificado.
- [ ] `db:migrate:status` sin pendientes.
- [ ] `custom/verify.rb` OK.
- [ ] Logs de Rails/Sidekiq sin errores nuevos.
- [ ] n8n producción ejecutando y sin 401/404 nuevos.
- [ ] Rollback identificado (imagen/commit anterior + backup).

---

## 7. Alineación documental (obligatoria)

Cada upgrade debe actualizar, según corresponda:

| Documento | Qué actualizar | Cuándo |
|---|---|---|
| `TECHNICAL.md` §2 | Versión de Chatwoot, Rails, Ruby, Node y stack | Siempre que cambie |
| `TECHNICAL.md` §15 | Nueva subsección de lecciones de la versión + link a esta guía | Siempre |
| `TECHNICAL.md` §24 | Versión desplegada en producción, URLs/build info | Al desplegar |
| `TECHNICAL.md` Apéndice | Archivos fuera de `custom/` que se modificaron/preservaron | Si cambia el merge |
| `TECHNICAL.md` §16 / §22.4 | Conteo y alcance real de `custom/verify.rb` | Si cambia el script o sus checks |
| `docs/GUIA_ACTUALIZACION_CHATWOOT.md` | Última revisión, estado del repo, registro de versión e impacto | Siempre |
| `custom/verify.rb` | Checks de nuevas clases, tablas, asociaciones, workers o initializers | Si la versión agrega/cambia capa custom |
| `docs/PANELES_DASHBOARD_APPS.md` | `Frame.vue`, `postMessage`, URLs de paneles | Si cambia Dashboard Apps |
| `docs/REQUERIMIENTOS_YOBOT.md` | Contratos bridge/n8n, endpoints, envs | Si cambia el bridge o n8n |
| `n8n/*.json` + docs de workflows | Nodos, webhooks, URLs, tokens, contratos | Si cambia n8n |
| `docs/notebooklm/*` | Visión general, funcionalidades, roadmap | Si cambia el producto |
| `AGENTS.md` | Reglas de upgrade y preservación | Si cambia el proceso |

### Regla de PR

Ningún PR de upgrade se considera terminado si no incluye:

- [ ] Actualización de `TECHNICAL.md`.
- [ ] Actualización de esta guía (registro + impacto + estado).
- [ ] `custom/verify.rb` actualizado si cambió la superficie custom.
- [ ] Docs de paneles/bridge/n8n actualizados si cambió el contrato.
- [ ] Evidencia de smoke tests en la descripción del PR.

---

## 8. Registro de versiones e impacto

### v4.18.0 — baseline actual del repo (2026-09-18) — [release notes](https://github.com/chatwoot/chatwoot/releases/tag/v4.18.0)
- Rails 7.2.3.1 / Ruby 3.4.4.
- Custom layer completo: pre-venta, post-venta, reclamos, bridge, RAG, paneles.
- `custom/verify.rb`: 60 checks (verificar salida real).
- 20 migraciones custom.

### v4.19.0 — analizada (release 2026-10-20) — [release notes](https://github.com/chatwoot/chatwoot/releases/tag/v4.19.0)
- Release grande: traducción automática, conversation monitors, sugerencias de labels/prioridad, Captain con toolset, WhatsApp campaigns, Companies CRM, bulk macros, Bearer auth, 2FA, Super Admin rediseñado.
- **Captain V1 retirado**: si hubiera instrucciones V1, migrarlas a V2 antes de actualizar.
- Nuevas features Enterprise en `premium_features.yml`: `conversation_monitors`, `campaign_analytics`, `copilot_workflows`.
- Cambios de UI importantes en ReplyBox, Labels, ContactInfo, Sidebar y reportes.
- Auth/API: soporte Bearer **sin quitar** `api_access_token`.
- Migraciones nuevas, sin impacto en `meli_*`/`reply_ai_*`.
- **Conclusión**: no se identificó un cambio que obligue a tocar `custom/` de entrada; sí requiere smoke de API/auth, assignments, UI y Zeitwerk.

### v4.19.1 — analizada (release 2026-10-24; análisis 2026-10-27, no aplicada) — [release notes](https://github.com/chatwoot/chatwoot/releases/tag/v4.19.1)
- Patch de seguridad/hardening: Node 24.22.1, Twilio webhook, CSS sanitization, SAML metadata, fixes de Help Center/inbox bots, cookies de sesión solo en páginas públicas.
- Rails/Ruby **sin cambios**.
- 24 migraciones upstream nuevas, **sin colisión exacta** con las 20 custom; ninguna toca tablas custom.
- `Frame.vue`, `SidepanelSwitch.vue`, `ReportPolicy`, `ChatwootApp`, `ChatwootHub` y `DashboardAppsController` **sin cambios**.
- Selectores críticos del middleware siguen presentes; `ReplyBottomPanel` conserva iconos y `left-wrap`; `LabelBox` conserva `sidebar-labels-wrap`; `ContactInfo` conserva iconos de acciones; rutas de Informes conservan nombres.
- `Sidebar` agrega Monitors (admin/report_manage; agentes no lo ven).
- API: `api_access_token` legacy sigue soportado; `ConversationsController#create` valida `team_id`/`assignee_id`; n8n manda IDs válidos. `MessagesController` agrega traducción y `clear_source_id` solo para inboxes no API.
- Dockerfile: Node 24.22.1; preservar 6144 + `HEALTHCHECK`.
- Zeitwerk 2.7.5 → 2.8.3; ejecutar `zeitwerk:check`.
- **Estado**: analizada, pendiente de aplicar. Al aplicarla, actualizar esta entrada con fecha, conflictos, migraciones ejecutadas y resultado del smoke.

---

## 9. Plantilla para futuras versiones

Copiar este bloque en el registro de versiones y completarlo **antes** de mergear:

```markdown
### vX.Y.Z — YYYY-MM-DD
- **Tipo**: patch / minor / major.
- **Release notes**: link.
- **Rails/Ruby/Node/pnpm**: ...
- **Migraciones**: N nuevas; colisiones: sí/no; tablas custom afectadas: sí/no.
- **Dependencias**: ...
- **Áreas afectadas**: auth/API, UI, Enterprise, n8n, RAG, bridge, claims, Docker.
- **Cambios que nos impactan**: ...
- **Riesgos**: ...
- **Cambios requeridos en custom/**: ...
- **Verificación ejecutada**: ...
- **Documentación actualizada**: TECHNICAL.md / esta guía / verify / paneles / bridge / n8n.
- **Estado**: analizada / aplicada en local / desplegada en producción.
- **Rollback**: tag/imagen/commit.
```

---

## 10. Automatización pendiente

Hoy el proceso es manual/asistido. Para que un agente pueda hacer upgrades de forma más autónoma faltan:

1. Script único de upgrade (`script/upgrade_chatwoot.sh` o rake task) con precondiciones, merge, colisiones, migraciones, verify y reporte.
2. Checks de invariantes custom (Dockerfile 6144/healthcheck, `VERSION_CW`, initializers, asociaciones, tablas, Enterprise, n8n).
3. Workflow CI en PR a `master` que corra Postgres+pgvector, migraciones, `custom/verify.rb`, specs custom y build Docker.
4. Staging real o efímero con datos representativos.
5. Smoke post-deploy automatizado + backup + rollback.
6. Accesos de mínimo privilegio para el agente (GitHub, Easypanel, DB read-only, n8n).
7. Specs de flujos custom y contract tests de n8n.

Mientras eso no exista, este documento + `TECHNICAL.md` son la fuente de verdad y el upgrade se considera **asistido**, no automático.

---

## 11. Checklist final de una línea

> **Tag mergeado, migraciones OK, verify/zeitwerk OK, smokes OK, producción OK y documentación actualizada. Si falta uno, no terminó.**
