defmodule BorsNG.Database.Repo.Migrations.ChangeUsersLoginTypeToCitext do
  use Ecto.Migration

  defp fetch_adapter do
    case System.get_env("BORS_DATABASE", "postgresql") do
      "mysql" -> Ecto.Adapters.MyXQL
      _ -> Ecto.Adapters.Postgres
    end
  end

  def up do
    case fetch_adapter() do
      Ecto.Adapters.Postgres ->
        execute "CREATE EXTENSION IF NOT EXISTS citext"
        alter table(:users) do
          modify :login, :citext
        end
      Ecto.Adapters.MyXQL ->
        :ok
    end
  end

  def down do
    case fetch_adapter() do
      Ecto.Adapters.Postgres ->
        alter table(:users) do
          modify :login, :string
        end
        execute "DROP EXTENSION citext"
      Ecto.Adapters.MyXQL ->
        :ok
    end
  end
end
