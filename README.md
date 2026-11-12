# Expensy on Amazon EKS

Expensy is a small expense tracker: a Next.js frontend, a Node.js and Express backend, MongoDB for the expenses and Redis as a cache. This repository runs it locally with Docker Compose and in AWS on Amazon EKS, at <https://martin.diogo.world/> while the course's demo environment is up.

In AWS, MongoDB is Amazon DocumentDB and Redis is Amazon ElastiCache for Valkey. Terraform creates the infrastructure. GitHub Actions builds and tests the code, pushes the images to Amazon ECR and, after a manual approval, writes the new image tags to Git. Argo CD, running for the cluster, then deploys what Git describes. Prometheus and Grafana show the app's metrics, and the container logs go to CloudWatch Logs.

Security, data protection and retention are in [SECURITY.md](SECURITY.md).

## Contents

- [Architecture](#architecture)
- [Repository layout](#repository-layout)
- [Run it locally](#run-it-locally)
- [Containers](#containers)
- [Configuration](#configuration)
- [Deploy to AWS](#deploy-to-aws)
- [CI/CD](#cicd)
- [Monitoring](#monitoring)
- [Logs](#logs)
- [Deviations from the brief](#deviations-from-the-brief)
- [Known gaps](#known-gaps)
- [Teardown](#teardown)
- [Credits](#credits)

## Architecture

```
AWS us-east-1
  EKS Auto Mode cluster martin-project-final (AWS manages the nodes)
    gateway            NGINX Gateway Fabric behind a Network Load Balancer (NLB),
                       TLS certificate from Let's Encrypt via cert-manager,
                       DNS name martin.diogo.world written by ExternalDNS
    expensy            frontend x2, backend x2; /api goes to the backend, everything else to the frontend
    monitoring         Prometheus, Grafana, kube-state-metrics, node-exporter
    amazon-cloudwatch  CloudWatch agent and Fluent Bit, sending container logs to CloudWatch Logs
  Argo CD, run by AWS for the cluster (the EKS Argo CD capability)
  DocumentDB 8.0     the expenses; the backend signs in as its own user
  Valkey             the cache; the backend's user may only read and write the key "expenses"
  Secrets Manager    the passwords, mounted into the backend pod as files
  ECR                the two images
```

A change reaches the cluster like this:

1. A push to `main` starts GitHub Actions, which tests the code, builds the images and pushes them to ECR.
2. After a reviewer approves the deploy in GitHub, the workflow commits the new image tags to `main`.
3. Argo CD notices the commit and updates the pods. The pipeline never connects to the cluster.

The browser loads the frontend from `https://martin.diogo.world/` and calls the backend on the same origin (`/api/expenses`), so one certificate and one route cover both. The backend has four endpoints: `GET` and `POST /api/expenses`, `GET /healthz` for Kubernetes' probes, and `GET /metrics` for Prometheus. An invalid expense gets a 400 with the validation message. If Redis fails, the backend logs it and answers from the database, since Redis is only a cache.

## Repository layout

```
expensy_frontend/        Next.js app (standalone output)
expensy_backend/         Express API, tests in test/
certs/                   the public CA bundle that signs DocumentDB's certificates
Dockerfile.frontend      Dockerfile.backend      docker-compose.yaml
infra/                   three Terraform root modules, applied in this order, each with its own state:
  bootstrap/             the S3 bucket for the other two roots' state (its own state stays local, git-ignored)
  main/                  VPC, EKS, the Argo CD capability, DocumentDB, Valkey, ECR, IAM, log groups, alarms
  gitops-bridge/         what Argo CD needs before it can start: its project and first Applications,
                         the namespaces, the expensy-config ConfigMap, the secret mounts
gitops/
  root/                  one Application per platform component (Argo CD's "app of apps")
  gateway/               Gateway, HTTPS redirect, certificate issuers, network policies of the platform
  apps/expensy/          frontend, backend, route, network policies, the DocumentDB user Job
  cloudwatch/            network policies of the CloudWatch add-on's namespace
monitoring/              Helm values for Prometheus and Grafana, the backend's ServiceMonitor,
                         the Grafana dashboard (dashboards/expensy.json), network policies
.github/                 ci.yml, deploy.yml, dependabot.yml
```

## Run it locally

With Docker and Compose:

```bash
docker compose up --build
```

The frontend is at <http://localhost:3000> and the backend at <http://localhost:8706> (try `curl localhost:8706/api/expenses`). `docker compose down -v` stops it and deletes the local database.

Without Compose (stop it first, the ports are the same), start MongoDB and Redis with the brief's `docker run` commands, here with pinned versions:

```bash
docker run --name mongo -d -p 27017:27017 -e MONGO_INITDB_ROOT_USERNAME=root -e MONGO_INITDB_ROOT_PASSWORD=example mongo:8.0
docker run --name redis -d -p 6379:6379 redis:8-alpine redis-server --requirepass someredispassword
```

Then the backend in one terminal. Variables set in the shell take precedence over `expensy_backend/.env`, so these two point it at `localhost` instead of the Compose service names:

```bash
cd expensy_backend
npm ci
npm test
npm run build
DATABASE_URI=mongodb://root:example@localhost:27017 REDIS_HOST=localhost npm start
```

And the frontend in a second terminal:

```bash
cd expensy_frontend
npm ci
NEXT_PUBLIC_API_URL=http://localhost:8706 npm run dev
```

## Containers

- `Dockerfile.backend` compiles the TypeScript, keeps only the production dependencies and copies the CA bundle to `/etc/ssl/certs/rds-global-bundle.pem`. It listens on 8706.
- `Dockerfile.frontend` builds Next.js with `output: 'standalone'` and runs its `server.js`. It takes the build argument `NEXT_PUBLIC_API_URL` (default `http://localhost:8706`, for Compose) and listens on 3000.
- Both are multi-stage, start from `node:26.13.1-slim` pinned by digest, install the current security updates and `tini` (a small init process that passes signals to Node), and run as the unprivileged user `node` (uid 1000). CI checks both with hadolint, a Dockerfile linter.

To build them by hand, from the repository root (Compose above builds and runs them the same way):

```bash
docker build -f Dockerfile.backend -t expensy-backend .
docker build -f Dockerfile.frontend --build-arg NEXT_PUBLIC_API_URL=http://localhost:8706 -t expensy-frontend .
```

## Configuration

The backend reads its settings from environment variables, and its passwords from files when the matching `_FILE` variable is set (`expensy_backend/src/config/settings.ts`).

| Variable | Default | Locally (Compose) | On EKS |
|---|---|---|---|
| `PORT` | `8706` | `expensy_backend/.env` | image default |
| `DATABASE_URI` | none | `expensy_backend/.env` | not set |
| `DB_HOST`, `DB_PORT`, `DB_NAME` | none, `27017`, `expensy` | not set | ConfigMap `expensy-config` |
| `DB_TLS`, `DB_TLS_CA_FILE` | off | not set | `expensy-config` (`true`, the CA bundle in the image) |
| `DB_USERNAME_FILE`, `DB_PASSWORD_FILE` | none | not set | files from Secrets Manager (`/mnt/secrets/db-username`, `db-password`) |
| `REDIS_HOST`, `REDIS_PORT` | `localhost`, `6379` | `expensy_backend/.env` | `expensy-config` |
| `REDIS_USERNAME`, `REDIS_TLS` | none, off | not set | `expensy-config` |
| `REDIS_PASSWORD` or `REDIS_PASSWORD_FILE` | none | `REDIS_PASSWORD` in `.env` | `REDIS_PASSWORD_FILE=/mnt/secrets/redis-password` |

`expensy_backend/.env` holds only the brief's local demo values (`root:example`, `someredispassword`) for Compose; no real credential is in Git.

The frontend reads `NEXT_PUBLIC_API_URL`, the backend's address as the browser sees it. Next.js writes it into the browser bundle at build time ([Next.js environment variables](https://nextjs.org/docs/app/building-your-application/configuring/environment-variables)), so each address needs its own image; the AWS image is built with `https://martin.diogo.world`. `expensy_frontend/api/apiclient.tsx` also reads `NEXT_APP_API_KEY` and falls back to a fixed placeholder; the backend ignores it.

## Deploy to AWS

### Prerequisites

- AWS CLI v2, `kubectl` 1.37, Terraform 1.17, Docker with Compose and the GitHub CLI. This build used AWS CLI 2.38.5, kubectl 1.37.1, Terraform 1.17.1, Docker Compose 5.6.1 and gh 2.103.3.
- An AWS identity with administrator access. Whoever applies `infra/main` becomes the cluster's admin.
- A public Route 53 hosted zone for `diogo.world` in the account. Terraform looks it up by name; it does not create it.
- An IAM Identity Center user `martin-project-final`, created by hand ([add users](https://docs.aws.amazon.com/singlesignon/latest/userguide/addusers.html)) before `infra/main` is applied, with no permission set and no account assignment, so it can sign in to Argo CD but has no access to AWS itself. Terraform maps it to Argo CD's `ADMIN` role.
- The IAM OIDC provider for `token.actions.githubusercontent.com` in the account. It is shared with other projects, so Terraform only reads it.

The state bucket's name contains the account ID, so it goes only into git-ignored files (`backend.hcl`, `terraform.tfvars`), with committed `.example` copies.

### 1. State bucket

`infra/bootstrap` creates the S3 bucket for the other roots' state in the [account regional namespace](https://docs.aws.amazon.com/AmazonS3/latest/userguide/gpbucketnamespaces.html), plus an alarm on requests to it without TLS. It keeps its own state locally, because a bucket cannot hold the state of the root that creates it. For the alarms to email someone, copy `terraform.tfvars.example` to `terraform.tfvars`, set `alarm_email`, and confirm the subscription from the email AWS sends.

```bash
terraform -chdir=infra/bootstrap init
terraform -chdir=infra/bootstrap plan -out=tfplan
terraform -chdir=infra/bootstrap apply tfplan
terraform -chdir=infra/bootstrap output -raw state_bucket
```

The bucket name goes into three git-ignored files, each copied from its `.example`: `infra/main/backend.hcl`, `infra/gitops-bridge/backend.hcl` and `infra/gitops-bridge/terraform.tfvars` ([partial backend configuration](https://developer.hashicorp.com/terraform/language/backend#partial-configuration)).

### 2. Cluster, databases and registry

```bash
cp infra/main/terraform.tfvars.example infra/main/terraform.tfvars
curl -s https://checkip.amazonaws.com     # your public IP: set api_allowed_cidrs = ["<ip>/32"]
terraform -chdir=infra/main init -backend-config=backend.hcl
terraform -chdir=infra/main plan -out=tfplan
terraform -chdir=infra/main apply tfplan
aws eks update-kubeconfig --name martin-project-final --region us-east-1
```

`api_allowed_cidrs` lists the addresses that may reach the cluster's API. The apply creates the VPC (two zones, a NAT gateway in each), the cluster, the Argo CD capability, DocumentDB (one `db.t4g.medium` instance), Valkey (two nodes), the two ECR repositories, the IAM roles, the CloudWatch Observability add-on with its log groups, and the alarms: 96 resources when this was written.

### 3. Hand the cluster to Argo CD

```bash
terraform -chdir=infra/gitops-bridge init -backend-config=backend.hcl
terraform -chdir=infra/gitops-bridge plan -out=tfplan
terraform -chdir=infra/gitops-bridge apply tfplan
```

Argo CD then installs the platform from `gitops/root/`: the Gateway API CRDs, NGINX Gateway Fabric, cert-manager, the gateway, Prometheus and Grafana, and the CloudWatch network policies. ExternalDNS writes `martin.diogo.world`, and cert-manager gets the certificate. The `expensy` and `external-dns` Applications are created by this Terraform root instead of `gitops/root/`, because they carry the registry address and the zone ID, which stay out of Git.

The Argo CD UI address is `terraform -chdir=infra/main output -raw argocd_server_url`; sign in as the Identity Center user. After a few minutes `kubectl get applications -n argocd` lists every Application as `Synced` and `Healthy`, except `expensy` until step 6. If `expensy` or `external-dns` stops retrying because the platform was not ready yet, open it in the Argo CD UI and press Sync.

### 4. Grafana's admin password

Grafana's admin password is the only Kubernetes object created by hand, so that no password is in Git. Grafana starts once it exists:

```bash
kubectl create secret generic grafana-admin -n monitoring \
  --from-literal=admin-user=admin --from-literal=admin-password="$(openssl rand -base64 24)"
```

### 5. GitHub settings

Set the two repository secrets from Terraform's outputs (replace the repository with your fork):

```bash
R=terbin-tech/ironhack-project-final
terraform -chdir=infra/main output -raw github_build_role_arn  | gh secret set AWS_BUILD_ROLE_ARN  -R $R
terraform -chdir=infra/main output -raw github_record_role_arn | gh secret set AWS_RECORD_ROLE_ARN -R $R
```

Then create the environment `production` (repository Settings, Environments) with yourself as required reviewer and deployment branches limited to `main`.

### 6. First images

The ECR repositories start empty, so run the deploy workflow once by hand and approve it in GitHub (Actions, the run, Review deployments):

```bash
gh workflow run deploy.yml -R $R --ref main
```

When it has recorded the tags, Argo CD rolls the app out on its next poll. Then open <https://martin.diogo.world/> and add an expense, or run `curl https://martin.diogo.world/api/expenses`.

## CI/CD

Two workflows in `.github/workflows/`:

- `ci.yml` runs on every push and pull request: `terraform fmt` and `validate` of the three roots, `kubectl kustomize` of the app, hadolint on both Dockerfiles, the backend's `npm ci`, `npm test` and `npm run build`, the frontend's `npm ci` and `npm run build`, and on pull requests GitHub's dependency review.
- `deploy.yml` runs on a push to `main` that changes the frontend, the backend, a Dockerfile or `certs/`, and when started by hand. It runs `ci.yml` on the same commit first, then three jobs:
  1. `changes` works out which of the two services changed.
  2. `build` signs in to AWS with GitHub's OIDC token (a short-lived identity token AWS accepts instead of a stored key) as the role in `AWS_BUILD_ROLE_ARN`, builds each changed image and pushes it to ECR, tagged with the commit SHA. Tags are immutable.
  3. `record-tags` is the deploy. It belongs to the environment `production`, so it waits until the reviewer approves it in GitHub. It then signs in as the read-only role in `AWS_RECORD_ROLE_ARN`, reads each new image's digest from ECR and commits the tag and digest to `gitops/apps/expensy/kustomization.yaml` on `main` through GitHub's API, which signs the commit.

Argo CD notices the commit on its next poll (about three minutes in this build) and rolls the new image out, running it by digest.

The pipeline needs only the two secrets above and the `production` environment, both set in [Deploy to AWS, step 5](#5-github-settings). The role ARNs are secrets so that GitHub masks them in logs; they grant nothing without GitHub's token. The workflows read no GitHub variables: the frontend's `NEXT_PUBLIC_API_URL` is a build argument in `deploy.yml`. The pipeline holds no AWS keys and no cluster credentials ([GitHub OIDC in AWS](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws)).

Deploy runs queue instead of cancelling each other, so every push gets its own images and tag commit. Every deploy adds a commit to `main`, so run `git pull --rebase` before pushing.

## Monitoring

Deploy step 3 installs the monitoring stack, and step 4 is its one manual part. Argo CD installs [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) 93.2.2 in the namespace `monitoring` (`gitops/root/kube-prometheus-stack.yaml`), with the values in `monitoring/values.yaml` read from this repository. A second Application, `monitoring-extras`, applies `monitoring/` itself: the `ServiceMonitor` that makes Prometheus scrape the backend's `/metrics`, the dashboard, and the namespace's network policies.

- Prometheus scrapes the backend, the kubelets (container CPU and memory), node-exporter, kube-state-metrics, the API server and itself. Alertmanager is off. Prometheus keeps 10 days of data, without a persistent volume.
- Grafana loads `monitoring/dashboards/expensy.json`: request rate, error rate (share of 5xx) and p95 latency of the API (health checks and scrapes left out), and the pods' CPU and memory. To change it, edit the JSON or export it from Grafana, and commit.
- Alarms are in CloudWatch, not Prometheus: Valkey CPU, NAT gateway port allocation and etcd size (`infra/main/monitoring.tf`), GuardDuty findings on the cluster, and requests to the state bucket without TLS (`infra/bootstrap/alarm.tf`). All go to one SNS topic, which emails `alarm_email` if it is set.

To open Grafana (user `admin`), get the password and forward a port:

```bash
kubectl get secret grafana-admin -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d; echo
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
```

Then open <http://localhost:3000> and go to Dashboards, Expensy (stop a local frontend first, it uses the same port). For Prometheus itself, run `kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090` and open <http://localhost:9090/targets>.

## Logs

The EKS add-on `amazon-cloudwatch-observability` runs the CloudWatch agent and Fluent Bit on every node and sends the logs to CloudWatch Logs ([install the add-on](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/install-CloudWatch-Observability-EKS-addon.html)). Terraform creates its log groups first, with a 7-day retention (`infra/main/logs.tf`):

- `/aws/containerinsights/martin-project-final/application`: the containers' output
- `dataplane`: the nodes' kubelet and container runtime
- `host`: the nodes' system logs
- `performance`: Container Insights metrics, as log events

In the console, open CloudWatch, Logs, Log groups, `/aws/containerinsights/martin-project-final/application`, or CloudWatch, Logs Insights with a query such as `fields @timestamp, log | filter kubernetes.namespace_name = "expensy"`. From the command line, for the lines that contain `expensy`:

```bash
aws logs tail /aws/containerinsights/martin-project-final/application --since 1h --follow \
  --filter-pattern '"expensy"'
```

`kubectl logs -n expensy deploy/backend` shows the same lines live.

## Deviations from the brief

| Brief says | This repo | Why |
|---|---|---|
| MongoDB and Redis as containers | Containers locally (Compose); in AWS, DocumentDB and ElastiCache for Valkey | AWS runs backups, patching and failover. DocumentDB keeps the MongoDB API, so the app's database code is unchanged. |
| `.github/workflows/ci-cd.yaml` | `ci.yml` and `deploy.yml` | CI runs on every push and pull request, deploy only from `main`, and the deploy reuses CI on the same commit. |
| Deploy to EKS from the pipeline | The pipeline records the image tag in Git after approval; Argo CD deploys it | No cluster credentials outside AWS, and the Kubernetes API stays restricted ([OpenGitOps](https://opengitops.dev/), "Pulled Automatically"). See [CI/CD](#cicd). |
| `deployment.yaml` and `service.yaml` | One file per component (`frontend.yaml`, `backend.yaml`) with a `kustomization.yaml` | The brief allows a kustomization; each file holds a component's Deployment, Service, ServiceAccount and PodDisruptionBudget. |
| Infrastructure in `/infrastructure/` | `infra/` | The brief gives the name as an example. |
| Variables passed by ConfigMaps or Secrets | Settings in the ConfigMap `expensy-config`; passwords as files from Secrets Manager, no Kubernetes Secret | The brief also allows "an external secret manager (AWS Secrets Manager)". No copy of a password sits in the cluster. |
| Docker Hub or another registry | Amazon ECR | One AWS sign-in for build and deploy, and no registry password in GitHub. |
| TLS for frontend to backend | HTTPS from the browser to the gateway for both; plain HTTP from the gateway to the pods | The browser calls the backend on the same HTTPS origin. A service mesh is out of scope. |

The course app came with Next.js 14.2.3; this repository runs Next.js 15.5.29, because critical advisories (remote code execution in the image optimizer) cover every Next.js up to 15.5.27, so no 14.x release fixes them. React stays 18.2.

## Known gaps

- Argo CD polls Git instead of receiving a webhook, so a deploy reaches the cluster a few minutes after the tag commit.
- Re-run only the newest deploy run: an older one would write its older tag back to Git.
- Without `alarm_email` the alarms notify nobody; this deployment has none set.
- Security gaps are listed in [SECURITY.md](SECURITY.md#known-gaps).

## Teardown

Run this from an address listed in `infra/main/terraform.tfvars`, since the API accepts only those.

1. Note the gateway's address (the ADDRESS column of `kubectl get gateway -n gateway`). Then stop the root Application's auto-sync, so nothing recreates what is deleted next:

   ```bash
   kubectl patch application root -n argocd --type json -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
   ```

2. Delete the app, then the gateway, and wait until the NLB is gone and ExternalDNS has removed `martin.diogo.world` and its TXT records (both checks print `[]`; `aws route53 list-hosted-zones-by-name --dns-name diogo.world` shows the zone ID). Network policies stay enforced until the cluster is destroyed: the ConfigMap that turns the policy controller on is marked `Delete=false`, so Argo CD does not remove it.

   ```bash
   kubectl delete application expensy -n argocd --wait --timeout=10m
   kubectl delete application gateway -n argocd --wait --timeout=10m
   aws elbv2 describe-load-balancers --query "LoadBalancers[?DNSName=='<gateway address>']"
   aws route53 list-resource-record-sets --hosted-zone-id <zone-id> --query "ResourceRecordSets[?contains(Name,'martin.diogo.world')]"
   ```

3. Delete the other Applications; deleting an Application also deletes what it installed:

   ```bash
   kubectl delete application monitoring-extras kube-prometheus-stack cloudwatch external-dns \
     cert-manager nginx-gateway-fabric gateway-api-crds -n argocd --wait --timeout=10m
   ```

4. Destroy the bridge first (its objects live in the cluster), then the main root:

   ```bash
   terraform -chdir=infra/gitops-bridge plan -destroy -out=tfplan
   terraform -chdir=infra/gitops-bridge apply tfplan
   terraform -chdir=infra/main plan -destroy -out=tfplan
   terraform -chdir=infra/main apply tfplan
   ```

5. Destroy the state bucket, the log bucket, the alarm and its topic:

   ```bash
   terraform -chdir=infra/bootstrap plan -destroy -out=tfplan
   terraform -chdir=infra/bootstrap apply tfplan
   ```

6. Delete the Identity Center user, the two GitHub secrets (`gh secret delete AWS_BUILD_ROLE_ARN -R $R`, the same for `AWS_RECORD_ROLE_ARN`) and the kubeconfig entry.

7. Check that nothing is left. `aws resourcegroupstaggingapi get-resources --tag-filters Key=Owner,Values=martin` should print an empty list. It does not list IAM roles, so also check that `aws iam list-roles --query "Roles[?starts_with(RoleName,'martin-project-final')].RoleName"` prints `[]`, and that no log group, secret or Route 53 record named after `martin-project-final` or `martin.diogo.world` remains. Secrets Manager keeps deleted secrets for a recovery window.

## Credits

The app comes from the course repository [ironhack-labs/devops-final-project-ih](https://github.com/ironhack-labs/devops-final-project-ih), whose README names saurabhd2106/devops-final-project as its origin. The infrastructure, the GitOps layer and the workflows build on the author's earlier course project, [terbin-tech/ironhack-project-2](https://github.com/terbin-tech/ironhack-project-2).
