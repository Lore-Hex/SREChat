defmodule OpenChat.Store.AuthTokensTest do
  use ExUnit.Case, async: false

  alias OpenChat.{Config, Time}
  alias OpenChat.Store.AuthTokens

  setup do
    previous_secret = Application.get_env(:open_chat, :local_jwt_secret)
    Application.put_env(:open_chat, :local_jwt_secret, "test-local-jwt-secret")

    on_exit(fn ->
      case previous_secret do
        nil -> Application.delete_env(:open_chat, :local_jwt_secret)
        value -> Application.put_env(:open_chat, :local_jwt_secret, value)
      end
    end)

    :ok
  end

  test "local JWT lookup accepts canonical tokens and falls back to opaque tokens" do
    token = AuthTokens.local_jwt(123, 456, Time.now())

    assert {:ok, "456"} = AuthTokens.local_jwt_token(token)
    assert AuthTokens.lookup_tokens(token) == ["456"]
    assert AuthTokens.lookup_tokens(123) == ["123"]
    assert AuthTokens.lookup_tokens("") == []
    assert AuthTokens.uid_token("uid:alice") == {:ok, "alice"}
    assert AuthTokens.uid_token("uid:") == :error

    Application.put_env(:open_chat, :local_jwt_secret, "rotated-local-jwt-secret")
    assert :error = AuthTokens.local_jwt_token(token)
    assert {:ok, "456"} = AuthTokens.local_jwt_embedded_token(token)
    assert AuthTokens.lookup_tokens(token) == ["456"]
  end

  test "local JWT lookup rejects expired malformed and tampered local tokens" do
    assert {:ok, "string-exp"} =
             AuthTokens.local_jwt_token(
               local_token(%{"token" => "string-exp", "exp" => Integer.to_string(Time.now() + 60)})
             )

    assert :error = AuthTokens.local_jwt_token(local_token(%{"token" => "missing-exp"}))
    assert :error = AuthTokens.local_jwt_token(local_token(%{"token" => "nil-exp", "exp" => nil}))

    assert :error =
             AuthTokens.local_jwt_token(local_token(%{"token" => "bad-exp", "exp" => "bad"}))

    assert :error =
             AuthTokens.local_jwt_token(local_token(%{"token" => "", "exp" => Time.now() + 60}))

    assert :error =
             AuthTokens.local_jwt_token(local_token(%{"token" => "old", "exp" => Time.now() - 1}))

    assert {:ok, "old"} =
             AuthTokens.local_jwt_embedded_token(
               local_token(%{"token" => "old", "exp" => Time.now() - 1})
             )

    token = local_token(%{"token" => "auth", "exp" => Time.now() + 60})
    assert :error = AuthTokens.local_jwt_token(token <> "tampered")
    assert AuthTokens.lookup_tokens(token <> "tampered") == ["auth"]
  end

  defp local_token(payload) do
    encoded_payload =
      payload
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    signature =
      :crypto.mac(:hmac, :sha256, Config.local_jwt_secret(), encoded_payload)
      |> Base.url_encode64(padding: false)

    "local." <> encoded_payload <> "." <> signature
  end
end
