defmodule MDTClient.Sandbox.CertificateAuthorityTest do
  use ExUnit.Case, async: true

  alias MDTClient.Sandbox.CertificateAuthority, as: CA

  test "signs leaves that validate against the CA, for names and addresses" do
    ca = CA.new()
    leaf = CA.leaf(ca, "api.github.com")

    assert {:ok, _} = :public_key.pkix_path_validation(ca.cert, [leaf.cert], [])
    assert :public_key.pkix_verify_hostname(leaf.cert, dns_id: ~c"api.github.com")
    refute :public_key.pkix_verify_hostname(leaf.cert, dns_id: ~c"evil.example")

    ip_leaf = CA.leaf(ca, "10.0.0.5")
    assert {:ok, _} = :public_key.pkix_path_validation(ca.cert, [ip_leaf.cert], [])
    assert :public_key.pkix_verify_hostname(ip_leaf.cert, ip: {10, 0, 0, 5})
  end

  test "a leaf from another CA does not validate" do
    leaf = CA.leaf(CA.new(), "api.github.com")
    assert {:error, _} = :public_key.pkix_path_validation(CA.new().cert, [leaf.cert], [])
  end

  test "renders PEM a trust store reads back" do
    ca = CA.new()
    assert [{:Certificate, der, :not_encrypted}] = ca.cert |> CA.pem() |> :public_key.pem_decode()
    assert der == ca.cert
  end
end
