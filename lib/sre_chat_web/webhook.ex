defmodule SREChatWeb.Webhook do
  @moduledoc """
  Turn a webhook payload into one readable chat line.

  Every sender has its own JSON shape and none of them are worth a parser each.
  The rule here is: pull out the few fields a human needs at a glance, and fall
  back to compact JSON rather than dropping anything — a line you cannot read is
  still better than an alert you never saw.

  Payloads are UNTRUSTED. A Sentry issue title is chosen by whoever caused the
  exception, so the text is escaped of nothing and interpreted as nothing; it is
  rendered as data, posted to chat, and never fed to a tool-calling path.
  """

  @max_chars 1200

  @doc "One chat line for `source` and `payload`."
  def render(source, payload) when is_map(payload) do
    label = source |> to_string() |> String.slice(0, 40)

    body =
      cond do
        sentry?(payload) -> sentry(payload)
        gcp_alert?(payload) -> gcp_alert(payload)
        true -> generic(payload)
      end

    "🔔 [#{label}] #{body}" |> String.slice(0, @max_chars)
  end

  def render(source, payload),
    do: "🔔 [#{source}] #{inspect(payload) |> String.slice(0, @max_chars)}"

  # -- Sentry ---------------------------------------------------------------

  # Sentry has more than one webhook shape and we receive at least two:
  #
  #   * issue webhooks put the payload under data.issue
  #   * an ALERT RULE action puts it under data.event, with the rule's name
  #     alongside it
  #
  # The alert-rule shape is the one wired in production, because subscribing to
  # every issue in every project posts noise while an alert rule posts what
  # somebody already decided was worth being told about.
  defp sentry?(%{"data" => %{"issue" => _}}), do: true
  defp sentry?(%{"data" => %{"event" => _}}), do: true
  defp sentry?(%{"culprit" => _}), do: true
  defp sentry?(%{"event" => %{"event_id" => _}}), do: true
  defp sentry?(_), do: false

  defp sentry(payload) do
    data = payload["data"] || %{}
    issue = data["issue"] || payload
    event = data["event"] || payload["event"] || %{}

    title =
      issue["title"] || event["title"] || payload["message"] || issue["metadata"]["value"] ||
        event["metadata"]["value"] || "unknown issue"

    culprit = issue["culprit"] || event["culprit"] || payload["culprit"]
    level = issue["level"] || event["level"] || "error"
    count = issue["count"]
    # web_url points at the event or issue page a human can open; issue_url is
    # the REST resource, which is useless to click, so it is never a fallback.
    url = payload["url"] || issue["web_url"] || issue["permalink"] || event["web_url"]

    [
      "#{level}: #{title}",
      culprit && "at #{culprit}",
      # Occurrence count separates "happened once" from "happening constantly",
      # which is the difference between reading it now and reading it later.
      count && "seen #{count}x",
      # Which rule fired. Two alerts on one service are usually two different
      # questions, and the rule name is the cheapest way to tell them apart.
      data["triggered_rule"] && "[rule: #{data["triggered_rule"]}]",
      # The link last and on its own, so a mail or chat client does not swallow
      # trailing punctuation into the href.
      url && "\n#{url}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join(" ")
  end

  # -- GCP / Cloud Monitoring ----------------------------------------------

  defp gcp_alert?(%{"incident" => _}), do: true
  defp gcp_alert?(_), do: false

  defp gcp_alert(%{"incident" => incident}) do
    state = incident["state"] || "unknown"
    policy = incident["policy_name"] || "unnamed policy"
    summary = incident["summary"] || incident["condition_name"] || ""
    url = incident["url"]

    ["#{state}: #{policy}", summary != "" && "— #{summary}", url && "\n#{url}"]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join(" ")
  end

  # -- anything else --------------------------------------------------------

  defp generic(payload) do
    # Prefer the fields senders conventionally use, then fall back to the whole
    # thing. Dropping an unrecognised payload would make the endpoint silently
    # useless for exactly the sender nobody wrote a branch for.
    text =
      payload["text"] || payload["message"] || payload["summary"] || payload["subject"] ||
        payload["title"]

    case text do
      nil -> Jason.encode!(payload) |> String.slice(0, @max_chars)
      value -> to_string(value)
    end
  rescue
    _ -> inspect(payload) |> String.slice(0, @max_chars)
  end
end
