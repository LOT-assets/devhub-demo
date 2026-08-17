# Instalación de Red Hat Developer Hub (RHDH)

Esta carpeta contiene todo lo necesario para desplegar RHDH sobre un cluster de OpenShift **ya existente**, con:

- Los 3 plugins dinámicos de MCP habilitados (acciones de Backstage, catálogo de software, TechDocs).
- El catálogo de FinBridge (`../initial-catalog`) descubierto vía GitHub.
- Login real vía Keycloak OIDC.
- `../demo-workspace/.env` listo para que Codium/VS Code se conecte al MCP de RHDH.
- Red Hat Trusted Artifact Signer (RHTAS) desplegado, integrado con el mismo Keycloak.
- Red Hat Trusted Profile Analyzer (RHTPA) desplegado (operador comunitario `trustify-operator`, Technology Preview).

## Contenido

| Archivo | Descripción |
|---|---|
| `deploy-demo.sh` | Script principal de instalación. Idempotente: puede volver a ejecutarse sin efectos secundarios. |
| `pull-secret.txt` | Pull secret (`dockerconfigjson`) para `registry.redhat.io` / `quay.io`. **Contiene credenciales, no lo compartas ni lo subas a git.** |
| `github-token.txt` | Personal Access Token **classic** (scope `repo`) sobre la org `FinBridgeDemo`, usado por RHDH tanto para descubrir `../initial-catalog` como para que el golden path `simple-frontend` pueda crear repos nuevos vía `publish:github`. **Contiene credenciales, no lo compartas ni lo subas a git.** Trae un valor placeholder por defecto; el script falla si no lo reemplazas. |
| `rhdh-values.yaml` | `values.yaml` del chart de Helm. **Generado por el script** (heredoc en el paso 6) — se sobrescribe en cada ejecución. |

Si necesitas cambiar los values del chart de forma permanente (plugins, ubicación del catálogo, etc.), edita el heredoc dentro de `deploy-demo.sh`, no `rhdh-values.yaml` directamente (se pierde en la siguiente ejecución).

## Prerequisitos

1. Sesión activa de `oc login` contra el cluster destino, apuntando a un namespace vacío (el script crea el namespace `backstage`).
2. Un `pull-secret.txt` válido en esta carpeta, con credenciales para `registry.redhat.io` / `quay.io`.
3. Un `github-token.txt` válido en esta carpeta: un Personal Access Token **classic** con scope `repo`, de un usuario miembro de la org `FinBridgeDemo`. Tiene que ser classic — los fine-grained PAT no pueden crear repositorios (ni con `Administration: Read and write` en Organization permissions), y ese golden path los necesita para el paso `publish:github`. El repo `../initial-catalog` debe estar pusheado a `github.com/FinBridgeDemo/devhub-demo` — el script no lo hace por ti.
4. Un Keycloak (operador RHBK) **ya desplegado** en el namespace `keycloak`, con:
   - Secret `keycloak-initial-admin` (admin de bootstrap del realm `master`).
   - Un realm ya importado (por defecto `sso`, ver `KEYCLOAK_REALM` en el script).

   El script **no instala Keycloak**, solo crea un client OIDC dentro de él.

   Nota: el login OIDC usa el resolver `preferredUsernameMatchingUserEntityName`, es decir que el usuario de Keycloak que inicia sesión debe existir como entidad `User` en el catálogo. El demo trae un `User: admin` en `../initial-catalog/org/teams.yaml` para esto — si inicias sesión con otro usuario de Keycloak, agrégalo también al catálogo.

## Uso

```bash
cd install
./deploy-demo.sh
```

El script:

1. Instala `helm` localmente en `~/bin/helm` si no está disponible.
2. Crea el namespace `backstage` y el pull secret.
3. Crea el secret con el token de GitHub para el discovery del catálogo.
4. Genera un token bearer para autenticación MCP.
5. Crea (o recrea, si ya existe) el client OIDC `backstage` en el realm de Keycloak.
6. Renderiza `rhdh-values.yaml` con plugins MCP + OIDC + integración GitHub + discovery del catálogo de FinBridge.
7. Instala/actualiza el chart `redhat-developer-hub` vía Helm y espera a que el pod quede listo.
8. Si detecta el CLI `claude` localmente, registra el endpoint MCP de RHDH (`claude mcp add`). Si detecta `codium`, instala la extensión de Claude Code.
9. Escribe `../demo-workspace/.env` con `RHDH_MCP_URL` y `RHDH_MCP_TOKEN`, que es lo que usa el `.mcp.json` de esa carpeta para conectarse al RHDH recién desplegado (ver `../demo-workspace/README.md`).
10. Si `RHTAS_ENABLED=true` (default): instala el operador RHTAS, crea un client OIDC (`trusted-artifact-signer`) en el mismo Keycloak, y crea una instancia `Securesign` (Fulcio + Rekor + TUF + TSA) en el namespace `trusted-artifact-signer`.
11. Si `RHTPA_ENABLED=true` (default): instala el operador RHTPA (`trustify-operator`, canal `alpha`, catálogo `community-operators`) y crea una instancia `Trustify` con spec vacío (defaults del operador: Server + UI) en el namespace `trusted-profile-analyzer`.

