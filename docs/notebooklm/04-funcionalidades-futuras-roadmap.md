# Funcionalidades Futuras y Roadmap — Reply-AI

> Documento fuente para NotebookLM. Recopila todo lo documentado como pendiente, futuro o decidido-no-implementar en el proyecto Reply-AI (fuentes: `TECHNICAL.md` §18 "Plan de Implementación", `docs/REQUERIMIENTOS_YOBOT.md`, y §23 operaciones).

## 1. Estado general del plan de implementación

El plan original (§18 de TECHNICAL.md) se organizó en 3 fases + temas transversales. Estado actual:

| Fase | Alcance | Estado |
|------|---------|--------|
| **Fase 1 — Post-venta IA avanzada** | Sentimiento, ciclo de vida de conversaciones, handoff H1–H6, loop detection, auto-cierre nativo, comprensión IA de adjuntos | ✅ Implementada (2026-08-03) — pendiente 1 validación runtime |
| **Fase 2 — Reclamos, devoluciones y cambios** | Modelo `MeliClaim`, webhook/sync, automatización determinista, agente ReAct con 8 tools, 21 endpoints, UI de reclamos | ✅ Implementada (2026-08-03) — pendiente 1 validación runtime con seller real |
| **Fase 3 — Bridge Yobot ↔ Reply-AI** | Endpoints bridge + HMAC, `BridgeApi` (21 acciones), forwards completos, sync de config, adjuntos, gating nativo/bridge | ✅ Implementada (2026-08-05/07) — pendiente piloto y migración masiva de sellers |
| **Control de confianza (D4 revisado)** | `requireRagOrConfidence` + `confidenceByCategory`, retención con sugerencia, informe de info faltante | ✅ Implementado (2026-08-08) |
| **Migración RAG Yobot → Reply** | Import desde Supabase + regeneración de embeddings | ✅ Implementado (2026-08-08) |
| **Bandeja de reclamos en Chatwoot** | Inbox Reclamos + labels + Dashboard App + timeline | ✅ Implementado (2026-08-04/09) |
| **Paneles Dashboard Apps** | Venta ML, Producto ML, Reclamo ML | ✅ Implementado (2026-08-08/09) |

## 2. Pendientes de validación (implementado, falta probar en runtime)

1. **Handoff manual en producción (item 1.9 de la Fase 1)**: verificar en runtime con un seller real que cuando un agente asigna/etiqueta una conversación, el `conversation_ai_gate` efectivamente detiene la IA.
2. **Fase 2 con seller real**: probar el flujo completo de reclamos (webhook → automatización → agente → acciones) con un token OAuth que tenga **scope Post Purchase** — requisito de la Claims API de MercadoLibre (`/post-purchase/v1/`), solo aplicable a cuentas nativas.
3. **Flujo de post-venta end-to-end en producción**: smoke post-venta con el piloto (cuenta 50): pregunta entrante → respuesta IA → respuesta manual → ticks de lectura ✓✓.

## 3. Funcionalidades por implementar

### 3.1 Migración masiva de sellers de Yobot (`YobotMigrator`)

- **Estado**: ❌ Pendiente (único item del puente Fase 3 nunca completado).
- **Qué es**: migración automática de los usuarios de Yobot a Reply-AI: registro de la cuenta (`bridge_register`), transferencia de tokens del seller desde la BD de Yobot (Mongo), y migración de su configuración.
- **Ya existe como base**: `BridgeConfigMapper` + `BridgeConfigSyncWorker` migran prompts, delays, schedules, saludos por tienda y automatización de reclamos (validado end-to-end); `YobotRagMigrator` migra los documentos RAG. Falta el orquestador general.

### 3.2 Piloto del bridge con usuario real

- **Estado**: ⏳ pendiente — Reply-AI está listo (endpoints, HMAC, receive-only, config sync); falta del lado de Yobot: configurar `REPLY_AI_BRIDGE_URL`/`BRIDGE_SECRET`, marcar la cuenta de prueba (`bridge: { enabled: true, mode: "full" }`) y validar el flujo completo.
- **Secuencia documentada**: primero piloto **local** en modo receive-only (todo llega a Chatwoot, nada se envía a ML) → luego modo `mirror`/`full` → recién después **producción** (marcar el usuario real en la BD de producción de Yobot).
- **Restricción clave**: el flag en Yobot debe ser `mode: "full"` (nunca `mirror`) para perfiles migrados, para evitar dobles respuestas.

### 3.3 Onboarding de nuevos sellers en producción

Runbook documentado (§23.5): `/signup` en producción → OAuth de MercadoLibre (con scope Post Purchase para reclamos) → sync de productos → carga de documentos RAG (importación masiva o migración desde Yobot).

## 4. Pendientes operativos de producción (§23.5)

