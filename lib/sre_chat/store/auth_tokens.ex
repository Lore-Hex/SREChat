defmodule SREChat.Store.AuthTokens do
  @moduledoc false

  alias SREChat.{Config, Time}

  @sdk_jwt_advisory_ttl_seconds 24 * 60 * 60

  # A real base64url JWT header, not the literal marker "local" this used to
  # emit. "local" is 5 characters, and a base64 segment can never have a length
  # of 1 more than a multiple of 4 — so the token was structurally undecodable.
  # The JS SDK never looks inside it and passed it around happily; the iOS SDK
  # decodes it, gets nil, and per its own log line "jwtToken found nil calling
  # disconnect" it tears the socket down BEFORE dialling. That is why the native
  # client connected to nothing at all while REST worked perfectly.
  @jwt_header Base.url_encode64(~s({"alg":"HS256","typ":"JWT"}), padding: false)

  @doc """
  True when a token CLAIMS to be one of our local JWTs, whichever header it
  carries. Callers use this to route a credential to JWT verification rather
  than treating it as an opaque token.

  Deliberately a shared predicate: the "local." prefix used to be spelled out in
  four different files, so changing the header fixed the client and silently
  broke the WebSocket's credential classification and the store's auth branch.
  """
  def local_jwt_shaped?(token) do
    token = to_s(token)
    String.starts_with?(token, "local.") or String.starts_with?(token, @jwt_header <> ".")
  end

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

    @jwt_header <> "." <> payload <> "." <> signature(payload)
  end

  def lookup_tokens(token) do
    token = to_s(token)

    # A uid token that fails the passcode check must not reach the stored-token
    # lookup at all. Users created BEFORE the gate was switched on have their
    # "uid:<name>" persisted as a real auth token, so without this an attacker
    # who simply guesses an existing name would still be let in — the passcode
    # would protect only names nobody had used yet. Refusing here revokes those
    # legacy tokens the moment a passcode is configured.
    if blocked_uid_token?(token) do
      []
    else
      token
      |> local_jwt_token()
      |> case do
        {:ok, auth_token} -> [auth_token]
        :error -> opaque_token_candidates(token)
      end
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()
    end
  end

  @doc false
  def blocked_uid_token?(token) do
    token = to_s(token)

    String.starts_with?(token, "uid:") and not is_nil(access_secret()) and
      uid_token(token) == :error
  end

  def local_jwt_token(token) do
    # Accept both headers: tokens minted before the fix carry the legacy "local"
    # marker and are still in clients' hands, so rejecting them would sign
    # everyone out. The signature covers the payload in both cases — the header
    # was never signed material, so nothing about the security changes.
    with [header, payload, token_signature] when header in ["local", @jwt_header] <-
           String.split(to_s(token), ".", parts: 3),
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

  # A token that CLAIMS to be one of our JWTs but failed verification must never
  # be retried as an opaque stored token — that would let a tampered or
  # stale-secret credential match a real token by string equality. This keyed on
  # the "local." prefix, so changing the header to a proper base64 JWT header
  # silently reopened the fallback; match on either header instead.
  defp opaque_token_candidates(token) do
    if local_jwt_shaped?(token), do: [], else: [token]
  end

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
