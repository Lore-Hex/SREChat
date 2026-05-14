defmodule OpenChat.DeactivationTest do
  use ExUnit.Case, async: false

  alias OpenChat.Store

  setup do
    Store.reset!()
    :ok
  end

  test "deactivated user cannot authenticate" do
    {:ok, %{"authToken" => token, "uid" => uid}} = Store.create_auth_token("deactivate_me")

    # Authenticate works
    assert {:ok, user} = Store.authenticate(token)
    assert user["uid"] == uid

    # Deactivate
    assert {:ok, _} = Store.delete_user(uid)

    # Authenticate should fail
    assert {:error, %{"code" => "ERR_NO_AUTH"}} = Store.authenticate(token)
  end
end
