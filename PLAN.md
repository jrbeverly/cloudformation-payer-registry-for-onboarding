# Implementation plan

Target: `cloudformation/cloudformation-payer-registry-for-onboarding/`. This
document is the durable copy of the plan for the AWS Organization onboarding
proof of concept and the source of truth for the follow-up issues in this
milestone. The work described below is proposed implementation work, not
completed functionality. Every follow-up issue constrains its implementation
work to this experiment directory.

The proof of concept is exercised against two real AWS environments — one
standing in for the central management platform, one standing in for the
acquired AWS Organization. The behaviours under test (cross-account role
assumption, organization discovery) cannot be meaningfully simulated, and the
VISION's expected outputs require real AWS.

## Assumptions

- The "central platform" in this proof of concept is a set of plain scripts
  run by the experimenter, not a service or application. The VISION
  explicitly defers any portal or UI and allows stack generation by
  command-line script.
- The acquired environment is an AWS Organization with a management account,
  matching the VISION's primary scenario.
- The experimenter can deploy into the acquired environment and holds
  credentials in the central environment; without both, the end-to-end run
  cannot happen.
- The repository's experiment conventions apply: the experiment is
  self-contained, prefers hard-coded values and primitive scripts over
  configuration and frameworks, and is documented by a visually small README
  whose Notes record what was actually learned.
- The experiment may be left in place unmaintained afterwards; the VISION
  treats experiments as observations, not maintained software.

## What we are validating

The proof of concept exists to validate these behaviours, in order of
importance:

1. A generated CloudFormation stack can carry enough context — an onboarding
   request identifier and the central platform's identity — for the eventual
   registration to be correlated back to the request.
2. Deploying that stack is a sufficient trust ceremony: it authorizes the
   central environment to assume a bootstrap role, with no manual exchange of
   role ARNs or account identifiers.
3. Registration is automatic: completing the deployment notifies the central
   platform. The human-triggered part ends at deployment; everything after is
   machine-driven.
4. The registration event carries enough information — account identifier,
   organization identifier, role ARN, request identifier, deployment region —
   for the central system to identify the environment and begin interacting
   with it.
5. A narrowly scoped bootstrap role — read access to the organization
   structure plus the ability to create the next-stage role — is sufficient
   for the first two onboarding steps: discovery and role deployment.
6. Discovery through the assumed role yields the organization structure
   (identifier, organizational units, member accounts).
7. The handoff tolerates partial failure: duplicate registration events are
   harmless, the stack can be redeployed, and onboarding can be restarted
   without rebuilding the environment.

## The smallest end-to-end implementation

Five phases, each owned by one side of the handoff:

- **Phase 1 — generate (central side, before deployment).** One script
  generates the CloudFormation template for an onboarding request and records
  the request locally.
- **Phase 2 — deploy (acquired side).** One command deploys the stack into
  the acquired management account. The stack creates the bootstrap role and,
  on completion, emits the registration event. The human action ends here.
- **Phase 3 — receive (central side, during registration).** One script
  observes the registration event, verifies it matches a known request, and
  records it.
- **Phase 4 — enter and discover (central side, after registration).** One
  script assumes the bootstrap role and discovers the organization structure,
  writing a report; a second creates the next-stage role.
- **Phase 5 — repeat and probe.** The failure scenarios from the VISION are
  exercised against phases 2–4 and the observed behaviour recorded.

Nothing else is needed to answer the VISION's key question.

## Sequence of work

The follow-up issues implement the phases in order; each issue ends with a
checkable outcome the next issue consumes:

- Onboarding stack generator — phase 1 and phase 2's template (behaviour 1).
- Bootstrap stack: role and automatic registration — behaviours 2, 3, and 4.
- Central registration receiver — behaviour 4 and the idempotence half of
  behaviour 7.
- Assume bootstrap role and discover the organization — behaviour 5's
  discovery half and behaviour 6.
- Next-stage role through the bootstrap role — behaviour 5's role-deployment
  half. Runs in parallel with the failure scenarios issue; both consume the
  discovery step.
- Failure and retry scenarios — behaviour 7.
- End-to-end run and success review — the verdict, after both branches.

## Decisions from the bootstrap-stack issue (#550)

### Registration transport

Chosen: an API call — the stack's registration Lambda makes an HTTPS PUT of
the registration JSON to an S3 PutObject presigned URL that the generator
creates with the onboarding request. The URL points at
`s3://onboarding-registration-<central-account-id>/registrations/<request-id>.json`
in the central account and is embedded in the template as the
`RegistrationEndpoint` parameter default.

Rationale:

