# Least-privilege IAM, enforced in CI

A small Terraform module with a deliberately tight IAM role, plus an Open Policy Agent guardrail that fails CI if anyone introduces a wildcard permission. The Lambda is only there to give the role something to do. The interesting part is the pipeline: any policy that grants more than it should fails the build before it reaches an account.

## What it builds

A `document-processor` service: a Lambda that reads an uploaded document from an ingest bucket, processes it, and writes the result to a separate output bucket. Three data resources, one execution role.

The interesting file is [`modules/document-processor/main.tf`](modules/document-processor/main.tf), specifically the role's permission policy. Every statement is scoped on purpose:

| Statement | Action | Resource | Why this shape |
|---|---|---|---|
| Read input | `s3:GetObject` | ingest bucket objects only | The function reads uploads. It cannot read the output bucket. |
| Write output | `s3:PutObject` | output bucket objects only | It writes results. It cannot overwrite the input it was handed. |
| List | `s3:ListBucket` | the two bucket ARNs only | Enough to enumerate its own buckets, no others. |
| Logs | `logs:CreateLogStream`, `logs:PutLogEvents` | this function's own log group ARN | It writes its own logs and no other log group in the account. |

There is no `s3:*` and no `"Resource": "*"` on any data action. The most important decision is the read/write split across two buckets: if the processor could also write to the ingest bucket, a bug in it could overwrite or corrupt the original upload.

## The guardrail

[`policy/iam.rego`](policy/iam.rego) runs against `terraform show -json` output with [conftest](https://www.conftest.dev/). It walks every IAM policy Terraform plans to create and denies:

1. **Wildcard actions** such as `s3:*` on an Allow statement.
2. **Full-admin `"*"`** as an action, ever, in a service role.
3. **`"Resource": "*"`** on data actions (with a tiny allowlist for the handful of actions that are genuinely account-scoped, like `cloudwatch:PutMetricData`).
4. **Over-open trust policies**: `Principal: "*"` or an AWS principal of `"*"`, which would let anyone assume the role.

Checking the plan means the guardrail sees the resolved policy JSON, including anything produced by `jsonencode`, a module, or a `for_each`. A grep over `.tf` files would miss all of those.

## Proof it works

A passing check on the real module only shows that the module is clean. To show the guardrail catches violations, the repo also carries [`test/insecure-fixture/`](test/insecure-fixture/main.tf), a module that intentionally grants `s3:*` on `*`, full admin, and a world-assumable trust policy. CI plans it and asserts the guardrail **rejects** it. If the insecure fixture ever passes, the build fails.

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

No AWS account or credentials are needed. The provider is configured to skip credential and account checks, and region and account ID are passed in as variables, so `plan` renders the full IAM offline.

```bash
make init      # terraform init
make check     # plan + run the guardrail against the real module (expect pass)
make test-bad  # plan the insecure fixture + assert the guardrail rejects it
```

Requires `terraform` and `conftest` on the path. CI runs the same targets on every push and pull request; see [`.github/workflows/iam-guardrail.yml`](.github/workflows/iam-guardrail.yml).

## Terraform and AWS CDK

I have built production infrastructure as code in AWS CDK (TypeScript) and wrote this one in Terraform, partly because Terraform is more widely used and partly because the two tools lead to different habits around IAM.

CDK's `grant*` helpers are good at this: `bucket.grantRead(fn)` writes a correctly scoped policy for you, which is safer by default than hand-writing JSON. The trade-off is that the permissions are implicit. The application code says `grantRead`, and the actual statements only exist in the synthesized CloudFormation. Terraform makes you write the policy document yourself, which is more verbose and easier to get wrong, but the full policy shows up in the diff at review time, where a wildcard can be caught.

The guardrail covers Terraform's weak spot: the policies are explicit in the plan, so a machine can reject the over-broad ones before a reviewer has to spot them. The same approach works for CDK by running a policy check against `cdk synth` output.

## What I would add next

- Extend the guardrail to flag missing `Condition` blocks on sensitive actions (for example requiring `aws:SecureTransport` on S3).
- Add `tflint` for provider-specific correctness alongside the policy check.
- A second service module to show the guardrail holding across more than one role.
