defmodule PurpleFlow.Credentials.Cipher do
  @moduledoc """
  Encrypts and decrypts credential values with AES-256-GCM, using a master
  key from `PURPLEFLOW_SECRET_KEY`.

  The stored binary is `nonce <> tag <> ciphertext`: everything needed to
  decrypt, in one blob, so the schema only needs a single `key` column.
  """

  @aad ""

  @doc "Encrypts `plaintext`, returning the binary to store."
  def encrypt(plaintext) when is_binary(plaintext) do
    key = master_key()
    nonce = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plaintext, @aad, true)

    nonce <> tag <> ciphertext
  end

  @doc "Decrypts a binary produced by `encrypt/1`."
  def decrypt(<<nonce::binary-12, tag::binary-16, ciphertext::binary>>) do
    key = master_key()

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, ciphertext, @aad, tag, false) do
      :error -> raise "credential value failed to decrypt (wrong PURPLEFLOW_SECRET_KEY?)"
      plaintext -> plaintext
    end
  end

  defp master_key do
    raw =
      System.get_env("PURPLEFLOW_SECRET_KEY") ||
        raise """
        environment variable PURPLEFLOW_SECRET_KEY is missing.
        It encrypts every stored credential. Generate one with:
        openssl rand -base64 32
        """

    # Accept any length: derive a fixed 32-byte AES-256 key from whatever
    # string was given, rather than requiring the operator to produce
    # exactly 32 raw bytes themselves.
    :crypto.hash(:sha256, raw)
  end
end