Al finalizar imprime un resumen con la URL de RHDH, el modo de login, el `MCP_TOKEN`, y el estado de RHTAS/RHTPA (también queda guardado en el secret `rhdh-mcp-token` del namespace `backstage`).

El catálogo tarda hasta el `schedule.frequency` del provider de GitHub (30 min por defecto, configurado en el `pluginConfig` del dynamic plugin `backstage-plugin-catalog-backend-module-github-dynamic` dentro del heredoc) en poblarse la primera vez; para forzarlo antes, revisa los logs del pod de RHDH o reduce ese valor temporalmente en el heredoc.

## RHTAS y RHTPA

### RHTAS (Red Hat Trusted Artifact Signer) — confirmado, activo por defecto

Instala `rhtas-operator` (canal `stable`, catálogo `redhat-operators`, namespace `rhtas-operator` — OpenShift no deja crear proyectos con prefijo `openshift-`) y crea una instancia `Securesign` (Fulcio, Rekor, TUF, TSA con ingress habilitado) en el namespace `trusted-artifact-signer`, con Fulcio apuntando al mismo Keycloak que usa RHDH (client OIDC `trusted-artifact-signer`, público).

**Sin validar contra un cluster real todavía**: el client OIDC (`redirectUris: ["http://localhost:*", "http://localhost:*/*"]`) es el flujo típico que usa `cosign` para login interactivo, pero no se probó de punta a punta. Si el login de `cosign`/RHTAS falla, lo primero a revisar es ese client en Keycloak.

Para desactivarlo: `RHTAS_ENABLED="false"` al inicio de `deploy-demo.sh`.

### RHTPA (Red Hat Trusted Profile Analyzer) — confirmado, activo por defecto

Es **Technology Preview** (sin SLA de producción) y, al menos en el catálogo de operadores probado, solo está disponible como operador **comunitario** (`trustify-operator`, catálogo `community-operators`, canal `alpha` — no hay un paquete "Red Hat Operators" separado). Confirmado corriendo `oc get packagemanifest trustify-operator -n openshift-marketplace -o json` contra un cluster real.

El CRD (`Trustify`, `org.trustify/v1alpha1`) solo soporta `installMode: OwnNamespace` — el operador y la instancia comparten el namespace `trusted-profile-analyzer` (a diferencia de RHTAS, que usa un namespace separado para el operador). La instancia se crea con `spec: {}` (el `alm-examples` oficial del operador), que según su descripción instala Server + UI con sus defaults.

**No investigado todavía:** integración con Keycloak/OIDC — el `spec` vacío no configura autenticación. Una vez desplegado, `oc explain trustify.spec -n trusted-profile-analyzer` muestra los campos disponibles si se quiere ajustar.

Para desactivarlo: `RHTPA_ENABLED="false"` al inicio de `deploy-demo.sh`.

## Variables principales

Configurables al inicio de `deploy-demo.sh`:

| Variable | Valor por defecto | Descripción |
|---|---|---|
| `NAMESPACE` | `backstage` | Namespace donde se instala RHDH. |
| `RELEASE` | `rhdh` | Nombre del release de Helm. |
| `CHART_VERSION` | `1.9.7` | Versión del chart, fijada para que coincida con la versión de Backstage core requerida por los 3 plugins MCP. |
| `KEYCLOAK_NAMESPACE` | `keycloak` | Namespace donde vive Keycloak. |
| `KEYCLOAK_REALM` | `sso` | Realm donde se crea el client OIDC. |
| `KEYCLOAK_CLIENT_ID` | `backstage` | Client ID del client OIDC creado para RHDH. |
| `GITHUB_ORG` | `FinBridgeDemo` | Organización de GitHub sobre la que corre el discovery provider del catálogo y donde el golden path publica repos nuevos. |
| `GITHUB_REPO` | `devhub-demo` | Repo que contiene `../initial-catalog`. |
| `GITHUB_BRANCH` | `main` | Rama usada en las locations explícitas de `org/` y `apis/`. |
| `RHTAS_ENABLED` | `true` | Instala o no RHTAS. |
| `RHTAS_NAMESPACE` | `trusted-artifact-signer` | Namespace de la instancia `Securesign`. |
| `RHTPA_ENABLED` | `true` | Instala o no RHTPA. |
| `RHTPA_NAMESPACE` | `trusted-profile-analyzer` | Namespace compartido del operador y la instancia `Trustify`. |

`CLUSTER_DOMAIN` y los hostnames derivados (`RHDH_HOST`, `KEYCLOAK_HOST`) se descubren en tiempo de ejecución desde el cluster, no están hardcodeados.
