defmodule SREChat.Store.AuthTokens do
  @moduledoc false

  alias SREChat.{Config, Time}

  @sdk_jwt_advisory_ttl_seconds 24 * 60 * 60

  def local_jwt(uid, auth_token, now \\ Time.now()) do
    payload =
      %{
        "uid" => to_s(uid),
        "token" => to_s(auth_token),
        "iat" => now,
        "exp" => now + @sdk_jwt_advisory_ttl_seconds
      }
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    "local." <> payload <> "." <> signature(payload)
  end

  def lookup_tokens(token) do
    token = to_s(token)

    token
    |> local_jwt_token()
    |> case do
      {:ok, auth_token} -> [auth_token]
      :error -> opaque_token_candidates(token)
    end
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  def local_jwt_token(token) do
    with ["local", payload, token_signature] <- String.split(to_s(token), ".", parts: 3),
         true <- valid_signature?(payload, token_signature),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"token" => auth_token} = payload_map} <- Jason.decode(json),
         true <- valid_expiry_claim?(payload_map),
         auth_token <- to_s(auth_token),
         false <- blank?(auth_token) do
      {:ok, auth_token}
    else
      _ -> :error
    end
  end

  # A uid token is "uid:<name>" optionally suffixed with "|<passcode>". When an
  # access passcode is configured (SRE_ACCESS_SECRET), the suffix must match, so
  # only someone holding the passcode can sign in as anyone — the deployment is
  # no longer open to whoever guesses a name. With no passcode set the suffix is
  # ignored, preserving the open dev/test behaviour and letting clients start
  # sending "|<passcode>" before the gate is switched on (no lockout window).
  def uid_token("uid:" <> rest) when rest != "" do
    {uid, provided} =
      case String.split(rest, "|", parts: 2) do
        [uid, secret] -> {uid, secret}
        [uid] -> {uid, nil}
      end

    cond do
      uid == "" -> :error
      is_nil(access_secret()) -> {:ok, uid}
      is_binary(provided) and secure_compare(provided, access_secret()) -> {:ok, uid}
      true -> :error
    end
  end

  def uid_token(_token), do: :error

  defp access_secret do
    case Config.access_secret() do
      secret when is_binary(secret) and secret != "" -> secret
      _ -> nil
    end
  end

  defp opaque_token_candidates("local." <> _invalid_jwt), do: []
  defp opaque_token_candidates(token), do: [token]

  defp valid_signature?(payload, token_signature) do
    secure_compare(to_s(token_signature), signature(payload))
  end

  defp signature(payload) do
    :crypto.mac(:hmac, :sha256, Config.local_jwt_secret(), payload)
    |> Base.url_encode64(padding: false)
  end

  defp secure_compare(left, right) when byte_size(left) == byte_size(right) do
    :crypto.hash_equals(left, right)
  end

  defp secure_compare(_left, _right), do: false

  # CometChat SDKs persist this websocket credential and do not reliably
  # refresh it. Revocation of the underlying opaque token is authoritative.
  defp valid_expiry_claim?(%{"exp" => exp}), do: to_int(exp) > 0
  defp valid_expiry_claim?(_payload), do: false

  defp blank?(value), do: value in [nil, "", false]

  defp to_s(nil), do: ""
  defp to_s(value) when is_binary(value), do: value
  defp to_s(value), do: to_string(value)

  defp to_int(nil), do: 0
  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _rest} -> int
      :error -> 0
    end
  end

  defp to_int(value), do: value |> to_s() |> to_int()
end
