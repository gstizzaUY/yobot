#!/usr/bin/env python3
"""Sincroniza los flujos n8n de producción al repo (sanitizados).

Contexto: los cambios de producción se aplican vía API de n8n; este script baja
la definición de cada workflow `reply_ai_*` y la escribe en `n8n/<nombre>.json`
con los valores de desarrollo (sin hosts ni tokens de producción).

Uso:
    N8N_API_KEY=... python3 n8n/sync/sync_from_prod.py [--dry-run]

Requiere:
    N8N_API_KEY   API key de la instancia de n8n (no se guarda en el repo).

Opcional:
    N8N_BASE_URL  Base de la API de n8n (default: instancia de producción).

Después de correrlo:
    git diff n8n/   (verificar que no haya secretos de producción) y commitear.
"""
import json
import os
import sys
import urllib.request

BASE = os.environ.get("N8N_BASE_URL", "https://yobot-cw-n8n-main.bsj9p0.easypanel.host/api/v1")
REPO_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# prod -> dev: valores que no deben quedar versionados
SANITIZE = [
    ("https://yobot-cw-yobot-app.bsj9p0.easypanel.host", "https://w1206-app.site"),
    ("http://yobot_cw_yobot-app:3000", "http://rails:3000"),
    ("https://yobot-cw-n8n-main.bsj9p0.easypanel.host", "https://n8nn.w1206-app.site"),
    ("RZ2EoYFYa6ckmQqRMcdT7DHy", "TSL8r4ctWYzXJF9fiAS1Z8RV"),
    ("Postgres chatwoot_production", "Postgres chatwoot_development"),
]

KEEP_KEYS = ["name", "active", "nodes", "connections", "settings"]


def api(path):
    req = urllib.request.Request(BASE + path, headers={"X-N8N-API-KEY": os.environ["N8N_API_KEY"]})
    with urllib.request.urlopen(req, timeout=120) as res:
        return json.load(res)


def sanitize(obj):
    blob = json.dumps(obj, ensure_ascii=False)
    for old, new in SANITIZE:
        blob = blob.replace(old, new)
    return json.loads(blob)


def main():
    if not os.environ.get("N8N_API_KEY"):
        print("Falta N8N_API_KEY en el entorno.")
        return 1

    dry = "--dry-run" in sys.argv
    workflows = api("/workflows?limit=100")["data"]
    targets = sorted(w for w in workflows if w["name"].startswith("reply_ai_"))

    changed, same = [], []
    for w in targets:
        wf = api(f"/workflows/{w['id']}")
        out = sanitize({k: wf[k] for k in KEEP_KEYS if k in wf})
        path = os.path.join(REPO_DIR, f"{w['name']}.json")
        new_text = json.dumps(out, ensure_ascii=False, indent=2) + "\n"
        old_text = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
        if old_text == new_text:
            same.append(w["name"])
            continue
        changed.append(w["name"])
        if not dry:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(new_text)

    print(f"workflows reply_ai_*: {len(targets)}")
    print(f"sin cambios: {len(same)}")
    print(f"{'cambiarían' if dry else 'actualizados'}: {len(changed)}")
    for name in changed:
        print(f"  - {name}")
    if not dry and changed:
        print("\nRevisar con: git diff n8n/  (verificar que no haya secretos de producción)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