- EventBridge, SQS, and SNS all deliver across accounts through a
  resource-based policy on the central resource (bus, queue, topic), and that
  policy must name the sender's account identifier. The acquired account
  identifier is itself learned from the registration event, so every one of
  those transports needs the central side to know in advance the identifier
  it is trying to learn — a circular setup dependency.
- A presigned URL authenticates the request rather than the sender: the
  signature is scoped to one object key for one onboarding request, so the
  central side needs no advance knowledge of the acquired account and no
  cross-account policy at all.
- The central-side footprint is a single S3 bucket. The registration record
  is a durable object the receiver script (next issue) reads directly; there
  is no central compute, endpoint, or subscription to run.
- Delivery is automatic by construction: the registration runs inside a
  CloudFormation custom resource that signals success only after the PUT
  returns 2xx, so the stack reaches CREATE_COMPLETE only after the event is
  delivered.

Constraints of this choice, to be probed in the failure-scenarios issue:

- The presigned URL expires after 7 days (SigV4 maximum); a package deployed
  later must be regenerated, which is one generator run.
- The Lambda does not retry the PUT: one transient failure signals FAILED and
  rolls the stack back, deleting the bootstrap role; redeploying retries the
  registration.
- Update and Delete of the stack are no-ops for registration (no
  de-registration or re-delivery); duplicate events are the receiver issue's
  concern.

### Registration event

The event object, written as JSON to the presigned URL, carries exactly the
five required fields:

- `requestId` — the generator's request identifier parameter.
- `accountId` — `AWS::AccountId` of the deploying account.
- `organizationId` — read by the Lambda from the acquired environment with
  `organizations:DescribeOrganization` at deployment time.
- `bootstrapRoleArn` — the created role's ARN.
- `region` — `AWS::Region` of the deployment.

### Bootstrap role permissions

Trust policy: `sts:AssumeRole` from `arn:aws:iam::<central-account-id>:root`,
the identifier embedded in the template at generation time. The role carries
two policies; every action is listed with the step that uses it:

| Policy | Action | Used by |
| --- | --- | --- |
| OrganizationDiscovery | `organizations:DescribeOrganization` | discovery step (assume-and-discover issue): the organization identifier in the discovery report |
| OrganizationDiscovery | `organizations:ListRoots` | discovery step: entry point of the organization tree walk |
| OrganizationDiscovery | `organizations:ListChildren` | discovery step: organizational units under the root |
| OrganizationDiscovery | `organizations:ListOrganizationalUnitsForParent` | discovery step: nested organizational units while walking the tree |
| OrganizationDiscovery | `organizations:ListAccounts` | discovery step: member accounts under the root and each organizational unit |
| NextStageRoleDeployment | `iam:CreateRole` | next-stage role step (`create-next-stage-role.sh`): create the placeholder role |
| NextStageRoleDeployment | `iam:PutRolePolicy` | next-stage role step (`create-next-stage-role.sh`): attach the placeholder's inline policy |

