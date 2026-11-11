locals {
  main     = data.terraform_remote_state.main.outputs
  repo_url = "https://github.com/terbin-tech/ironhack-project-final.git"

  sync_policy = {
    automated = {
      prune    = true
      selfHeal = true
    }
    syncOptions = ["ServerSideApply=true"]
    retry = {
      limit = 10
      backoff = {
        duration    = "10s"
        factor      = 2
        maxDuration = "5m"
      }
    }
  }

  restricted = {
    "pod-security.kubernetes.io/enforce"         = "restricted"
    "pod-security.kubernetes.io/enforce-version" = "latest"
    "pod-security.kubernetes.io/warn"            = "restricted"
    "pod-security.kubernetes.io/audit"           = "restricted"
  }
}

# No project key: a project-scoped cluster is unusable by the AppProject.
resource "kubernetes_secret_v1" "in_cluster" {
  metadata {
    name      = "in-cluster"
    namespace = "argocd"

    labels = {
      "argocd.argoproj.io/secret-type" = "cluster"
    }
  }

  data = {
    name   = "in-cluster"
    server = local.main.cluster_arn
  }
}

# Argo CD stopped assessing Application health in 1.8; the app-of-apps root needs
# it. Lua verbatim from https://github.com/argoproj/argo-cd/blob/master/docs/operator-manual/health.md
resource "kubernetes_config_map_v1" "argocd_cm" {
  metadata {
    name      = "argocd-cm"
    namespace = "argocd"

    labels = {
      "app.kubernetes.io/part-of" = "argocd"
    }
  }

  data = {
    "resource.customizations.health.argoproj.io_Application" = <<-EOT
      hs = {}
      hs.status = "Progressing"
      hs.message = ""
      if obj.status ~= nil then
        if obj.status.health ~= nil then
          hs.status = obj.status.health.status
          if obj.status.health.message ~= nil then
            hs.message = obj.status.health.message
          end
        end
      end
      return hs
    EOT
  }
}

# Cluster-scoped kinds stay open: a kind list broke syncs in Project 2.
resource "kubernetes_manifest" "project" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "AppProject"
    metadata = {
      name      = "martin-project-final"
      namespace = "argocd"
    }
    spec = {
      description = "Expensy platform, app and monitoring"
      sourceRepos = [
        local.repo_url,
        "https://github.com/kubernetes-sigs/gateway-api",
        "ghcr.io/nginx/charts",
        "quay.io/jetstack/charts",
        "https://kubernetes-sigs.github.io/external-dns/",
        "https://prometheus-community.github.io/helm-charts",
      ]
      # Required by the EKS Argo CD capability for Applications stored in argocd.
      sourceNamespaces = ["argocd"]
      destinations = [
        for namespace in [
          "argocd", "expensy", "gateway", "nginx-gateway", "cert-manager",
          "external-dns", "monitoring", "amazon-cloudwatch", "kube-system", "aws-secrets-manager",
        ] : { name = "in-cluster", namespace = namespace }
      ]
      clusterResourceWhitelist = [{
        group = "*"
        kind  = "*"
      }]
    }
  }
}

resource "kubernetes_manifest" "root" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name       = "root"
      namespace  = "argocd"
      finalizers = ["resources-finalizer.argocd.argoproj.io"]
    }
    spec = {
      project = kubernetes_manifest.project.manifest.metadata.name
      source = {
        repoURL        = local.repo_url
        targetRevision = "main"
        path           = "gitops/root"
      }
      destination = {
        name      = "in-cluster"
        namespace = "argocd"
      }
      syncPolicy = local.sync_policy
    }
  }

  depends_on = [
    kubernetes_secret_v1.in_cluster,
    kubernetes_config_map_v1.argocd_cm,
    kubernetes_manifest.project,
  ]
}

resource "kubernetes_namespace_v1" "expensy" {
  metadata {
    name   = "expensy"
    labels = local.restricted
  }
}

# node-exporter needs host namespaces and a hostPath mount.
resource "kubernetes_namespace_v1" "monitoring" {
  metadata {
    name = "monitoring"

    labels = {
      "pod-security.kubernetes.io/enforce"         = "privileged"
      "pod-security.kubernetes.io/enforce-version" = "latest"
      "pod-security.kubernetes.io/warn"            = "privileged"
      "pod-security.kubernetes.io/audit"           = "privileged"
    }
  }
}

# The CSI driver, the GuardDuty agent, the CloudWatch agent and Fluent Bit need
# hostPath volumes and host access.
resource "kubernetes_labels" "pod_security" {
  for_each = {
    argocd              = "restricted"
    default             = "restricted"
    aws-secrets-manager = "privileged"
    amazon-guardduty    = "privileged"
    amazon-cloudwatch   = "privileged"
  }

  api_version = "v1"
  kind        = "Namespace"

  metadata {
    name = each.key
  }

  labels = {
    "pod-security.kubernetes.io/enforce"         = each.value
    "pod-security.kubernetes.io/enforce-version" = "latest"
    "pod-security.kubernetes.io/warn"            = each.value
    "pod-security.kubernetes.io/audit"           = each.value
  }
}

