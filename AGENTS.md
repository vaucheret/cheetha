# Chita Chatbot de Trámites — AGENTS.md

## Qué es este proyecto

Agente conversacional en español (protocolo A2A) que guía a los usuarios por trámites administrativos argentinos. Núcleo en SWI-Prolog, integración con WhatsApp vía Flask + Meta Cloud API, backend asíncrono con Kafka.

## Arquitectura

```
WhatsApp → Flask proxy (8070) → Prolog /chat (8000) → Kafka bridge (8090) → Kafka → Motor (simulado/real)
         ← Flask /enviar_mensaje ← Prolog /notificacion_tramite ← Kafka bridge ← Kafka ←
```

Alternativa: `flask_cloud_api_proxy_a2a.py` (8071), el mismo proxy pero actuando como **cliente A2A** del bridge (ver «Proxy WhatsApp vía A2A»).

- **chatbot.pl** — servidor HTTP, motor de diálogo (3 fases: buscar/confirmar/ejecutar), integración LLM (compatible OpenAI)
- **tramite_json.pl** — carga definiciones de trámites desde `tramites/*.json` locales y dos APIs remotas (RIL + GPS con auth por token)
- **persistencia.pl** — hechos persistentes en SQLite (`estado`, `tramite_pendiente`, `tramite_en_espera`, `dato_tramite`, `usuario_identificado`)
- **gramatica.pl** — parsers DCG para números (incl. spelling en español), fechas, booleanos
- **flask_cloud_api_proxy.py** — webhook de WhatsApp Cloud API, TTS (OpenAI), envío de PDF, enlaces DIDComm de identidad
- **flask_cloud_api_proxy_a2a.py** — igual que el anterior pero como cliente A2A del bridge (puerto 8071, proceso `flask_a2a`); alternativa al directo
- **kafka_bridge.py** — puentea Kafka `tramitesAsincronicos` → Prolog `/notificacion_tramite`
- **sistema_motor.py** / **motor_simulado.py** — procesadores backend simulados
- **chita_a2a_server.py** — bridge A2A (puerto 8001): expone a Chita como subagente vía protocolo A2A (JSON-RPC 2.0). Otros agentes (municipios) lo usan sin pasar por WhatsApp; también lo usa el proxy WhatsApp vía A2A
- **test_a2a_client.py** — cliente A2A de ejemplo (agente municipio ficticio)

## Arquitectura A2A (subagente)

```
                           ┌─ Bridge A2A (8001) ── /a2a (JSON-RPC)
Agentes municipio ── A2A ──┤   /.well-known/agent.json
(Google ADK, LangGraph…)   │   message/send → POST /chat_a2a (Prolog 8000)
                           │   tasks/get    → store in-memory del bridge
                           │   /internal/update_task ← Prolog (Kafka/DIDComm)
                           │        └─ push del Task → callback registrado
                           │           por el cliente (pushNotificationConfig)
                           │
WhatsApp ── Flask (8070) ──┤   POST /chat (8000, sin cambios)
WhatsApp ── Flask A2A (8071) ─┤   message/send → /a2a del bridge; push → /a2a/push
                           │
Kafka ── bridge (8090) ─→ Prolog /notificacion_tramite
   Prolog bifurca por Contexto.canal:
     whatsapp → POST FLASKURL/enviar_mensaje (como hoy)
     a2a      → POST 8001/internal/update_task
```

## Orden de inicio

### Forma recomendada: `chita.sh`

```bash
./chita.sh doctor             # preflight: binarios, .env, módulos Python, puertos
./chita.sh start              # levanta los 5 procesos, esperando readiness de cada uno
./chita.sh status             # tabla: proceso / PID / puerto / estado / uptime
./chita.sh restart prolog     # reinicia solo un proceso (ej. si falló el chatbot)
./chita.sh logs flask         # tail -f del log de un proceso (sin argumento: todos)
./chita.sh stop               # detiene todo en orden inverso
```

