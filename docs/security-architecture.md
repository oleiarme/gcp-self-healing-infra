 Security Architecture & Threat Model

    This document outlines the security boundaries, data flows, and incident response procedures for the n8n self-healing infrastructure.

    Data Flow Diagram


    [User] <--HTTPS--> [Cloudflare Edge] <--Cloudflare Tunnel--> [VM e2-micro]
                                                                  |
                                                                  ├─> [n8n container :5678] ───> [Cloud SQL PostgreSQL]
                                                                  └─> [cloudflared container]


    Trust Boundaries
    1. Internet ↔ Cloudflare: Encrypted (HTTPS). Cloudflare handles TLS termination. No public IP on VM.
    2. Cloudflare Tunnel ↔ VM: Encrypted (QUIC/HTTPS) via cloudflared. Authenticated by a shared token (TF_VAR_CF_TUNNEL_TOKEN).
    3. VM ↔ Cloud SQL: Private IP within VPC. No public internet access to the database.
    4. GitHub Actions ↔ GCP: Keyless authentication via Workload Identity Federation (OIDC token exchange).

    Threat Model

    | Threat | Impact | Mitigation |
    |--------|---------|-------------|
    | Cloudflare Tunnel Token compromised | Attacker can route traffic to their own instance or inspect tunnel traffic | Token stored in GCP Secret Manager + GitHub Secrets. Rotate immediately via Runbook §3. prevent_destroy on resource. |
    | n8n vulnerability (CVE) | RCE or data exfiltration via n8n workflows | n8n image pinned by SHA256 digest. Weekly digest refresh via digest-refresh.yml. VM SA has no shell or compute.admin — limits blast radius. |
    | Cloud SQL credentials leaked | Full database access | Credentials in Secret Manager. VM SA has per-secret secretAccessor binding. DB password rotated via Runbook §3. |
    | GitHub Actions OIDC token stolen | Attacker can terraform apply in your project | WIF attribute condition pins to repository == "oleiarme/gcp-self-healing-infra" AND ref == "refs/heads/main". |
    | e2-micro instance compromised (container breakout) | Attacker gains VM context | Docker socket not exposed to n8n. VM SA scope is limited (cloud-platform scope restricted by IAM). No SSH open to internet. |

    Security Incident Response

    Unlike availability incidents (see Runbook), security incidents require a different playbook.

    1. Compromised Cloudflare Tunnel Token
    1. Rotate: Go to Cloudflare Zero Trust Dashboard → Networks → Tunnels → Edit → Reset Token.
    2. Update Secret: echo -n "NEW_TOKEN" | gcloud secrets versions add n8n-cf-token --data-file=-
    3. Redeploy: Force MIG recreation (Runbook §4). Old token becomes invalid immediately.

    2. Suspected n8n compromise (RCE)
    1. Isolate: gcloud compute instance-groups managed abandon-instances n8n-mig --instances=<name> --region=us-central1 (removes from MIG so it won't auto-heal, but stays running for forensics).
    2. Snapshot: Create disk snapshot for forensic analysis.
    3. Kill: Delete the isolated instance after snapshot.
    4. Review: Check n8n execution logs in Cloud Logging for unauthorized workflow runs.
    5. Patch: Update var.n8n_image to latest digest, apply Terraform.

    3. Cloud SQL Credentials Leaked
    1. Rotate: Runbook §3 (Secret Rotation).
    2. Audit: Check Cloud SQL logs for connections from unknown IPs (though it's private IP, check VPC flow logs if enabled).
    3. Revoke: Ensure old secret version is disabled.

    4. Security Contact
    - Report vulnerabilities: comf@ukr.net
    - PGP Key: (Attach your public key here if you have one)
    - Response SLA:
      - Critical (RCE, Data Leak): 48h initial response
      - High: 7 days