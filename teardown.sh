#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# teardown.sh — Remove all resources created by setup.sh
# ──────────────────────────────────────────────────────────────────────
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
SCHEDULE_NAME="${SCHEDULE_NAME:-devops-agent-daily-eval}"
LAMBDA_NAME="${LAMBDA_NAME:-devops-agent-daily-eval}"
LAMBDA_ROLE_NAME="${LAMBDA_ROLE_NAME:-DevOpsAgentEvalLambdaRole}"
SCHEDULER_ROLE_NAME="${SCHEDULER_ROLE_NAME:-EvBridgeSchedulerDevOpsAgentRole}"

echo "🗑  Removing EventBridge schedule: $SCHEDULE_NAME"
aws scheduler delete-schedule --name "$SCHEDULE_NAME" --region "$REGION" 2>/dev/null && echo "   Done" || echo "   Not found"

echo "🗑  Removing Lambda: $LAMBDA_NAME"
aws lambda delete-function --function-name "$LAMBDA_NAME" --region "$REGION" 2>/dev/null && echo "   Done" || echo "   Not found"

echo "🗑  Removing Lambda role: $LAMBDA_ROLE_NAME"
aws iam delete-role-policy --role-name "$LAMBDA_ROLE_NAME" --policy-name "DevOpsAgentCreateBacklogTask" 2>/dev/null || true
aws iam detach-role-policy --role-name "$LAMBDA_ROLE_NAME" --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" 2>/dev/null || true
aws iam delete-role --role-name "$LAMBDA_ROLE_NAME" 2>/dev/null && echo "   Done" || echo "   Not found"

echo "🗑  Removing Scheduler role: $SCHEDULER_ROLE_NAME"
aws iam delete-role-policy --role-name "$SCHEDULER_ROLE_NAME" --policy-name "InvokeEvalLambda" 2>/dev/null || true
aws iam delete-role --role-name "$SCHEDULER_ROLE_NAME" 2>/dev/null && echo "   Done" || echo "   Not found"

echo ""
echo "✅ Teardown complete"
