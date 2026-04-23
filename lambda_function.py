"""
Lambda function that triggers an AWS DevOps Agent EVALUATION backlog task.

Uses raw SigV4-signed HTTP requests because the Lambda runtime's
boto3/botocore doesn't include the devops-agent service model yet.

Environment variables:
  AGENT_SPACE_ID  — DevOps Agent space ID
  GOAL_ID         — Evaluation goal ID (from list-goals)
  AWS_REGION      — Region (set automatically by Lambda)
"""
import json
import os
import hashlib
import hmac
import uuid
import datetime
import urllib.request
import urllib.error

REGION = os.environ.get("AWS_REGION", "us-east-1")
SPACE_ID = os.environ["AGENT_SPACE_ID"]
GOAL_ID = os.environ["GOAL_ID"]
SERVICE = "aidevops"
HOST = f"dp.{SERVICE}.{REGION}.api.aws"
ENDPOINT = f"https://{HOST}"


def _sign(key, msg):
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()


def _get_signature_key(secret, date_stamp, region, service):
    k_date = _sign(("AWS4" + secret).encode("utf-8"), date_stamp)
    k_region = _sign(k_date, region)
    k_service = _sign(k_region, service)
    return _sign(k_service, "aws4_request")


def _make_signed_request(method, path, body_dict):
    access_key = os.environ["AWS_ACCESS_KEY_ID"]
    secret_key = os.environ["AWS_SECRET_ACCESS_KEY"]
    session_token = os.environ.get("AWS_SESSION_TOKEN", "")

    now = datetime.datetime.now(datetime.timezone.utc)
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    date_stamp = now.strftime("%Y%m%d")

    payload = json.dumps(body_dict)
    payload_hash = hashlib.sha256(payload.encode("utf-8")).hexdigest()

    headers_to_sign = {
        "content-type": "application/json",
        "host": HOST,
        "x-amz-date": amz_date,
    }
    if session_token:
        headers_to_sign["x-amz-security-token"] = session_token

    signed_header_keys = sorted(headers_to_sign.keys())
    signed_headers = ";".join(signed_header_keys)
    canonical_headers = "".join(
        f"{k}:{headers_to_sign[k]}\n" for k in signed_header_keys
    )

    canonical_request = "\n".join([
        method, path, "",
        canonical_headers, signed_headers, payload_hash,
    ])

    algorithm = "AWS4-HMAC-SHA256"
    credential_scope = f"{date_stamp}/{REGION}/{SERVICE}/aws4_request"
    string_to_sign = "\n".join([
        algorithm, amz_date, credential_scope,
        hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
    ])

    signing_key = _get_signature_key(secret_key, date_stamp, REGION, SERVICE)
    signature = hmac.new(
        signing_key, string_to_sign.encode("utf-8"), hashlib.sha256
    ).hexdigest()

    auth_header = (
        f"{algorithm} Credential={access_key}/{credential_scope}, "
        f"SignedHeaders={signed_headers}, Signature={signature}"
    )

    request_headers = {
        "Content-Type": "application/json",
        "X-Amz-Date": amz_date,
        "Authorization": auth_header,
    }
    if session_token:
        request_headers["X-Amz-Security-Token"] = session_token

    url = f"{ENDPOINT}{path}"
    req = urllib.request.Request(
        url, data=payload.encode("utf-8"), headers=request_headers, method=method
    )

    try:
        with urllib.request.urlopen(req, timeout=25) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8")
        print(f"HTTP {e.code}: {body}")
        return e.code, {"error": body}


def handler(event, context):
    today = datetime.date.today().isoformat()
    path = f"/backlog/agent-space/{SPACE_ID}/tasks"

    body = {
        "taskType": "EVALUATION",
        "title": f"Daily anomaly evaluation — {today}",
        "description": json.dumps({"goal_id": GOAL_ID}),
        "priority": "MEDIUM",
        "clientToken": str(uuid.uuid4()),
    }

    status, result = _make_signed_request("POST", path, body)
    print(f"Status: {status}, Result: {json.dumps(result)}")

    if status == 409:
        print("Evaluation already in progress — skipping")
        return {"statusCode": 200, "message": "evaluation already running"}

    return {"statusCode": status, "taskId": result.get("task", {}).get("taskId")}
