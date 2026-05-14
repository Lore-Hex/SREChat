# AWS deployment notes

## Recommended production topology

- ECS Fargate service running the Docker image in this repo.
- Application Load Balancer with HTTPS listener on 443.
- ALB target group forwards to container port `4000`.
- WebSocket upgrade support is automatic through ALB HTTP/1.1 targets.
- Route 53 DNS:
  - `chat.example.com` -> ALB
  - Optional wildcard `*.chat.example.com` -> ALB for `CometChat.callExtension("reactions", ...)`.
- ACM certificate:
  - `chat.example.com`
  - Optional `*.chat.example.com`
- ElastiCache Redis for chat state.
- Private S3 bucket for uploaded media. OpenChat returns presigned S3 URLs in message payloads and keeps `/media/...` as a service-side fallback proxy, so the bucket does not need public access.

## Environment

```text
PORT=4000
PUBLIC_HOST=chat.example.com
PUBLIC_WS_PORT=443
COMETCHAT_APP_ID=<your app id>
COMETCHAT_API_KEY=<admin key for server-side token minting>
COMETCHAT_REGION=us
EXTENSION_DOMAIN=chat.example.com
REDIS_URL=redis://<elasticache-primary-endpoint>:6379/0
REDIS_KEY_PREFIX=open_chat
MEDIA_STORAGE=s3
S3_BUCKET=<private-upload-bucket>
S3_REGION=<aws-region>
S3_PRESIGNED_URL_TTL_SECONDS=3600
UPLOAD_DIR=/app/priv/static/uploads
PUBLIC_MEDIA_BASE_URL=https://chat.example.com
```

Uploaded media expires through the S3 lifecycle policy configured in the CloudFormation stack. The default retention is 30 days.

## Health checks

Use `GET /v3.0/settings` as a simple health check. It does not require auth.

## Security hardening checklist

- Set a non-empty `COMETCHAT_API_KEY` and keep it only in AWS secrets/config. Admin routes reject missing/invalid API keys unless this variable is intentionally set blank.
- Replace `uid:<uid>` development tokens with server-minted auth tokens or signed JWT verification.
- Put AWS WAF/rate limiting in front of public endpoints.
- Keep S3 media buckets private unless a dedicated CDN path is added intentionally.
- Move from GenServer-mediated writes to operation-specific Redis commands or Postgres if high concurrency or multi-region operation is needed.