1. **Persistir las variables de entorno en Easypanel**: el import inicial se hizo con `docker service update --env-add`, que queda fuera del spec de Easypanel — al editar/redeployar servicios desde el panel hay que re-aplicar las env en la UI o se pierden.
2. **App de MercadoLibre**: configurar la URL de notificaciones de ML apuntando al webhook de `questions_main` (la de producción).
3. **Onboarding del primer seller real** (ver §3.3).
4. Confirmar `REPLY_RECEIVE_ONLY=false` en producción (responder de verdad a ML); el flag solo se activa para pruebas controladas.
5. **Servicio Tika en producción**: sin `yobot_cw_tika`, `process_attachments` falla solo para PDFs (Visión y Whisper no dependen de Tika).

## 5. Tech debt conocido

- **Token de API hardcodeado en n8n**: los Code nodes usan un token estático de Chatwoot; si el admin regenera su token, los workflows fallan con 401. Refactor pendiente: leerlo dinámicamente de `access_tokens` (o del usuario agente creado en el signup).
- **`YOBOT_BRIDGE_URL` apunta a Yobot de dev**: valor heredado; cuando un seller migrado opere en producción debe apuntar al Yobot de producción.
- **`CheckNewVersionsJob` loguea un `NoMethodError` inofensivo** (bug upstream) cuando el ping al hub de Chatwoot falla — no escribe nada; existe desde febrero.
- **`data_services: "failing"` cosmético** en el healthcheck de Chatwoot (conexiones lazy de Rails 7.2) — artefacto del endpoint upstream; corregir en upstream.
- **`/auth/sign_in` → 500 solo en dev**: el `.env` local apunta `FRONTEND_URL` a producción y Rails bloquea el redirect cross-host; preexistente, no afecta a producción.
- **Sandbox de Code nodes en n8n 2.6.4**: hallazgos documentados sobre cómo envolver el código en `async function` para validar con `node --check` (§20).

## 6. Decisiones del owner: NO se van a implementar

Documentadas en §18.0 (2026-08-03) — decisiones explícitas, no pendencias:

| # | Tema | Decisión |
|---|------|----------|
| D1 | Roles y permisos granulares (como Yobot) | **No** — usar los nativos de Chatwoot (Admin/Agent) |
| D2 | Suscripciones/pagos PayPal y feature gating por plan | **No** — sin cobros ni planes |
| D3 | Dashboard de métricas propio (heatmap, evolución, conversión) | **No** — usar Reports nativos de Chatwoot |
| D4 | "Mejorar publicaciones" (bulk-add de info faltante) | **No** — pero SÍ se implementó el control de confianza (decisión revisada) |
| D6 | Timeline de eventos custom en `meli_orders` | **No** — solo el timeline nativo de la conversación (el timeline de reclamos en `meli_claims` sí existe) |
| D5 | Auto-cierre por inactividad | **No custom** — se usa el nativo de Chatwoot (`auto_resolve_after`) |
| D7 | Sentimiento | **Sí, como nodo dedicado** (decisión de arquitectura: sin reglas duplicadas en clasificación de intención) |
| D8 | Multimedia | **Nativa de Chatwoot** + comprensión IA de adjuntos (Vision/Tika/Whisper) |
| D9 | Bridge Yobot | **Último paso** — ya implementado |

## 7. Gap real restante Yobot → Reply-AI

De la comparativa original (§18.1), todo lo funcional ya está implementado. El gap restante se resume en:

- **Migración masiva de sellers** (§3.1) y **piloto bridge** (§3.2) — temas de adopción, no de funcionalidad.
- **Validaciones runtime** con sellers reales (§2).
- Las features marcadas "No implementar" (§6) son decisiones de producto, no deuda.
- **Multicanal**: Chatwoot es omnicanal de fábrica (web, email, WhatsApp, Facebook, Instagram) — habilitarlo para nuevos canales sería habilitar inboxes nativos, sin trabajo Reply-AI.

## 8. Reglas de implementación para el futuro (§18.5–18.6)

Cualquier funcionalidad nueva debe seguir estas reglas documentadas:

1. **Todo el código nuevo va en `custom/`** — modelos, controladores, workers, vistas, migraciones. Nunca en `app/`, `lib/` ni `enterprise/`.
2. **Workflows n8n en `n8n/`** (modificar los existentes o crear nuevos).
3. **Endpoints nuevos en `LandingController`** o controladores en `custom/app/controllers/`.
4. **Workers en `custom/lib/reply_ai/`**; **migraciones en `custom/db/migrate/`** con timestamps en rango `2099...` para no colisionar con upstream.
5. **Variables de entorno nuevas**: documentar en `.env.example` y en TECHNICAL.md.
6. **Verificar** tras cada fase: `rails runner custom/verify.rb` (59 checks) + testing manual del flujo afectado + actualización de §18 del documento.
7. En specs, preferir `let`/setup directo sobre helpers; usar `with_modified_env` en vez de stub de `ENV`.
