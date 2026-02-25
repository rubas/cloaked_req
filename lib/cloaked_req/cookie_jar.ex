defmodule CloakedReq.CookieJar do
  @moduledoc """
  Reference to a Rust-side cookie jar (wreq `Jar`).

  Cookies are automatically stored from `set-cookie` response headers
  and sent with subsequent requests sharing the same jar. The jar is
  garbage-collected by the BEAM when no longer referenced.

  ## Examples

      jar = CloakedReq.CookieJar.new()

      # Login — server sets session cookie
      Req.new(url: "https://example.com/login")
      |> CloakedReq.attach(impersonate: :chrome_136, cookie_jar: jar)
      |> Req.post!(body: "user=admin&pass=secret")

      # Dashboard — session cookie sent automatically
      Req.new(url: "https://example.com/dashboard")
      |> CloakedReq.attach(impersonate: :chrome_136, cookie_jar: jar)
      |> Req.get!()
  """

  @enforce_keys [:ref]
  defstruct [:ref]

  @type t :: %__MODULE__{ref: reference()}

  @doc """
  Creates a new empty cookie jar.

  ## Examples

      iex> jar = CloakedReq.CookieJar.new()
      iex> %CloakedReq.CookieJar{} = jar
      iex> is_reference(jar.ref)
      true
  """
  @spec new() :: t()
  def new do
    %__MODULE__{ref: CloakedReq.Native.create_cookie_jar()}
  end
end
