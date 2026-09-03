# Chita Chatbot de Trámites — AGENTS.md

## Qué es este proyecto

Agente conversacional en español (protocolo A2A) que guía a los usuarios por trámites administrativos argentinos. Núcleo en SWI-Prolog, integración con WhatsApp vía Flask + Meta Cloud API, backend asíncrono con Kafka.

## Arquitectura

```
WhatsApp → Flask proxy (8070) → Prolog /chat (8000) → Kafka bridge (8090) → Kafka → Motor (simulado/real)
         ← Flask /enviar_mensaje ← Prolog /notificacion_tramite ← Kafka bridge ← Kafka ←
```

- **chatbot.pl** — servidor HTTP, motor de diálogo (3 fases: buscar/confirmar/ejecutar), integración LLM (compatible OpenAI)
- **tramite_json.pl** — carga definiciones de trámites desde `tramites/*.json` locales y dos APIs remotas (RIL + GPS con auth por token)
- **persistencia.pl** — hechos persistentes en SQLite (`estado`, `tramite_pendiente`, `tramite_en_espera`, `dato_tramite`, `usuario_identificado`)
- **gramatica.pl** — parsers DCG para números (incl. spelling en español), fechas, booleanos
- **flask_cloud_api_proxy.py** — webhook de WhatsApp Cloud API, TTS (OpenAI), envío de PDF, enlaces DIDComm de identidad
- **kafka_bridge.py** — puentea Kafka `tramitesAsincronicos` → Prolog `/notificacion_tramite`
- **sistema_motor.py** / **motor_simulado.py** — procesadores backend simulados
- **chita_a2a_server.py** — bridge A2A (puerto 8001): expone a Chita como subagente vía protocolo A2A (JSON-RPC 2.0). Otros agentes (municipios) lo usan sin pasar por WhatsApp
- **test_a2a_client.py** — cliente A2A de ejemplo (agente municipio ficticio)

## Arquitectura A2A (subagente)

```
                           ┌─ Bridge A2A (8001) ── /a2a (JSON-RPC)
Agentes municipio ── A2A ──┤   /.well-known/agent.json
(Google ADK, LangGraph…)   │   message/send → POST /chat_a2a (Prolog 8000)
                           │   tasks/get    → store in-memory del bridge
                           │   /internal/update_task ← Prolog (Kafka/DIDComm)
                           │
WhatsApp ── Flask (8070) ──┤   POST /chat (8000, sin cambios)
                           │
Kafka ── bridge (8090) ─→ Prolog /notificacion_tramite
   Prolog bifurca por Contexto.canal:
     whatsapp → POST FLASKURL/enviar_mensaje (como hoy)
     a2a      → POST 8001/internal/update_task
```

## Orden de inicio

```bash
# 1. Chatbot Prolog (puerto 8000)
swipl -g "start_server(openai,8000)." -t halt chatbot.pl
# o en REPL interactivo: start_server(openai,8000).

# 2. Bridge A2A (puerto 8001) — para que otros agentes usen a Chita como subagente
python3 chita_a2a_server.py

# 3. Kafka bridge (puerto 8090)
python3 kafka_bridge.py

# 4. (opcional) Motor simulado
python3 sistema_motor.py

# 5. Proxy Flask de WhatsApp (puerto 8070)
python3 flask_cloud_api_proxy.py

# 6. ngrok (exponer puerto 8070 para WhatsApp, o 8001 para A2A)
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
# Opcional: URLs de las APIs de trámites (si no se setean, se usan los defaults hardcodeados)
RIL_TRAMITES_URL=https://thinknetc3.ddns.net/chitaV2/APIRIL/api/TramitesRIL/ListarTramitesSimulados
GPS_TRAMITES_URL=https://thinknetc3.ddns.net/chitav2/apigps/api/Tramite/ListarConParametros?Ticket=qwqw
GPS_TOKEN_URL=https://thinknetc3.ddns.net/chitaV2/APIGPS/api/Login/ObtenerToken?Usuario=fcuello&Clave=fc1234%21
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

Mapeo TaskState A2A ↔ fase Chita:
- `buscar/confirmar/ejecutar_tramite` pidiendo dato → `input-required`
- `tramite_completado` → export Kafka → `working`
- `handle_notificacion` Accion=4 (resultado) → `completed` + Artifact
- `solicitar_identificacion` (DIDComm) → `auth-required`
- `terminar` / cancelar → `canceled`

El canal de salida (`enviar_resultado/5` en chatbot.pl) bifurca por `Contexto.canal`:
- `whatsapp` (default) → POST `FLASKURL/enviar_mensaje` (como hoy, retrocompatible)
- `a2a` → POST `A2A_BRIDGE_URL/internal/update_task`

## Carga de trámites

Tres fuentes se cargan al inicio (en orden):
1. API RIL remota → `tramite_codigo_nombre_descripcion_motor/4`
2. API GPS remota (con bearer token de `thinknetc3.ddns.net`) → actualiza existentes + agrega `flujo_tramite_codigo_pasos/2`
3. `tramites/*.json` locales → agrega trámites estáticos con `automatizado:false`

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
