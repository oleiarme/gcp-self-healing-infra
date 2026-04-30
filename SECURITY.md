Security Policy

    Reporting a Vulnerability

    We take the security of gcp-self-healing-infra seriously. If you discover a security vulnerability, please report it responsibly.

    Contact
    - Email: comf@ukr.net
    - Subject: [SECURITY] gcp-self-healing-infra vulnerability report

    Response SLA
    - Initial Response: Within 48 hours.
    - Critical Fix: Within 7 days of verification.
    - Status Updates: Every 72 hours until resolved.

    Supported Versions

    | Version | Supported          |
    | ------- | ------------------ |
    | n8n 2.x (latest)   | :white_check_mark: |
    | Terraform module (main) | :white_check_mark: |

    Disclosure Policy
    We follow a coordinated disclosure process:
    1. Reporter sends details.
    2. We confirm and assess the vulnerability.
    3. We develop and test a fix.
    4. We release the patch and credit the reporter (unless anonymity is requested).
    5. We publish a security advisory on GitHub.

    Known Security Features
    - Workload Identity Federation (keyless CI/CD)
    - All secrets stored in Google Secret Manager (no plaintext)
    - Container images pinned by SHA256 digest
    - Static analysis in CI (tfsec, Checkov, Trivy)
    - WIF Attribute Conditions restrict deployment to main branch only