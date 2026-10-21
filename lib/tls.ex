defmodule BorsNG.TLS do
  @moduledoc """
  The TLS options for bors's outgoing requests, to GitHub's API, GitHub's
  OAuth endpoints and Zulip, which all go through hackney.

  They trust the operating system's certificate store, from
  `:public_key.cacerts_get/0`, instead of hackney's default: the roots of the
  `certifi` package, compiled into hackney when it is built. The system's
  store is updated with the system's other security fixes, so a root that is
  distrusted there stops being trusted here without a new `certifi` release
  or a change to `mix.lock`. In the Docker image, that is Debian's
  `ca-certificates`, as installed when the image was built.
  """

  require Record

  @hrl "public_key/include/public_key.hrl"
  Record.defrecordp(:cert, Record.extract(:cert, from_lib: @hrl))

  Record.defrecordp(
    :otp_certificate,
    :OTPCertificate,
    Record.extract(:OTPCertificate, from_lib: @hrl)
  )

  Record.defrecordp(
    :otp_tbs_certificate,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: @hrl)
  )

  @doc """
  hackney's `:ssl_options` for a request.

  hackney merges them into its defaults, so its hostname check stays. They
  replace both defaults that name certifi's roots: `:cacerts`, and
  `:partial_chain`, which accepts a chain that includes a certificate with
  the key of one of certifi's roots, even one the system no longer trusts.
  """
  @spec hackney_ssl_options() :: keyword
  def hackney_ssl_options do
    [cacerts: :public_key.cacerts_get(), partial_chain: &__MODULE__.partial_chain/1]
  end

  @doc """
  The `:partial_chain` of `hackney_ssl_options/0`: hackney's own, with the
  system's store in place of certifi's. If the chain the server sends doesn't
  end at a root in the store, but includes a certificate with the key of
  one, that certificate is trusted.
  """
  @spec partial_chain([:public_key.der_encoded()]) ::
          {:trusted_ca, :public_key.der_encoded()} | :unknown_ca
  def partial_chain(chain) do
    keys = MapSet.new(:public_key.cacerts_get(), fn cert(otp: otp) -> public_key_info(otp) end)

    chain
    |> Enum.reverse()
    |> Enum.find(fn der ->
      MapSet.member?(keys, der |> :public_key.pkix_decode_cert(:otp) |> public_key_info())
    end)
    |> case do
      nil -> :unknown_ca
      der -> {:trusted_ca, der}
    end
  end

  defp public_key_info(otp_certificate(tbsCertificate: tbs)),
    do: otp_tbs_certificate(tbs, :subjectPublicKeyInfo)
end
