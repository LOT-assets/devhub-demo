#!/usr/bin/env bash
# ==============================================================================
# Despliega Red Hat Developer Hub (RHDH) con el plugin dinámico de MCP habilitado,
# el catálogo de FinBridge (../initial-catalog) descubierto vía GitHub, login
# real vía Keycloak OIDC, y los operadores OpenShift GitOps y OpenShift Pipelines.
#
# Prerequisitos:
#   - Sesión activa de `oc login` contra el cluster destino (namespace vacío).
#   - Un pull-secret.txt válido con credenciales para registry.redhat.io / quay.io.
#   - Un github-token.txt con un Personal Access Token de solo lectura sobre el
#     repo GITHUB_ORG/GITHUB_REPO (ver variables abajo), usado por RHDH para
#     descubrir el catálogo de ../initial-catalog. Ese repo debe estar pusheado.
#   - Un Keycloak (RHBK operator) YA desplegado en el namespace `keycloak`, con:
#       - Secret `keycloak-initial-admin` (bootstrap admin del realm master)
#       - Un realm ya importado (ver KEYCLOAK_REALM abajo)
#     Este script NO instala Keycloak, solo crea un client OIDC dentro de él.
# ==============================================================================
set -euo pipefail

# ---- Variables --------------------------------------------------------------
NAMESPACE="backstage"
RELEASE="rhdh"
CHART_VERSION="1.9.7"                 # RHDH 1.9.7 == Backstage core 1.45.3,
                                       # versión con la que coinciden los 3 plugins MCP (ver abajo)

# Validamos que oc este instalado y exista una sesión activa antes de ejecutar el script o retornamos error con código 1
if ! command -v oc &>/dev/null; then
    echo "Error: oc no encontrado en la ruta del PATH."
    exit 1
fi

if ! oc whoami &>/dev/null; then
    echo "Error: No hay una sesión activa en OpenShift. Por favor, ejecuta 'oc login' primero."
    exit 1
fi 

# extraemos el nombre del cluster domain al cual estamos conectados
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
RHDH_HOST="backstage-backstage.${CLUSTER_DOMAIN}"

KEYCLOAK_NAMESPACE="keycloak"
KEYCLOAK_HOST="sso.${CLUSTER_DOMAIN}"
KEYCLOAK_REALM="sso"
KEYCLOAK_CLIENT_ID="backstage"

GITHUB_ORG="FinBridgeDemo"
GITHUB_REPO="devhub-demo"          # repo que contiene ../initial-catalog
GITHUB_BRANCH="main"

# ---- Red Hat Trusted Artifact Signer (RHTAS) --------------------------------
# Confirmado contra github.com/securesign/secure-sign-operator (docs/openshift.md
# + config/samples/rhtas_v1_securesign.yaml). RHTAS_ENABLED=false para saltarse
# este bloque sin borrar el resto del script.
RHTAS_ENABLED="true"
RHTAS_OPERATOR_NAMESPACE="rhtas-operator"   # OpenShift no permite crear proyectos con prefijo "openshift-"
RHTAS_NAMESPACE="trusted-artifact-signer"   # namespace donde vive la instancia (Securesign CR)
RHTAS_CLIENT_ID="trusted-artifact-signer"   # client OIDC en Keycloak, para el login de Fulcio

# ---- Red Hat Trusted Profile Analyzer (RHTPA) --------------------------------
# Confirmado contra un packagemanifest real (no hay operador "Red Hat" separado
# en este catálogo, solo el comunitario). Es Technology Preview (sin SLA de
# producción). El CRD (Trustify) solo soporta installMode "OwnNamespace", así
# que operador e instancia comparten un único namespace.
RHTPA_ENABLED="true"
RHTPA_NAMESPACE="trusted-profile-analyzer"
RHTPA_PACKAGE="trustify-operator"
RHTPA_CHANNEL="alpha"
RHTPA_CATALOG_SOURCE="community-operators"

PULL_SECRET_FILE="$(dirname "$0")/pull-secret.txt"
GITHUB_TOKEN_FILE="$(dirname "$0")/github-token.txt"
VALUES_FILE="$(dirname "$0")/rhdh-values.yaml"
WORKSPACE_ENV_FILE="$(dirname "$0")/../demo-workspace/.env"

HELM_BIN="${HOME}/bin/helm"
SCRATCH_DIR="$(mktemp -d)"
trap 'rm -rf "$SCRATCH_DIR"' EXIT

# Validamos que exista un PAT de GitHub real (no el placeholder) antes de seguir
if [ ! -f "$GITHUB_TOKEN_FILE" ] || [ "$(tr -d '[:space:]' < "$GITHUB_TOKEN_FILE")" = "REPLACE_WITH_YOUR_GITHUB_TOKEN" ]; then
    echo "Error: ${GITHUB_TOKEN_FILE} no existe o todavía tiene el valor de ejemplo."
    echo "       Genera un PAT de solo lectura sobre ${GITHUB_ORG}/${GITHUB_REPO} y guárdalo ahí (sin saltos de línea extra)."
    exit 1
fi

# ---- 1. Operadores de cluster: OpenShift GitOps + OpenShift Pipelines ---------
install_operator() {
  local NAME="$1" PACKAGE="$2" CHANNEL="$3" NS="$4"
  if oc get subscription "$NAME" -n "$NS" &>/dev/null; then
    echo "==> Operador ${NAME} ya existe en ${NS}, se omite"
    return 0
  fi
  echo "==> Instalando operador ${NAME} (canal ${CHANNEL}) en ${NS}"
  cat <<EOFSUB | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${NAME}
  namespace: ${NS}
spec:
  channel: ${CHANNEL}
  installPlanApproval: Automatic
  name: ${PACKAGE}
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOFSUB
}

