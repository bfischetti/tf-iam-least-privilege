# IAM least-privilege guardrail
#
# Runs against `terraform show -json <plan>` output with conftest. It walks
# every IAM policy document Terraform is about to create and rejects the ones
# that grant more than they should. The goal is to make a lazy "s3:*" or a
# "Resource": "*" fail CI before it ever reaches an account.
#
# Test locally:
#   terraform plan -out tfplan.binary
#   terraform show -json tfplan.binary > tfplan.json
#   conftest test tfplan.json --policy policy

package main

import future.keywords.contains
import future.keywords.if
import future.keywords.in

# --- Collect the IAM policy JSON that Terraform plans to write ---------------
#
# aws_iam_role_policy and aws_iam_policy both carry the policy as a JSON string
# in `.policy`. aws_iam_role carries its trust policy in `.assume_role_policy`.
# We gather all of them, tagged with the resource address for good messages.

iam_documents contains doc if {
	rc := input.resource_changes[_]
	rc.type in {"aws_iam_role_policy", "aws_iam_policy"}
	raw := rc.change.after.policy
	raw != null
	doc := {"address": rc.address, "kind": "permission", "policy": json.unmarshal(raw)}
}

iam_documents contains doc if {
	rc := input.resource_changes[_]
	rc.type == "aws_iam_role"
	raw := rc.change.after.assume_role_policy
	raw != null
	doc := {"address": rc.address, "kind": "trust", "policy": json.unmarshal(raw)}
}

# Normalize Statement to always be an array.
statements(policy) := s if {
	is_array(policy.Statement)
	s := policy.Statement
} else := s if {
	s := [policy.Statement]
}

# Normalize Action / Resource, which may each be a string or an array.
as_set(x) := {x} if is_string(x)
as_set(x) := {v | v := x[_]} if is_array(x)
as_set(x) := set() if x == null

# --- Rule 1: no wildcard actions on Allow statements ------------------------

deny contains msg if {
	doc := iam_documents[_]
	doc.kind == "permission"
	stmt := statements(doc.policy)[_]
	stmt.Effect == "Allow"
	action := as_set(stmt.Action)[_]
	contains(action, "*")
	msg := sprintf(
		"%s: wildcard action %q is not least-privilege. List the exact actions this principal needs.",
		[doc.address, action],
	)
}

# --- Rule 2: no full-admin wildcard action ("*") ----------------------------

deny contains msg if {
	doc := iam_documents[_]
	doc.kind == "permission"
	stmt := statements(doc.policy)[_]
	stmt.Effect == "Allow"
	"*" in as_set(stmt.Action)
	msg := sprintf("%s: action \"*\" grants full admin. Never in a service role.", [doc.address])
}

# --- Rule 3: no "Resource": "*" on Allow statements -------------------------
#
# A small allowlist covers actions that genuinely have no resource scope
# (they are account- or partition-level). Everything else must name an ARN.

resource_wildcard_ok := {
	"sts:GetCallerIdentity",
	"cloudwatch:PutMetricData",
}

deny contains msg if {
	doc := iam_documents[_]
	doc.kind == "permission"
	stmt := statements(doc.policy)[_]
	stmt.Effect == "Allow"
	"*" in as_set(stmt.Resource)
	actions := as_set(stmt.Action)
	# Only complain if at least one action in this statement is NOT allowlisted.
	some a in actions
	not a in resource_wildcard_ok
	msg := sprintf(
		"%s: \"Resource\": \"*\" on action %q. Scope this to specific ARNs.",
		[doc.address, a],
	)
}

# --- Rule 4: trust policy must name a principal, never "*" ------------------

deny contains msg if {
	doc := iam_documents[_]
	doc.kind == "trust"
	stmt := statements(doc.policy)[_]
	stmt.Effect == "Allow"
	stmt.Principal == "*"
	msg := sprintf("%s: trust policy allows Principal \"*\". Anyone could assume this role.", [doc.address])
}

deny contains msg if {
	doc := iam_documents[_]
	doc.kind == "trust"
	stmt := statements(doc.policy)[_]
	stmt.Effect == "Allow"
	"*" in as_set(stmt.Principal.AWS)
	msg := sprintf("%s: trust policy allows AWS Principal \"*\". Scope to a specific account or role.", [doc.address])
}
