#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# setup.sh — Scheduled DevOps Agent Evaluation Trigger
#
# Deploys a Lambda + EventBridge Scheduler that triggers a DevOps Agent
# EVALUATION backlog task on a daily schedule.
#
# Usage:
#   ./setup.sh                          # uses defaults (15:20 ET)
#   CRON="cron(0 9 * * ? *)" ./setup.sh # override schedule
#   SCHEDULE_TZ="UTC" ./setup.sh        # override timezone
#
# Prerequisites:
#   - AWS CLI v2.34+ (for devops-agent subcommand)
#   - IAM permissions: devops-agent:List*, lambda:Create/Update*,
#     iam:CreateRole/PutRolePolicy/AttachRolePolicy, scheduler:Create*
# ──────────────────────────────────────────────────────────────────────
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
SCHEDULE_NAME="${SCHEDULE_NAME:-devops-agent-daily-eval}"
SCHEDULE_TZ="${SCHEDULE_TZ:-US/Eastern}"
CRON="${CRON:-cron(20 15 * * ? *)}"
LAMBDA_NAME="${LAMBDA_NAME:-devops-agent-daily-eval}"
LAMBDA_ROLE_NAME="${LAMBDA_ROLE_NAME:-DevOpsAgentEvalLambdaRole}"
SCHEDULER_ROLE_NAME="${SCHEDULER_ROLE_NAME:-EvBridgeSchedulerDevOpsAgentRole}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── 0. Check CLI version ─────────────────────────────────────────────
CLI_VERSION=$(aws --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
REQUIRED="2.34.0"
if printf '%s\n' "$REQUIRED" "$CLI_VERSION" | sort -V | head -1 | grep -qv "$REQUIRED"; then
  echo "❌ AWS CLI $CLI_VERSION is too old. Requires >= $REQUIRED"
  echo "   Upgrade: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
  exit 1
fi
echo "✅ AWS CLI $CLI_VERSION"

# ── 1. Discover agent space & goal ───────────────────────────────────
echo "🔍 Looking up DevOps Agent space..."
SPACE_ID=$(aws devops-agent list-agent-spaces \
  --region "$REGION" \
  --query 'agentSpaces[0].agentSpaceId' \
  --output text)

if [[ -z "$SPACE_ID" || "$SPACE_ID" == "None" ]]; then
  echo "❌ No agent space found in $REGION"
  exit 1
fi
echo "   Space: $SPACE_ID"

echo "🎯 Looking up evaluation goal..."
GOAL_ID=$(aws devops-agent list-goals \
  --agent-space-id "$SPACE_ID" \
  --region "$REGION" \
  --query 'goals[0].goalId' \
  --output text)

if [[ -z "$GOAL_ID" || "$GOAL_ID" == "None" ]]; then
  echo "❌ No goals found — create one in the DevOps Agent console first"
  exit 1
fi
echo "   Goal: $GOAL_ID"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "   Account: $ACCOUNT_ID"

# ── 2. Lambda execution role ─────────────────────────────────────────
LAMBDA_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${LAMBDA_ROLE_NAME}"

if ! aws iam get-role --role-name "$LAMBDA_ROLE_NAME" &>/dev/null; then
  echo "🔧 Creating Lambda role: $LAMBDA_ROLE_NAME"

  aws iam create-role \
    --role-name "$LAMBDA_ROLE_NAME" \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [{
        "Effect": "Allow",
        "Principal": { "Service": "lambda.amazonaws.com" },
        "Action": "sts:AssumeRole"
      }]
    }' \
    --description "Lambda role for DevOps Agent scheduled evaluations" \
    --query 'Role.Arn' --output text

  aws iam attach-role-policy \
    --role-name "$LAMBDA_ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
else
  echo "   Lambda role already exists"
fi

# IAM action is aidevops:*, resource ARN uses aidevops and agentspace (no hyphen)
aws iam put-role-policy \
  --role-name "$LAMBDA_ROLE_NAME" \
  --policy-name "DevOpsAgentCreateBacklogTask" \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": \"aidevops:CreateBacklogTask\",
      \"Resource\": \"arn:aws:aidevops:${REGION}:${ACCOUNT_ID}:agentspace/${SPACE_ID}\"
    }]
  }"

echo "   Waiting 10s for IAM propagation..."
sleep 10

# ── 3. Lambda function ───────────────────────────────────────────────
echo "📦 Packaging Lambda..."
TMPDIR=$(mktemp -d)
cp "${SCRIPT_DIR}/lambda_function.py" "${TMPDIR}/"
(cd "${TMPDIR}" && zip -j function.zip lambda_function.py) >/dev/null

