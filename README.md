# Catálogo inicial — FinBridge

Este directorio es el **catálogo semilla** que se importa a Developer Hub al arrancar el demo. Crea todos los activos (dominio, sistemas, equipos, APIs, componentes y recursos) de la empresa ficticia **FinBridge**, una plataforma de intermediación financiera para pymes y comercios.

Su propósito no es solo poblar la UI: es dar al MCP de Developer Hub algo real que servir — APIs disponibles, dueños/sistemas existentes y la estructura de arquitectura — para que un desarrollador (o su asistente de IA) pueda consultarlo *antes* de crear un componente nuevo. Los componentes nuevos deben crearse vía golden path (ver `../templates/`), cuyo paso `catalog:register` los añade de vuelta al catálogo. Este directorio es el punto de partida de ese ciclo, no un catálogo estático que se edita a mano indefinidamente.

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

Todas las referencias (`dependsOn`, `providesApis`, `owner`, `system`) fueron verificadas y resuelven a una entidad existente en este catálogo — no hay relaciones rotas.

## Cómo importarlo en RHDH

Este repo (`devhub-demo` en GitHub, remote `LOT-assets/devhub-demo`) todavía no tiene commits — hay que pushearlo antes de que RHDH pueda descubrirlo vía integración de GitHub. Dos formas de registrarlo, según el escenario:

### Opción A — Demo offline / sin salida a GitHub (igual que `install/`)

`install/deploy-demo.sh` ya monta un catálogo de ejemplo como ConfigMap (`catalog-entities.yaml`, un único archivo con entidades separadas por `---`). Para reusar ese mecanismo con el catálogo de FinBridge en lugar del catálogo mínimo actual, habría que concatenar todos los `catalog-info.yaml` de este directorio en un solo archivo `all.yaml` y montarlo igual. No implementado todavía — es el paso natural si se prefiere una demo sin dependencia de red hacia GitHub.

### Opción B — Discovery vía GitHub (recomendada, sostiene el ciclo de golden paths)

Una vez pusheado el repo, agregar en el `appConfig` de RHDH (`install/rhdh-values.yaml`):

```yaml
catalog:
  providers:
    github:
      finbridge:
        organization: 'LOT-assets'
        catalogPath: '/**/catalog-info.yaml'
        schedule:
          frequency: { minutes: 30 }
          timeout: { minutes: 3 }
  locations:
    # org/ y apis/ no siguen la convención catalog-info.yaml (son varias
    # entidades por archivo), así que se registran explícitamente:
    - type: url
      target: https://github.com/LOT-assets/devhub-demo/blob/main/org/domain.yaml
    - type: url
      target: https://github.com/LOT-assets/devhub-demo/blob/main/org/systems.yaml
    - type: url
      target: https://github.com/LOT-assets/devhub-demo/blob/main/org/teams.yaml
    - type: url
      target: https://github.com/LOT-assets/devhub-demo/blob/main/apis/bank-aggregator-api.yaml
    - type: url
      target: https://github.com/LOT-assets/devhub-demo/blob/main/apis/merchant-public-api.yaml
    - type: url
      target: https://github.com/LOT-assets/devhub-demo/blob/main/apis/payment-orchestrator-api.yaml
```

El discovery provider (`catalogPath: '/**/catalog-info.yaml'`) es lo que hace que el catálogo se automantenga: cualquier componente nuevo creado a través de un golden path (que registra su propio `catalog-info.yaml` en el repo destino) aparece solo, sin tocar esta configuración. Requiere que RHDH tenga configurada una integración/token de GitHub con acceso al repo.