wait_for_operator() {
  local NAME="$1" NS="$2" TIMEOUT="${3:-300}"
  echo "==> Esperando CSV del operador ${NAME} en ${NS} (timeout ${TIMEOUT}s)..."
  local ELAPSED=0
  while [ $ELAPSED -lt $TIMEOUT ]; do
    local CSV
    CSV=$(oc get subscription "$NAME" -n "$NS" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
    if [ -n "$CSV" ]; then
      local PHASE
      PHASE=$(oc get csv "$CSV" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)
      if [ "$PHASE" = "Succeeded" ]; then
        echo "    ${CSV} → Succeeded"
        return 0
      fi
    fi
    sleep 10
    ELAPSED=$((ELAPSED + 10))
  done
  echo "Error: timeout esperando operador ${NAME}" >&2
  exit 1
}

install_operator "openshift-gitops-operator" "openshift-gitops-operator" "latest" "openshift-operators"
install_operator "openshift-pipelines-operator" "openshift-pipelines-operator-rh" "latest" "openshift-operators"

wait_for_operator "openshift-gitops-operator" "openshift-operators"
wait_for_operator "openshift-pipelines-operator" "openshift-operators"

# ---- 2. Instalar helm (si no está disponible) ---------------------------------
if [ ! -x "$HELM_BIN" ]; then
  echo "==> Instalando helm en ${HELM_BIN}"
  mkdir -p "$(dirname "$HELM_BIN")"
  HELM_VERSION=$(curl -fsSL https://get.helm.sh/helm-latest-version)
  curl -fsSL -o "$SCRATCH_DIR/helm.tar.gz" "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"
  curl -fsSL -o "$SCRATCH_DIR/helm.tar.gz.sha256sum" "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum"
  (cd "$SCRATCH_DIR" && echo "$(cat helm.tar.gz.sha256sum | awk '{print $1}')  helm.tar.gz" | sha256sum -c -)
  tar -xzf "$SCRATCH_DIR/helm.tar.gz" -C "$SCRATCH_DIR"
  cp "$SCRATCH_DIR/linux-amd64/helm" "$HELM_BIN"
  chmod +x "$HELM_BIN"
fi
"$HELM_BIN" version

# ---- 3. Namespace + pull secret -----------------------------------------------
echo "==> Creando namespace ${NAMESPACE}"
oc get namespace "$NAMESPACE" >/dev/null 2>&1 || oc new-project "$NAMESPACE"

echo "==> Creando pull secret desde ${PULL_SECRET_FILE}"
oc create secret generic rhdh-pull-secret \
  --from-file=.dockerconfigjson="$PULL_SECRET_FILE" \
  --type=kubernetes.io/dockerconfigjson \
  -n "$NAMESPACE" --dry-run=client -o yaml | oc apply -f -
oc secrets link default rhdh-pull-secret --for=pull -n "$NAMESPACE"

echo "==> Otorgando cluster-reader al SA default/${NAMESPACE} (kubernetes plugin)"
oc adm policy add-cluster-role-to-user cluster-reader \
  "system:serviceaccount:${NAMESPACE}:default" 2>/dev/null || true

# ---- 4. Token GitHub para discovery del catálogo -------------------------------
echo "==> Creando secret con el token de GitHub para descubrir ${GITHUB_ORG}/${GITHUB_REPO}"
GITHUB_TOKEN=$(tr -d '[:space:]' < "$GITHUB_TOKEN_FILE")
oc create secret generic rhdh-github-token \
  --from-literal=token="$GITHUB_TOKEN" \
  -n "$NAMESPACE" --dry-run=client -o yaml | oc apply -f -

# ---- 5. Token MCP -------------------------------------------------------------
echo "==> Generando token MCP"
MCP_TOKEN=$(python3 -c "import secrets; print(secrets.token_hex(32))")
oc create secret generic rhdh-mcp-token \
  --from-literal=token="$MCP_TOKEN" \
  -n "$NAMESPACE" --dry-run=client -o yaml | oc apply -f -

# ---- 6. Cliente OIDC en Keycloak ----------------------------------------------
echo "==> Creando cliente OIDC '${KEYCLOAK_CLIENT_ID}' en el realm ${KEYCLOAK_REALM}"
KC="https://${KEYCLOAK_HOST}"
KC_ADMIN_USER=$(oc get secret keycloak-initial-admin -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.data.username}' | base64 -d)
KC_ADMIN_PASS=$(oc get secret keycloak-initial-admin -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.data.password}' | base64 -d)

KC_TOKEN=$(curl -fsS -X POST "$KC/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" -d "username=$KC_ADMIN_USER" -d "password=$KC_ADMIN_PASS" -d "grant_type=password" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])")

KEYCLOAK_CLIENT_SECRET=$(python3 -c "import secrets;print(secrets.token_urlsafe(24))")

# Idempotencia: si el client ya existe, lo borramos y lo recreamos
EXISTING_ID=$(curl -fsS "$KC/admin/realms/${KEYCLOAK_REALM}/clients?clientId=${KEYCLOAK_CLIENT_ID}" \
  -H "Authorization: Bearer $KC_TOKEN" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d[0]['id'] if d else '')")
if [ -n "$EXISTING_ID" ]; then
  curl -fsS -X DELETE "$KC/admin/realms/${KEYCLOAK_REALM}/clients/$EXISTING_ID" -H "Authorization: Bearer $KC_TOKEN"
fi

curl -fsS -X POST "$KC/admin/realms/${KEYCLOAK_REALM}/clients" \
  -H "Authorization: Bearer $KC_TOKEN" -H "Content-Type: application/json" \
  -d '{
    "clientId": "'"$KEYCLOAK_CLIENT_ID"'",
    "enabled": true,
    "protocol": "openid-connect",
    "publicClient": false,
    "standardFlowEnabled": true,
    "directAccessGrantsEnabled": false,
    "serviceAccountsEnabled": false,
    "clientAuthenticatorType": "client-secret",
    "secret": "'"$KEYCLOAK_CLIENT_SECRET"'",
    "redirectUris": ["https://'"$RHDH_HOST"'/api/auth/oidc/handler/frame"],
    "webOrigins": ["https://'"$RHDH_HOST"'"],
    "attributes": {"post.logout.redirect.uris": "https://'"$RHDH_HOST"'/*"}
  }'

