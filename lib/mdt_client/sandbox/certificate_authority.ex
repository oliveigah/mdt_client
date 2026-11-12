defmodule MDTClient.Sandbox.CertificateAuthority do
  @moduledoc """
  The certificate authority only the VM trusts, so MDT can read the requests
  that carry a placeholder.

  One CA per identity, kept in its vault and baked into the VM image. For each
  host it intercepts, MDT signs a short-lived certificate on the spot. Nothing
  else trusts this CA: the host never installs it.

  Built on `:public_key` alone. Certificates carry the extensions strict
  verifiers ask for (key identifiers, key usage, a server-auth leaf with its
  host as subject alternative name), since Go and Python 3.13 reject leaves
  without them.
  """

  require Record

  @hrl "public_key/include/public_key.hrl"
  Record.defrecordp(:tbs, :OTPTBSCertificate, Record.extract(:OTPTBSCertificate, from_lib: @hrl))

  Record.defrecordp(
    :sig_alg,
    :SignatureAlgorithm,
    Record.extract(:SignatureAlgorithm, from_lib: @hrl)
  )

  Record.defrecordp(
    :attr,
    :AttributeTypeAndValue,
    Record.extract(:AttributeTypeAndValue, from_lib: @hrl)
  )

  Record.defrecordp(:validity, :Validity, Record.extract(:Validity, from_lib: @hrl))

  Record.defrecordp(
    :spki,
    :OTPSubjectPublicKeyInfo,
    Record.extract(:OTPSubjectPublicKeyInfo, from_lib: @hrl)
  )

  Record.defrecordp(
    :pk_alg,
    :PublicKeyAlgorithm,
    Record.extract(:PublicKeyAlgorithm, from_lib: @hrl)
  )

  Record.defrecordp(:ec_point, :ECPoint, Record.extract(:ECPoint, from_lib: @hrl))
  Record.defrecordp(:ec_key, :ECPrivateKey, Record.extract(:ECPrivateKey, from_lib: @hrl))
  Record.defrecordp(:ext, :Extension, Record.extract(:Extension, from_lib: @hrl))
  Record.defrecordp(:basic, :BasicConstraints, Record.extract(:BasicConstraints, from_lib: @hrl))

  Record.defrecordp(
    :aki,
    :AuthorityKeyIdentifier,
    Record.extract(:AuthorityKeyIdentifier, from_lib: @hrl)
  )

  @common_name {2, 5, 4, 3}
  @organization {2, 5, 4, 10}
  @ecdsa_sha256 {1, 2, 840, 10045, 4, 3, 2}
  @ec_public_key {1, 2, 840, 10045, 2, 1}
  @secp256r1 {1, 2, 840, 10045, 3, 1, 7}
  @basic_constraints {2, 5, 29, 19}
  @key_usage {2, 5, 29, 15}
  @ext_key_usage {2, 5, 29, 37}
  @server_auth {1, 3, 6, 1, 5, 5, 7, 3, 1}
  @subject_alt_name {2, 5, 29, 17}
  @subject_key_id {2, 5, 29, 14}
  @authority_key_id {2, 5, 29, 35}

  @ca_days 3650
  @leaf_days 30

  @typedoc "A certificate as DER, with the private key that goes with it."
  @type pair :: %{cert: binary(), key: tuple()}

  @doc "Creates a new CA, valid for ten years."
  @spec new(String.t()) :: pair()
  def new(name \\ "MDT Agent Sandbox CA") do
    key = :public_key.generate_key({:namedCurve, @secp256r1})
    point = public_point(key)
    subject = name(name)

    cert =
      tbs(
        version: :v3,
        serialNumber: serial(),
        signature: sig_alg(algorithm: @ecdsa_sha256, parameters: :asn1_NOVALUE),
        issuer: subject,
        validity: valid_for(-1, @ca_days),
        subject: subject,
        subjectPublicKeyInfo: public_key_info(point),
        extensions: [
          ext(
            extnID: @basic_constraints,
            critical: true,
            extnValue: basic(cA: true, pathLenConstraint: 0)
          ),
          ext(extnID: @key_usage, critical: true, extnValue: [:keyCertSign, :cRLSign]),
          ext(extnID: @subject_key_id, critical: false, extnValue: key_id(point))
        ]
      )
      |> :public_key.pkix_sign(key)

    %{cert: cert, key: key}
  end

  @doc "Signs a certificate for `host`, valid for 30 days, with a fresh key."
  @spec leaf(pair(), String.t()) :: pair()
  def leaf(%{cert: ca_cert, key: ca_key}, host) when is_binary(host) do
    key = :public_key.generate_key({:namedCurve, @secp256r1})
    point = public_point(key)
    ca_point = public_point(ca_key)
    issuer = ca_cert |> :public_key.pkix_decode_cert(:otp) |> elem(1) |> tbs(:subject)

    cert =
      tbs(
        version: :v3,
        serialNumber: serial(),
        signature: sig_alg(algorithm: @ecdsa_sha256, parameters: :asn1_NOVALUE),
        issuer: issuer,
        validity: valid_for(-1, @leaf_days),
        subject: name(host),
        subjectPublicKeyInfo: public_key_info(point),
        extensions: [
          ext(
            extnID: @basic_constraints,
            critical: true,
            extnValue: basic(cA: false, pathLenConstraint: :asn1_NOVALUE)
          ),
          ext(extnID: @key_usage, critical: true, extnValue: [:digitalSignature]),
          ext(extnID: @ext_key_usage, critical: false, extnValue: [@server_auth]),
          ext(extnID: @subject_alt_name, critical: false, extnValue: [san(host)]),
          ext(extnID: @subject_key_id, critical: false, extnValue: key_id(point)),
          ext(
            extnID: @authority_key_id,
            critical: false,
            extnValue:
              aki(
                keyIdentifier: key_id(ca_point),
                authorityCertIssuer: :asn1_NOVALUE,
                authorityCertSerialNumber: :asn1_NOVALUE
              )
          )
        ]
      )
      |> :public_key.pkix_sign(ca_key)

    %{cert: cert, key: key}
  end

  @doc "A certificate as PEM text, as the VM's trust store wants it."
  @spec pem(binary()) :: String.t()
  def pem(der), do: :public_key.pem_encode([{:Certificate, der, :not_encrypted}])

  @doc "The `:ssl` options that serve `pair` as the server's certificate."
  @spec ssl_options(pair()) :: keyword()
  def ssl_options(%{cert: cert, key: key}) do
    [cert: cert, key: {:ECPrivateKey, :public_key.der_encode(:ECPrivateKey, key)}]
  end

  defp public_point(ec_key(publicKey: point)), do: point

  defp public_key_info(point) do
    spki(
      algorithm: pk_alg(algorithm: @ec_public_key, parameters: {:namedCurve, @secp256r1}),
      subjectPublicKey: ec_point(point: point)
    )
  end

  defp name(common_name) do
    {:rdnSequence,
     [
       [attr(type: @organization, value: {:utf8String, "MDT"})],
       [attr(type: @common_name, value: {:utf8String, common_name})]
     ]}
  end

  # An address gets an IP entry, anything else a DNS one.
  defp san(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {_, _, _, _} = ip} -> {:iPAddress, :binary.list_to_bin(Tuple.to_list(ip))}
      {:ok, ip} -> {:iPAddress, for(part <- Tuple.to_list(ip), into: <<>>, do: <<part::16>>)}
      {:error, _} -> {:dNSName, String.to_charlist(host)}
    end
  end

  defp key_id(point), do: :crypto.hash(:sha, point)

  # 15 random bytes: always positive and well under the 20 octets allowed.
  defp serial, do: :crypto.strong_rand_bytes(15) |> :binary.decode_unsigned() |> max(1)

  defp valid_for(from_days, to_days) do
    now = DateTime.utc_now()

    validity(
      notBefore: time(DateTime.add(now, from_days, :day)),
      notAfter: time(DateTime.add(now, to_days, :day))
    )
  end

  # UTCTime until 2049, GeneralizedTime after, as RFC 5280 requires.
  defp time(%DateTime{year: year} = at) when year < 2050,
    do: {:utcTime, Calendar.strftime(at, "%y%m%d%H%M%SZ") |> String.to_charlist()}

  defp time(at),
    do: {:generalTime, Calendar.strftime(at, "%Y%m%d%H%M%SZ") |> String.to_charlist()}
end