resource "kubernetes_config_map_v1" "expensy_config" {
  metadata {
    name      = "expensy-config"
    namespace = kubernetes_namespace_v1.expensy.metadata[0].name
  }

  data = {
    DB_HOST        = local.main.docdb_endpoint
    DB_PORT        = tostring(local.main.docdb_port)
    DB_NAME        = "expensy"
    DB_TLS         = "true"
    DB_TLS_CA_FILE = "/etc/ssl/certs/rds-global-bundle.pem"
    REDIS_HOST     = local.main.valkey_primary_endpoint
    REDIS_PORT     = tostring(local.main.valkey_port)
    REDIS_USERNAME = local.main.valkey_username
    REDIS_TLS      = "true"
  }
}

# The RDS CA bundle for the docdb-user Job, from the one committed copy that the
# backend image also uses (kustomize may not read files outside its folder).
resource "kubernetes_config_map_v1" "rds_ca" {
  metadata {
    name      = "rds-ca"
    namespace = kubernetes_namespace_v1.expensy.metadata[0].name
  }

  data = {
    "rds-global-bundle.pem" = file("${path.module}/../../certs/rds-global-bundle.pem")
  }
}

resource "kubernetes_manifest" "expensy_backend_secrets" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "expensy-backend"
      namespace = kubernetes_namespace_v1.expensy.metadata[0].name
    }
    spec = {
      provider = "aws"
      parameters = {
        usePodIdentity = "true"
        objects = yamlencode([
          {
            objectName = local.main.docdb_app_secret_arn
            objectType = "secretsmanager"
            jmesPath = [
              { path = "username", objectAlias = "db-username" },
              { path = "password", objectAlias = "db-password" },
            ]
          },
          {
            objectName = local.main.valkey_secret_arn
            objectType = "secretsmanager"
            jmesPath = [
              { path = "password", objectAlias = "redis-password" },
            ]
          },
        ])
      }
    }
  }
}

resource "kubernetes_manifest" "expensy_docdb_admin_secrets" {
  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = "expensy-docdb-admin"
      namespace = kubernetes_namespace_v1.expensy.metadata[0].name
    }
    spec = {
      provider = "aws"
      parameters = {
        usePodIdentity = "true"
        objects = yamlencode([
          {
            objectName = local.main.docdb_master_secret_arn
            objectType = "secretsmanager"
            jmesPath = [
              { path = "username", objectAlias = "master-username" },
              { path = "password", objectAlias = "master-password" },
            ]
          },
          {
            objectName = local.main.docdb_app_secret_arn
            objectType = "secretsmanager"
            jmesPath = [
              { path = "username", objectAlias = "app-username" },
              { path = "password", objectAlias = "app-password" },
            ]
          },
        ])
      }
    }
  }
}

# These two Applications hold the account or zone ID, so they stay out of Git.
# The * keeps the tag and digest the pipeline records in Git (kustomize edit set image).
resource "kubernetes_manifest" "expensy_app" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "expensy"
      namespace = "argocd"
      annotations = {
        "argocd.argoproj.io/sync-wave"       = "3"
        "argocd.argoproj.io/compare-options" = "ServerSideDiff=true"
      }
      finalizers = ["resources-finalizer.argocd.argoproj.io"]
    }
    spec = {
      project = kubernetes_manifest.project.manifest.metadata.name
      source = {
        repoURL        = local.repo_url
        targetRevision = "main"
        path           = "gitops/apps/expensy"
        kustomize = {
          images = [
            for name in ["martin-expensy-frontend", "martin-expensy-backend"] :
            "${name}=${local.main.ecr_registry}/${name}:*@*"
          ]
        }
      }
      destination = {
        name      = "in-cluster"
        namespace = "expensy"
      }
      syncPolicy = local.sync_policy
    }
  }

  depends_on = [kubernetes_manifest.project]
}

resource "kubernetes_manifest" "external_dns_app" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "external-dns"
      namespace = "argocd"
      annotations = {
        "argocd.argoproj.io/sync-wave"       = "1"
        "argocd.argoproj.io/compare-options" = "ServerSideDiff=true"
      }
      finalizers = ["resources-finalizer.argocd.argoproj.io"]
    }
    spec = {
      project = kubernetes_manifest.project.manifest.metadata.name
      source = {
        repoURL        = "https://kubernetes-sigs.github.io/external-dns/"
        chart          = "external-dns"
        targetRevision = "1.23.0"
        helm = {
          valuesObject = {
            provider           = { name = "aws" }
            sources            = ["gateway-httproute"]
            policy             = "sync"
            registry           = "txt"
            txtOwnerId         = "martin-project-final"
            domainFilters      = ["martin.diogo.world"]
            labelFilter        = "app.kubernetes.io/part-of=expensy"
            triggerLoopOnEvent = true
            extraArgs = [
              "--aws-zone-match-parent",
              "--zone-id-filter=${local.main.zone_id}",
              "--events-emit=RecordError",
              "--aws-zones-cache-duration=1h",
            ]
            serviceAccount = { name = "external-dns" }
            env            = [{ name = "AWS_DEFAULT_REGION", value = "us-east-1" }]
          }
        }
      }
      destination = {
        name      = "in-cluster"
        namespace = "external-dns"
      }
      syncPolicy = merge(local.sync_policy, {
        syncOptions = ["ServerSideApply=true", "CreateNamespace=true"]
        # Argo CD creates this namespace, so it sets the Pod Security labels too.
        managedNamespaceMetadata = { labels = local.restricted }
      })
    }
  }

  depends_on = [kubernetes_manifest.project]
}
