#!/usr/bin/env bash
set -euo pipefail

REGION="${AWS_REGION:-us-east-2}"
TAG="${OPENCHAT_IMAGE_TAG:-$(git rev-parse --short HEAD)}"
STACK_NAME="${OPENCHAT_STACK_NAME:-openchat-scalable}"
TEMPLATE_FILE="${OPENCHAT_TEMPLATE_FILE:-infra/aws/openchat-ecs-fargate.yaml}"
DESIRED_COUNT="${OPENCHAT_DESIRED_COUNT:-3}"
MIN_CAPACITY="${OPENCHAT_MIN_CAPACITY:-3}"
MAX_CAPACITY="${OPENCHAT_MAX_CAPACITY:-8}"
TASK_MEMORY="${OPENCHAT_TASK_MEMORY:-4096}"
WEBSOCKET_HEARTBEAT_MS="${OPENCHAT_WEBSOCKET_HEARTBEAT_MS:-0}"

STAGING_PROFILE="${OPENCHAT_STAGING_PROFILE:-tt-staging}"
PRODUCTION_PROFILE="${OPENCHAT_PRODUCTION_PROFILE:-awsproduction-ttfm}"

STAGING_ACCOUNT="036958288468"
PRODUCTION_ACCOUNT="829838608284"

STAGING_DOMAIN="openchat.staging.tt.fm"
PRODUCTION_DOMAIN="openchat.prod.tt.fm"

STAGING_EXTENSION_DOMAIN="staging.tt.fm"
PRODUCTION_EXTENSION_DOMAIN="prod.tt.fm"

STAGING_EXTENSION_CERTIFICATE_ARN="arn:aws:acm:us-east-2:036958288468:certificate/83aecf08-0c25-435a-b1e8-c95faf7fff36"
PRODUCTION_EXTENSION_CERTIFICATE_ARN="arn:aws:acm:us-east-2:829838608284:certificate/881eeab3-edcf-4ef8-9e93-939f9fce2451"

STAGING_ADMIN_API_KEY_PARAMETER_NAME="${OPENCHAT_STAGING_ADMIN_API_KEY_PARAMETER_NAME:-/openchat/staging/admin-api-key}"
PRODUCTION_ADMIN_API_KEY_PARAMETER_NAME="${OPENCHAT_PRODUCTION_ADMIN_API_KEY_PARAMETER_NAME:-/openchat/production/admin-api-key}"

STAGING_CORS_ALLOWED_ORIGINS="https://staging.hang.fm,https://staging.tt.live,https://staging.hangout.fm,https://openchat.staging.tt.fm,http://localhost:3000,http://localhost:4173,http://localhost:5173"
PRODUCTION_CORS_ALLOWED_ORIGINS="https://hang.fm,https://www.hang.fm,https://hangout.fm,https://www.hangout.fm,https://tt.live,https://www.tt.live,https://openchat.prod.tt.fm"

STAGING_HOSTED_ZONE_ID="Z012303725HTFF0I5JI42"
PRODUCTION_HOSTED_ZONE_ID="Z10095773LLWNGK1FKJ1Q"

STAGING_VPC_ID="vpc-79269412"
STAGING_SUBNET_1="subnet-a0c366cb"
STAGING_SUBNET_2="subnet-9d1f0ce7"

PRODUCTION_VPC_ID="vpc-9973f1f2"
PRODUCTION_SUBNET_1="subnet-570ca63c"
PRODUCTION_SUBNET_2="subnet-61bb581c"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_command aws
require_command docker
require_command git
require_command jq

if [ "${ALLOW_DIRTY:-false}" != "true" ] && [ -n "$(git status --porcelain)" ]; then
  echo "Refusing to deploy with a dirty worktree. Set ALLOW_DIRTY=true to override." >&2
  git status --short >&2
  exit 1
fi

check_account() {
  local profile="$1"
  local expected="$2"
  local actual

  actual="$(aws sts get-caller-identity --profile "$profile" --region "$REGION" --query Account --output text)"

  if [ "$actual" != "$expected" ]; then
    echo "Refusing to use profile $profile: expected account $expected, got $actual" >&2
    exit 1
  fi
}