oc create secret generic rhdh-keycloak-oidc \
  --from-literal=client-id="$KEYCLOAK_CLIENT_ID" \
  --from-literal=client-secret="$KEYCLOAK_CLIENT_SECRET" \
  -n "$NAMESPACE" --dry-run=client -o yaml | oc apply -f -

# requerido por el provider oidc de Backstage para manejo de sesión/cookies (passport)
SESSION_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
oc create secret generic rhdh-session-secret \
  --from-literal=secret="$SESSION_SECRET" \
  -n "$NAMESPACE" --dry-run=client -o yaml | oc apply -f -

# ---- 7. Token ArgoCD para el plugin de GitOps ----------------------------------
ARGOCD_NAMESPACE="openshift-gitops"
ARGOCD_HOST="openshift-gitops-server-openshift-gitops.${CLUSTER_DOMAIN}"
ARGOCD_URL="https://${ARGOCD_HOST}"

echo "==> Esperando a que ArgoCD esté listo..."
oc wait --for=condition=available deployment/openshift-gitops-server \
  -n "$ARGOCD_NAMESPACE" --timeout=300s

echo "==> Generando token de API de ArgoCD"
ARGOCD_ADMIN_PASS=$(oc get secret openshift-gitops-cluster \
  -n "$ARGOCD_NAMESPACE" -o jsonpath='{.data.admin\.password}' | base64 -d)

# El operador de OpenShift GitOps reconcilia argocd-cm de forma declarativa
# contra el CR ArgoCD: un 'oc patch configmap argocd-cm' directo se revierte
# casi al instante. La forma persistente es spec.extraConfig en el CR.
oc patch argocd openshift-gitops -n "$ARGOCD_NAMESPACE" --type merge \
  -p '{"spec":{"extraConfig":{"accounts.admin":"apiKey, login"}}}'

echo "==> Esperando a que el operador reconcilie accounts.admin en argocd-cm..."
for i in $(seq 1 12); do
  if [ "$(oc get configmap argocd-cm -n "$ARGOCD_NAMESPACE" -o jsonpath='{.data.accounts\.admin}' 2>/dev/null)" = "apiKey, login" ]; then
    break
  fi
  sleep 5
done

# 'deployment available' no garantiza que el servidor de ArgoCD ya terminó de
# inicializar sus rutas HTTP (se vio un 415 transitorio justo después de que
# el deployment queda 'available'); reintentamos con backoff en vez de asumir
# que el primer intento va a funcionar.
ARGOCD_SESSION=""
for i in $(seq 1 6); do
  ARGOCD_SESSION=$(curl -kfsS -X POST "${ARGOCD_URL}/api/v1/session" \
    -H "Content-Type: application/json" \
    -d '{"username":"admin","password":"'"${ARGOCD_ADMIN_PASS}"'"}' 2>/dev/null \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)
  if [ -n "$ARGOCD_SESSION" ]; then
    break
  fi
  echo "    ArgoCD API todavía no responde, reintentando en 5s (intento $i/6)..."
  sleep 5
done
if [ -z "$ARGOCD_SESSION" ]; then
  echo "Error: no se pudo obtener un session token de ArgoCD tras 6 intentos." >&2
  exit 1
fi

ARGOCD_AUTH_TOKEN=""
for i in $(seq 1 6); do
  ARGOCD_AUTH_TOKEN=$(curl -kfsS -X POST "${ARGOCD_URL}/api/v1/account/admin/token" \
    -H "Authorization: Bearer ${ARGOCD_SESSION}" \
    -H "Content-Type: application/json" 2>/dev/null \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)
  if [ -n "$ARGOCD_AUTH_TOKEN" ]; then
    break
  fi
  echo "    ArgoCD API todavía no responde, reintentando en 5s (intento $i/6)..."
  sleep 5
done
if [ -z "$ARGOCD_AUTH_TOKEN" ]; then
  echo "Error: no se pudo generar un API token de ArgoCD tras 6 intentos." >&2
  exit 1
fi

oc create secret generic rhdh-argocd-token \
  --from-literal=token="$ARGOCD_AUTH_TOKEN" \
  -n "$NAMESPACE" --dry-run=client -o yaml | oc apply -f -

# ---- 8. values.yaml del chart --------------------------------------------------
# checksum de todos los secrets inyectados como env vars: si alguno cambia,
# el pod template cambia y helm upgrade dispara un rollout automático.
SECRET_HASH=$(echo -n "${GITHUB_TOKEN}${MCP_TOKEN}${KEYCLOAK_CLIENT_SECRET}${SESSION_SECRET}${ARGOCD_AUTH_TOKEN}" | sha256sum | cut -d' ' -f1)

