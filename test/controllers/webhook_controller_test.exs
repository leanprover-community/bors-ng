defmodule BorsNG.WebhookControllerTest do
  use BorsNG.ConnCase

  alias BorsNG.Database.Installation
  alias BorsNG.Database.Patch
  alias BorsNG.Database.Project
  alias BorsNG.Database.Repo
  alias BorsNG.Database.User
  alias BorsNG.GitHub.Pr
  alias BorsNG.GitHub

  setup do
    installation =
      Repo.insert!(%Installation{
        installation_xref: 31
      })

    project =
      Repo.insert!(%Project{
        installation_id: installation.id,
        repo_xref: 13,
        name: "example/project"
      })

    user =
      Repo.insert!(%User{
        user_xref: 23,
        login: "ghost"
      })

    {:ok, installation: installation, project: project, user: user}
  end

  test "edit PR", %{conn: conn, project: project} do
    patch =
      Repo.insert!(%Patch{
        title: "T",
        body: "B",
        pr_xref: 1,
        project_id: project.id,
        into_branch: "SOME_BRANCH"
      })

    body_params = %{
      "repository" => %{"id" => 13},
      "action" => "edited",
      "pull_request" => %{
        "number" => 1,
        "title" => "U",
        "body" => "C",
        "state" => "open",
        "base" => %{"ref" => "OTHER_BRANCH", "repo" => %{"id" => 456}},
        "head" => %{
          "sha" => "S",
          "ref" => "BAR_BRANCH",
          "repo" => %{
            "id" => 345
          }
        },
        "merged_at" => nil,
        "mergeable" => true,
        "user" => %{
          "id" => 23,
          "login" => "ghost",
          "avatar_url" => "U"
        }
      }
    }

    conn
    |> put_req_header("x-github-event", "pull_request")
    |> post(webhook_path(conn, :webhook, "github"), body_params)

    patch2 = Repo.get!(Patch, patch.id)
    assert "U" == patch2.title
    assert "C" == patch2.body
    assert "OTHER_BRANCH" == patch2.into_branch
  end

  test "sync PR on reopen", %{conn: conn, project: project} do
    patch =
      Repo.insert!(%Patch{
        title: "T",
        body: "B",
        pr_xref: 1,
        project_id: project.id,
        commit: "A",
        open: false,
        into_branch: "SOME_BRANCH"
      })

    body_params = %{
      "repository" => %{"id" => 13},
      "action" => "reopened",
      "pull_request" => %{
        "number" => 1,
        "title" => "T",
        "body" => "B",
        "state" => "open",
        "base" => %{"ref" => "OTHER_BRANCH", "repo" => %{"id" => 456}},
        "head" => %{
          "sha" => "B",
          "ref" => "BAR_BRANCH",
          "repo" => %{
            "id" => 345
          }
        },
        "merged_at" => nil,
        "mergeable" => true,
        "user" => %{
          "id" => 23,
          "login" => "ghost",
          "avatar_url" => "U"
        }
      }
    }

    conn
    |> put_req_header("x-github-event", "pull_request")
    |> post(webhook_path(conn, :webhook, "github"), body_params)

    patch2 = Repo.get!(Patch, patch.id)
    assert "B" == patch2.commit
    assert patch2.open
  end

  test "deletes by patch", %{conn: conn, project: proj} do
    pr = %Pr{
      number: 1,
      title: "Test",
      body: "Mess",
      state: :closed,
      base_ref: "master",
      head_sha: "00000001",
      head_ref: "update",
      base_repo_id: 13,
      head_repo_id: 13,
      merged: true
    }

    GitHub.ServerMock.put_state(%{
      {{:installation, 31}, 13} => %{
        branches: %{"master" => "ini", "update" => "foo"},
        comments: %{1 => []},
        statuses: %{},
        pulls: %{
          1 => pr
        },
        files: %{
          "master" => %{
            ".github/bors.toml" => ~s"""
              status = [ "ci" ]
              delete_merged_branches = true
            """
          },
          "update" => %{
            ".github/bors.toml" => ~s"""
              status = [ "ci" ]
              delete_merged_branches = true
            """
          }
        }
      }
    })

    %Patch{
      project_id: proj.id,
      pr_xref: 1,
      commit: "foo",
      into_branch: "master"
    }
    |> Repo.insert!()

    body_params = %{
      "repository" => %{"id" => 13},
      "action" => "closed",
      "pull_request" => %{
        "number" => 1,
        "title" => "U",
        "body" => "C",
        "state" => "closed",
        "base" => %{"ref" => "OTHER_BRANCH", "repo" => %{"id" => 456}},
        "head" => %{
          "sha" => "S",
          "ref" => "BAR_BRANCH",
          "repo" => %{
            "id" => 345
          }
        },
        "merged_at" => "time",
        "mergeable" => true,
        "user" => %{
          "id" => 23,
          "login" => "ghost",
          "avatar_url" => "U"
        }
      }
    }

    conn
    |> put_req_header("x-github-event", "pull_request")
    |> post(webhook_path(conn, :webhook, "github"), body_params)

    wait_until_other_branch_is_removed()

    branches =
      GitHub.ServerMock.get_state()
      |> Map.get({{:installation, 31}, 13})
      |> Map.get(:branches)
      |> Map.keys()

    assert branches == ["master"]
  end

  test "closing a PR removes it from waiting batches", %{conn: conn, project: proj} do
    # Minimal GitHub state to allow comment posting if needed
    GitHub.ServerMock.put_state(%{
      {{:installation, 31}, 13} => %{
        branches: %{},
        commits: %{},
        comments: %{1 => []},
        statuses: %{},
        files: %{}
      }
    })

    # Create an open patch and add it to a waiting batch
    patch =
      Repo.insert!(%Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "C",
        into_branch: "master",
        open: true
      })

    batch =
      Repo.insert!(%BorsNG.Database.Batch{
        project_id: proj.id,
        state: :waiting,
        into_branch: "master",
        last_polled: DateTime.to_unix(DateTime.utc_now(), :second) - 100
      })

    Repo.insert!(%BorsNG.Database.LinkPatchBatch{
      patch_id: patch.id,
      batch_id: batch.id,
      reviewer: "rvr"
    })

    # Send PR closed webhook
    body_params = %{
      "repository" => %{"id" => 13},
      "action" => "closed",
      "pull_request" => %{
        "number" => 1,
        "title" => "T",
        "body" => "B",
        "state" => "closed",
        "base" => %{"ref" => "master", "repo" => %{"id" => 13}},
        "head" => %{"sha" => "C", "ref" => "feature", "repo" => %{"id" => 13}},
        "merged_at" => "time",
        "mergeable" => true,
        "user" => %{"id" => 23, "login" => "ghost", "avatar_url" => "U"}
      }
    }

    conn
    |> put_req_header("x-github-event", "pull_request")
    |> post(webhook_path(conn, :webhook, "github"), body_params)

    # Ensure the batcher processed the cancel cast by doing a synchronous call
    batcher = BorsNG.Worker.Batcher.Registry.get(proj.id)
    :ok = BorsNG.Worker.Batcher.set_is_single(batcher, patch.id, false)

    # Patch should be closed
    patch2 = Repo.get!(Patch, patch.id)
    refute patch2.open

    # Link removed and empty batch deleted
    assert Repo.all(from(l in BorsNG.Database.LinkPatchBatch, where: l.batch_id == ^batch.id)) ==
             []

    assert Repo.get(BorsNG.Database.Batch, batch.id) == nil
  end

  def wait_until_other_branch_is_removed do
    branches =
      GitHub.ServerMock.get_state()
      |> Map.get({{:installation, 31}, 13})
      |> Map.get(:branches)
      |> Map.keys()

    if branches == ["master"] do
      :ok
    else
      wait_until_other_branch_is_removed()
    end
  end
end