ensure_ecr_repo() {
  local profile="$1"

  aws ecr describe-repositories \
    --profile "$profile" \
    --region "$REGION" \
    --repository-names openchat >/dev/null 2>&1 ||
    aws ecr create-repository \
      --profile "$profile" \
      --region "$REGION" \
      --repository-name openchat >/dev/null
}

ecr_auth() {
  local profile="$1"
  local password

  password="$(aws ecr get-login-password --profile "$profile" --region "$REGION")"
  printf 'AWS:%s' "$password" | base64 | tr -d '\n'
}

build_and_push() {
  local staging_registry="$STAGING_ACCOUNT.dkr.ecr.$REGION.amazonaws.com"
  local production_registry="$PRODUCTION_ACCOUNT.dkr.ecr.$REGION.amazonaws.com"
  local staging_auth production_auth auth_config

  ensure_ecr_repo "$STAGING_PROFILE"
  ensure_ecr_repo "$PRODUCTION_PROFILE"

  staging_auth="$(ecr_auth "$STAGING_PROFILE")"
  production_auth="$(ecr_auth "$PRODUCTION_PROFILE")"

  auth_config="$(jq -n \
    --arg sr "$staging_registry" --arg sa "$staging_auth" \
    --arg pr "$production_registry" --arg pa "$production_auth" \
    '{auths:{($sr):{auth:$sa},($pr):{auth:$pa}}}')"

  DOCKER_AUTH_CONFIG="$auth_config" docker buildx build --platform linux/arm64 \
    -t "$staging_registry/openchat:$TAG" \
    -t "$staging_registry/openchat:latest" \
    -t "$production_registry/openchat:$TAG" \
    -t "$production_registry/openchat:latest" \
    --push .
}

admin_key() {
  local env_name="$1"
  local profile="$2"
  local parameter_name="$3"
  local env_var="$4"
  local file_var="$5"
  local default_file="$6"

  if [ -n "${!env_var:-}" ]; then
    validate_admin_key "$env_name" "${!env_var}"
    printf '%s' "${!env_var}"
    return
  fi

  local key_file="${!file_var:-$default_file}"
  if [ -s "$key_file" ]; then
    local value
    value="$(cat "$key_file")"
    validate_admin_key "$env_name" "$value"
    printf '%s' "$value"
    return
  fi

  local ssm_value
  ssm_value="$(
    aws ssm get-parameter \
      --profile "$profile" \
      --region "$REGION" \
      --name "$parameter_name" \
      --with-decryption \
      --query 'Parameter.Value' \
      --output text 2>/dev/null || true
  )"

  if [ -n "$ssm_value" ] && [ "$ssm_value" != "None" ]; then
    validate_admin_key "$env_name" "$ssm_value"
    printf '%s' "$ssm_value"
    return
  fi

  echo "Missing $env_name admin API key. Set $env_var, $file_var, or SSM parameter $parameter_name." >&2
  exit 1
}

validate_admin_key() {
  local env_name="$1"
  local value="$2"

  if [ "$value" = "None" ] || [ "$value" = "null" ] || [ "${#value}" -lt 32 ]; then
    echo "Refusing weak $env_name admin API key. Generate a random key with at least 32 characters." >&2
    exit 1
  fi
}

store_admin_key_parameter() {
  local profile="$1"
  local env_name="$2"
  local parameter_name="$3"
  local value="$4"
  local input_file value_file

  if [ -z "$parameter_name" ]; then
    echo "Missing $env_name admin API key SSM parameter name." >&2
    exit 1
  fi

  input_file="$(mktemp)"
  value_file="$(mktemp)"
  chmod 600 "$input_file"
  chmod 600 "$value_file"
  printf '%s' "$value" >"$value_file"

  jq -n \
    --arg name "$parameter_name" \
    --rawfile value "$value_file" \
    '{Name: $name, Value: ($value | rtrimstr("\n")), Type: "SecureString", Overwrite: true}' >"$input_file"

  if aws ssm put-parameter \
    --profile "$profile" \
    --region "$REGION" \
    --cli-input-json "file://$input_file" >/dev/null; then
    rm -f "$input_file" "$value_file"
  else
    local status=$?
    rm -f "$input_file" "$value_file"
    exit "$status"
  fi
}

