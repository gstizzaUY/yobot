# Chatwoot E2E Testing - Documentation

Complete guide for writing and maintaining E2E tests for Chatwoot.

---

## Overview

End-to-end testing suite for Chatwoot built with Playwright and TypeScript using the Component Object Model (COM) pattern.

---

## Architecture

```
tests/playwright/
├── components/
│   ├── api/              # API interaction (auth.component.ts, inbox.component.ts ...)
│   └── ui/               # UI page objects (login.component.ts, agent-page.component.ts ...)
├── tests/e2e/            # Test specs (api/ and ui/)
├── utils/                # Shared utilities (fixture.ts, test-data.ts, db.ts)
├── response-schemas/     # API response schemas for validation
├── fixtures/             # Test fixtures
├── helpers/              # Helper functions
└── playwright.config.ts
```

---

## Configuration

All configuration managed through `.env` file. Copy `.env.example` to `.env`:

```
BASE_URL=http://localhost:3000
TEST_USER_EMAIL=admin@chatwoot.com
TEST_USER_PASSWORD="Password123@#"
ACCOUNT_ID=1

# Add additional variables as needed by specific test suites
# VARIABLE_NAME=value
```

> **Note:** `npx playwright install` is required after `pnpm install` to download browser binaries.

---

## Testing Patterns

### API Testing

```typescript
test('API operation', async ({ api }) => {
  const authHeaders = await authComponent.login(email, password);
  const result = await component.create(api, authHeaders, data);
  expect(result.id).toBeTruthy();
});
```

### UI Testing

```typescript
test('UI interaction', async ({ page }) => {
  const loginComponent = new Login(page);
  await loginComponent.login(email, password);
  await expect(page.getByText('Success')).toBeVisible();
});
```

### Hybrid Pattern

```typescript
test('UI with API setup', async ({ page, api }) => {
  // Fast: Create test data via API
  const inbox = await inboxComponent.createApiInbox(api, authHeaders, data);

  // Test UI interactions
  await page.goto(`/app/accounts/2/inbox/${inbox.id}`);
  await expect(page.getByText(inbox.name)).toBeVisible();
});
```

---

## Request Handler

```typescript
const data = await api
  .path('/api/v1/accounts/2/agents')
  .headers(authHeaders)
  .body({ name: 'John', email: 'john@test.com' })
  .logs(true)
  .postRequest(200);
```

**Methods:** `getRequest()`, `postRequest()`, `putRequest()`, `deleteRequest()`

---

## Test Data Generation

```typescript
import { fake } from '@utils/test-data';

const agent = fake.agent({ role: 'agent' });
const inboxName = fake.inboxName();
```

**Available:** `fake.fullName`, `fake.email`, `fake.phoneNumber`, `fake.password`, `fake.agent()`, `fake.inboxName()`

---

## Best Practices

**Do:**
- Use existing components
- Use `fake` for test data
- Use semantic selectors (`getByRole`, `getByLabel`)
- Clean up test data in `afterAll`
- Validate API schemas

**Don't:**
- Use CSS selectors
- Hardcode wait times
- Skip cleanup
- Commit sensitive data

---

## Troubleshooting

**Authentication errors:**
- Verify `.env` credentials match Chatwoot
- Check for rate limiting (429 errors)

**Database errors:**
- Verify database is running
- Check credentials in `.env`

**Timeout errors:**
- Ensure Chatwoot is running at `BASE_URL`
- Increase timeout: `{ timeout: 60000 }`

**Element not found:**
- Use `page.pause()` to inspect
- Check for timing issues

---

## Reply-AI / MercadoLibre — Modo Recepción y Verificación de Flujos

> Documenta el testing operacional de los flujos Reply-AI (pre-venta, post-venta y reclamos)
> sobre una instancia real, usando el **modo receive-only** implementado el 2026-08-05.
> Referencia técnica completa: `TECHNICAL.md` §19 (modo recepción) y §20 (operaciones n8n).

### Concepto

El modo **receive-only** permite bridgear un usuario real desde Yobot hacia Reply-AI para
validar que **preguntas, mensajes y reclamos llegan a los lugares correctos de Chatwoot**
(conversaciones en el inbox correspondiente, mensajes, labels) **sin que Reply-AI envíe nada**
a MercadoLibre ni a Yobot. Las respuestas que el bot generaría se espejan a Chatwoot como
**notas privadas** y las conversaciones quedan abiertas para revisión.

