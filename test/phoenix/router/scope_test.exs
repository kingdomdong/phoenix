defmodule Phoenix.Router.ScopedRoutingTest do
  use ExUnit.Case, async: true
  use RouterHelper

  # Path scoping

  defmodule Api.V1.UserController do
    use Phoenix.Controller
    def show(conn, _params), do: text(conn, "api v1 users show")
    def delete(conn, _params), do: text(conn, "api v1 users delete")
    def edit(conn, _params), do: text(conn, "api v1 users edit")
    def foo_host(conn, _params), do: text(conn, "foo request from #{conn.host}")
    def baz_host(conn, _params), do: text(conn, "baz request from #{conn.host}")
    def proxy(conn, _) do
      {controller, action} = conn.private.proxy_to
      controller.call(conn, controller.init(action))
    end
  end

  defmodule Router do
    use Phoenix.Router

    scope "/admin", host: "baz." do
      get "/users/:id", Api.V1.UserController, :baz_host
    end

    scope host: "foobar.com" do
      scope "/admin" do
        get "/users/:id", Api.V1.UserController, :foo_host
      end
    end

    scope "/admin" do
      get "/users/:id", Api.V1.UserController, :show
    end

    scope "/api" do
      scope "/v1" do
        get "/users/:id", Api.V1.UserController, :show
      end
    end

    scope "/api", Api, private: %{private_token: "foo"} do
      get "/users", V1.UserController, :show
      get "/users/:id", V1.UserController, :show, private: %{private_token: "bar"}

      scope "/v1", alias: V1 do
        resources "/users", UserController, only: [:delete], private: %{private_token: "baz"}
        get "/noalias", Api.V1.UserController, :proxy,
          private: %{proxy_to: {scoped_alias(__MODULE__, UserController), :show}},
          alias: false
      end
    end

    scope "/assigns", Api, assigns: %{assigns_token: "foo"} do
      get "/users", V1.UserController, :show
      get "/users/:id", V1.UserController, :show, assigns: %{assigns_token: "bar"}

      scope "/v1", alias: V1 do
        resources "/users", UserController, only: [:delete], assigns: %{assigns_token: "baz"}
      end
    end

    scope "/host", host: "baz." do
      get "/users/:id", Api.V1.UserController, :baz_host
    end

    scope host: "foobar.com" do
      scope "/host" do
        get "/users/:id", Api.V1.UserController, :foo_host
      end
    end

    scope "/api" do
      scope "/v1", Api do
        resources "/venues", V1.VenueController, only: [:show], alias: V1 do
          resources "/users", UserController, only: [:edit]
        end
      end
    end
  end

  setup do
    Logger.disable(self())
    :ok
  end

  test "single scope for single routes" do
    conn = call(Router, :get, "/admin/users/1")
    assert conn.status == 200
    assert conn.resp_body == "api v1 users show"
    assert conn.params["id"] == "1"

    conn = call(Router, :get, "/api/users/13")
    assert conn.status == 200
    assert conn.resp_body == "api v1 users show"
    assert conn.params["id"] == "13"
  end

  test "double scope for single routes" do
    conn = call(Router, :get, "/api/v1/users/1")
    assert conn.status == 200
    assert conn.resp_body == "api v1 users show"
    assert conn.params["id"] == "1"
  end

  test "scope for resources" do
    conn = call(Router, :delete, "/api/v1/users/12")
    assert conn.status == 200
    assert conn.resp_body == "api v1 users delete"
    assert conn.params["id"] == "12"
  end

  test "scope for double nested resources" do
    conn = call(Router, :get, "/api/v1/venues/12/users/13/edit")
    assert conn.status == 200
    assert conn.resp_body == "api v1 users edit"
    assert conn.params["venue_id"] == "12"
    assert conn.params["id"] == "13"
  end

  test "host scopes routes based on conn.host" do
    conn = call(Router, :get, "http://foobar.com/admin/users/1")
    assert conn.status == 200
    assert conn.resp_body == "foo request from foobar.com"
    assert conn.params["id"] == "1"
  end

  test "host scopes allows partial host matching" do
    conn = call(Router, :get, "http://baz.bing.com/admin/users/1")
    assert conn.status == 200
    assert conn.resp_body == "baz request from baz.bing.com"

    conn = call(Router, :get, "http://baz.pang.com/admin/users/1")
    assert conn.status == 200
    assert conn.resp_body == "baz request from baz.pang.com"
  end

  test "host 404s when failed match" do
    conn = call(Router, :get, "http://foobar.com/host/users/1")
    assert conn.status == 200

    conn = call(Router, :get, "http://baz.pang.com/host/users/1")
    assert conn.status == 200

    assert_raise Phoenix.Router.NoRouteError, fn ->
      call(Router, :get, "http://foobar.com.br/host/users/1")
    end

    assert_raise Phoenix.Router.NoRouteError, fn ->
      call(Router, :get, "http://ba.pang.com/host/users/1")
    end
  end

  test "private data in scopes" do
    conn = call(Router, :get, "/api/users")
    assert conn.status == 200
    assert conn.private[:private_token] == "foo"

    conn = call(Router, :get, "/api/users/13")
    assert conn.status == 200
    assert conn.private[:private_token] == "bar"

    conn = call(Router, :delete, "/api/v1/users/13")
    assert conn.status == 200
    assert conn.private[:private_token] == "baz"
  end

  test "assigns data in scopes" do
    conn = call(Router, :get, "/assigns/users")
    assert conn.status == 200
    assert conn.assigns[:assigns_token] == "foo"

    conn = call(Router, :get, "/assigns/users/13")
    assert conn.status == 200
    assert conn.assigns[:assigns_token] == "bar"

    conn = call(Router, :delete, "/assigns/v1/users/13")
    assert conn.status == 200
    assert conn.assigns[:assigns_token] == "baz"
  end

  test "string paths are enforced" do
    assert_raise ArgumentError, ~r{router paths must be strings, got: '/bar'}, fn ->
      defmodule SomeRouter do
        use Phoenix.Router, otp_app: :phoenix
        get "/foo", Router, []
        get '/bar', Router, []
      end
    end

    assert_raise ArgumentError, ~r{router paths must be strings, got: '/bar'}, fn ->
      defmodule SomeRouter do
        use Phoenix.Router, otp_app: :phoenix
        get "/foo", Router, []
        scope "/another" do
          resources '/bar', Router, []
        end
      end
    end
  end

  test "alias false with expanded scoped alias" do
    conn = call(Router, :get, "/api/v1/noalias")
    assert conn.status == 200
    assert conn.resp_body == "api v1 users show"
  end
end
