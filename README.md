# Secret Management in Automated Provisioning — Terraform + AWS Secrets Manager

Terraform stack that provisions a small VPC + EC2 instance and demonstrates
secure secret management: secrets are created and encrypted in AWS Secrets
Manager, an EC2 instance retrieves them at boot time via IAM role
credentials (no secret values ever appear in Terraform state diffs, CLI
output, or instance logs), and access is scoped with a least-privilege IAM
policy.

Chosen vendor option (from the task's Vendor Annex): **Terraform with AWS
Secrets Manager**.

## Architecture

```
Terraform apply
   │
   ├─ random_password.db_password ──► aws_secretsmanager_secret.db_password
   ├─ var.external_api_key         ──► aws_secretsmanager_secret.api_key
   ├─ var.ssh_deploy_private_key   ──► aws_secretsmanager_secret.ssh_key
   │                                        │ encrypted with
   │                                        ▼
   │                                aws_kms_key.secrets (CMK, rotation on)
   │
   ├─ aws_iam_role.app_role  ──attached──► aws_iam_policy.secrets_read_only
   │        │                              (GetSecretValue on the 3 ARNs above
   │        │                               + kms:Decrypt via Secrets Manager only)
   │        ▼
   └─ aws_instance.app (Ubuntu 24.04, iam_instance_profile = app_role)
            │ boots, user_data.sh.tftpl runs:
            ▼
      aws secretsmanager get-secret-value --secret-id <name>
            → writes value to /opt/app/config/*, mode 600/400, owner `app`
            → logs only "retrieved X successfully" to journald, never the value
```

## Secret types managed

| Secret | Terraform resource | Secrets Manager path | Type |
|---|---|---|---|
| Database password | `aws_secretsmanager_secret.db_password` | `secrets-demo/dev/db/password` | Randomly generated (`random_password`), rotated by re-running apply |
| External API key | `aws_secretsmanager_secret.api_key` | `secrets-demo/dev/api/external-key` | Operator-supplied string, JSON-wrapped |
| SSH deploy private key | `aws_secretsmanager_secret.ssh_key` | `secrets-demo/dev/ssh/deploy-key` | Operator-supplied PEM |

All three are encrypted at rest with a dedicated customer-managed KMS key
(`aws_kms_key.secrets`), not the default `aws/secretsmanager` key, so key
policy and rotation are explicit and auditable.

## Encryption & key management

- `aws_kms_key.secrets` is a customer-managed CMK with `enable_key_rotation
  = true` — AWS automatically rotates the backing key material yearly, no
  code change required.
- Each `aws_secretsmanager_secret` references this CMK via `kms_key_id`.
- The IAM policy's `kms:Decrypt` statement is scoped to this one key ARN
  **and** conditioned on `kms:ViaService = secretsmanager.<region>.amazonaws.com`
  — the app role cannot use the key to decrypt anything outside Secrets
  Manager.
- The unseal/master credential here is AWS's own KMS infrastructure — there
  is no separate key file to manage or leak; access to the CMK is itself
  governed by IAM.

## Access control model (least privilege)

- `aws_iam_role.app_role` — trust policy allows only `ec2.amazonaws.com` to
  assume it (`data.aws_iam_policy_document.ec2_assume`). No human principal
  can assume this role directly.
- `aws_iam_policy.secrets_read_only` grants exactly:
  - `secretsmanager:GetSecretValue` on the 3 specific secret ARNs (not
    `*`, not a wildcard prefix)
  - `kms:Decrypt` on the one CMK ARN, gated by `kms:ViaService`
  - Nothing else — no `PutSecretValue`, no `ListSecrets`, no `describe*`
    beyond what `GetSecretValue` needs, no SSM, no S3, no other service.
    This was verified live: the SSM agent on the instance gets
    `AccessDeniedException` on `ssm:UpdateInstanceInformation` because the
    role was never granted it — the policy really is scoped to just these
    3 secrets.
- Operator SSH access is separate from the app's secret access: a dedicated
  `aws_key_pair.operator` is used to log into the box for
  inspection/debugging; it has nothing to do with the app role's
  permissions or with the `ssh_deploy_private_key` secret (which is an
  *application* deploy key stored in Secrets Manager, not a login
  credential for this instance).
- The security group only allows inbound SSH (22) from `var.operator_cidr`
  (a single `/32`), egress is open for package installs / AWS API calls.

## How secrets are retrieved (no exposure)

`user_data.sh.tftpl` runs once on first boot:

1. Installs AWS CLI v2 via the official installer (Ubuntu 24.04's apt
   repos no longer carry an `awscli` package).
2. For each secret, calls `aws secretsmanager get-secret-value --secret-id
   <name> --query SecretString --output text` and redirects the output
   straight to a file — the value never touches stdout/a variable that
   could be echoed.
3. Sets `chmod 600` (or `400` for the private key) and `chown`s the file
   to a dedicated non-login service user (`app`, shell
   `/usr/sbin/nologin`).
4. Logs to `journald` only the fact that retrieval succeeded/failed
   (`logger "secrets-demo: retrieved X successfully"`), never the
   secret content.
5. `set -euo pipefail` — any failed retrieval aborts the boot script
   instead of silently continuing with a missing secret.

Terraform itself never prints secret values either:
- `variables.tf` marks `external_api_key` and `ssh_deploy_private_key`
  as `sensitive = true`.
- `outputs.tf` marks `db_password_value` as `sensitive = true`; only ARNs
  (safe, non-secret identifiers) are output in the clear.
- `terraform plan`/`apply` show `(sensitive value)` / `<sensitive>` in
  place of the actual values.

## How to add a new secret

1. Add a resource pair in `main.tf`:
   ```hcl
   resource "aws_secretsmanager_secret" "new_thing" {
     name        = "${var.project_name}/${var.environment}/new/thing"
     kms_key_id  = aws_kms_key.secrets.arn
     tags        = local.common_tags
   }

   resource "aws_secretsmanager_secret_version" "new_thing" {
     secret_id     = aws_secretsmanager_secret.new_thing.id
     secret_string = var.new_thing_value
   }
   ```
2. Add the ARN to the `resources` list in
   `data.aws_iam_policy_document.secrets_read_only` so the app role can
   read it — and only it, nothing broader.
3. Add a `sensitive = true` input variable in `variables.tf` if the value
   is operator-supplied.
4. Add a `fetch_secret_to_file` call in `user_data.sh.tftpl` and pass the
   secret's `name` through the `templatefile()` call in `main.tf`.
5. `terraform fmt && terraform validate && terraform plan` before
   applying.

## Rotation procedure

Two of the three secrets carry `lifecycle { ignore_changes =
[secret_string] }` (`api_key`, `ssh_key`) — this is intentional so that a
rotation performed *outside* Terraform (manually, or by a Lambda rotation
function) is never clobbered back to an old value by the next `terraform
apply`.

To rotate manually:

```bash
aws secretsmanager put-secret-value \
  --secret-id secrets-demo/dev/api/external-key \
  --secret-string '{"api_key":"<new-value>"}'
```

Then confirm Terraform sees no drift on the secret content:

```bash
terraform plan   # should show no diff for aws_secretsmanager_secret_version.api_key
```

The running instance picks up the new value on its next boot (secrets are
fetched fresh from Secrets Manager at boot time, not baked into the AMI or
cached) — e.g. `terraform apply -replace=aws_instance.app`, or by
restarting the app process on the instance if it re-reads
`/opt/app/config/*` itself.

The `db_password` secret is intentionally *not* ignore_changes'd — it's
fully Terraform-managed (`random_password`), so rotating it means
`terraform taint random_password.db_password && terraform apply`, which
generates and stores a brand new random value in one step.

## Audit logging

Secrets Manager API calls (`GetSecretValue`, `PutSecretValue`, etc.) are
recorded by AWS CloudTrail by default for the account/region, including
caller identity (the assumed role ARN), timestamp, and source IP — no
extra configuration needed on top of this stack. KMS `Decrypt` calls made
through Secrets Manager are logged the same way.

## Verifying no plaintext secrets ever hit git

```bash
git log -p --all | grep -iE "password|api_key|BEGIN (RSA|OPENSSH) PRIVATE KEY"
```

Expected output: empty. `terraform.tfvars` (the only file that ever holds
real secret values) is excluded via `.gitignore` and was never staged.

## Deploying this stack yourself

```bash
cp terraform.tfvars.example terraform.tfvars   # then fill in real values
# never commit terraform.tfvars

terraform init
terraform plan
terraform apply
```

Required inputs (see `variables.tf`): `operator_cidr` (your IP, for SSH),
`operator_ssh_public_key` (public key for operator SSH access — not
secret), `external_api_key` and `ssh_deploy_private_key` (secret values,
mark `sensitive`, prefer `TF_VAR_*` env vars over the tfvars file).

## Tested

- `terraform fmt -check`, `terraform validate`, `terraform plan`,
  `terraform apply` all complete without printing secret values.
- End-to-end retrieval verified on a live instance: all 3 secrets fetched
  to disk with correct permissions (`600`/`600`/`400`), owned by the
  non-login `app` user; `journalctl | grep secrets-demo` shows only
  success markers, no content.
- Re-applying after replacing the instance (AMI fix, key-pair addition)
  re-ran the same bootstrap successfully — retrieval is consistent across
  multiple runs, not a one-off.
