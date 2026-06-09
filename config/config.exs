import Config

default_api_key = if config_env() == :prod, do: "", else: "local-api-key"
default_local_jwt_secret = if config_env() == :prod, do: "", else: "local-jwt-secret"
default_cors_allowed_origins = if config_env() == :prod, do: "", else: "*"
default_reject_weak_admin_api_key = config_env() == :prod
default_request_body_limit = 10_000_000
default_upload_max_bytes = 10_000_000
default_group_max_members = 1_000
default_group_max_messages = 1_000
default_group_message_retention_days = 30
default_group_unread_fanout_limit = 1_000
default_group_presence_ttl_seconds = 1_800
default_group_max_presence = 5_000
default_media_storage = if config_env() == :prod, do: "s3", else: "local"
default_upload_dir = if config_env() == :prod, do: nil, else: "priv/static/uploads"

default_upload_allowed_mime_types =
  "image/jpeg,image/png,image/gif,image/webp,video/mp4,video/webm,audio/mpeg,audio/mp4,audio/ogg,audio/webm,application/pdf,text/plain"

config :logger, :default_formatter, format: "[$level] $message\n"

config :open_chat,
  port: 4000,
  host: "localhost",
  ws_port: "4000",
  app_id: "local-app",
  api_key: default_api_key,
  reject_weak_admin_api_key: default_reject_weak_admin_api_key,
  local_jwt_secret: default_local_jwt_secret,
  region: "us",
  cors_allowed_origins: default_cors_allowed_origins,
  extension_domain: "localhost",
  upload_dir: default_upload_dir,
  request_body_limit: default_request_body_limit,
  upload_max_bytes: default_upload_max_bytes,
  upload_allowed_mime_types: default_upload_allowed_mime_types,
  group_max_members: default_group_max_members,
  group_max_messages: default_group_max_messages,
  group_message_retention_days: default_group_message_retention_days,
  group_unread_fanout_limit: default_group_unread_fanout_limit,
  group_presence_ttl_seconds: default_group_presence_ttl_seconds,
  group_max_presence: default_group_max_presence,
  dm_history_connect_grace_ms: 0,
  public_group_reads_enabled: true,
  public_group_joins_as_visits: false,
  allow_local_media_storage: config_env() != :prod,
  media_storage: default_media_storage,
  public_media_base_url: nil,
  s3_presigned_url_ttl_seconds: 3600,
  redis_url: nil,
  redis_key_prefix: "open_chat",
  redis_snapshot_key: "open_chat:snapshot:v1",
  redis_boot_mode: "full",
  seed_users_json: nil,
  seed_groups_json: nil,
  accept_uid_tokens: config_env() == :test