### Activar el modo

1. `.env`: `REPLY_RECEIVE_ONLY=true`
2. Aplicar y recrear contenedores:
   ```bash
   docker compose up -d rails n8n-main n8n-worker
   ```
3. Bridgear el usuario de prueba desde Yobot. `bridge_register` marca automáticamente la cuenta
   con `custom_attributes.receive_only = true` cuando el env está activo.

Desactivar: `.env` → `REPLY_RECEIVE_ONLY=false` + `docker compose up -d rails n8n-main n8n-worker`
+ desmarcar la cuenta (`custom_attributes` sin la clave `receive_only`).

### Flujos a verificar (E2E manual con usuario bridge real)

| Flujo | Entrada | Dónde verificar en Chatwoot | Esperado |
|---|---|---|---|
| **Pregunta pre-venta** | Comprador pregunta en ML → Yobot → `POST /api/bridge/question` | Inbox "Pre-venta (MercadoLibre)" | Conversación con la pregunta (incoming), respuesta del bot como **nota privada**, conversación **abierta**, sin POST a `api.mercadolibre.com/answers` ni a Yobot `send-answer` |
| **Mensaje post-venta** | Comprador escribe en la conversación de la orden → `POST /api/bridge/message` | Inbox "Post-venta (MercadoLibre)" | Conversación por pack/orden, mensaje incoming, respuesta del bot como **nota privada**, sin envío a ML/Yobot (`send_*_reply_ml` saltados), sin auto-resolve |
| **Reclamo** | ML notifica claim → `POST /api/bridge/claim` | Inbox "Reclamos (MercadoLibre)" | Conversación con `source_id = claim_id`, labels `reclamo-*`, banner de mediación si aplica; automatización/agente en modo **dry-run** (decisión en `agent_log`, sin ejecutar) |
| **Acciones manuales** | Desde el panel de reclamos (refund, mensaje, etc.) | Respuesta JSON del endpoint | `200 {"receive_only": true, "accion_bloqueada": true}` |

### Verificación de "cero outbound"

- **Rails logs**: ninguna request a `api.mercadolibre.com` ni a `YOBOT_BRIDGE_URL` proveniente de
  acciones de reclamos (responden `receive_only`).
- **n8n executions** (DB `n8n`):
  ```sql
  SELECT w.name, e.status, e."startedAt"
  FROM execution_entity e JOIN workflow_entity w ON w.id = e."workflowId"
  WHERE e."startedAt" > now() - interval '1 hour' ORDER BY e."startedAt" DESC;
  ```
  En los nodos de envío de los workflows (5× `send_*_reply_ml`, `mercadolibre_answer_question`,
  `send_to_ml`, `send_via_messages`, `send_via_action_guide`, `mercadolibre_post_answer`,
  `send_claim_message`) la salida debe ser `{receive_only: true, ...}` — sin fetch a ML/Yobot.
- **Chatwoot**: los mensajes del bot aparecen con `private: true` (notas privadas) y las
  conversaciones quedan en estado abierto.

### Endpoints de ingesta útiles para verificar (sin pasar por Yobot)

```bash
# RAG pre-venta (lectura, debe seguir funcionando)
curl -X POST http://localhost:3000/rag/search \
  -H "Content-Type: application/json" -H "x-internal-secret: $INTERNAL_API_SECRET" \
  -d '{"account_id": 1, "query": "..."}'

# RAG post-venta
curl -X POST http://localhost:3000/rag/pv_search \
  -H "Content-Type: application/json" -H "x-internal-secret: $INTERNAL_API_SECRET" \
  -d '{"account_id": 1, "query": "...", "item_id": "MLA..."}'

# Estado de n8n
curl http://localhost:5678/healthz   # → {"status":"ok"}
```

### Notas para tests automatizados (Playwright)

- El modo receive-only **no requiere datos reales de ML** para validar la ingesta de claims
  (entran por `POST /api/bridge/claim`), pero **preguntas y mensajes sí** requieren forwards
  reales de Yobot (los nodos de n8n consultan la API de ML para detalles del item/orden).
- Para tests de UI del dashboard con cuenta receive-only, la cuenta 50 de dev NO debe quedar
  marcada (se usa solo la cuenta bridge de prueba).
- Al crear datos de prueba (claims, preguntas) vía API, limpiarlos en `afterAll`
  (`MeliClaim`, `MeliQuestion`, conversaciones creadas).
