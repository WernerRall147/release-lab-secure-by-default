# Release Lab: secure by default on GitHub

A small, fictional service ("Contoso Bank - Payments Status API") used to show how GitHub's built-in security
and delivery controls work together. Everything here is synthetic: the payment records are made up (amounts in
Naira, NGN) and every "secret" used by the demos is a fake value generated at run time.

## What it demonstrates

| Topic | What you see | Where to look |
|---|---|---|
| A secret is blocked before it is saved | Push protection rejects a push that contains a credential | `scripts/demo-secret-push.ps1` |
| A vulnerable dependency is flagged | Dependency review fails a pull request that adds a package with known advisories; Dependabot alerts and security-update pull requests cover the default branch | `.github/workflows/dependency-review.yml`, `.github/dependabot.yml` |
| A code flaw is flagged, with a suggested fix | CodeQL reports an SQL injection on the pull request and Copilot Autofix suggests the parameterised query | CodeQL default setup, `scripts/assets/v2/` |
| Deploy without stored passwords | A workflow signs in to Azure with OpenID Connect (no secret) after a person approves the `production` environment | `.github/workflows/deploy.yml`, `.github/workflows/azure-deploy.yml` |
| Prove what was built | The release workflow publishes the package with an SBOM and signed attestations (build provenance and SBOM) on an immutable release; anyone can verify them | `.github/workflows/release.yml` |
| Guardrails on `main` | A ruleset requires a pull request with one approval and passing checks, and blocks force pushes and deletion, with no bypass | `.github/rulesets/main.json` |
| Optional: an AI agent proposes, a person decides | Assigning an issue to the GitHub Copilot cloud agent opens a draft pull request; its checks need a person's go-ahead and the required approval must come from someone other than the person who asked | `scripts/Reset-GitHubDemo.ps1 -Scenario V4` (needs a paid Copilot plan) |

## The application

Python 3.12 and Flask, with three endpoints and unit tests:

- `GET /` - service name and version
- `GET /health` - liveness check
- `GET /api/payments/status[?status=settled|pending|failed]` - synthetic payment records

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1          # Linux/macOS: source .venv/bin/activate
python -m pip install -r requirements-dev.txt
python -m pytest -q
python -m flask --app app.main run
```

## Workflows

| Workflow | Trigger | What it does |
|---|---|---|
| `ci.yml` (job `ci`) | push and pull request to `main` | installs pinned dependencies, runs the tests, builds the package |
| `dependency-review.yml` | pull request | fails the pull request when it adds a dependency with a high or critical advisory |
| CodeQL (default setup) | push, pull request, weekly | code scanning for Python and GitHub Actions; the `CodeQL` check reports new alerts |
| `release.yml` | manual (`version` input) | builds wheel and source archive, creates an SPDX SBOM, creates build-provenance and SBOM attestations, publishes an immutable release |
| `deploy.yml` | manual (`tag` input) | verifies the attestations of the release, waits for approval in the `production` environment, then calls `azure-deploy.yml` |
| `azure-deploy.yml` | called by `deploy.yml` | signs in to Azure with OpenID Connect and runs a read-only check |

All actions are pinned to a commit SHA, workflows run on `ubuntu-24.04`, and every job requests only the
permissions it needs.

## Scripts

They need PowerShell 5.1 or 7 and the [GitHub CLI](https://cli.github.com/) signed in (`gh auth login`).
They only touch this repository and never print identifiers or secret values.

| Script | Purpose |
|---|---|
| `scripts/demo-secret-push.ps1` | pushes a branch with a fake secret, shows GitHub rejecting it, cleans up |
| `scripts/Reset-GitHubDemo.ps1` | restores the starting state: `-Scenario V1`, `V2`, `V3`, `V4` or `All` (default) |
| `scripts/Test-GitHubDemo.ps1` | read-only smoke test of all settings through `gh api` (`-Verify` also verifies the latest release) |
| `scripts/Set-MainProtection.ps1` | applies, shows, disables or enables the ruleset on `main` |
| `scripts/Set-DeployApproval.ps1` | restores the `production` environment; `-PreventSelfReview` requires a second approver |
| `scripts/Setup-AzureOidc.ps1` | creates the Microsoft Entra app, federated credential and the three repository variables |

## Verify a release

Anyone can check where a release asset came from. With the GitHub CLI:

```powershell
gh release download v1.0.0 --repo WernerRall147/release-lab-secure-by-default --pattern "*.whl"
gh attestation verify .\contoso_payments_status_api-1.0.0-py3-none-any.whl --repo WernerRall147/release-lab-secure-by-default
gh attestation verify .\contoso_payments_status_api-1.0.0-py3-none-any.whl --repo WernerRall147/release-lab-secure-by-default --predicate-type https://spdx.dev/Document/v2.3
gh release verify v1.0.0 --repo WernerRall147/release-lab-secure-by-default
```

The first command proves the file was built by the `release.yml` workflow of this repository from a given
commit, the second proves the SBOM belongs to the same file, the third checks the release itself. Immutable
releases cannot be changed or re-published under the same tag, so each new release needs a new version.

## Deploying from your own copy

The deploy workflow needs no stored secret. It reads three repository **variables** (not secrets):
`AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID`, and uses OpenID Connect to sign in.
`scripts/Setup-AzureOidc.ps1` creates the app registration and the federated credential for the
`production` environment and stores the variables. The app only gets the Reader role on one resource group.
Do not print these values in workflow logs: the repository is public.

## Safety notes

- All data is fictional. The deliberately flawed endpoint in `scripts/assets/v2/` is only added on a demo
  pull request branch and must never be merged.
- The secret used by `scripts/demo-secret-push.ps1` is generated at random each time and is fake. Never use the
  "allow the secret" link in the rejection message: the demo is about the push being blocked.
- Repository settings (rulesets, environment, security features) are scripted, so they can be restored after
  every rehearsal.