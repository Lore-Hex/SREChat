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

  def render(source, payload), do: "🔔 [#{source}] #{inspect(payload) |> String.slice(0, @max_chars)}"

  # -- Sentry ---------------------------------------------------------------

  defp sentry?(%{"data" => %{"issue" => _}}), do: true
  defp sentry?(%{"culprit" => _}), do: true
  defp sentry?(%{"event" => %{"event_id" => _}}), do: true
  defp sentry?(_), do: false

  defp sentry(payload) do
    issue = get_in(payload, ["data", "issue"]) || payload
    event = payload["event"] || %{}

    title =
      issue["title"] || event["title"] || payload["message"] || issue["metadata"]["value"] ||
        "unknown issue"

    culprit = issue["culprit"] || event["culprit"] || payload["culprit"]
    level = issue["level"] || event["level"] || "error"
    count = issue["count"]
    url = payload["url"] || issue["web_url"] || issue["permalink"]

    [
      "#{level}: #{title}",
      culprit && "at #{culprit}",
      # Occurrence count separates "happened once" from "happening constantly",
      # which is the difference between reading it now and reading it later.
      count && "seen #{count}x",
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
