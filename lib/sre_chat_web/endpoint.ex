defmodule SREChatWeb.Endpoint do
  @moduledoc false
  use Plug.Router
  alias SREChatWeb.{Auth, JSON}

  @parser_opts_key {__MODULE__, :parser_opts}

  plug(:cors)
  plug(:security_headers)
  plug(:log_request_path)
  plug(:collapse_duplicate_version)
  plug(:instrument_request)
  plug(:parse_body)

  plug(:match)
  plug(:dispatch)

  # The CometChat iOS SDK is inconsistent about the API-version prefix: it uses
  # the configured host verbatim for the login/`/me` call but ALSO prepends
  # `chatAPIVersion` for message calls. With a host that already carries the
  # version, message fetches arrive as `/v3.0/v3.0/users/.../messages` and match
  # nothing, so fetch returns 404 and the SDK's callback hangs. Rather than force
  # every client to a bare host — which breaks the calls that expect the version
  # baked in — collapse a doubled leading version segment here, so both shapes
  # resolve to the same route. Idempotent for every well-formed single-version
  # path.
  # Method and path only, never headers: the CometChat SDK sends its credential
  # in an `authtoken` header, and that token's claims embed the access
  # passcode, so a header-logging diagnostic writes the passcode to disk.
  # Gated by SRE_LOG_PATHS=1 and off by default.
  defp log_request_path(conn, _opts) do
    if System.get_env("SRE_LOG_PATHS") == "1" do
      require Logger
      Logger.info("REQ #{conn.method} /#{Enum.join(conn.path_info, "/")}")
    end

    conn
  end

  @disk_alert_percent 90

  @doc false
  # Everything this region needs in order to serve, checked directly. Returns
  # the problems rather than a boolean so the response can name what is wrong —
  # "degraded" with no detail sends an operator to read logs on three machines.
  # SERVING problems only — the things that stop this region answering
  # correctly. Replication is deliberately NOT here; see health_warnings/0.
  def health_problems do
    Enum.filter([redis_problem(), disk_problem()], &is_binary/1)
  end

  @doc false
  # Real, worth alerting on, and NOT a reason to fail health.
  #
  # SREChat is partition-tolerant on purpose: during a partition every region
  # keeps accepting reads and writes, and converges on heal. A region that
  # cannot reach a peer is therefore still serving correctly — failing health
  # would pull it out of its load balancer and turn a replication problem into
  # an availability one, which is the opposite of what the architecture exists
  # to provide.
  #
  # Deploying this as a hard failure took a healthy AWS region out of rotation
  # within seconds, which is how the distinction got drawn.
  def health_warnings do
    Enum.filter([replication_problem()], &is_binary/1)
  end

  defp redis_problem do
    # A region whose Redis is gone cannot commit a single write, and this is
    # exactly the case that answered 200 while a drill held redis stopped.
    #
    # "Never configured" and "configured but dead" must not look alike. A
    # deployment with no redis_url genuinely does not use Redis (dev, tests) and
    # is not degraded; a deployment that HAS one and cannot reach it is an
    # outage. Treating them the same either cries wolf in development or, far
    # worse, reports a dead connection as fine in production.
    cond do
      is_nil(SREChat.Config.redis_url()) or SREChat.Config.redis_url() == "" ->
        nil

      true ->
        case SREChat.Store.RedisPersistence.ping() do
          :ok -> nil
          {:error, reason} -> "redis unreachable (#{inspect(reason)})"
        end
    end
  rescue
    error -> "redis check failed (#{inspect(error)})"
  catch
    :exit, reason -> "redis check exited (#{inspect(reason)})"
  end

  defp replication_problem do
    # A tailer in :degraded has REFUSED to continue — usually a cursor past the
    # peer's trim horizon. It backs off and logs, and nothing else notices;
    # AWS and Azure sat broken in both directions for hours that way.
    degraded =
      for peer <- SREChat.Config.peer_regions(),
          status = SREChat.Replication.Tailer.status(peer.index),
          status[:mode] == :degraded or status[:state] == :down,
          do: "region #{peer.index} (#{status[:last_error] || status[:state]})"

    case degraded do
      [] -> nil
      peers -> "replication not running from " <> Enum.join(peers, ", ")
    end
  rescue
    error -> "replication check failed (#{inspect(error)})"
  end

  defp disk_problem do
    # A full disk stops writes without stopping the process, so nothing else
    # here would notice until a commit fails.
    case System.cmd("df", ["--output=pcent", "/"], stderr_to_stdout: true) do
      {output, 0} ->
        used =
          output
          |> String.split("\n", trim: true)
          |> List.last()
          |> to_string()
          |> String.replace(~r/[^0-9]/, "")
          |> Integer.parse()

        case used do
          {percent, _} when percent >= @disk_alert_percent -> "disk #{percent}% full"
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp collapse_duplicate_version(conn, _opts) do
    case conn.path_info do
      [v, v | rest] when v in ["v3.0", "v3"] ->
        %{conn | path_info: [v | rest]}

      _ ->
        conn
    end
  end

  # Liveness AND readiness. This used to be `send_resp(conn, 200, "ok")` — a
  # literal that checked nothing, which is how a series of real outages stayed
  # invisible: redis stopped, the disk filled to 93%, and replication from a
  # peer sat degraded for hours, and every one of them answered 200.
  #
  # A health check that does not exercise what the region needs in order to
  # serve is not a health check; it only proves the HTTP listener is accepting
  # sockets. So this now touches the things a region actually cannot work
  # without, and says which one is wrong.
  #
  # Kept cheap on purpose — a PING and in-memory state, no writes — because
  # every load balancer in three clouds calls it constantly.
  get "/health" do
    case {health_problems(), health_warnings()} do
      {[], []} ->
        send_resp(conn, 200, "ok")

      {[], warnings} ->
        # Still serving, and something is wrong that a human should chase. 200
        # keeps it in rotation; the body is what the agent and an operator read.
        send_resp(conn, 200, "ok (warning: " <> Enum.join(warnings, "; ") <> ")")

      {problems, warnings} ->
        # 503, not 500: this region is unable to serve, which is a different
        # thing from having crashed, and load balancers treat them differently.
        send_resp(
          conn,
          503,
          "degraded: " <> Enum.join(problems ++ warnings, "; ")
        )
    end
  end

  # Voice call instructions, fetched by Telnyx TeXML when a call connects.
  #
  # Deliberately public and unauthenticated: the carrier fetches it from its own
  # infrastructure with no credential of ours, so there is nothing to
  # authenticate with. It is safe because it is a pure function of the query
  # string — it reads no state and reveals nothing — and the only thing an
  # attacker gains by calling it is a sentence of their own text read back.
  #
  # XML metacharacters are stripped rather than escaped: a malformed document
  # is a call that connects and says nothing, which is indistinguishable from a
  # page that never arrived.
  get "/texml" do
    params = conn.query_params
    # `text` is what we send; `msg` is what an older deployed agent sends. A
    # caller using the wrong name would otherwise get a call that connects and
    # reads the generic line, which looks like success and carries no incident.
    text =
      (Map.get(params, "text") || Map.get(params, "msg") || "")
      |> to_string()
      |> String.slice(0, 400)
      |> String.replace(~r/[<>&]/, " ")

    # Same brand the SMS path uses: an unrecognized number reading an
    # unattributed sentence at 3am gets hung up on.
    stripped = String.replace(text, ~r/^\s*trusted router:?\s*/i, "")

    spoken =
      if stripped == "",
        do: "Trusted Router notification.",
        else: "Trusted Router notification. #{stripped}"

    conn
    |> Plug.Conn.put_resp_content_type("application/xml")
    |> send_resp(
      200,
      # Said twice: a ringing phone is answered mid-sentence, so the first pass
      # is usually half heard.
      ~s(<?xml version="1.0" encoding="UTF-8"?><Response><Say voice="alice">) <>
        spoken <> ". Again. " <> spoken <> "</Say></Response>"
    )
  end

  # Anything with a webhook can put a line in the chat: Sentry, GCP alerting,
  # Stripe, CI, SES inbound mail forwarded from help@. One endpoint turns all of
  # those from code into configuration.
  #
  #   POST /hooks/<source>?token=<secret>
  #
  # UNTRUSTED INPUT. A Sentry issue title is attacker-influenced — anyone who
  # can cause an exception picks most of the text — so it is rendered as data
  # here and never parsed for meaning.
  #
  # It is delivered to TWO recipients, and the split is the design:
  #
  #   * the owner, so an error is visible in chat even when the agent is dead —
  #     the moment you most want to see it;
  #   * this region's agent, so something triages it in seconds instead of
  #     whenever a human next opens the app.
  #
  # Reaching the agent means untrusted text reaches a tool-calling loop, so the
  # containment is on that side and it is structural, not a prompt request: a
  # signal-triggered investigation is handed the READ-ONLY tool table, so no
  # schema for shell/restart/rollback is ever sent to the model and a name it
  # invents resolves to nothing. An error whose message says to run a command
  # gets logs read and the owner told; acting still requires either the owner's
  # word or a condition the agent measured itself.
  #
  # The token is a shared secret in the query string rather than a header
  # because several senders (Sentry's legacy webhook among them) cannot set
  # headers. That makes the URL itself the credential: it will appear in the
  # sender's config and in our access logs, so it is a low-value secret whose
  # only power is posting a chat message, and it is rotatable by changing one
  # env var.
  post "/hooks/:source" do
    secret = SREChat.Config.webhook_secret()
    given = conn.query_params["token"] || ""

    cond do
      is_nil(secret) or secret == "" ->
        # Refuse rather than accept anything when unconfigured. An open
        # endpoint that posts to your pager is worse than a broken one.
        send_resp(conn, 503, "webhooks not configured")

      not Plug.Crypto.secure_compare(given, secret) ->
        send_resp(conn, 403, "bad token")

      true ->
        text = SREChatWeb.Webhook.render(source, conn.body_params)

        results =
          Enum.map(
            [SREChat.Config.owner_uid(), SREChat.Config.agent_uid()],
            &{&1, post_signal(&1, text)}
          )

        case Enum.filter(results, fn {_to, result} -> match?({:error, _}, result) end) do
          [] ->
            send_resp(conn, 200, "ok")

          failures ->
            require Logger

            for {to, {:error, reason}} <- failures do
              Logger.error("webhook #{source} could not post to #{to}: #{inspect(reason)}")
            end

            # 500 on ANY failed recipient so the sender retries: Sentry and GCP
            # both back off and retry, and a dropped alert is the failure this
            # endpoint exists to prevent. Retrying may duplicate the delivery
            # that did succeed, which is the right way round — a line you read
            # twice beats an outage nobody was told about.
            send_resp(conn, 500, "could not post")
        end
    end
  end

  defp post_signal(receiver, text) do
    SREChat.Store.send_message(
      "webhook",
      %{
        "receiver" => receiver,
        "receiverType" => "user",
        "type" => "text",
        "category" => "message",
        "data" => %{"text" => text}
      },
      [],
      admin?: true
    )
  end

  get "/v3/observability" do
    observability(conn)
  end

  get "/v3.0/observability" do
    observability(conn)
  end

  defp cors(conn, _opts) do
    origin = conn |> Plug.Conn.get_req_header("origin") |> List.first()

    conn
    |> put_allow_origin(SREChat.Config.cors_allowed_origin(origin))
    |> Plug.Conn.put_resp_header(
      "access-control-allow-methods",
      "GET,POST,PUT,PATCH,DELETE,OPTIONS"
    )
    |> Plug.Conn.put_resp_header(
      "access-control-allow-headers",
      "Authorization,Content-Type,Accept,appId,apiKey,authToken,resource,sdk,chatApiVersion,settingsHash,settingsHashReceivedAt"
    )
    |> Plug.Conn.put_resp_header("access-control-expose-headers", "*")
  end

  defp put_allow_origin(conn, nil), do: conn

  defp put_allow_origin(conn, origin) do
    Plug.Conn.put_resp_header(conn, "access-control-allow-origin", origin)
  end

  defp security_headers(conn, _opts) do
    conn
    |> Plug.Conn.put_resp_header("x-content-type-options", "nosniff")
    |> Plug.Conn.put_resp_header("x-frame-options", "DENY")
    |> Plug.Conn.put_resp_header("referrer-policy", "no-referrer")
    |> Plug.Conn.put_resp_header("vary", "origin")
  end

  defp parse_body(conn, _opts) do
    Plug.Parsers.call(conn, parser_opts())
  end

  defp instrument_request(conn, _opts) do
    start = System.monotonic_time()

    Plug.Conn.register_before_send(conn, fn conn ->
      duration_ms = SREChat.Observability.duration_ms(start)
      SREChat.Observability.record_http(conn.method, conn.request_path, conn.status, duration_ms)

      if conn.status >= 500 or duration_ms >= 1_000 do
        require Logger

        Logger.warning(
          "HTTP #{conn.method} #{sanitize_request_path(conn.request_path)} status=#{conn.status} duration_ms=#{duration_ms}"
        )
      end

      conn
    end)
  end

  defp parser_opts do
    case :persistent_term.get(@parser_opts_key, nil) do
      nil ->
        opts =
          Plug.Parsers.init(
            parsers: [:urlencoded, :multipart, :json],
            pass: ["*/*"],
            json_decoder: Jason,
            length: SREChat.Config.request_body_limit()
          )

        :persistent_term.put(@parser_opts_key, opts)
        opts

      opts ->
        opts
    end
  end

  options _ do
    send_resp(conn, 204, "")
  end

  forward("/v3", to: SREChatWeb.ApiRouter)
  forward("/v3.0", to: SREChatWeb.ApiRouter)
  forward("/", to: SREChatWeb.ApiRouter)

  defp observability(conn) do
    if Auth.admin?(conn) do
      JSON.raw(conn, SREChat.Observability.snapshot())
    else
      JSON.error(conn, SREChat.Errors.forbidden("Invalid apiKey."), 403)
    end
  end

  defp sanitize_request_path(path) do
    path
    |> to_string()
    |> String.split("/", trim: true)
    |> Enum.map(fn segment ->
      if String.length(segment) > 24 or String.match?(segment, ~r/^\d+$/),
        do: ":id",
        else: segment
    end)
    |> then(&("/" <> Enum.join(&1, "/")))
  end
end