echo "==> Escribiendo ${VALUES_FILE}"
cat > "$VALUES_FILE" <<EOF
# Values para instalar Red Hat Developer Hub ${CHART_VERSION} con MCP + catálogo de
# FinBridge (../initial-catalog, descubierto vía GitHub) + login real vía Keycloak OIDC.
global:
  host: "${RHDH_HOST}"
  imagePullSecrets:
    - rhdh-pull-secret
  dynamic:
    plugins:
      # MCP server backend: expone Backstage actions como MCP tools
      - package: oci://ghcr.io/redhat-developer/rhdh-plugin-export-overlays/backstage-plugin-mcp-actions-backend:bs_1.45.3__0.1.5!backstage-plugin-mcp-actions-backend
        disabled: false
      # MCP tool: permite a un cliente MCP consultar el catálogo de software
      - package: oci://ghcr.io/redhat-developer/rhdh-plugin-export-overlays/red-hat-developer-hub-backstage-plugin-software-catalog-mcp-tool:bs_1.45.3__0.4.1!red-hat-developer-hub-backstage-plugin-software-catalog-mcp-tool
        disabled: false
      # MCP tool: permite a un cliente MCP consultar TechDocs
      - package: oci://ghcr.io/redhat-developer/rhdh-plugin-export-overlays/red-hat-developer-hub-backstage-plugin-techdocs-mcp-tool:bs_1.45.3__0.3.2!red-hat-developer-hub-backstage-plugin-techdocs-mcp-tool
        disabled: false
      # habilita el discovery provider de GitHub para el catálogo de FinBridge.
      # Viene deshabilitado por defecto en RHDH, con un pluginConfig de ejemplo
      # (provider "providerId" con \${GITHUB_ORG} sin resolver, porque esa env var
      # no existe en el contenedor). Si solo cambiamos disabled: false sin pisar
      # ese pluginConfig, el provider de ejemplo queda activo y roto (organization
      # vacío) y tira abajo TODO el módulo catalog al arrancar. Por eso la config
      # real va acá, bajo la MISMA clave 'providerId', para reemplazar el default
      # en vez de convivir con él.
      - package: ./dynamic-plugins/dist/backstage-plugin-catalog-backend-module-github-dynamic
        disabled: false
        pluginConfig:
          catalog:
            providers:
              github:
                providerId:
                  organization: '${GITHUB_ORG}'
                  catalogPath: '/**/catalog-info.yaml'
                  schedule:
                    frequency: { minutes: 30 }
                    timeout: { minutes: 3 }
      # habilita la acción publish:github del scaffolder (usada por el golden
      # path simple-frontend para crear el repo nuevo). Viene deshabilitada
      # por defecto; sin esto el step 'publish' del template falla porque la
      # acción publish:github no existe. No trae pluginConfig propio, usa la
      # integración de GitHub (integrations.github / GITHUB_TOKEN) de abajo.
      - package: ./dynamic-plugins/dist/backstage-plugin-scaffolder-backend-module-github-dynamic
        disabled: false
      # --- Kubernetes (dependencia de Tekton) ---
      - package: ./dynamic-plugins/dist/backstage-plugin-kubernetes-backend-dynamic
        disabled: false
      - package: ./dynamic-plugins/dist/backstage-plugin-kubernetes
        disabled: false
      # --- Tekton (Pipelines) ---
      - package: ./dynamic-plugins/dist/backstage-community-plugin-tekton
        disabled: false
      # --- ArgoCD (GitOps) ---
      - package: ./dynamic-plugins/dist/roadiehq-backstage-plugin-argo-cd-backend-dynamic
        disabled: false
      - package: ./dynamic-plugins/dist/roadiehq-scaffolder-backend-argocd-dynamic
        disabled: false
      # --- Topology (vista visual de Tekton + ArgoCD) ---
      - package: ./dynamic-plugins/dist/backstage-community-plugin-topology
        disabled: false