- PID files en `run/`, logs (con banner por arranque) en `logs/` (gitignored).
- Config por entorno: `CHITA_PROVIDER` (default `openai`), `PROLOG_PORT` (default `8000`), `PROLOG_READY_TIMEOUT` (default 90s), `PY_READY_TIMEOUT` (default 25s), `STOP_GRACE` (default 10s).
- Procesos: `prolog` (8000) → `a2a` (8001) → `kafka` (8090) → `flask` (8070) → `flask_a2a` (8071).
- `flask` y `flask_a2a` son alternativos: el webhook de WhatsApp (ngrok) apunta a uno solo; el otro queda en pie para pruebas. `FLASKURL` debe apuntar al proxy activo (Sovra registra el callback de identificación contra esa URL).
- El PID guardado para `prolog` es el del swipl real (dueño del puerto), no el del wrapper bash de flatpak (`~/.local/bin/swipl` → `flatpak run`), para que TERM/estado operen sobre el proceso correcto.

### Arranque manual (equivalente)

```bash
# 1. Chatbot Prolog (puerto 8000)
# OJO: '-t halt' a secas NO sirve: http_server/2 devuelve el control y el
# toplevel mata los threads al instante. Hace falta un goal bloqueante:
swipl -g "start_server(openai,8000)" -g "thread_get_message(_)" -t halt chatbot.pl
# o en REPL interactivo: start_server(openai,8000).

# 2. Bridge A2A (puerto 8001) — para que otros agentes usen a Chita como subagente
python3 chita_a2a_server.py

# 3. Kafka bridge (puerto 8090)
python3 kafka_bridge.py

# 4. (opcional) Motor simulado
python3 sistema_motor.py

# 5. Proxy Flask de WhatsApp (puerto 8070, habla directo con Prolog)
python3 flask_cloud_api_proxy.py
#    ...o su alternativa como cliente A2A (puerto 8071)
python3 flask_cloud_api_proxy_a2a.py

# 6. ngrok (exponer puerto 8070 o 8071 para WhatsApp, o 8001 para A2A)
ngrok http http://localhost:8070

# 7. Token de verificación del webhook de Meta (desde .env META_VERIFY_TOKEN):
#    mitokendeverificacion1739
```

## Variables `.env` requeridas

```
META_VERIFY_TOKEN=...
META_ACCESS_TOKEN=...
META_PHONE_NUMBER_ID=...
APP_ID=...
APP_SECRET=...
SHORT_TOKEN=...
PROLOG_BASE_URL=http://localhost:8000
KAFKA_BRIDGE_URL=http://localhost:8090
FLASKURL=https://<ngrok>.ngrok-free.app
# Opcional (A2A): si se setea, Prolog la usa para /internal/update_task
A2A_BRIDGE_URL=http://localhost:8001
# Opcional (proxy vía A2A): puerto de flask_cloud_api_proxy_a2a.py y URL que registra
# como callback de push en el bridge para los resultados asíncronos
A2A_FLASK_PORT=8071
A2A_PUSH_CALLBACK_URL=http://localhost:8071/a2a/push
# Opcional (Sovra): token Bearer y URL de PedirVerificacion para la identificación (si no, defaults en chatbot.pl)
SOVRA_TOKEN=...
SOVRA_PEDIR_VERIFICACION_URL=https://thinknetc3.ddns.net/chitaV2/APISovraV2/api/Sovra/PedirVerificacion
# Opcional: URLs de las APIs de trámites (si no se setean, se usan los defaults hardcodeados)
RIL_TRAMITES_URL=https://thinknetc3.ddns.net/chitaV2/APIRIL/api/TramitesRIL/ListarTramitesSimulados
GPS_TRAMITES_URL=https://thinknetc3.ddns.net/chitav2/apigps/api/Tramite/ListarConParametros?Ticket=qwqw
GPS_TOKEN_URL=https://thinknetc3.ddns.net/chitaV2/APIGPS/api/Login/ObtenerToken?Usuario=fcuello&Clave=fc1234%21
# Opcional: Kafka — broker y tópicos (chatbot.pl, kafka_bridge.py y motores simulados)
KAFKA_BROKER=66.70.179.213:9092
KAFKA_TOPICO_ENVIO=tramitesPrueba
KAFKA_TOPICO_RESPUESTA=tramitesAsincronicos
```

