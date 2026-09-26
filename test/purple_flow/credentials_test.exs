defmodule PurpleFlow.CredentialsTest do
  use PurpleFlow.DataCase, async: true

  alias PurpleFlow.Credentials

  describe "create/2 and get/1" do
    test "a new credential is unset" do
      {:ok, cred} = Credentials.create("STRIPE_KEY", "for checkout")
      assert Credentials.get(cred.name) == nil
    end

    test "get/1 round-trips a value through real encryption" do
      {:ok, cred} = Credentials.create("STRIPE_KEY", "for checkout")
      {:ok, _} = Credentials.update(cred.id, %{key: "sk_live_abc123"})

      assert Credentials.get("STRIPE_KEY") == "sk_live_abc123"

      # the encrypted bytes on disk are never the plaintext
      stored = PurpleFlow.Repo.get!(Credentials.Credential, cred.id)
      refute stored.key == "sk_live_abc123"
      assert is_binary(stored.key)
    end

    test "get/1 on a name that was never created is nil" do
      assert Credentials.get("NOPE") == nil
    end
  end

  describe "set?/1" do
    test "is true only for an active credential with a value" do
      {:ok, cred} = Credentials.create("A", "")
      refute Credentials.set?("A")

      {:ok, _} = Credentials.update(cred.id, %{key: "v"})
      assert Credentials.set?("A")

      {:ok, _} = Credentials.archive(cred.id)
      refute Credentials.set?("A")
      refute Credentials.set?("NOPE")
    end
  end

  describe "update/2" do
    test "accepts string-keyed attrs, as from raw form params" do
      {:ok, cred} = Credentials.create("A", "")
      {:ok, _} = Credentials.update(cred.id, %{"description" => "d", "key" => "v"})

      assert Credentials.get("A") == "v"
      assert [%{description: "d"}] = Credentials.list()
    end

    test "changes name, description, and key independently" do
      {:ok, cred} = Credentials.create("A", "first")

      {:ok, cred} = Credentials.update(cred.id, %{description: "second"})
      assert cred.description == "second"
      assert cred.name == "A"

      {:ok, cred} = Credentials.update(cred.id, %{name: "B"})
      assert cred.name == "B"
      assert Credentials.get("B") == nil

      {:ok, _} = Credentials.update(cred.id, %{key: "secret"})
      assert Credentials.get("B") == "secret"
    end

    test "leaving key out of attrs doesn't touch the stored value" do
      {:ok, cred} = Credentials.create("A", "")
      {:ok, _} = Credentials.update(cred.id, %{key: "secret"})

      {:ok, _} = Credentials.update(cred.id, %{description: "updated"})
      assert Credentials.get("A") == "secret"
    end

    test "an empty key string doesn't clear the stored value" do
      {:ok, cred} = Credentials.create("A", "")
      {:ok, _} = Credentials.update(cred.id, %{key: "secret"})

      {:ok, _} = Credentials.update(cred.id, %{key: ""})
      assert Credentials.get("A") == "secret"
    end
  end

  describe "list/0" do
    test "lists active credentials, never the key" do
      {:ok, unset} = Credentials.create("UNSET", "")
      {:ok, set} = Credentials.create("SET", "")
      {:ok, _} = Credentials.update(set.id, %{key: "secret"})

      rows = Credentials.list()

      assert Enum.find(rows, &(&1.id == unset.id)).set == false
      assert Enum.find(rows, &(&1.id == set.id)).set == true
      refute Enum.any?(rows, &Map.has_key?(&1, :key))
    end

    test "doesn't include archived credentials" do
      {:ok, cred} = Credentials.create("A", "")
      {:ok, _} = Credentials.archive(cred.id)

      refute Enum.any?(Credentials.list(), &(&1.id == cred.id))
    end
  end

  describe "archive/1" do
    test "frees the name, and get/1 on the old name is nil" do
      {:ok, cred} = Credentials.create("A", "")
      {:ok, _} = Credentials.update(cred.id, %{key: "secret"})

      {:ok, archived} = Credentials.archive(cred.id)

      assert archived.archived_at
      assert archived.name != "A"
      assert Credentials.get("A") == nil
    end

    test "the freed name can be reused immediately" do
      {:ok, cred} = Credentials.create("A", "")
      {:ok, _} = Credentials.archive(cred.id)

      assert {:ok, _} = Credentials.create("A", "a new one")
    end
  end

  describe "naming" do
    test "rejects a name containing a dot" do
      assert {:error, changeset} = Credentials.create("a.b", "")
      assert "can't contain \".\"" in errors_on(changeset).name
    end

    test "rejects a name containing { or }" do
      assert {:error, changeset} = Credentials.create("a{b", "")
      assert "can't contain \"{\" or \"}\"" in errors_on(changeset).name

      assert {:error, changeset} = Credentials.create("a}b", "")
      assert "can't contain \"{\" or \"}\"" in errors_on(changeset).name
    end

    test "rejects leading or trailing whitespace" do
      assert {:error, changeset} = Credentials.create(" A", "")
      assert changeset.errors[:name]

      assert {:error, changeset} = Credentials.create("A ", "")
      assert changeset.errors[:name]
    end

    test "rejects an empty name" do
      assert {:error, changeset} = Credentials.create("", "")
      assert changeset.errors[:name]
    end

    test "accepts punctuation, spaces, and unicode" do
      assert {:ok, _} = Credentials.create("lee's stripe key (prod) 🔑", "")
    end

    test "rejects a duplicate active name" do
      {:ok, _} = Credentials.create("DUP", "")
      assert {:error, changeset} = Credentials.create("DUP", "")
      assert "has already been taken" in errors_on(changeset).name
    end
  end
end