upstream:
  backstage:
    podAnnotations:
      checksum/secrets: "${SECRET_HASH}"
    appConfig:
      auth:
        session:
          secret: \${SESSION_SECRET}
        providers:
          guest:
            dangerouslyAllowOutsideDevelopment: true
          oidc:
            production:
              clientId: \${KEYCLOAK_CLIENT_ID}
              clientSecret: \${KEYCLOAK_CLIENT_SECRET}
              metadataUrl: https://${KEYCLOAK_HOST}/realms/${KEYCLOAK_REALM}/.well-known/openid-configuration
              callbackUrl: https://${RHDH_HOST}/api/auth/oidc/handler/frame
              additionalScopes: ['email', 'profile']
              prompt: auto
              signIn:
                resolvers:
                  - resolver: preferredUsernameMatchingUserEntityName
      signInPage: oidc
      backend:
        auth:
          externalAccess:
            # entrada por defecto del chart (no se debe perder al sobreescribir el array)
            - type: legacy
              options:
                subject: legacy-default-config
                secret: \${BACKEND_SECRET}
            # habilita clientes MCP autenticados con un bearer token estático
            - type: static
              options:
                token: \${MCP_TOKEN}
                subject: mcp-clients
        actions:
          pluginSources:
            - software-catalog-mcp-tool
            - techdocs-mcp-tool
            # expone las well-known actions del scaffolder (scaffolder.execute-template,
            # scaffolder.dry-run-template) como MCP tools; sin esto el MCP no puede
            # lanzar golden paths. No es un plugin -mcp-tool dedicado como los de
            # arriba, es el id del plugin core del scaffolder.
            - scaffolder
            # expone search.query (búsqueda de Backstage) como MCP tool. El plugin
            # search ya corre nativo en RHDH, no requiere dynamic plugin adicional.
            - search
      kubernetes:
        clusterLocatorMethods:
          - type: config
            clusters:
              - name: local-cluster
                url: https://kubernetes.default.svc
                authProvider: serviceAccount
                skipTLSVerify: true
        customResources:
          - group: tekton.dev
            apiVersion: v1
            plural: pipelineruns
          - group: tekton.dev
            apiVersion: v1
            plural: taskruns
        serviceLocatorMethod:
          type: multiTenant
      argocd:
        appLocatorMethods:
          - type: config
            instances:
              - name: openshift-gitops
                url: https://${ARGOCD_HOST}
                token: \${ARGOCD_AUTH_TOKEN}
      integrations:
        github:
          - host: github.com
            token: \${GITHUB_TOKEN}
      catalog:
        # catalog.providers.github vive en el pluginConfig del dynamic plugin
        # (ver global.dynamic.plugins arriba), no acá.
        locations:
          # org/ y apis/ agrupan varias entidades por archivo y no se llaman
          # catalog-info.yaml, así que el discovery de arriba no las alcanza.
          # rules.allow es obligatorio: sin él, Backstage rechaza en silencio
          # cualquier kind que no esté en su allow-list global por defecto
          # (Domain, Group y User quedan fuera de esa lista por defecto).
          - type: url
            target: https://github.com/${GITHUB_ORG}/${GITHUB_REPO}/blob/${GITHUB_BRANCH}/org/domain.yaml
            rules:
              - allow: [Domain]
          - type: url
            target: https://github.com/${GITHUB_ORG}/${GITHUB_REPO}/blob/${GITHUB_BRANCH}/org/systems.yaml
            rules:
              - allow: [System]
          - type: url
            target: https://github.com/${GITHUB_ORG}/${GITHUB_REPO}/blob/${GITHUB_BRANCH}/org/teams.yaml
            rules:
              - allow: [Group, User]
          - type: url
            target: https://github.com/${GITHUB_ORG}/${GITHUB_REPO}/blob/${GITHUB_BRANCH}/apis/bank-aggregator-api.yaml
            rules:
              - allow: [API]
          - type: url
            target: https://github.com/${GITHUB_ORG}/${GITHUB_REPO}/blob/${GITHUB_BRANCH}/apis/merchant-public-api.yaml
            rules:
              - allow: [API]
          - type: url
            target: https://github.com/${GITHUB_ORG}/${GITHUB_REPO}/blob/${GITHUB_BRANCH}/apis/payment-orchestrator-api.yaml
            rules:
              - allow: [API]
          # golden paths (kind: Template), tampoco se llaman catalog-info.yaml
          - type: url
            target: https://github.com/${GITHUB_ORG}/${GITHUB_REPO}/blob/${GITHUB_BRANCH}/templates/simple-frontend/template.yaml
            rules:
              - allow: [Template]

    extraEnvVars:
      # entradas por defecto del chart (no se deben perder al sobreescribir el array)
      - name: BACKEND_SECRET
        valueFrom:
          secretKeyRef:
            key: backend-secret
            name: '{{ include "rhdh.backend-secret-name" \$ }}'
      - name: POSTGRESQL_ADMIN_PASSWORD
        valueFrom:
          secretKeyRef:
            key: postgres-password
            name: '{{- include "rhdh.postgresql.secretName" . }}'
      # token para autenticar clientes MCP
      - name: MCP_TOKEN
        valueFrom:
          secretKeyRef:
            name: rhdh-mcp-token
            key: token
      # credenciales del cliente OIDC "backstage" en el realm ${KEYCLOAK_REALM} de Keycloak
      - name: KEYCLOAK_CLIENT_ID
        valueFrom:
          secretKeyRef:
            name: rhdh-keycloak-oidc
            key: client-id
      - name: KEYCLOAK_CLIENT_SECRET
        valueFrom:
          secretKeyRef:
            name: rhdh-keycloak-oidc
            key: client-secret
      # requerido por el provider oidc para el manejo de sesión/cookies (passport)
      - name: SESSION_SECRET
        valueFrom:
          secretKeyRef:
            name: rhdh-session-secret
            key: secret
      # token para que el discovery de catálogo lea ${GITHUB_ORG}/${GITHUB_REPO}
      - name: GITHUB_TOKEN
        valueFrom:
          secretKeyRef:
            name: rhdh-github-token
            key: token
      # token de ArgoCD para el plugin de GitOps
      - name: ARGOCD_AUTH_TOKEN
        valueFrom:
          secretKeyRef:
            name: rhdh-argocd-token
            key: token

    extraVolumeMounts:
      # entradas por defecto del chart (no se deben perder al sobreescribir el array)
      - name: dynamic-plugins-root
        mountPath: /opt/app-root/src/dynamic-plugins-root
      - name: extensions-catalog
        mountPath: /extensions
      - name: temp
        mountPath: /tmp

    extraVolumes:
      # entradas por defecto del chart (no se deben perder al sobreescribir el array)
      - name: dynamic-plugins-root
        ephemeral:
          volumeClaimTemplate:
            spec:
              accessModes:
                - ReadWriteOnce
              resources:
                requests:
                  storage: 5Gi
      - name: dynamic-plugins
        configMap:
          defaultMode: 420
          name: '{{ printf "%s-dynamic-plugins" .Release.Name }}'
          optional: true
      - name: dynamic-plugins-npmrc
        secret:
          defaultMode: 420
          optional: true
          secretName: '{{ printf "%s-dynamic-plugins-npmrc" .Release.Name }}'
      - name: dynamic-plugins-registry-auth
        secret:
          defaultMode: 416
          optional: true
          secretName: '{{ printf "%s-dynamic-plugins-registry-auth" .Release.Name }}'
      - name: npmcacache
        emptyDir: {}
      - name: extensions-catalog
        emptyDir: {}
      - name: temp
        emptyDir: {}
