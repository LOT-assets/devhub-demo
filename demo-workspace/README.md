# demo-workspace

Esta es la carpeta que se abre en VSCodium (o VS Code) el día del demo. Es la "mesa de trabajo" del desarrollador: deliberadamente está vacía de código — todo lo que aparece durante la demo sale de Developer Hub a través del asistente de IA, no de algo ya preparado aquí.

## Qué contiene

| Archivo | Para qué |
|---|---|
| `.mcp.json` | Registra el servidor MCP de RHDH (`rhdh-mcp`) a nivel de proyecto, vía HTTP con bearer token. Usa variables de entorno (`RHDH_MCP_URL`, `RHDH_MCP_TOKEN`) en vez de valores fijos, así el archivo es commiteable sin exponer secretos. |
| `.vscode/extensions.json` | Recomienda la extensión de Claude Code, para que Codium la sugiera al abrir la carpeta si no está instalada. |
| `.env` | **No versionado** (ver `.gitignore`). Trae `RHDH_MCP_URL`/`RHDH_MCP_TOKEN` reales, generado automáticamente por `../install/deploy-demo.sh` al final del despliegue. |
| `.env.example` | Referencia de las claves que espera `.env`, por si necesitas setearlas a mano. |

## Antes de salir a demo

1. Corre `../install/deploy-demo.sh` — al terminar, escribe `.env` en esta carpeta con la URL y el token del RHDH recién desplegado.
2. Abre esta carpeta en Codium/VS Code.
3. La primera vez que uses el asistente aquí, Claude Code va a pedir confirmar que confías en el `.mcp.json` del proyecto (workspace trust). **Acepta ese diálogo antes de la demo en vivo**, no durante — si quieres resetear la decisión, `claude mcp reset-project-choices`.
4. Verifica que el servidor MCP responde: pídele al asistente que liste los golden paths o systems disponibles en el catálogo (debería consultar `rhdh-mcp`).

## Guion sugerido del demo

Con el workspace ya confiado y el MCP respondiendo, la demo consiste en pedirle al asistente que trabaje **a través** de Developer Hub en vez de a partir de conocimiento genérico:

1. "¿Qué golden paths hay disponibles en Developer Hub?" → debería listar `simple-frontend` (`../initial-catalog/templates/`).
2. "¿Qué systems y APIs existen ya en el catálogo de FinBridge?" → debería listar los 4 systems y las 3 APIs de `../initial-catalog`, para mostrar que el agente arquitecta la solución nueva sabiendo qué ya existe.
3. "Crea un componente nuevo usando el golden path simple-frontend, para <caso de uso>, owned by <team>, system <uno de los 4>." → el asistente debería invocar el golden path vía MCP, publicar el repo y registrarlo en el catálogo.
4. Volver al catálogo (UI de RHDH) y mostrar que el componente nuevo ya aparece — cerrando el ciclo: el catálogo creció solo, sin edición manual.
