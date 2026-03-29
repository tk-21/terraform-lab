# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AWS-based RAG (Retrieval-Augmented Generation) knowledge bot. Documents are stored in S3, vectorized and indexed in Amazon OpenSearch Serverless, and the Bedrock Knowledge Base ties the retrieval pipeline together. The FastAPI app runs on EKS and calls Bedrock via IRSA.

## Common Commands

All commands run from the repo root (`knowledge-bot/`).

```bash
# Terraform
make tf-init          # terraform init (in infra/)
make tf-apply         # terraform apply -auto-approve
make tf-output        # print terraform outputs

# App
make build-push       # build Docker image and push to ECR (tag: dev)
./scripts/build_push_ecr.sh <TAG>  # push with a specific tag

# Kubernetes
make deploy           # deploy k8s manifests
make kb-ingest        # ingest documents into the knowledge base

# Terraform validation (run before any infra change)
cd infra && terraform fmt -recursive
cd infra && terraform validate
```

## Architecture

```
User → ALB → EKS (knowledgebot namespace)
                        └─ FastAPI app (port 8080)
                              └─ IRSA → Bedrock RetrieveAndGenerate API
                                            └─ Knowledge Base
                                                  ├─ S3 (source documents, KMS encrypted)
                                                  └─ OpenSearch Serverless (vector index, hnsw/faiss, dim=1024)
```

**Key Terraform files in `infra/`:**

| File | Purpose |
|---|---|
| `eks.tf` | EKS cluster (v1.29, t3.medium, 2 AZ managed node group) |
| `bedrock_kb.tf` | Bedrock Knowledge Base + S3 data source; uses Titan Embed v2 |
| `opensearch_serverless.tf` | AOSS collection + security/access policies |
| `opensearch_index.tf` | Vector index (`knn_vector`, hnsw, faiss, l2, dim=1024) |
| `irsa_app.tf` | IRSA role for EKS pods → `bedrock:InvokeModel`, `Retrieve`, `RetrieveAndGenerate` |
| `endpoints.tf` | VPC endpoints for Bedrock, ECR, logs, STS, S3 (private DNS) |
| `github_oidc_ci.tf` | GitHub OIDC role for CI/CD (set `github_repository` variable) |
| `helm_addons.tf` | AWS Load Balancer Controller (enabled via `enable_lbc = true`) |

**Kubernetes (`k8s/base/`):** Namespace `knowledgebot`, ServiceAccount `knowledgebot-sa` (annotate with IRSA ARN from `terraform output irsa_app_role_arn`), HPA, Ingress.

**App (`app/`):** Python 3.12, FastAPI, uvicorn on port 8080. `src/rag_mvp.py` contains a keyword-based fallback retriever used when Bedrock KB is unavailable.

## Key Variables

| Variable | Default | Notes |
|---|---|---|
| `region` | `ap-northeast-1` | AWS region |
| `bedrock_model_id` | `anthropic.claude-3-5-sonnet-20240620-v1:0` | Claude model for generation |
| `aoss_index_name` | `knowledge-bot-index` | OpenSearch index name |
| `enable_lbc` | `false` | Set `true` to deploy AWS Load Balancer Controller |
| `github_repository` | `YOURORG/knowledge-bot` | Update before applying CI OIDC role |

## CI/CD

GitHub Actions (`.github/workflows/terraform.yml`) authenticates via OIDC. On PR: `fmt`, `validate`, `plan`. On push to `main`: `apply`. The `AWS_ROLE_TO_ASSUME` secret must be configured in the repository.

## Coding Rules

- Prefer module reuse over direct resource definitions (`terraform-aws-modules/*`)
- Run `terraform fmt` and `terraform validate` before proposing any Terraform change
- Do not modify `provider`, `backend`, or state configuration without explicit instruction
- Keep comments minimal; explain only non-obvious logic
- Do not read `.env`, `*.tfvars`, `*.pem`, `*.key`, or `secrets/` / `private/` paths
- The `infra/.terraform/` directory should not be modified or read
