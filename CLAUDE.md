# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This repo demos **AI-assisted development powered by Red Hat Developer Hub (RHDH)**. The point isn't "RHDH is installed" — it's that RHDH, exposed to the developer's AI assistant via MCP, becomes the source of truth an AI agent consults *before* generating anything: golden paths (Scaffolder templates), available APIs (catalog `API` entities), and architecture standards (domains, systems, teams).

Intended flow: a developer's AI assistant queries the RHDH MCP endpoint for golden paths / APIs / standards, then scaffolds a new component through a golden path — which auto-registers the result back into the catalog. This closes the loop: components created the intended way add themselves back to the Hub, so the catalog self-maintains and grows in a structured way instead of drifting out of sync. Anything you do in this repo should reinforce that loop (e.g. a new component type should come with, or point at, a golden path template — not just ad-hoc code).

## Repository layout

This top-level directory is itself a git repo (GitHub: `LOT-assets/devhub-demo`, branch `main`) holding the tooling that supports the demo — but the demo *content* (catalog + golden paths) lives in a separate, independently-pushed repo nested inside it:

- **`install/`** — everything needed to deploy RHDH onto an existing OpenShift cluster (script, generated Helm values; `pull-secret.txt`/`github-token.txt` are gitignored, the operator supplies them locally). See "Deploying" below.
- **`demo-workspace/`** — the folder opened in VSCodium/VS Code during the live demo. Deliberately empty of code; only carries `.mcp.json` + `.vscode/extensions.json` so the assistant can reach the RHDH MCP endpoint. `.env` (gitignored) is written automatically by `install/deploy-demo.sh`.
- **`initial-catalog/`** — **gitignored by this repo**, a *separate* independent git repo (GitHub: `FinBridgeDemo/devhub-demo`, branch `main`, its own dedicated org) holding the seed catalog for the demo's fictional company, **FinBridge** (a fintech), plus the golden path templates. This is what RHDH imports at startup and what golden paths add to over time.

Why two repos/orgs: the golden path's `publish:github` step needs a token that can *create* repos, which is a broader permission than you want sitting next to install-time secrets or a "real" org. `FinBridgeDemo` is a dedicated org that exists only to hold FinBridge's catalog and receive golden-path-created repos — see "Catalog & golden paths" below for the exact token requirements. Since `initial-catalog/` is an independent git repo, check `git status`/`git remote -v` from *within* it before assuming changes belong to this outer repo.

## Deploying (`install/`)

`install/deploy-demo.sh` provisions RHDH end-to-end on OpenShift: MCP dynamic plugins, GitHub-based catalog discovery pointed at `initial-catalog`, and Keycloak OIDC login. Prerequisites (the script exits early if missing): active `oc login` against an empty namespace, a valid `install/pull-secret.txt`, a valid `install/github-token.txt`, and a Keycloak (RHBK operator) already deployed in the `keycloak` namespace with its realm imported — the script only creates an OIDC client inside it, it doesn't install Keycloak.

`github-token.txt` **must be a classic PAT with the `repo` scope**, from a user who's a member of the `FinBridgeDemo` org — not a fine-grained PAT. Fine-grained PATs cannot create repositories via the GitHub API regardless of permissions granted (confirmed empirically: `POST /orgs/{org}/repos` and `POST /user/repos` both 403 "Resource not accessible by personal access token" even with Organization → Administration: Read & write set). The golden path's `publish:github` step needs repo creation; catalog discovery only needs read, but both share the same token since Backstage's `integrations.github` is one token per host.