LAMBDA_ARN=""
if aws lambda get-function --function-name "$LAMBDA_NAME" --region "$REGION" &>/dev/null; then
  echo "   Lambda exists — updating code & config..."
  # Wait for any in-progress updates
  aws lambda wait function-updated --function-name "$LAMBDA_NAME" --region "$REGION" 2>/dev/null || true

  aws lambda update-function-configuration \
    --function-name "$LAMBDA_NAME" \
    --runtime "python3.13" \
    --handler "lambda_function.handler" \
    --timeout 30 \
    --environment "Variables={AGENT_SPACE_ID=${SPACE_ID},GOAL_ID=${GOAL_ID}}" \
    --region "$REGION" \
    --output text >/dev/null

  aws lambda wait function-updated --function-name "$LAMBDA_NAME" --region "$REGION" 2>/dev/null || true

  aws lambda update-function-code \
    --function-name "$LAMBDA_NAME" \
    --zip-file "fileb://${TMPDIR}/function.zip" \
    --region "$REGION" \
    --output text >/dev/null

  LAMBDA_ARN=$(aws lambda get-function --function-name "$LAMBDA_NAME" --region "$REGION" \
    --query 'Configuration.FunctionArn' --output text)
else
  echo "   Creating Lambda: $LAMBDA_NAME"
  LAMBDA_ARN=$(aws lambda create-function \
    --function-name "$LAMBDA_NAME" \
    --runtime "python3.13" \
    --handler "lambda_function.handler" \
    --role "$LAMBDA_ROLE_ARN" \
    --zip-file "fileb://${TMPDIR}/function.zip" \
    --timeout 30 \
    --environment "Variables={AGENT_SPACE_ID=${SPACE_ID},GOAL_ID=${GOAL_ID}}" \
    --region "$REGION" \
    --query 'FunctionArn' --output text)
fi
echo "   Lambda: $LAMBDA_ARN"
rm -rf "${TMPDIR}"

# ── 4. Scheduler execution role ──────────────────────────────────────
SCHEDULER_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${SCHEDULER_ROLE_NAME}"

if ! aws iam get-role --role-name "$SCHEDULER_ROLE_NAME" &>/dev/null; then
  echo "🔧 Creating Scheduler role: $SCHEDULER_ROLE_NAME"

  aws iam create-role \
    --role-name "$SCHEDULER_ROLE_NAME" \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [{
        "Effect": "Allow",
        "Principal": { "Service": "scheduler.amazonaws.com" },
        "Action": "sts:AssumeRole"
      }]
    }' \
    --description "Allows EventBridge Scheduler to invoke the eval Lambda" \
    --query 'Role.Arn' --output text
else
  echo "   Scheduler role already exists"
fi

aws iam put-role-policy \
  --role-name "$SCHEDULER_ROLE_NAME" \
  --policy-name "InvokeEvalLambda" \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": \"lambda:InvokeFunction\",
      \"Resource\": \"${LAMBDA_ARN}\"
    }]
  }"

sleep 5

# ── 5. EventBridge schedule ──────────────────────────────────────────
echo "📅 Creating schedule: $SCHEDULE_NAME ($CRON $SCHEDULE_TZ)"

TARGET_JSON="{\"Arn\": \"${LAMBDA_ARN}\", \"RoleArn\": \"${SCHEDULER_ROLE_ARN}\"}"

if aws scheduler get-schedule --name "$SCHEDULE_NAME" --region "$REGION" &>/dev/null; then
  echo "   Schedule exists — updating..."
  aws scheduler update-schedule \
    --name "$SCHEDULE_NAME" \
    --schedule-expression "$CRON" \
    --schedule-expression-timezone "$SCHEDULE_TZ" \
    --flexible-time-window '{"Mode":"OFF"}' \
    --target "$TARGET_JSON" \
    --region "$REGION" \
    --output text
else
  aws scheduler create-schedule \
    --name "$SCHEDULE_NAME" \
    --schedule-expression "$CRON" \
    --schedule-expression-timezone "$SCHEDULE_TZ" \
    --flexible-time-window '{"Mode":"OFF"}' \
    --target "$TARGET_JSON" \
    --region "$REGION" \
    --output text
fi

echo ""
echo "✅ Done!"
echo "   Schedule : $SCHEDULE_NAME — $CRON ($SCHEDULE_TZ)"
echo "   Lambda   : $LAMBDA_NAME"
echo "   Space    : $SPACE_ID"
echo "   Goal     : $GOAL_ID"
echo "   Console  : https://${REGION}.console.aws.amazon.com/scheduler/home?region=${REGION}#schedules/${SCHEDULE_NAME}"