Both deployment actions are scoped to
`arn:aws:iam::<acquired-account>:role/onboarding/*`. The next-stage role is
created under the path `onboarding/` with the policy attached by
`PutRolePolicy`, so both permissions are demonstrably used. Rotation,
reduction, or removal of the bootstrap role is future work (see "Standing
cost" under success criteria).

### Registration function permissions

The registration Lambda's execution role (separate from the bootstrap role)
holds:

| Action | Used by |
| --- | --- |
| `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents` | Lambda execution logging |
| `organizations:DescribeOrganization` | registration event assembly: the event's `organizationId`, read from the acquired environment at deployment time |

The template deploys with `CAPABILITY_IAM` (it creates IAM roles, none with
explicit names). The Lambda is a Node.js function with the code inlined in
the template (`ZipFile`), using the runtime's bundled AWS SDK v3 and
CommonJS, because the nodejs22 runtime disables ESM auto-detection and inline
code is packaged as `index.js`.

## Decisions from the central-registration-receiver issue (#551)

### Local records

The generator writes `requests/<request-id>.json` (`requestId`,
`centralAccountId`) when it generates a package, and the receiver treats a
request as known only when that record exists. Accepted registrations are
written to `registrations/<request-id>.json` — the delivered event verbatim —
and that file is the only input the discovery step reads.

### Receiving

`receive-registration.sh <central-account-id>` sweeps the bucket's
`registrations/` prefix. Per object it requires the five event fields to be
non-empty strings, the event's `requestId` to match the object key and a
local request record, and it writes the record without overwriting an
existing one, so a replayed event never creates a second record. Rejections
print to stderr, leave existing records untouched, and make the script exit
non-zero.

### Offline validation

`test-receiver.sh` exercises the acceptance criteria without real AWS: a fake
`aws` CLI in PATH maps the bucket onto a local directory, and the scripts run
from a copied directory so their local records land in a temp dir.

## Decisions from the assume-and-discover issue (#549)

### Discovery step

`discover-organization.sh` takes no arguments: it sweeps `registrations/`
and, per accepted registration, assumes the bootstrap role using only the
record's `bootstrapRoleArn`, then walks the organization through the
assumed-role session. It writes `discovery/<request-id>.json` containing
exactly the organization identifier, the organizational units, and the
member accounts.

The walk starts at the root's child ids from `organizations:ListChildren`,
attaches names and descends with
`organizations:ListOrganizationalUnitsForParent`, and lists accounts with
one org-wide `organizations:ListAccounts` call, so every discovery
permission on the bootstrap role is used. All organizations calls target
us-east-1 — the API is global regardless of the deployment region in the
registration — and the report's organization identifier is read with
`organizations:DescribeOrganization` through the assumed session rather
than copied from the record.

### Offline validation

`test-discover.sh` exercises the acceptance criteria without real AWS: a
fake `aws` CLI in PATH serves sts and organizations, refuses to serve
organizations data to any session other than the one created by the fake
`sts:AssumeRole`, and rejects an assume-role call whose role ARN does not
match the registration record.

## Decisions from the failure-scenarios issue (#553)

### Scenario exercise

- The six failure scenarios the VISION names are exercised offline by
  `test-failures.sh`: a fake `aws` CLI with failure switches for sts and
  organizations, a local HTTPS server standing in for the presigned
  registration endpoint, and a stubbed organizations SDK for the Lambda.
  One observation per scenario, including the human recovery step, is
  recorded in the README Notes.
- Real-AWS confirmation of the deploy boundary (CloudFormation rollback on
  a FAILED registration signal) remains with the end-to-end run; the
  offline exercise observes the Lambda's single PUT and its FAILED signal.

### Discovery step changes

- `discover-organization.sh` treats each registration independently: a
  failed walk prints FAILED with the underlying AWS error, writes no
  report, and the remaining registrations still run, exiting non-zero if
  any failed.
- Every aws call's failure now fails the record instead of silently
  producing an incomplete report (the previous behaviour for calls piped
  through jq).
- No retry was added: a human re-runs after fixing the environment, and a
  failed run leaves nothing behind to clean up. This is the accepted
  limitation — the VISION rules out sophisticated recovery orchestration.

### Unchanged

- The receiver and the Lambda needed no change: duplicate collapse,
  unknown-request rejection, and the single-shot registration PUT already
  met the scenarios.

## Decisions from the next-stage-role issue (#555)

### Next-stage role step

`create-next-stage-role.sh` sweeps `registrations/` and, per accepted
registration, assumes the bootstrap role and creates the placeholder role
through the assumed-role session. It writes `next-stage/<request-id>.json`
with the created role's ARN (as returned by `iam:CreateRole`) and the
attached policy name; a failed creation fails that record only and the
script exits non-zero if any failed.

### Next-stage role identity

Hard-coded, not configurable: role name `next-stage` under path
`/onboarding/`, so the role ARN is
`arn:aws:iam::<acquired-account>:role/onboarding/next-stage`. The path is
forced by the bootstrap policy's resource scope
(`arn:aws:iam::<account>:role/onboarding/*`); the name is the documented
placeholder for the permanent management roles.

### Next-stage role permissions

Trust policy: `sts:AssumeRole` from `arn:aws:iam::<central-account-id>:root`.
The registration event does not carry the central account identifier, so the
step reads it from the request record `requests/<request-id>.json`. Inline
policy `OrganizationDiscovery`: the five organizations read actions,
mirroring the bootstrap role's discovery policy — the set a future discovery
role would hold.

### Bootstrap permissions used

Exactly the two `NextStageRoleDeployment` actions (table above):
`iam:CreateRole` to create the role under `onboarding/`, and
`iam:PutRolePolicy` to attach the inline policy. No other bootstrap
permission is involved and none was added.

### Offline validation

`test-next-stage-role.sh` exercises the acceptance criteria without real
AWS: a fake `aws` CLI serves sts and iam, serving iam only to the session
created by the fake `sts:AssumeRole`, which accepts exactly the role ARN
recorded in the registration. A `FAKE_FAIL_CREATE_ROLE` switch fails the
creation, showing a failed record writes nothing and the script exits
non-zero.

## What is mocked, hard-coded, simplified, or excluded

- **Mocked:** the central platform is plain scripts; onboarding request
  bookkeeping and accepted registrations are local records (`requests/`,
  `registrations/`), not a database or service. The offline check backs S3
  with a fake `aws` CLI over a local directory; only the final end-to-end
  run exercises real AWS.
- **Hard-coded:** a single deployment region; the central account identifier
  supplied as a generator input; the next-stage role's identity (name
  `next-stage`, path `onboarding/`); the registration bucket name
  `onboarding-registration-<central-account-id>`. No configuration files or
  parameter systems.