Sequence: install `helm` locally if missing → namespace + pull secret → GitHub token secret (catalog discovery + scaffolder publish) → MCP bearer token → create/recreate the `backstage` OIDC client in Keycloak → render `rhdh-values.yaml` (MCP plugins + OIDC + GitHub integration + catalog discovery/locations) → `helm upgrade --install` and wait for rollout → register the MCP endpoint with the local `claude` CLI / install the Codium extension if present → write `demo-workspace/.env` → optionally install Red Hat Trusted Artifact Signer (RHTAS, on by default) and Red Hat Trusted Profile Analyzer (RHTPA, off by default — its OLM package name isn't confirmed yet, see `install/README.md` § "RHTAS y RHTPA"). Idempotent: safe to re-run (namespace/secrets/configmap use `--dry-run=client -o yaml | oc apply -f -`; the Keycloak client is deleted and recreated).

`install/rhdh-values.yaml` is a **generated artifact** — fully overwritten by the heredoc in `deploy-demo.sh` on every run. Edit the heredoc in the script, not the generated file, for changes to persist.

Three RHDH dynamic plugins ship disabled by default and had to be explicitly enabled in `global.dynamic.plugins` for this to work, each with a gotcha discovered by actually deploying (not visible from static config review):
- `backstage-plugin-catalog-backend-module-github-dynamic` (catalog discovery) — its bundled example `pluginConfig` (key `providerId`) references `${GITHUB_ORG}` as a *Backstage runtime env var* that's never set in the container; enabling the plugin without overriding that `pluginConfig` leaves the broken example provider active alongside ours and crashes the whole `catalog` backend module on startup. Fixed by supplying our real config under the *same* `providerId` key so it replaces the default instead of coexisting with it.
- `backstage-plugin-scaffolder-backend-module-github-dynamic` — provides the `publish:github` scaffolder action. No pluginConfig of its own; just needs `disabled: false`.
- `catalog.locations` of `type: url` silently drop `Domain`/`Group`/`User` entities unless each location declares `rules: allow: [...]` explicitly listing every kind present in that file — `System`/`API`/`Template` come through fine without it, but the org-hierarchy files (`domain.yaml`, `teams.yaml`) need it or the entities vanish with only a `warn`-level log line (no error).

**Known limitation:** `backend.actions.pluginSources` (which exposes a plugin's actions as MCP tools) is configured with `scaffolder` and `search` alongside the two dedicated `-mcp-tool` plugins, but neither works in RHDH 1.9.7 / Backstage core 1.45.3 — their `/api/<plugin>/.backstage/actions/v1/actions` endpoint 404s (confirmed via direct curl; `catalog`'s equivalent endpoint returns 200). So `scaffolder.execute-template` is not currently reachable via the RHDH MCP endpoint — golden paths have to be run from the RHDH UI directly until a newer RHDH version ships scaffolder/search plugins that implement this endpoint (or a dedicated `scaffolder-mcp-tool`-style wrapper appears, matching the pattern of the catalog/techdocs ones).

Login depends on the catalog: the OIDC resolver is `preferredUsernameMatchingUserEntityName`, so whoever logs in via Keycloak must exist as a `User` entity in `initial-catalog` (see `org/teams.yaml`, which has a `User: admin` for exactly this).

## Catalog & golden paths (`initial-catalog/`)

Standard Backstage catalog YAML (`apiVersion: backstage.io/v1alpha1`). One `Domain` (`financial-intermediation`) → four `System`s (`payments-platform`, `banking-integration`, `credit-intermediation`, `merchant-experience`), each owned by a `Group`. Every `Component`/`Resource` sets `spec.owner`/`spec.system` consistent with that hierarchy — new entries must too, not invent new ones ad hoc. `templates/` holds the golden paths (currently `simple-frontend`); its `template.yaml` requires the operator to pick both an `owner` and a `system` so scaffolded components never end up orphaned from the architecture.

RHDH finds this content two ways (both configured in `install/deploy-demo.sh`'s values heredoc): a GitHub discovery provider scanning the whole `FinBridgeDemo` org for `**/catalog-info.yaml` (this is what lets golden-path-created repos register themselves automatically — the self-maintaining part), plus explicit `type: url` locations for the handful of files that group multiple entities or aren't named `catalog-info.yaml` (`org/*.yaml`, `apis/*.yaml`, `templates/simple-frontend/template.yaml`).

## `demo-workspace/`

Opened in Codium for the live demo. `.mcp.json` registers the `rhdh-mcp` server via env vars (`${RHDH_MCP_URL}`, `${RHDH_MCP_TOKEN}`) rather than hardcoded values, so it's safe to commit. Claude Code will prompt a workspace-trust dialog the first time this folder is used — accept it *before* going live, not during (see `demo-workspace/README.md` for the full pre-demo checklist and suggested demo script).