Dependencias Python (no hay requirements.txt): `flask`, `kafka-python`, `requests`, `python-dotenv`, `openai`, `phonenumbers`

## Proveedores LLM (chatbot.pl:28-32)

```prolog
set_provider(openai).    % gpt-4o-mini
set_provider(deepseek).  % deepseek/deepseek-chat-v3.1:free (via OpenRouter)
set_provider(gemini).    % google/gemini-2.0-flash-exp:free (OpenRouter)
set_provider(groq).      % openai/gpt-oss-20b
set_provider(ollamalocal). % gemma4:latest (localhost:11434)
```

## Máquina de estados del diálogo (chatbot.pl)

3 fases: `buscar_tramite` → `confirmar_tramite` → `ejecutar_tramite`
- Las transiciones de fase se gestionan con `assert_estado/4` / `retract_estado/4` (persistentes en SQLite `chatbot.db`)
- El LLM resuelve la intención en cada fase (`resolver_intencion_llm`, `resolver_intencion_pos_neg`, `resolver_intencion_cont`)
- Resultados de intención: `iniciar_nuevo`, `retomar_pendiente`, `preguntar`, `confirmar_si`, `confirmar_no`, `continuar`, `pausar_tramite`, `cancelar_tramite`

## Endpoints principales (chatbot.pl:68-72)

| Path | Método | Propósito |
|------|--------|-----------|
| `/chat` | POST | Diálogo principal WhatsApp (input: `{message:{user_id, text}}`, output: `{respuesta}`) |
| `/chat_a2a` | POST | Diálogo vía A2A (input: `{message:{user_id,text}, task_id, context_id}`, output: `{respuesta, estado, artifact?}`) |
| `/notificacion_tramite` | POST | Resultado asíncrono desde el puente Kafka |
| `/identificacion_usuario` | POST | Callback de verificación de identidad DIDComm |
| `/.well-known/agent.json` | GET | Agent card (legacy, protocolo custom) |

## Bridge A2A (chita_a2a_server.py, puerto 8001)

| Path | Método | Propósito |
|------|--------|-----------|
| `/.well-known/agent.json` | GET | Agent Card estándar A2A v0.2.6 |
| `/a2a` | POST | Despachador JSON-RPC 2.0 (`message/send`, `tasks/get`) |
| `/web` | GET | Interfaz web de testing (chat multi-turno desde el browser) |
| `/internal/update_task` | POST | Interno: Prolog notifica resultados asíncronos (Kafka/DIDComm) al bridge |

Push notifications: `message/send` acepta `params.pushNotificationConfig.url` (o `params.configuration.pushNotificationConfig.url`, o `message.metadata.callbackUrl`). El bridge guarda `{task_id: url}` y, cuando Prolog empuja un resultado a `/internal/update_task`, reenvía el Task actualizado a ese callback en un thread (para no bloquear el timeout de 5s de Prolog). En memoria: los clientes re-registran el callback en cada `message/send`.

Mapeo TaskState A2A ↔ fase Chita:
- `buscar/confirmar/ejecutar_tramite` pidiendo dato → `input-required`
- `tramite_completado` → export Kafka → `working`
- `handle_notificacion` Accion=4 (resultado) → `completed` + Artifact
- `solicitar_identificacion` (Sovra OID4VP) → `auth-required` + Artifact QR: el chatbot guarda `deep_link_verificacion` (URI `openid4vp://` ref) en el contexto de `tramite_en_espera`; `handle_chat_a2a` lo devuelve como Artifact y el bridge lo convierte a PNG data-URI (lib `qrcode`) para que `/web` lo muestre escaneable
- `terminar` / cancelar → `canceled`