EOF

# ---- 9. Instalar RHDH ----------------------------------------------------------
echo "==> helm install"
"$HELM_BIN" repo add openshift-helm-charts https://charts.openshift.io >/dev/null
"$HELM_BIN" repo update >/dev/null
"$HELM_BIN" upgrade --install "$RELEASE" openshift-helm-charts/redhat-developer-hub \
  --version "$CHART_VERSION" -n "$NAMESPACE" -f "$VALUES_FILE" --timeout 10m

echo "==> Esperando a que el pod quede listo..."
oc rollout status deployment "${RELEASE}-developer-hub" -n "$NAMESPACE" --timeout=8m

# ---- 10. Integración con Claude Code / VSCodium --------------------------------
if command -v claude >/dev/null 2>&1; then
  echo "==> Actualizando el servidor MCP en Claude Code"
  claude mcp remove rhdh-mcp >/dev/null 2>&1 || true
  claude mcp add --transport http rhdh-mcp \
    "https://${RHDH_HOST}/api/mcp-actions/v1" \
    --header "Authorization: Bearer ${MCP_TOKEN}" || true
else
  echo "==> claude CLI no encontrado, se omite el registro del MCP en Claude Code"
fi

for EDITOR_CMD in codium code; do
  if command -v "$EDITOR_CMD" >/dev/null 2>&1; then
    echo "==> Instalando extensión de Claude Code en ${EDITOR_CMD}"
    "$EDITOR_CMD" --install-extension anthropic.claude-code || true
  else
    echo "==> ${EDITOR_CMD} no encontrado, se omite la instalación de la extensión"
  fi
done

# ---- 11. .env de demo-workspace -------------------------------------------------
echo "==> Escribiendo ${WORKSPACE_ENV_FILE}"
mkdir -p "$(dirname "$WORKSPACE_ENV_FILE")"
cat > "$WORKSPACE_ENV_FILE" <<EOF
RHDH_MCP_URL=https://${RHDH_HOST}/api/mcp-actions/v1
RHDH_MCP_TOKEN=${MCP_TOKEN}
EOF

# ---- 12. Red Hat Trusted Artifact Signer (RHTAS) --------------------------------
if [ "$RHTAS_ENABLED" = "true" ]; then
  echo "==> Instalando el operador RHTAS (rhtas-operator) en ${RHTAS_OPERATOR_NAMESPACE}"
  oc get namespace "$RHTAS_OPERATOR_NAMESPACE" >/dev/null 2>&1 || oc new-project "$RHTAS_OPERATOR_NAMESPACE" >/dev/null

  # rhtas-operator solo soporta installMode AllNamespaces (confirmado contra el
  # packagemanifest real: OwnNamespace/SingleNamespace/MultiNamespace = false).
  # Sin targetNamespaces, el OperatorGroup queda en modo AllNamespaces.
  cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhtas-operator-group
  namespace: ${RHTAS_OPERATOR_NAMESPACE}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhtas-operator
  namespace: ${RHTAS_OPERATOR_NAMESPACE}
