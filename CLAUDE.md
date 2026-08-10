# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This repo demos **AI-assisted development powered by Red Hat Developer Hub (RHDH)**. The point isn't "RHDH is installed" — it's that RHDH, exposed to the developer's AI assistant via MCP, becomes the source of truth an AI agent consults *before* generating anything: golden paths (Scaffolder templates), available APIs (catalog `API` entities), and architecture standards (domains, systems, teams).

Intended flow: a developer's AI assistant queries the RHDH MCP endpoint for golden paths / APIs / standards, then scaffolds a new component through a golden path — which auto-registers the result back into the catalog. This closes the loop: components created the intended way add themselves back to the Hub, so the catalog self-maintains and grows in a structured way instead of drifting out of sync. Anything you do in this repo should reinforce that loop (e.g. a new component type should come with, or point at, a golden path template — not just ad-hoc code).

## Repository layout

The top-level directory itself is not a git repo — it's a workspace of three independent pieces, each serving one phase of the demo:

- **`install/`** — everything needed to deploy RHDH onto an existing OpenShift cluster (script, secrets, generated Helm values). See "Deploying" below.
- **`initial-catalog/`** — a separate git repo (GitHub: `FinBridgeDemo/devhub-demo`, branch `main`, already pushed) holding the seed catalog for the demo's fictional company, **FinBridge** (a fintech), plus the golden path templates. This is what RHDH imports at startup and what golden paths add to over time.
- **`demo-workspace/`** — the folder opened in VSCodium/VS Code during the live demo. Deliberately empty of code; only carries `.mcp.json` + `.vscode/extensions.json` so the assistant can reach the RHDH MCP endpoint. `.env` (gitignored) is written automatically by `install/deploy-demo.sh`.

Since `initial-catalog/` is an independent git repo nested in this workspace, check `git status`/`git remote -v` from *within* it before assuming changes belong to some other repo.

## Deploying (`install/`)

`install/deploy-demo.sh` provisions RHDH end-to-end on OpenShift: MCP dynamic plugins, GitHub-based catalog discovery pointed at `initial-catalog`, and Keycloak OIDC login. Prerequisites (the script exits early if missing): active `oc login` against an empty namespace, a valid `install/pull-secret.txt`, a valid `install/github-token.txt` (read access to `FinBridgeDemo/devhub-demo`, replacing the placeholder), and a Keycloak (RHBK operator) already deployed in the `keycloak` namespace with its realm imported — the script only creates an OIDC client inside it, it doesn't install Keycloak.

Sequence: install `helm` locally if missing → namespace + pull secret → GitHub token secret (catalog discovery) → MCP bearer token → create/recreate the `backstage` OIDC client in Keycloak → render `rhdh-values.yaml` (MCP plugins + OIDC + GitHub integration + catalog discovery/locations) → `helm upgrade --install` and wait for rollout → register the MCP endpoint with the local `claude` CLI / install the Codium extension if present → write `demo-workspace/.env`. Idempotent: safe to re-run (namespace/secrets/configmap use `--dry-run=client -o yaml | oc apply -f -`; the Keycloak client is deleted and recreated).

`install/rhdh-values.yaml` and (previously) `catalog-entities.yaml` are **generated artifacts** — `rhdh-values.yaml` is fully overwritten by the heredoc in `deploy-demo.sh` on every run. Edit the heredoc in the script, not the generated file, for changes to persist.

Login depends on the catalog: the OIDC resolver is `preferredUsernameMatchingUserEntityName`, so whoever logs in via Keycloak must exist as a `User` entity in `initial-catalog` (see `org/teams.yaml`, which has a `User: admin` for exactly this).

## Catalog & golden paths (`initial-catalog/`)

Standard Backstage catalog YAML (`apiVersion: backstage.io/v1alpha1`). One `Domain` (`financial-intermediation`) → four `System`s (`payments-platform`, `banking-integration`, `credit-intermediation`, `merchant-experience`), each owned by a `Group`. Every `Component`/`Resource` sets `spec.owner`/`spec.system` consistent with that hierarchy — new entries must too, not invent new ones ad hoc. `templates/` holds the golden paths (currently `simple-frontend`); its `template.yaml` requires the operator to pick both an `owner` and a `system` so scaffolded components never end up orphaned from the architecture.

RHDH finds this content two ways (both configured in `install/deploy-demo.sh`'s values heredoc): a GitHub discovery provider scanning the whole `FinBridgeDemo` org for `**/catalog-info.yaml` (this is what lets golden-path-created repos register themselves automatically — the self-maintaining part), plus explicit `type: url` locations for the handful of files that group multiple entities or aren't named `catalog-info.yaml` (`org/*.yaml`, `apis/*.yaml`, `templates/simple-frontend/template.yaml`).

## `demo-workspace/`

Opened in Codium for the live demo. `.mcp.json` registers the `rhdh-mcp` server via env vars (`${RHDH_MCP_URL}`, `${RHDH_MCP_TOKEN}`) rather than hardcoded values, so it's safe to commit. Claude Code will prompt a workspace-trust dialog the first time this folder is used — accept it *before* going live, not during (see `demo-workspace/README.md` for the full pre-demo checklist and suggested demo script).