El canal de salida (`enviar_resultado/5` en chatbot.pl) bifurca por `Contexto.canal`:
- `whatsapp` (default) → POST `FLASKURL/enviar_mensaje` (como hoy, retrocompatible)
- `a2a` → POST `A2A_BRIDGE_URL/internal/update_task`

## Proxy WhatsApp vía A2A (flask_cloud_api_proxy_a2a.py, puerto 8071)

Misma lógica de WhatsApp que el proxy directo (webhook, TTS, PDF, CTA de identificación, `/identificar`, `/identificacion_usuario`), pero actúa como **cliente A2A puro** del bridge, igual que cualquier agente externo:

- Turno del usuario → `message/send` (JSON-RPC 2.0) al bridge con `pushNotificationConfig.url` apuntando a su `A2A_PUSH_CALLBACK_URL` (`/a2a/push`).
- Respuesta síncrona: texto de `task.status.message` → WhatsApp (PDF si hay link, CTA si contiene `/identificar?`).
- Resultados asíncronos: Prolog → `/internal/update_task` → el bridge pushea el Task → `/a2a/push` entrega a WhatsApp sólo los mensajes agent nuevos del `history` (índice `delivered_hist` por sesión, evita duplicar la respuesta síncrona).
- Sesión en memoria: `sender_wa → {context_id, task_id, delivered_hist}` + `task_id → sender_wa`; un `context_id` estable por número de WhatsApp.
- No expone `/enviar_mensaje` (con `canal:a2a` el Prolog no lo usa).
- Env vars: `A2A_FLASK_PORT` (default 8071), `A2A_PUSH_CALLBACK_URL` (default `http://localhost:8071/a2a/push`).

**Riesgo conocido (revisar más adelante):** tanto el mapeo de sesiones del proxy como los callbacks de push y los tasks del bridge viven sólo en memoria. Si se reinicia el bridge o el proxy se pierden los tasks/callbacks activos: los resultados asíncronos en vuelo (Kafka/DIDComm) no llegan a WhatsApp hasta el próximo `message/send` del usuario (que re-registra el callback y recrea el task con el mismo id). Antes de producción: persistir el mapeo (SQLite) y/o re-registro de callbacks, y evaluar persistencia de tasks en el bridge.

## Carga de trámites

Tres fuentes se cargan al inicio (en orden):
1. API RIL remota → `tramite_codigo_nombre_descripcion_motor/4`
2. API GPS remota (con bearer token de `thinknetc3.ddns.net`) → actualiza existentes + agrega `flujo_tramite_codigo_pasos/2`
3. `tramites/*.json` locales → agrega trámites estáticos con `automatizado:false`

Los trámites de GPS cuyo `codigoRIL` no matchea nada de RIL se ignoran con un "Aviso:" en el log (antes, uno solo de estos desincronizados hacía fallar `start_server` completo y el servidor no arrancaba).

## Persistencia

SQLite vía `library(persistency)`, archivo: `chatbot.db`. Hechos: `estado/4`, `tramite_pendiente/4`, `tramite_en_espera/4`, `dato_tramite/5`, `usuario_identificado/3`.

## Advertencias

- No hay archivos de gestor de paquetes (no `requirements.txt`, no `package.json`). Instalar dependencias Python manualmente.
- Prolog requiere SWI-Prolog con `library(persistency)` (incluida) y `library(http)`.
- La caché de preguntas persiste en `pregunta_cache.pl` al completar un trámite.
- `.env` está en `.gitignore`; nunca commitear secretos.
- `estado_usuarios.pl` está gitignorado (archivo de estado en runtime).
- Git remote: `https://github.com/vaucheret/cheetha.git`
- Sin framework de testing automatizado. Scripts de test informales: `testurl.pl`, `test_url_asincronico.pl`.
- Normalización de números de WhatsApp en `flask_cloud_api_proxy.py:105-116` — maneja prefijo argentino `549`.
