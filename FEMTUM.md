# Femtum's fork of CVAT

This repository is Femtum's fork of [`cvat-ai/cvat`](https://github.com/cvat-ai/cvat).
It exists to host the Terraform and Kubernetes deployment code that runs CVAT
on Femtum's own infrastructure, alongside upstream's unmodified source.

## Branch model

- **`develop`** stays a **clean, unmodified mirror of upstream `develop`**. It
  carries no Femtum code and is never a base for Femtum work.
- **`Femtum-<tag>`** branches are cut from an **upstream release tag**, not
  from `develop`. The current one is **`Femtum-2.82.0`**, cut from
  `v2.82.0` (`02bd74fde`). All of Femtum's deployment work lives on a
  `Femtum-<tag>` branch.
- **The repository's default branch is set to the current `Femtum-<tag>`
  branch**, not `develop` — currently `Femtum-2.82.0`. This is deliberate:
  it's where the work actually is, and it's what a clone, a new PR's base,
  and `workflow_dispatch` all land on by default. It has one consequence
  worth knowing: GitHub runs **scheduled (`cron`) workflows against the
  default branch**, regardless of any branch filter on their other
  triggers. So `schedule.yml` and `codeql-analysis.yml`'s weekly cron now
  run against `Femtum-2.82.0` itself, not `develop` — one more reason
  they're in the disabled list below, and a case where "it only runs on
  push to develop/master" reasoning alone would have been wrong.

## The add-only rule

**Femtum commits only ADD files. They never modify a file that exists
upstream.** This keeps every Femtum branch a clean, mechanical rebase onto
the next upstream tag — there is nothing to reconcile because nothing
upstream was touched.

Concretely, Femtum commits add (and only add):

- `infra/` — the Terraform root for Femtum's infrastructure (RDS, security
  groups, IAM, etc.)
- `deploy/` — Helm values overrides, the `SecretStore`/`ExternalSecret`
  manifests, and the SSO settings overlay
- `FEMTUM.md` (this file)
- Femtum-owned GitHub Actions workflows (e.g. `.github/workflows/femtum-*.yml`)

**There is exactly one permitted exception:** a one-line, bold pointer to this
file at the very top of `README.md`. It is kept to a single line specifically
so it rebases cleanly onto upstream's own README changes.

If a change seems to require modifying an upstream file for any other reason,
that is a sign the change doesn't belong in this fork as currently scoped —
stop and raise it rather than breaking the add-only rule.

## Upgrading to a new upstream tag

1. Cut a new branch `Femtum-<new tag>` from the new upstream release tag
   (e.g. `v2.84.0`).
2. Rebase the Femtum commits (everything currently on `Femtum-2.82.0` on top
   of `v2.82.0`) onto the new tag.
3. Because Femtum commits are add-only, the rebase should be conflict-free —
   there is nothing upstream to have diverged from.