spec:
  channel: stable
  name: rhtas-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

  echo "==> Esperando a que el CSV de rhtas-operator quede en 'Succeeded' (hasta 5 min)..."
  RHTAS_CSV_READY=""
  for i in $(seq 1 30); do
    CSV_NAME=$(oc get subscription rhtas-operator -n "$RHTAS_OPERATOR_NAMESPACE" -o jsonpath='{.status.installedCSV}' 2>/dev/null)
    if [ -n "$CSV_NAME" ]; then
      CSV_PHASE=$(oc get csv "$CSV_NAME" -n "$RHTAS_OPERATOR_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)
    else
      CSV_PHASE=""
    fi
    if [ "$CSV_PHASE" = "Succeeded" ]; then
      RHTAS_CSV_READY="true"
      break
    fi
    sleep 10
  done
  if [ -z "$RHTAS_CSV_READY" ]; then
    echo "AVISO: el CSV de rhtas-operator no llegó a 'Succeeded' en 5 min (fase actual: '${CSV_PHASE:-desconocida}')."
    echo "       Revisa 'oc get csv -n ${RHTAS_OPERATOR_NAMESPACE}' y 'oc get installplan -n ${RHTAS_OPERATOR_NAMESPACE}'."
    echo "       Sigo con el resto del script; la instancia de Securesign puede quedar pendiente hasta que el operador esté listo."
  fi

  echo "==> Creando cliente OIDC '${RHTAS_CLIENT_ID}' en el realm ${KEYCLOAK_REALM} (login de Fulcio)"
  # Client público (sin secret): cosign hace login interactivo abriendo un
  # listener local en http://localhost:<puerto>. NO VALIDADO end-to-end
  # todavía — revisar si el flujo real de cosign/RHTAS necesita otro
  # redirectUri una vez probado contra el cluster de prueba.
  #
  # Pedimos un token de Keycloak nuevo en vez de reusar $KC_TOKEN del paso 5:
  # el access token de admin-cli vive poco (default ~1 min) y el wait del CSV
  # de arriba puede tardar hasta 5 min, así que para acá ya expiró.
  KC_TOKEN=$(curl -fsS -X POST "$KC/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli" -d "username=$KC_ADMIN_USER" -d "password=$KC_ADMIN_PASS" -d "grant_type=password" \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])")

  EXISTING_RHTAS_CLIENT_ID=$(curl -fsS "$KC/admin/realms/${KEYCLOAK_REALM}/clients?clientId=${RHTAS_CLIENT_ID}" \
    -H "Authorization: Bearer $KC_TOKEN" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d[0]['id'] if d else '')")
  if [ -n "$EXISTING_RHTAS_CLIENT_ID" ]; then
    curl -fsS -X DELETE "$KC/admin/realms/${KEYCLOAK_REALM}/clients/$EXISTING_RHTAS_CLIENT_ID" -H "Authorization: Bearer $KC_TOKEN"
  fi
  curl -fsS -X POST "$KC/admin/realms/${KEYCLOAK_REALM}/clients" \
    -H "Authorization: Bearer $KC_TOKEN" -H "Content-Type: application/json" \
    -d '{
      "clientId": "'"$RHTAS_CLIENT_ID"'",
      "enabled": true,
      "protocol": "openid-connect",
      "publicClient": true,
      "standardFlowEnabled": true,
      "directAccessGrantsEnabled": true,
      "serviceAccountsEnabled": false,
      "redirectUris": ["http://localhost:*", "http://localhost:*/*"]
    }'

  echo "==> Creando instancia Securesign en ${RHTAS_NAMESPACE}"
  oc get namespace "$RHTAS_NAMESPACE" >/dev/null 2>&1 || oc new-project "$RHTAS_NAMESPACE" >/dev/null

  # Aunque el CSV ya esté 'Succeeded', el CRD puede tardar unos segundos más en
  # quedar visible para la caché de discovery de 'oc' (visto en el cluster de
  # prueba: "no matches for kind Securesign ... ensure CRDs are installed
  # first" con el CRD ya creado). Reintentamos el apply en vez de fallar en seco.
  cat > "$SCRATCH_DIR/securesign.yaml" <<EOF
apiVersion: rhtas.redhat.com/v1
kind: Securesign
metadata:
  name: securesign-sample
  namespace: ${RHTAS_NAMESPACE}
  labels:
    app.kubernetes.io/name: securesign-sample
    app.kubernetes.io/instance: securesign-sample
    app.kubernetes.io/part-of: trusted-artifact-signer
spec:
  fulcio:
    ingress:
      enabled: true
    config:
      oidcIssuers:
        - clientID: "${RHTAS_CLIENT_ID}"
          issuerURL: "https://${KEYCLOAK_HOST}/realms/${KEYCLOAK_REALM}"
          issuer: "https://${KEYCLOAK_HOST}/realms/${KEYCLOAK_REALM}"
          type: "email"
    signer:
      certificateChain:
        organizationName: Red Hat
  rekor:
    ingress:
      enabled: true
  tuf:
    ingress:
      enabled: true
  tsa:
    ingress:
      enabled: true
    signer:
      certificateChain:
        intermediateCA:
          - organizationName: Red Hat
        leafCA:
          organizationName: Red Hat
        rootCA:
          organizationName: Red Hat
EOF

  RHTAS_CR_APPLIED=""
  for i in $(seq 1 6); do
    if oc apply -f "$SCRATCH_DIR/securesign.yaml" 2>"$SCRATCH_DIR/rhtas-apply-err"; then
      RHTAS_CR_APPLIED="true"
      break
    fi
    cat "$SCRATCH_DIR/rhtas-apply-err"
    echo "    CRD Securesign todavía no visible, reintentando en 5s (intento $i/6)..."
    sleep 5
  done
  if [ -z "$RHTAS_CR_APPLIED" ]; then
    echo "Error: no se pudo crear la instancia Securesign tras 6 intentos." >&2
    exit 1
  fi
else
  echo "==> RHTAS_ENABLED=false, se omite la instalación de Red Hat Trusted Artifact Signer"
fi

# ---- 13. Red Hat Trusted Profile Analyzer (RHTPA) --------------------------------
if [ "$RHTPA_ENABLED" = "true" ]; then
  echo "==> Instalando el operador RHTPA (${RHTPA_PACKAGE}) en ${RHTPA_NAMESPACE}"
  oc get namespace "$RHTPA_NAMESPACE" >/dev/null 2>&1 || oc new-project "$RHTPA_NAMESPACE" >/dev/null

  # El CRD Trustify solo soporta installMode "OwnNamespace": el OperatorGroup
  # tiene que apuntar al mismo namespace donde corre el operador (no a un ns
  # separado como hicimos con RHTAS).
  cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhtpa-operator-group
  namespace: ${RHTPA_NAMESPACE}
spec:
  targetNamespaces:
    - ${RHTPA_NAMESPACE}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${RHTPA_PACKAGE}
  namespace: ${RHTPA_NAMESPACE}
