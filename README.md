# Least-privilege IAM, enforced in CI

A small Terraform module with a deliberately tight IAM role, plus an Open Policy Agent guardrail that fails CI if anyone introduces a wildcard permission. The point is not the Lambda. The point is that "least privilege" is a property the pipeline enforces, not a habit you hope people keep.

## What it builds

A `document-processor` service: a Lambda that reads an uploaded document from an ingest bucket, processes it, and writes the result to a separate output bucket. Three data resources, one execution role.

The interesting file is [`modules/document-processor/main.tf`](modules/document-processor/main.tf), specifically the role's permission policy. Every statement is scoped on purpose:

| Statement | Action | Resource | Why this shape |
|---|---|---|---|
| Read input | `s3:GetObject` | ingest bucket objects only | The function reads uploads. It cannot read the output bucket. |
| Write output | `s3:PutObject` | output bucket objects only | It writes results. It cannot overwrite the input it was handed. |
| List | `s3:ListBucket` | the two bucket ARNs, not `*` | Enough to enumerate its own buckets, no others. |
| Logs | `logs:CreateLogStream`, `logs:PutLogEvents` | this function's own log group ARN | It writes its own logs, not every log group in the account. |

No `s3:*`. No `"Resource": "*"` on a data action. The read/write split across two buckets is the least-privilege decision that matters most here: a processor that can read its input and overwrite it is a processor that can corrupt the thing it was asked to protect.

## The guardrail

[`policy/iam.rego`](policy/iam.rego) runs against `terraform show -json` output with [conftest](https://www.conftest.dev/). It walks every IAM policy Terraform plans to create and denies:

1. **Wildcard actions** such as `s3:*` on an Allow statement.
2. **Full-admin `"*"`** as an action, ever, in a service role.
3. **`"Resource": "*"`** on data actions (with a tiny allowlist for the handful of actions that are genuinely account-scoped, like `cloudwatch:PutMetricData`).
4. **Over-open trust policies**: `Principal: "*"` or an AWS principal of `"*"`, which would let anyone assume the role.

Checking the *plan* rather than the HCL means it sees the real, resolved policy JSON, including anything produced by `jsonencode`, a module, or a `for_each`. A grep over `.tf` files would miss all of those.

## Proof it works

A passing check on a clean module proves nothing on its own. So the repo also carries [`test/insecure-fixture/`](test/insecure-fixture/main.tf), a module that intentionally grants `s3:*` on `*`, full admin, and a world-assumable trust policy. CI plans it and asserts the guardrail **rejects** it. If the insecure fixture ever passes, the build fails on regression.

```
# the real module: guardrail passes
$ make check
5 tests, 5 passed, 0 warnings, 0 failures

# the insecure fixture: guardrail must reject it
$ make test-bad
6 tests, 0 passed, 6 failures
OK: guardrail correctly rejected the insecure fixture
```

## Running it locally

No AWS account or credentials are needed. The provider is configured to skip credential and account checks, and region and account ID are passed in as variables rather than discovered from a live account, so `plan` renders the full IAM offline.

```bash
make init      # terraform init
make check     # plan + run the guardrail against the real module (expect pass)
make test-bad  # plan the insecure fixture + assert the guardrail rejects it
```

Requires `terraform` and `conftest` on the path. CI runs the same targets on every push and pull request; see [`.github/workflows/iam-guardrail.yml`](.github/workflows/iam-guardrail.yml).

## A note on Terraform vs AWS CDK

I have built production infrastructure as code in AWS CDK (TypeScript) and wanted this artifact in Terraform, both because it is the more common ask and because the two tools push you toward different habits around IAM.

CDK's `grant*` helpers are excellent: `bucket.grantRead(fn)` writes a correctly scoped policy for you, which is safer by default than hand-writing JSON. The cost is that the granted permissions are implicit. You read the application code, not the policy, and the actual statements only exist in synthesized CloudFormation. Terraform makes you write the policy document explicitly, which is more verbose and easier to get wrong by hand, but the policy is right there in the diff at review time, which is exactly where a wildcard should get caught.

The guardrail closes CDK's blind spot for the Terraform workflow: the permissions are explicit in the plan, and a machine rejects the lazy ones before a human has to notice them. The same idea ports to CDK by running the policy check against `cdk synth` output instead of a Terraform plan.

## What I would add next

- Extend the guardrail to flag missing `Condition` blocks on sensitive actions (for example requiring `aws:SecureTransport` on S3).
- Add `tflint` for provider-specific correctness alongside the policy check.
- A second service module to show the guardrail holding across more than one role.