4. **Re-check the disabled-workflow list below** (see "Upstream workflows
   disabled in the fork") — remember that cron-scheduled workflows run
   against whatever the default branch is, not just push/PR branch
   filters.
5. **Repoint the repository's default branch** to the new `Femtum-<tag>`
   branch (repo Settings → Branches on GitHub). Skipping this leaves
   clones, new PRs' default base, `workflow_dispatch` runs and any
   cron-scheduled workflow pointed at the *old* branch even after the new
   one is otherwise ready.
6. Once the new branch is verified and is the default, it becomes the one
   that may run `terraform plan`/`apply` (see next section). Retire
   plan/apply access on the old `Femtum-*` branch.

## Only the newest `Femtum-*` branch may run Terraform against `cvat-rnd`

**Only the newest `Femtum-*` branch may run `terraform plan` or
`terraform apply` against the `cvat-rnd` Terraform Cloud workspace.**

Terraform Cloud runs here are **CLI-driven**, not triggered by CI on a
specific branch. That means nothing stops someone from running `terraform
apply` from an old `Femtum-*` checkout — and if they do, it will **silently
revert** whatever the newer branch already applied, because Terraform only
knows about the configuration in front of it, not which branch is "current".

There is no technical guard against this (CLI-driven runs don't have a branch
check), so it is enforced by convention: always confirm you are on the newest
`Femtum-*` branch before running `plan` or `apply` against `cvat-rnd`.

## Upstream workflows disabled in the fork

Upstream's GitHub Actions workflows are not relevant to this fork — the fork
doesn't develop CVAT's own source, run its CI, or cut its own releases — and
several of them cost compute or reach into unrelated repositories if left
enabled. They are disabled in the fork's **Actions settings**
(`gh workflow disable`), **not** by editing the workflow files themselves,
to keep the add-only rule intact.

As of `v2.82.0`, the following upstream workflows auto-trigger (on push, on
pull request, or on a schedule) and **must be disabled**:

| workflow | why it must be disabled |
|---|---|
| `cache.yml` | runs on every push to `develop` |
| `codeql-analysis.yml` | runs on push to `develop`/`master`/`release-*` and on a weekly schedule |
| `comment.yml` | runs on any issue/PR comment in the fork |
| `docs.yml` | runs on push to `master`/`develop` and on every PR |
| `linters.yml` | runs on every PR |
| `main.yml` | the full upstream test suite; runs on push to `master`/`develop` and on every PR |
| `schedule.yml` | runs nightly plus on manual dispatch |
| `trigger-dependent-repo-update.yml` | runs on push to `develop`; pings an unrelated downstream repository |
| `update-python-requirements.yml` | runs on PRs touching requirements files |

The following workflows only run via `workflow_dispatch`, `workflow_call`
(i.e. only when another workflow calls them — none of which Femtum enables),
or a `release` event that this fork does not produce. They are **harmless**
left enabled, but disabling them too is a reasonable belt-and-suspenders
choice since none of them serve any purpose here:

| workflow | trigger |
|---|---|
| `finalize-release.yml` | `workflow_dispatch` only |
| `prepare-release.yml` | `workflow_dispatch` only |
| `full.yml` | `workflow_call` / `workflow_dispatch` only |
| `search-cache.yml` | `workflow_call` only |
| `upload-testops-results.yml` | `workflow_call` only |
| `trigger-cvat-models-images-build.yml` | `workflow_dispatch` or `release: released` |
| `publish-artifacts.yml` | `release: released` only |

**A rebase can bring in brand-new upstream workflows, and they start out
enabled by default.** This list is therefore not a one-time setup step — it
is **re-checked on every upgrade** (step 4 above), by diffing
`.github/workflows/` between the old and new tag and disabling anything new
that auto-triggers.

## Layout (present and planned)

- **`FEMTUM.md`** (this file) and the one-line `README.md` pointer — present.
- **`.github/workflows/femtum-infra.yml`** — present. Femtum-owned CI that
  runs `terraform fmt -check` against `infra/`. `terraform test` runs locally
  only (see `infra/README.md`): it downloads `platform_contract` from the
  private `Femtum/Infrastructure`, which the runners have no key for.
- **`infra/`** — present. The Terraform root for Femtum's infrastructure on
  the `cvat-rnd` Terraform Cloud workspace, with its `infra/tests/*.tftest.hcl`
  suite. It holds `cvat_data`, the EFS file system behind the backend's shared
  `ReadWriteMany` volume (see `infra/README.md`). Still to come: the
  `cvat-database` RDS instance, its security group, and the IAM role External
  Secrets Operator assumes to read its secret. See the `cvat-rds-root` task.
- **`deploy/`** — not yet present. Will hold the Kubernetes-facing deployment
  assets: the Helm values override for the `cvat` chart (wiring it to the
  external RDS instance instead of the bundled Postgres), the `SecretStore`
  and `ExternalSecret` manifests that surface the database credentials from
  AWS Secrets Manager, and the SSO settings overlay. See the
  `cvat-deploy-values` task.
