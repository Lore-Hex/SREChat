defmodule OpenChat.Store.AuthTokens do
  @moduledoc false

  alias OpenChat.{Config, Time}

  @local_jwt_ttl_seconds 24 * 60 * 60

  def local_jwt(uid, auth_token, now \\ Time.now()) do
    payload =
      %{
        "uid" => to_s(uid),
        "token" => to_s(auth_token),
        "iat" => now,
        "exp" => now + @local_jwt_ttl_seconds
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
      :error -> local_jwt_embedded_token_or_self(token)
    end
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  def local_jwt_embedded_token(token) do
    with ["local", payload, _token_signature] <- String.split(to_s(token), ".", parts: 3),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"token" => auth_token} = payload_map} <- Jason.decode(json),
         true <- token_not_expired?(payload_map),
         auth_token <- to_s(auth_token),
         false <- blank?(auth_token) do
      {:ok, auth_token}
    else
      _ -> :error
    end
  end

  def local_jwt_token(token) do
    with ["local", payload, token_signature] <- String.split(to_s(token), ".", parts: 3),
         true <- valid_signature?(payload, token_signature),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"token" => auth_token} = payload_map} <- Jason.decode(json),
         true <- token_not_expired?(payload_map),
         auth_token <- to_s(auth_token),
         false <- blank?(auth_token) do
      {:ok, auth_token}
    else
      _ -> :error
    end
  end

  def uid_token("uid:" <> uid) when uid != "", do: {:ok, uid}
  def uid_token(_token), do: :error

  defp local_jwt_embedded_token_or_self(token) do
    case local_jwt_embedded_token(token) do
      {:ok, auth_token} -> [auth_token]
      :error -> [token]
    end
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

  defp token_not_expired?(%{"exp" => exp}), do: to_int(exp) > Time.now()
  defp token_not_expired?(_payload), do: false

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
