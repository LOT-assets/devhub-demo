# Catálogo inicial — FinBridge

Este directorio es el **catálogo semilla** que se importa a Developer Hub al arrancar el demo. Crea todos los activos (dominio, sistemas, equipos, APIs, componentes y recursos) de la empresa ficticia **FinBridge**, una plataforma de intermediación financiera para pymes y comercios — y también aloja los **golden paths** (`templates/`) con los que se crean componentes nuevos.

Su propósito no es solo poblar la UI: es dar al MCP de Developer Hub algo real que servir — APIs disponibles, dueños/sistemas existentes, estándares de arquitectura y golden paths — para que un desarrollador (o su asistente de IA) pueda consultarlo *antes* de crear un componente nuevo. Los componentes nuevos deben crearse vía golden path, cuyo paso `catalog:register` los añade de vuelta al catálogo. Este directorio es el punto de partida de ese ciclo, no un catálogo estático que se edita a mano indefinidamente.

Repo en GitHub: `LOT-assets/devhub-demo`, rama `main`.

## Estructura

```
initial-catalog/
├── org/                  # Domain, Systems y Groups/Users de FinBridge
│   ├── domain.yaml
│   ├── systems.yaml
│   └── teams.yaml
├── apis/                 # Entidades API (contrato OpenAPI inline)
│   ├── bank-aggregator-api.yaml
│   ├── merchant-public-api.yaml
│   └── payment-orchestrator-api.yaml
├── infra/                # Recursos compartidos (kind: Resource)
│   ├── ledger-db/catalog-info.yaml
│   ├── payments-db/catalog-info.yaml
│   ├── message-broker/catalog-info.yaml
│   └── redis-cache/catalog-info.yaml
├── templates/            # Golden paths (kind: Template)
│   └── simple-frontend/
│       ├── template.yaml
│       └── skeleton/     # contenido que se scaffoldea en el repo nuevo
└── <servicio>/catalog-info.yaml   # un directorio por Component
```

Cada componente y recurso vive en su propio directorio con un `catalog-info.yaml`, siguiendo la convención estándar de Backstage (un archivo por entidad, colocado junto al "código" del componente).

## Mapa de entidades

**Domain:** `financial-intermediation` (owner: `fintech-core-team`)

| System | Equipo dueño | Componentes | Recursos |
|---|---|---|---|
| `payments-platform` | fintech-core-team | api-gateway, payment-orchestrator, core-ledger-service, reconciliation-service, payout-disbursement-service | ledger-db, payments-db, message-broker, redis-cache |
| `banking-integration` | banking-integrations-team | bank-aggregator, bank-connector-alfa, bank-connector-meridiano, bank-connector-vertice | — |
| `credit-intermediation` | credit-risk-team | credit-scoring-service, fraud-risk-service, factoring-service | — |
| `merchant-experience` | merchant-experience-team | merchant-portal, merchant-onboarding-service, notifications-service, admin-backoffice | — |

Los 4 recursos de `infra/` están asignados a `payments-platform` (dueño: `platform-sre-team`) porque es donde se originan, pero son consumidos también por componentes de otros systems (p. ej. `credit-scoring-service` depende de `redis-cache`) — eso es válido en Backstage, `dependsOn` puede cruzar systems.

**APIs:** `payment-orchestrator-api` y `merchant-public-api` (owner: fintech-core-team, system: payments-platform), `bank-aggregator-api` (owner: banking-integrations-team, system: banking-integration).

**Users:** `product-owner-finbridge` (fintech-core-team), `admin` (platform-sre-team — cuenta de Keycloak usada para el login OIDC del demo, ver `install/README.md`).

Todas las referencias (`dependsOn`, `providesApis`, `owner`, `system`) fueron verificadas y resuelven a una entidad existente en este catálogo — no hay relaciones rotas.

## Golden paths (`templates/`)

`templates/simple-frontend` scaffoldea un frontend React + Vite y lo registra en el catálogo. Pide `name`, `description`, `owner` (Group/User) y `system` (uno de los 4 systems de arriba) — este último es obligatorio para que el componente nuevo no quede huérfano de la arquitectura de FinBridge. El `catalog-info.yaml` generado hereda esos valores, incluido `spec.system`.

Owner del template: `platform-sre-team`.

## Cómo se importa en RHDH

`install/deploy-demo.sh` configura esto automáticamente (ver `install/README.md`):

- **Discovery por organización** (`catalog.providers.github`, `catalogPath: '/**/catalog-info.yaml'`): encuentra automáticamente cualquier `catalog-info.yaml` en cualquier repo de `LOT-assets`, incluyendo los que registre un golden path al crear un componente nuevo. Esto es lo que sostiene el ciclo de autocrecimiento del catálogo.
- **Locations explícitas** para los archivos que agrupan varias entidades o no siguen la convención `catalog-info.yaml` (no los alcanza el discovery de arriba): `org/domain.yaml`, `org/systems.yaml`, `org/teams.yaml`, las 3 APIs de `apis/`, y `templates/simple-frontend/template.yaml`.

Requiere que RHDH tenga un token de GitHub con acceso de lectura a este repo (`install/github-token.txt`).