deploy_env() {
  local env_name="$1"
  local profile="$2"
  local account="$3"
  local domain="$4"
  local hosted_zone_id="$5"
  local vpc_id="$6"
  local subnet_1="$7"
  local subnet_2="$8"
  local admin_api_key_parameter_name="$9"
  local cors_allowed_origins="${10}"
  local extension_domain="${11}"
  local extension_certificate_arn="${12}"
  local image_uri="$account.dkr.ecr.$REGION.amazonaws.com/openchat:$TAG"

  aws cloudformation deploy \
    --profile "$profile" \
    --region "$REGION" \
    --stack-name "$STACK_NAME" \
    --template-file "$TEMPLATE_FILE" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides \
      EnvironmentName="$env_name" \
      DomainName="$domain" \
      HostedZoneId="$hosted_zone_id" \
      CorsAllowedOrigins="$cors_allowed_origins" \
      ExtensionDomain="$extension_domain" \
      VpcId="$vpc_id" \
      PublicSubnet1="$subnet_1" \
      PublicSubnet2="$subnet_2" \
      ImageUri="$image_uri" \
      AdminApiKeyParameterName="$admin_api_key_parameter_name" \
      DesiredCount="$DESIRED_COUNT" \
      MinCapacity="$MIN_CAPACITY" \
      MaxCapacity="$MAX_CAPACITY" \
      TaskMemory="$TASK_MEMORY" \
      WebsocketHeartbeatMs="$WEBSOCKET_HEARTBEAT_MS"

  ensure_extension_routing "$profile" "$env_name" "$hosted_zone_id" "$extension_domain" "$extension_certificate_arn"
}

ensure_extension_routing() {
  local profile="$1"
  local env_name="$2"
  local hosted_zone_id="$3"
  local extension_domain="$4"
  local extension_certificate_arn="$5"
  local lb_name="openchat-$env_name"
  local lb_dns lb_zone lb_arn listener_arn existing_certs change_batch

  lb_dns="$(aws elbv2 describe-load-balancers \
    --profile "$profile" \
    --region "$REGION" \
    --names "$lb_name" \
    --query 'LoadBalancers[0].DNSName' \
    --output text)"

  lb_zone="$(aws elbv2 describe-load-balancers \
    --profile "$profile" \
    --region "$REGION" \
    --names "$lb_name" \
    --query 'LoadBalancers[0].CanonicalHostedZoneId' \
    --output text)"

  lb_arn="$(aws elbv2 describe-load-balancers \
    --profile "$profile" \
    --region "$REGION" \
    --names "$lb_name" \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text)"

  listener_arn="$(aws elbv2 describe-listeners \
    --profile "$profile" \
    --region "$REGION" \
    --load-balancer-arn "$lb_arn" \
    --query 'Listeners[?Port==`443`].ListenerArn | [0]' \
    --output text)"

  existing_certs="$(aws elbv2 describe-listener-certificates \
    --profile "$profile" \
    --region "$REGION" \
    --listener-arn "$listener_arn" \
    --query 'Certificates[].CertificateArn' \
    --output text)"

  if ! grep -Fqx "$extension_certificate_arn" <<<"$(tr '\t' '\n' <<<"$existing_certs")"; then
    aws elbv2 add-listener-certificates \
      --profile "$profile" \
      --region "$REGION" \
      --listener-arn "$listener_arn" \
      --certificates CertificateArn="$extension_certificate_arn" >/dev/null
  fi

  change_batch="$(mktemp)"
  jq -n \
    --arg name "reactions-us.$extension_domain" \
    --arg dns "$lb_dns" \
    --arg zone "$lb_zone" \
    '{
      Changes: [{
        Action: "UPSERT",
        ResourceRecordSet: {
          Name: $name,
          Type: "A",
          AliasTarget: {
            HostedZoneId: $zone,
            DNSName: $dns,
            EvaluateTargetHealth: false
          }
        }
      }]
    }' >"$change_batch"

  aws route53 change-resource-record-sets \
    --profile "$profile" \
    --hosted-zone-id "$hosted_zone_id" \
    --change-batch "file://$change_batch" >/dev/null

  rm -f "$change_batch"
}

