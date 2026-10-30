# GCP Cloud SQL PostgreSQL Service

Nullplatform **dependency service** that provisions and manages a Cloud SQL
for PostgreSQL instance. Each service instance is one Cloud SQL instance with
one database; each application link creates a dedicated PostgreSQL role with
grants for its access level, so apps authenticate with their own credentials
and never see the administrator's.

The service lives under [`cloud-sql-postgresql/`](./cloud-sql-postgresql). It
is a port of [services-postgresql-flexible-server](https://github.com/nullplatform/services-postgresql-flexible-server)
(Azure): the link model, the role and grant management, the OpenTofu
execution and the three-tier configuration are the same code. What changes is
the cloud: the instance, private networking, the GCS state backend and the
credentials, which come from Workload Identity instead of a secret.

## What It Does

- Provisions a Cloud SQL instance (version, machine tier, SSD size, backup
  retention, optional regional HA) and a database via OpenTofu, with a
  **private IP only** and TLS enforced (`ssl_mode = ENCRYPTED_ONLY`)
- Creates a PostgreSQL role per link, with a generated password and grants
  derived from the link's access level; drops it on unlink, keeping the data
- Exposes `{LINK}_HOSTNAME` / `{LINK}_PORT` / `{LINK}_DATABASE_NAME` from the
  service, and **`DATABASE_URL` / `DATABASE_USER` / `DATABASE_PASSWORD`** from
  the link, the names a Spring Boot `container` profile reads without mapping
- Stores OpenTofu state in a shared GCS bucket under a per-service prefix
  (`cloud-sql-postgresql/<service_id>/`)
- Authenticates to GCP as the agent's Kubernetes service account, through
  Workload Identity Federation: no GCP service account key anywhere
- Ships as an OCI worker image: the channel routes `package-exec` to a worker
  built from this repository's [`Dockerfile`](./Dockerfile), with OpenTofu
  baked in

## Repository Layout

```
.
├── cloud-sql-postgresql/
│   ├── specs/
│   │   ├── service-spec.json.tpl         # Service schema (attributes the user sees)
│   │   ├── links/database-user.json.tpl  # Link schema (access level, credentials)
│   │   ├── requirements/gcp/             # OpenTofu: IAM for the worker, tfstate bucket
│   │   └── install/gcp/                  # OpenTofu: standalone registration module
│   ├── deployment/                       # OpenTofu module: instance, database, admin user
│   ├── permissions/                      # OpenTofu module: role + grants (per link)
│   ├── workflows/                    # Workflow YAMLs (create/update/delete/link/link-update/unlink/read)
│   ├── scripts/                      # placement resolution, tofu execution, output writing
│   ├── entrypoint/                       # entrypoint/service/link (agent entrypoint)
│   ├── examples/                         # fixtures and the offline test harness
│   └── values.yaml                       # Static config, optional — all keys may stay empty
├── Dockerfile                            # worker image: worker-bridge + OpenTofu + this service
├── mise.toml                             # run it on your machine as a package (np package run)
└── README.md
```

## Service Configuration Parameters

Exposed in the nullplatform UI when creating/updating the service:

| Parameter | Type | Default | Allowed Values | Editable After Create |
|---|---|---|---|---|
| `database_name` | string | — (required) | `^[a-z][a-z0-9_]{0,62}$` | No |
| `postgres_version` | string | `16` | `15`, `16`, `17` | No |
| `tier` | string | `db-g1-small` | `db-f1-micro`, `db-g1-small`, `db-custom-1-3840`, `db-custom-2-7680`, `db-custom-4-16384` | Yes |
| `disk_size_gb` | number | `10` | 10–1024 | Yes (grow only) |
| `backup_retention_days` | number | `7` | 1–365 daily backups | Yes |
| `high_availability` | bool | `false` | | Yes (ignored on shared-core tiers) |

The edition (`ENTERPRISE`, so the shared-core tiers stay available), private
IP only, TLS enforcement and the administrator login (`npadmin`) are fixed in
the module and deliberately not exposed.

**Instance naming**: `<sanitized-service-name>-<first 8 chars of service ID>`,
starting with a letter, capped at 63 characters. Computed once on first
create, then persisted and read back on every later action — recomputing it
after a rename would force `replace` on the instance and destroy every
database in it.

## Link Parameters (`database-user`)

| Parameter | Type | Default | Description |
|---|---|---|---|
| `access_level` | enum | `admin` | `read`, `read-write`, `admin` |

`access_level` maps onto grants, all on the `public` schema of the service's
database:

| Access level | Database | Schema `public` | Tables | Sequences |
|---|---|---|---|---|
| `read` | CONNECT | USAGE | SELECT | SELECT |
| `read-write` | CONNECT, TEMPORARY | USAGE | SELECT, INSERT, UPDATE, DELETE | SELECT, USAGE, UPDATE |
| `admin` | CONNECT, CREATE, TEMPORARY | USAGE, CREATE | ALL | ALL |

`admin` is the default because the first consumers run their own migrations
(Flyway, Liquibase, Prisma): they need CREATE on the database to create their
schema and CREATE on `public` for the migration history table.

## Service Attributes (post-create, exported as env vars)

| Attribute | Description |
|---|---|
| `hostname` | Private IP address of the instance |
| `port` | `5432` |
| `database_name` | The database |

Names are `{LINK_SLUG_UPPER}_{ATTRIBUTE_UPPER}` with hyphens removed from the
slug: a link slugged `db-main` yields `DBMAIN_HOSTNAME`, `DBMAIN_PORT` and
`DBMAIN_DATABASE_NAME`.

`instance_name`, `connection_name` and `project_id` are also stored, but not
exported — `instance_name` is what keeps the name stable across renames, and
`connection_name` is what the Cloud SQL Auth Proxy and the language
connectors take, for applications that prefer them.

## Link Attributes (per link, exported as env vars)

| Attribute | Env var | Type | Description |
|---|---|---|---|
| `username` | `DATABASE_USER` | plain | The link's role, `u_<app>_<link id prefix>` |
| `password` | `DATABASE_PASSWORD` | secret | Its password, 32 alphanumerics |
| `jdbc_url` | `DATABASE_URL` | plain | `jdbc:postgresql://<private ip>:5432/<db>?sslmode=require`, no credentials |

The link uses `export.target` to fix these names instead of the
`{LINK}_...` convention, so an application reads them with no mapping. The
consequence is that **one scope can consume one link of this service**: two
links to two instances would both try to export `DATABASE_URL`.

## Workflows

| Workflow | Trigger | What It Does |
|---|---|---|
| `create` | Service created | Creates the instance, the database and the administrator user |
| `update` | Service updated | Re-applies tier, disk size, backup retention and HA |
| `delete` | Service deleted | **Destroys the instance**, its database, its backups and all data |
| `link` | Application linked | Creates the role with its grants |
| `link-update` | Link updated | Reapplies the grants after an `access_level` change; password unchanged |
| `unlink` | Application unlinked | **Drops the role**; its objects are reassigned to the administrator, data is kept |
| `read` | Read action | Reports current attributes; touches nothing in GCP |

## Requirements

### nullplatform prerequisites

- An agent with worker orchestration enabled on a GKE cluster with Workload
  Identity, and this service's package slug (`gcp-cloud-sql-postgresql`)
  listed in the agent module's `worker_orchestrated_packages`. Listing it is
  what makes the worker pod run as the agent's Kubernetes service account
- The worker's placement (region, VPC, tfstate bucket); see "Configuration"
- A GCS bucket for OpenTofu state, which this service never creates
  (`specs/requirements/gcp` can)

### GCP prerequisites

- APIs `sqladmin.googleapis.com` and `servicenetworking.googleapis.com`
  enabled on the project
- **Private Service Access** on the VPC: a reserved internal range and the
  `servicenetworking.googleapis.com` peering. Every instance gets its private
  IP from that range
- The agent's cluster in that same VPC (VPC-native): the link action connects
  to the instance from the worker pod, and the linked applications from their
  own pods

### GCP permissions

The worker authenticates as the Kubernetes service account
`nullplatform-tools/nullplatform-agent` (the tofu-modules agent defaults).
Grant the roles to that identity directly, as a Workload Identity Federation
principal:

```
principal://iam.googleapis.com/projects/<project number>/locations/global/workloadIdentityPools/<project id>.svc.id.goog/subject/ns/nullplatform-tools/sa/nullplatform-agent
```

| On | Role | For |
|---|---|---|
| The project | `roles/cloudsql.admin` | creating instances, databases and users |
| The tfstate bucket | `roles/storage.objectAdmin` | reading and writing state |

[`specs/requirements/gcp`](cloud-sql-postgresql/specs/requirements/gcp)
grants both, and can create the bucket and enable the APIs. Private Service
Access is left to the network layer that owns the VPC.

### Runtime dependencies

- **OpenTofu** — baked into the worker image at the version pinned by the
  Dockerfile's `TOFU_VERSION`. `do_tofu` keeps a download fallback for agents
  without it, but the packaged deployment never uses it.
- `bash`, `jq`, `np` and `curl` ship in the `worker-bridge` base image.
- **No `gcloud`, no `psql`**: the google provider uses Application Default
  Credentials, and roles and grants are managed by the `cyrilgdn/postgresql`
  Terraform provider over TLS.

## Configuration

Three tiers, each field resolved independently, highest first:

1. `cloud-sql-postgresql/values.yaml` (committed; ships empty)
2. The account's cloud-providers (GCP) provider config
3. The worker's environment

| Setting | values.yaml | Provider | Environment |
|---|---|---|---|
| Project | `project_id` | `project.id` (published by tofu-modules) | `SERVICES_GCP_PROJECT`, then `GOOGLE_CLOUD_PROJECT` |
| Region | `region` | `services.region` | `SERVICES_GCP_REGION` |
| VPC | `network` (name or `projects/<p>/global/networks/<n>`) | `services.network` | `SERVICES_GCP_NETWORK` |
| State bucket | `tfstate_bucket` | `services.tfstate.bucket` | `SERVICES_TFSTATE_BUCKET` |

The `services` block is not part of the schema tofu-modules publishes for the
GCP provider (whether the provider specification accepts it is not
confirmed), so the documented install sets region, VPC and bucket in the
worker's environment, as below.

## How to register this service in nullplatform

Three pieces, in three layers.

**1 — The agent** must run the worker and give it the placement. In the
[`nullplatform/agent`](https://github.com/nullplatform/tofu-modules/tree/main/nullplatform/agent)
module:

```hcl
  worker_orchestrated_packages = ["containers", "gcp-cloud-sql-postgresql"]

  extra_envs = {
    SERVICES_GCP_REGION     = "<region>"
    SERVICES_GCP_NETWORK    = "<vpc name>"
    SERVICES_TFSTATE_BUCKET = "<tfstate bucket>"
  }

  worker = {
    patches = [{
      target = { package = "gcp-cloud-sql-postgresql" }
      merge = {
        spec = {
          containers = [{
            name    = "worker"
            envFrom = [{ secretRef = { name = "<agent-secret>" } }]
          }]
        }
      }
    }]
  }
```

Listing the package in `worker_orchestrated_packages` is what runs its worker
as the agent's Kubernetes service account, the identity the GCP permissions
are granted to. The `envFrom` is required: the module hands its environment
only to the `containers` worker, and `extra_envs` land in the agent's Helm
secret (`<release>-secret-<chart>`, `nullplatform-agent-secret-nullplatform-agent`
with the module's defaults), which the patch mounts. Same model as the Azure
services, minus the credentials: nothing secret is needed here.

**2 — The service specification**, with the worker image pinned:

```hcl
module "service_definition_cloud_sql_postgresql" {
  source              = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition?ref=<tofu-modules tag>"
  nrn                 = var.nrn
  service_path        = "cloud-sql-postgresql"
  service_name        = "GCP Cloud SQL PostgreSQL"
  repository_name     = "services-gcp-cloudsql-postgres"
  repository_branch   = "<tag>"
  repository_ref_type = "tags"
  available_links     = ["database-user"]

  package = {
    version = "<semver>"
    artifacts = [{
      name   = "worker-image"
      type   = "oci_image"
      lookup = true
      meta = {
        registry   = "public.ecr.aws"
        repository = "nullplatform/agent-plugins/services/cloud-sql-postgresql"
        tag        = "<tag>"
      }
    }]
  }
}
```

The module derives the package slug from `service_name` (lowercased, spaces
to hyphens): "GCP Cloud SQL PostgreSQL" gives `gcp-cloud-sql-postgresql`, the
`NP_PACKAGE_NAME` baked into the worker image. Another name applies cleanly
and fails on first use.

**3 — The channel association**, routing the action to the worker:

```hcl
module "service_agent_association_cloud_sql_postgresql" {
  source                     = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/service_definition_agent_association?ref=<tofu-modules tag>"
  nrn                        = var.nrn
  service_path               = "cloud-sql-postgresql"
  service_specification_slug = module.service_definition_cloud_sql_postgresql.service_specification_slug
  tags_selectors             = var.tags_selectors

  worker_orchestrator = true
  package_slug        = module.service_definition_cloud_sql_postgresql.service_specification_slug
}
```

A ready-made version of pieces 2 and 3 lives in
[`cloud-sql-postgresql/specs/install/gcp/`](cloud-sql-postgresql/specs/install/gcp)
for a standalone install.

## Important considerations

### Delete destroys everything

`delete` destroys the instance, which deletes the database, every role, all
their data **and the automated backups**: Cloud SQL drops them with the
instance. Unlink, by contrast, keeps the data: the role's objects are
reassigned to the administrator before the role is dropped. A deleted
instance's name stays reserved for up to a week; the service-id suffix keeps
that from mattering.

### Private IP only

The instance has no public address. Anything that connects to it — the
worker, the linked applications — must run in the peered VPC. Reaching it
from a laptop needs the Cloud SQL Auth Proxy, outside this service.

### Grants cover the public schema

The role's grants apply to the `public` schema, to the tables that exist at
link time, and — through default privileges — to tables the administrator
creates later. Tables created by another link's `admin` role are owned by that
role; a `read` link does not see them until their owner grants access. For a
single application per database, the common case, this never comes up.

### A password is issued once

The link's password is generated on `link` and anchored in state; `link-update`
changes grants and nothing else. Rotation is deleting and recreating the link.

### The tfstate is a credential store

The deployment state holds the administrator password and every link state
holds its role's password. **Anyone with read access to the tfstate bucket
holds every credential this service has issued.** Use a dedicated bucket and
treat it like a vault.

### Creation takes minutes

Cloud SQL provisions an instance in roughly five to fifteen minutes. The
`create` action runs that long; a link issued before `create` completes fails
with a clear "hostname not found" error and can be retried.

## Testing

The offline suite needs no GCP session, no agent and no platform: it stubs
`np` and `tofu` on `PATH`.

```bash
bash cloud-sql-postgresql/examples/run-all-tests.sh
```

A dry run parses a notification fixture, prints the derived variables and
validates the Terraform module. It needs placement from somewhere: either fill
`values.yaml` locally or export the worker's variables:

```bash
export SERVICES_GCP_PROJECT=<project> SERVICES_GCP_REGION=<region> SERVICES_GCP_NETWORK=<vpc> SERVICES_TFSTATE_BUCKET=<bucket>
bash cloud-sql-postgresql/examples/dry-run.sh
bash cloud-sql-postgresql/examples/dry-run.sh cloud-sql-postgresql/examples/link.json
```

`full-test.sh` applies the modules against a real GCP project, outside the
platform. It creates real resources, and the link step only works from inside
the peered VPC.

## Run locally as a package

`np package run` runs this service on your machine the way production does: a
local controlplane-agent that registers with the platform, spawns the worker
image built from this repo, and hands it every action routed to it. The two
tasks in `mise.toml` are the whole contract with the CLI:

| Command | Runs | Does |
|---|---|---|
| `np package build --image` | `mise run build:image` | Builds `cloud-sql-postgresql-worker:dev` |
| `np package run` | `mise run run` | Builds the image, then starts the local agent |

The agent is tagged `package:gcp-cloud-sql-postgresql` and `local:<your user>`.
It receives an action only when the service's notification channel selects
those tags, so point a channel at `local:<your user>` to route work to your
machine. **Never start a local agent with tags a production channel selects.**
Locally, `create`, `update` and `delete` work with your ADC session; `link`
does not, because a laptop cannot reach the private IP.

## CI

| Workflow | When | What |
|---|---|---|
| branch-validation | PR | branch named `feat/…`, `fix/…`, `chore/…` |
| conventional-commit | PR | commit messages (release-please reads them) |
| specs | PR | service and link specs, plus the offline suite |
| terraform | PR | `tofu fmt`, `init` and `validate` on the deployment, permissions and requirements modules |
| shellcheck | PR | every bash script |
| trivy | PR | IaC misconfiguration and image scan, to the Security tab |
| beta | PR | pushes `beta/agent-plugins/services/cloud-sql-postgresql:test-<branch>-<short sha>` and registers it as a nullplatform artifact |
| release | push to `main` | release-please → build and push `vX.Y.Z` and `latest` to ECR Public → nullplatform artifact → GitHub release |
| auto-merge-release | after release | merges the release PR |

## Publishing

Set in this repository:

| Name | Kind | Value |
|---|---|---|
| `AWS_ROLE_ARN_ECR_PUSH` | secret | the publisher role ARN for `agent-plugins/services/cloud-sql-postgresql` |
| `NP_ARTIFACT_NRN` | variable | the NRN of the organization that owns the artifacts |

`ARTIFACT_NP_API_KEY` comes from the organization. The release checks all
three before building and fails with a clear error if one is missing.