spec:
  channel: ${RHTPA_CHANNEL}
  name: ${RHTPA_PACKAGE}
  source: ${RHTPA_CATALOG_SOURCE}
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

  echo "==> Esperando a que el CSV de ${RHTPA_PACKAGE} quede en 'Succeeded' (hasta 5 min)..."
  RHTPA_CSV_READY=""
  for i in $(seq 1 30); do
    CSV_NAME=$(oc get subscription "$RHTPA_PACKAGE" -n "$RHTPA_NAMESPACE" -o jsonpath='{.status.installedCSV}' 2>/dev/null)
    if [ -n "$CSV_NAME" ]; then
      CSV_PHASE=$(oc get csv "$CSV_NAME" -n "$RHTPA_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)
    else
      CSV_PHASE=""
    fi
    if [ "$CSV_PHASE" = "Succeeded" ]; then
      RHTPA_CSV_READY="true"
      break
    fi
    sleep 10
  done
  if [ -z "$RHTPA_CSV_READY" ]; then
    echo "AVISO: el CSV de ${RHTPA_PACKAGE} no llegó a 'Succeeded' en 5 min (fase actual: '${CSV_PHASE:-desconocida}')."
    echo "       Revisa 'oc get csv -n ${RHTPA_NAMESPACE}' y 'oc get installplan -n ${RHTPA_NAMESPACE}'."
    echo "       Sigo con el resto del script; la instancia de Trustify puede quedar pendiente hasta que el operador esté listo."
  fi

  echo "==> Creando instancia Trustify en ${RHTPA_NAMESPACE}"
  # spec vacío == el alm-examples oficial del operador (instala Server + UI con
  # sus defaults). No se investigó integración con Keycloak/OIDC todavía; una
  # vez arriba, 'oc explain trustify.spec -n '"$RHTPA_NAMESPACE" muestra los
  # campos disponibles si se quiere ajustar.
  #
  # Mismo problema de caché de discovery que con Securesign: el CRD puede no
  # estar visible para 'oc' todavía aunque el CSV ya diga 'Succeeded'.
  cat > "$SCRATCH_DIR/trustify.yaml" <<EOF
apiVersion: org.trustify/v1alpha1
kind: Trustify
metadata:
  name: trustify-sample
  namespace: ${RHTPA_NAMESPACE}
spec: {}
EOF

  RHTPA_CR_APPLIED=""
  for i in $(seq 1 6); do
    if oc apply -f "$SCRATCH_DIR/trustify.yaml" 2>"$SCRATCH_DIR/rhtpa-apply-err"; then
      RHTPA_CR_APPLIED="true"
      break
    fi
    cat "$SCRATCH_DIR/rhtpa-apply-err"
    echo "    CRD Trustify todavía no visible, reintentando en 5s (intento $i/6)..."
    sleep 5
  done
  if [ -z "$RHTPA_CR_APPLIED" ]; then
    echo "Error: no se pudo crear la instancia Trustify tras 6 intentos." >&2
    exit 1
  fi
else
  echo "==> RHTPA_ENABLED=false, se omite la instalación de Red Hat Trusted Profile Analyzer"
fi

# ---- Resumen --------------------------------------------------------------------
cat <<SUMMARY

==========================================================================
RHDH desplegado correctamente.

  URL:          https://${RHDH_HOST}
  Login:        botón OIDC (usuario Keycloak del realm '${KEYCLOAK_REALM}')
  Catálogo:     FinBridge, descubierto desde github.com/${GITHUB_ORG}/${GITHUB_REPO}
                (puede tardar unos minutos en poblarse la primera vez)
  MCP endpoint: https://${RHDH_HOST}/api/mcp-actions/v1
  MCP_TOKEN:    ${MCP_TOKEN}

  (el MCP_TOKEN también queda guardado en el secret 'rhdh-mcp-token'
   del namespace '${NAMESPACE}', por si lo necesitas más adelante:
   oc get secret rhdh-mcp-token -n ${NAMESPACE} -o jsonpath='{.data.token}' | base64 -d)

  demo-workspace/.env ya quedó escrito con RHDH_MCP_URL y RHDH_MCP_TOKEN.
  Abre ../demo-workspace en Codium/VS Code y acepta el diálogo de confianza
  del .mcp.json antes de salir a demo (ver demo-workspace/README.md).

  RHTAS:  $( [ "$RHTAS_ENABLED" = "true" ] && echo "instalado en ${RHTAS_NAMESPACE} (ver 'oc get routes -n ${RHTAS_NAMESPACE}' para las URLs de Fulcio/Rekor/TUF/TSA)" || echo "omitido (RHTAS_ENABLED=false)" )
  RHTPA:  $( [ "$RHTPA_ENABLED" = "true" ] && echo "instalado en ${RHTPA_NAMESPACE} (ver 'oc get routes -n ${RHTPA_NAMESPACE}' para la URL de la UI)" || echo "omitido (RHTPA_ENABLED=false)" )
==========================================================================
SUMMARY

# Estado de los operadores instalados
GITOPS_CSV=$(oc get subscription openshift-gitops-operator -n openshift-operators -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
GITOPS_PHASE=$(oc get csv "$GITOPS_CSV" -n openshift-operators -o jsonpath='{.status.phase}' 2>/dev/null || true)
echo "  OpenShift GitOps:      ${GITOPS_CSV:-no encontrado} (${GITOPS_PHASE:-desconocido})"

PIPELINES_CSV=$(oc get subscription openshift-pipelines-operator -n openshift-operators -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
PIPELINES_PHASE=$(oc get csv "$PIPELINES_CSV" -n openshift-operators -o jsonpath='{.status.phase}' 2>/dev/null || true)
echo "  OpenShift Pipelines:   ${PIPELINES_CSV:-no encontrado} (${PIPELINES_PHASE:-desconocido})"
