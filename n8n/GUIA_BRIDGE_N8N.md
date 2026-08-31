# Guía: Adaptación de workflows n8n para cuentas Bridge

> Los cambios son idénticos en lógica para todos los workflows. Se documentan una vez y se replican.

---

## Cambio 1: Agregar campos `status` y `bridge_enabled` a las queries SQL

En **cada workflow** que tenga un nodo `get_account_details` (o `get_ml_credentials`), agregar 2 columnas al SELECT:

```sql
SELECT
  c.access_token,
  c.refresh_token,
  c.status,              ← NUEVO
  c.bridge_enabled,      ← NUEVO
  ...resto de columnas...
FROM meli_credentials c
...
```

**Workflows afectados:**
- `reply_ai_questions_main.json` → nodo `get_account_details`
- `reply_ai_questions_manual.json` → nodo `get_question_details` (revisar si lee `meli_credentials`)
- `reply_ai_postsale_main.json` → nodo `get_account_details`
- `reply_ai_postsale_outbound.json` → nodo `get_ml_credentials`

> **Verificación**: después de agregar las columnas, ejecutar el workflow una vez y ver en la salida del nodo PostgreSQL que `status` y `bridge_enabled` aparecen en el JSON.

---

## Cambio 2: Routing condicional bridge vs native

La lógica es la misma en todos los casos:

```
n8n expression para detectar bridge:
  {{ $json.status === 'bridge' && $json.bridge_enabled === true }}
```

### 2A. Workflow `reply_ai_questions_main` — envío de respuesta a ML

**Antes**: el nodo `mercadolibre_answer_question` llama directo a:
```
URL: https://api.mercadolibre.com/answers
Headers: Authorization: Bearer {{ access_token }}
Body: { question_id: ..., text: ... }
```

**Cambio**: insertar un nodo `If` antes de `mercadolibre_answer_question`:

```
                         ┌── true (bridge) ──► HTTP Request a Yobot
AI Agent ──► If (bridge?) ┤
                         └── false (native) ─► mercadolibre_answer_question (ML API)
```

**Nodo If**:
- Nombre: `is_bridge_account?`
- Condición: `{{ $json.status === 'bridge' && $json.bridge_enabled === true }}`

**Nuevo nodo HTTP Request (rama bridge)**:
- Nombre: `bridge_send_answer`
- Método: POST
- URL: `{{ $env.YOBOT_BRIDGE_URL }}/api/bridge/send-answer`
- Headers:
  - `Authorization: Bearer {{ $env.BRIDGE_SECRET }}`
  - `X-Bridge-Signature: {{ $json.hmac_signature }}` ← requiere nodo Code (ver abajo)
  - `Content-Type: application/json`
- Body (JSON):
```json
{
  "ml_user_id": "{{ $('get_account_details').item.json.ml_user_id }}",
  "question_id": "{{ $json.question_id }}",
  "answer_text": "{{ $json.output }}"
}
```

**Nodo Code para HMAC** (antes del HTTP Request en la rama bridge):
```javascript
const crypto = require('crypto');
const secret = $env.BRIDGE_SECRET;
const body = JSON.stringify({
  ml_user_id: $('get_account_details').item.json.ml_user_id,
  question_id: $json.question_id,
  answer_text: $json.output
});
const hmac = crypto.createHmac('sha256', secret).update(body).digest('hex');
return { ...$json, bridge_body: body, hmac_signature: hmac };
```

---

### 2B. Workflow `reply_ai_questions_manual` — respuesta manual a ML

**Antes**: nodo `mercadolibre_post_answer` → `api.mercadolibre.com/answers`

**Mismo cambio que 2A**: insertar `If (bridge?)` antes. Rama true → HTTP Request a Yobot `/api/bridge/send-answer`. Rama false → nodo actual.

---

### 2C. Workflow `reply_ai_postsale_main` — mensajes post-venta a ML

Este workflow tiene **5 nodos** que envían a ML API:
- `send_logistics_reply_ml`
- `send_support_reply_ml`
- `send_close_reply_ml`
- `send_escalation_to_buyer_ml`
- `send_saludo_reply_ml`

**Estrategia recomendada**: en vez de 5 Ifs, crear **UN** nodo Code al inicio que determine el destino, y luego usar una variable en cada URL:

**Nodo Code** (después de `get_account_details`):
```javascript
const isBridge = $json.status === 'bridge' && $json.bridge_enabled === true;
return {
  ...$json,
  is_bridge: isBridge,
  send_url: isBridge
    ? `${$env.YOBOT_BRIDGE_URL}/api/bridge/send-message`
    : 'https://api.mercadolibre.com'
};
```

**Modificar cada nodo de envío** para usar URL condicional:
```
URL: {{ $('nuevo_nodo_code').item.json.is_bridge
  ? $('nuevo_nodo_code').item.json.send_url + '/messages/packs/' + pack_id + '/sellers/' + ml_user_id + '?tag=post_sale'
  : 'https://api.mercadolibre.com/messages/packs/' + pack_id + '/sellers/' + ml_user_id + '?tag=post_sale' }}
```