- **Simplified:** exactly one registration mechanism — an API call: a
  presigned S3 PutObject URL per onboarding request (see "Decisions from the
  bootstrap-stack issue"); discovery covers the organization structure only;
  the next-stage role is a single placeholder for the permanent management
  roles.
- **Excluded:** onboarding portal or UI; Terraform import automation and the
  broader progressive-management lifecycle; networking discovery or
  redesign; account standardization; organization policy automation;
  resource migration; production hardening (retry frameworks, general error
  handling, CI, test suites) except where a failure scenario specifically
  needs it.

## How we will determine success

Judged in the final issue:

1. **Fresh run:** from no prior state, following only the experiment's own
   usage instructions, the full cycle completes and the central system learns
   the environment exists, obtains access, assumes the role, and produces a
   discovery report — with no manual copying of role ARNs, account
   identifiers, or metadata between systems.
   - **Outcome: not tested (real AWS) / met (offline full cycle).** The
     judgement run could not reach AWS: the workspace's only credentials are
     an expired SSO session and refreshing it needs an interactive browser
     login, so every AWS-facing usage step failed on credential expiry. The
     full cycle was instead run offline from no prior state — generate,
     deploy boundary (registration Lambda driven from the generated
     template), receive, assume, discover, next-stage role — on the same
     fake-aws tier as the phase tests. The only human inputs were the
     request identifier and the central account identifier, both documented
     generator arguments: the assumed ARN came from the registration record,
     the trust principal from the request record, and the report's
     organization identifier was read fresh through the assumed session. The
     live cross-account handoff remains unconfirmed.
2. **Permission traceability:** every permission on the bootstrap role is
   recorded with the step that uses it, and the end-to-end run confirms no
   permission went unused or missing.
   - **Outcome: met (offline) / not tested (real AWS).** All seven recorded
     bootstrap-role actions are used by exactly one step, and the offline run
     exercised every one through the assumed-role session: the fake aws CLI
     serves organizations and iam only to that session and fails on any
     subcommand outside the recorded set, so an unused or missing permission
     would have broken the run.
3. **Failure scenarios:** each scenario named in the VISION is exercised and
   its observed behaviour recorded; "required manual rework" is a legitimate
   finding, not a defect to hide.
   - **Outcome: met.** All six VISION scenarios are exercised by
     `test-failures.sh` (passes) and their observed behaviour plus the human
     recovery step are recorded in the README Notes. The one real-AWS
     sub-item — CloudFormation rollback on a FAILED registration signal —
     was not observed live (no credentials).
4. **Recorded verdict:** the README Notes state the answer to the key
   question — can an acquired AWS environment bootstrap its own transition
   into centralized management? — with the evidence and the list of what was
   mocked.
   - **Outcome: met.** The README Notes state the verdict, its evidence, and
     the mocked and hard-coded list (recorded in this issue).
5. **Standing cost:** the experiment leaves a bootstrap role in the acquired
   account and a registration endpoint in the central account. This plan
   records how to remove them; the exact steps are added once the follow-up
   issues fix the mechanisms, and the end-to-end run confirms them.
   - **Outcome: met (steps recorded) / not tested (removal run).** The
     removal steps are recorded below; running them against real AWS was not
     possible without credentials.

### Standing-cost removal

The run leaves three artifacts behind; each is removed with the credentials
that created it:

- Acquired account, deployment stack:
  `aws cloudformation delete-stack --stack-name onboarding-bootstrap`
  removes the bootstrap role, the registration Lambda, and the Lambda's
  execution role.
- Acquired account, next-stage placeholder created afterwards by the flow:
  `aws iam delete-role-policy --role-name next-stage --policy-name OrganizationDiscovery`
  then `aws iam delete-role --role-name next-stage`.
- Central account, registration endpoint:
  `aws s3 rb s3://onboarding-registration-<central-account-id> --force`
  removes the bucket and any delivered registrations.

Local state (`requests/`, `registrations/`, `discovery/`, `next-stage/`) is
plain files and is removed by deleting those directories.

## What is deprioritised

Robustness and retry behaviour (explored last, after the happy path);
everything in the exclusion list above; broad discovery beyond the
organization structure; and Terraform integration, which this proof of
concept only needs to leave a door open for.