verify_env() {
  local profile="$1"
  local cluster="$2"
  local task_family="$3"
  local domain="$4"
  local account="$5"

  aws ecs describe-services \
    --profile "$profile" \
    --region "$REGION" \
    --cluster "$cluster" \
    --services openchat \
    --query 'services[0].[status,desiredCount,runningCount,pendingCount,deployments[0].rolloutState]' \
    --output text

  aws ecs describe-task-definition \
    --profile "$profile" \
    --region "$REGION" \
    --task-definition "$task_family" \
    --query 'taskDefinition.containerDefinitions[?name==`openchat`].image' \
    --output text | grep -F "$account.dkr.ecr.$REGION.amazonaws.com/openchat:$TAG" >/dev/null

  curl -fsS "https://$domain/v3.0/settings" |
    jq -e --arg domain "$domain" '.data.CHAT_HOST == $domain and .data.CHAT_WSS_PORT == "443"' >/dev/null
}

main() {
  check_account "$STAGING_PROFILE" "$STAGING_ACCOUNT"
  check_account "$PRODUCTION_PROFILE" "$PRODUCTION_ACCOUNT"

  echo "Building and pushing OpenChat image tag $TAG"
  build_and_push

  local staging_key production_key
  staging_key="$(admin_key staging "$STAGING_PROFILE" "$STAGING_ADMIN_API_KEY_PARAMETER_NAME" OPENCHAT_STAGING_ADMIN_API_KEY OPENCHAT_STAGING_ADMIN_API_KEY_FILE /tmp/openchat-staging-admin-key)"
  production_key="$(admin_key production "$PRODUCTION_PROFILE" "$PRODUCTION_ADMIN_API_KEY_PARAMETER_NAME" OPENCHAT_PRODUCTION_ADMIN_API_KEY OPENCHAT_PRODUCTION_ADMIN_API_KEY_FILE /tmp/openchat-prod-admin-key)"

  store_admin_key_parameter "$STAGING_PROFILE" staging "$STAGING_ADMIN_API_KEY_PARAMETER_NAME" "$staging_key"
  store_admin_key_parameter "$PRODUCTION_PROFILE" production "$PRODUCTION_ADMIN_API_KEY_PARAMETER_NAME" "$production_key"
  unset staging_key production_key

  echo "Deploying staging"
  deploy_env staging "$STAGING_PROFILE" "$STAGING_ACCOUNT" "$STAGING_DOMAIN" "$STAGING_HOSTED_ZONE_ID" \
    "$STAGING_VPC_ID" "$STAGING_SUBNET_1" "$STAGING_SUBNET_2" "$STAGING_ADMIN_API_KEY_PARAMETER_NAME" \
    "$STAGING_CORS_ALLOWED_ORIGINS" "$STAGING_EXTENSION_DOMAIN" "$STAGING_EXTENSION_CERTIFICATE_ARN"

  echo "Deploying production"
  deploy_env production "$PRODUCTION_PROFILE" "$PRODUCTION_ACCOUNT" "$PRODUCTION_DOMAIN" "$PRODUCTION_HOSTED_ZONE_ID" \
    "$PRODUCTION_VPC_ID" "$PRODUCTION_SUBNET_1" "$PRODUCTION_SUBNET_2" "$PRODUCTION_ADMIN_API_KEY_PARAMETER_NAME" \
    "$PRODUCTION_CORS_ALLOWED_ORIGINS" "$PRODUCTION_EXTENSION_DOMAIN" "$PRODUCTION_EXTENSION_CERTIFICATE_ARN"

  echo "Verifying staging"
  verify_env "$STAGING_PROFILE" openchat-staging openchat-staging "$STAGING_DOMAIN" "$STAGING_ACCOUNT"

  echo "Verifying production"
  verify_env "$PRODUCTION_PROFILE" openchat-production openchat-production "$PRODUCTION_DOMAIN" "$PRODUCTION_ACCOUNT"

  echo "OpenChat $TAG deployed to staging and production."
}

main "$@"