**O alternativamente**: insertar un `Switch` antes de cada uno de los 5 nodos (más explícito, más nodos):

```
Switch (bridge?)
  ├── bridge → POST {{YOBOT_URL}}/api/bridge/send-message (con HMAC)
  └── native → send_xxx_reply_ml (ML API, sin cambios)
```

---

### 2D. Workflow `reply_ai_postsale_outbound` — mensaje manual post-venta

**Antes**: nodo `send_to_ml` → `api.mercadolibre.com/messages/packs/...`

**Mismo patrón**: insertar `If (bridge?)` antes. Rama true → HTTP Request a Yobot `/api/bridge/send-message`. Rama false → nodo actual.

---

## Cambio 3: Token refresh para cuentas bridge

### 3A. Agregar endpoint en Yobot — `POST /api/bridge/refresh-token`

Ya implementado en `backend/routes/bridge.js` y `backend/controllers/bridgeController.js`. Falta agregar la ruta en `bridge.js`:

```javascript
// En backend/routes/bridge.js — agregar:
router.post('/refresh-token', refreshToken);
```

Y en `backend/controllers/bridgeController.js` — agregar el handler:

```javascript
export async function refreshToken(req, res) {
  const body = req.body;
  if (!verifyBridgeRequest(body, req.headers['authorization'], req.headers['x-bridge-signature'])) {
    return res.status(401).json({ error: 'No autorizado' });
  }

  try {
    const response = await axios.post('https://api.mercadolibre.com/oauth/token', {
      grant_type: 'refresh_token',
      client_id: process.env.CLIENT_ID,
      client_secret: process.env.CLIENT_SECRET,
      refresh_token: body.refresh_token
    });

    res.json(response.data);
  } catch (e) {
    res.status(502).json({ error: e.response?.data || e.message });
  }
}
```

### 3B. Modificar `TokenRefreshWorker` en Reply-AI

En `custom/lib/reply_ai/token_refresh_worker.rb`, modificar `refresh_meli_token`:

```ruby
def refresh_meli_token(credential)
  if credential.status == 'bridge'
    refresh_via_yobot(credential)
  else
    refresh_via_ml(credential)
  end
end

def refresh_via_yobot(credential)
  body = { ml_user_id: credential.ml_user_id, refresh_token: credential.refresh_token }.to_json
  signature = OpenSSL::HMAC.hexdigest('SHA256', ENV.fetch('BRIDGE_SECRET'), body)

  response = RestClient.post(
    "#{ENV.fetch('YOBOT_BRIDGE_URL')}/api/bridge/refresh-token",
    body,
    {
      content_type: :json,
      accept: :json,
      Authorization: "Bearer #{ENV.fetch('BRIDGE_SECRET')}",
      'X-Bridge-Signature': signature
    }
  )

  data = JSON.parse(response.body)
  credential.update_columns(
    access_token: data['access_token'],
    refresh_token: data['refresh_token'] || credential.refresh_token,
    expires_at: Time.current + data['expires_in'].seconds,
    status: 'bridge',
    updated_at: Time.current
  )
end

def refresh_via_ml(credential)
  # código actual sin cambios
end
```

---

## Cambio 4: Variables de entorno en n8n

Agregar en la configuración de n8n (Settings → Environment Variables):

| Variable | Valor | Descripción |
|----------|-------|-------------|
| `BRIDGE_SECRET` | `<mismo que en Reply-AI y Yobot>` | Shared secret para HMAC |
| `YOBOT_BRIDGE_URL` | `https://yobot.ejemplo.com` | URL base de Yobot |

---

## Orden recomendado de implementación

1. **Agregar env vars en n8n** (`BRIDGE_SECRET`, `YOBOT_BRIDGE_URL`)
2. **Agregar endpoint `refresh-token`** en Yobot (`bridge.js` + `bridgeController.js`)
3. **Agregar columnas SQL** (`status`, `bridge_enabled`) en los 4 workflows → probar que aparecen en la salida
4. **Modificar `reply_ai_questions_main`** — 1 nodo If + 1 HTTP Request bridge (probar con 1 pregunta de test)
5. **Modificar `reply_ai_questions_manual`** — igual que arriba
6. **Modificar `reply_ai_postsale_main`** — 5 nodos de envío (usar estrategia de nodo Code central)
7. **Modificar `reply_ai_postsale_outbound`** — 1 nodo If
8. **Modificar `TokenRefreshWorker`** en Reply-AI — delegates a Yobot para bridge

---

## Verificación

Después de cada cambio, probar con el seller de test bridgeado:

1. Activar bridge: `MeliCredential.update(bridge_enabled: true, status: 'bridge')`
2. Simular pregunta de ML → ver que n8n routea por Yobot
3. Verificar que la respuesta llega a ML
4. Verificar que el refresh de token funciona (esperar 2h o forzar desde Sidekiq)
