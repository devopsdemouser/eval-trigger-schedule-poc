# Scheduled DevOps Agent Evaluation Trigger (POC)

Triggers AWS DevOps Agent proactive evaluations on a daily schedule using EventBridge Scheduler + Lambda.

## Why

DevOps Agent runs proactive evaluations weekly by default. This POC lets you run them more frequently — daily or on any custom cron schedule — by creating EVALUATION backlog tasks via the DevOps Agent API.

## Architecture

```
EventBridge Scheduler  ──cron──▶  Lambda  ──SigV4 HTTP──▶  DevOps Agent API
                                                            (CreateBacklogTask)
```

The Lambda uses raw SigV4-signed HTTP requests because the Lambda runtime's boto3 doesn't include the `devops-agent` service model yet. No external dependencies required.

## Prerequisites

- AWS CLI v2.34+
- An existing DevOps Agent space with at least one evaluation goal
- IAM permissions to create Lambda functions, IAM roles, and EventBridge schedules

## Quick Start

```sh
chmod +x setup.sh teardown.sh

# Deploy with defaults (daily at 3:20 PM Eastern)
./setup.sh

# Or customize the schedule
CRON="cron(0 9 * * ? *)" SCHEDULE_TZ="UTC" ./setup.sh

# Use a specific AWS profile
AWS_PROFILE=my-profile ./setup.sh
```

The script auto-discovers your agent space ID and goal ID.

## Verify

After setup, test the Lambda manually:

```sh
aws lambda invoke --function-name devops-agent-daily-eval --region us-east-1 /tmp/eval-test.json
cat /tmp/eval-test.json
```

Expected output:
```json
{"statusCode": 201, "taskId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"}
```

A `201` means the evaluation task was created. You can also check the DevOps Agent console — a new EVALUATION task should appear under the backlog. A `409` means an evaluation is already running (normal).

## Configuration

All settings can be overridden via environment variables:

| Variable | Default | Description |
|---|---|---|
| `AWS_REGION` | `us-east-1` | AWS region |
| `CRON` | `cron(20 15 * * ? *)` | EventBridge cron expression |
| `SCHEDULE_TZ` | `US/Eastern` | Timezone for the cron |
| `SCHEDULE_NAME` | `devops-agent-daily-eval` | EventBridge schedule name |
| `LAMBDA_NAME` | `devops-agent-daily-eval` | Lambda function name |
| `LAMBDA_ROLE_NAME` | `DevOpsAgentEvalLambdaRole` | Lambda execution role |
| `SCHEDULER_ROLE_NAME` | `EvBridgeSchedulerDevOpsAgentRole` | Scheduler role |

## What Gets Created

| Resource | Name | Purpose |
|---|---|---|
| Lambda function | `devops-agent-daily-eval` | Calls CreateBacklogTask API |
| IAM role | `DevOpsAgentEvalLambdaRole` | Lambda execution role with `aidevops:CreateBacklogTask` |
| IAM role | `EvBridgeSchedulerDevOpsAgentRole` | Scheduler role with `lambda:InvokeFunction` |
| EventBridge schedule | `devops-agent-daily-eval` | Daily cron trigger |

## Implementation Notes

- The DevOps Agent IAM namespace is `aidevops` (not `devops-agent`)
- Resource ARNs use `arn:aws:aidevops:<region>:<account>:agentspace/<id>` (no hyphen in `agentspace`)
- EVALUATION tasks require `description` to be JSON containing a valid `goal_id`
- Duplicate evaluations return 409 (handled gracefully — the Lambda logs it and returns 200)

## Cleanup

```sh
./teardown.sh
```

## Files

| File | Purpose |
|---|---|
| `lambda_function.py` | Lambda handler — SigV4-signed CreateBacklogTask call |
| `setup.sh` | Deploys Lambda + IAM roles + EventBridge schedule |
| `teardown.sh` | Removes all created resources |
