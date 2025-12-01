# cloudformation-payer-registry-for-onboarding

> [!WARNING]
> **AI-authored:** This change was autonomously planned and implemented by an AI software factory from a human-authored specification, with possible subsequent human review or modification.

Explores a self-registering onboarding flow: deploy a generated CloudFormation stack into an acquired AWS Organization's management account and the central platform learns the environment exists, assumes a bootstrap role, begins discovery, and creates the next-stage role without manually copying role ARNs or account identifiers.

Central side, once:

```sh
./create-registration-bucket.sh <central-account-id>
```

Central side, per onboarding request:

```sh
./generate-onboarding-stack.sh <request-id> <central-account-id> > template.json
```

## Notes

- Cross-account EventBridge, SQS, and SNS delivery all require the central resource's policy to name the sender account — the very identifier registration is meant to learn — so the API-call transport avoids the circularity (rationale in PLAN.md).
- Presigned URLs are capped at 7 days (SigV4), so a generated package has a shelf life; regenerating is one script run.
- Idea has merit
