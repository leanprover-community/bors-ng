defmodule BorsNG.Worker.AttemptorTest do
  use BorsNG.Worker.TestCase

  alias BorsNG.Worker.Attemptor
  alias BorsNG.Worker.Batcher
  alias BorsNG.Database.Attempt
  alias BorsNG.Database.AttemptStatus
  alias BorsNG.Database.Context.Logging
  alias BorsNG.Database.Installation
  alias BorsNG.Database.LinkPatchBatch
  alias BorsNG.Database.Patch
  alias BorsNG.Database.Project
  alias BorsNG.Database.Repo
  alias BorsNG.Database.User
  alias BorsNG.GitHub
  alias BorsNG.GitHub.Commit
  alias BorsNG.GitHub.FullUser
  alias BorsNG.GitHub.Pr
  alias BorsNG.GitHub.User, as: GitHubUser

  setup do
    inst =
      %Installation{installation_xref: 91}
      |> Repo.insert!()

    proj =
      %Project{
        installation_id: inst.id,
        repo_xref: 14,
        staging_branch: "staging",
        trying_branch: "trying"
      }
      |> Repo.insert!()

    {:ok, inst: inst, proj: proj}
  end

  def new_patch(proj, pr_xref, commit) do
    %Patch{
      project_id: proj.id,
      pr_xref: pr_xref,
      into_branch: "master",
      commit: commit
    }
    |> Repo.insert!()
  end

  def new_attempt(patch, state) do
    %Attempt{patch_id: patch.id, state: state, into_branch: "master"}
    |> Repo.insert!()
  end

  defp try_commit_message(patch, reviewer, arguments) do
    patch = Repo.preload(patch, :author)
    link = %LinkPatchBatch{patch: patch, reviewer: reviewer}
    template = "Try ${PR_REFS}#{try_arguments_suffix(arguments)}"

    Batcher.Message.generate_commit_message(
      [link],
      nil,
      [],
      template
    )
  end

  defp try_arguments_suffix(arguments) do
    case arguments do
      "" -> ":"
      nil -> ":"
      _ -> ":#{arguments}"
    end
  end

  test "rejects running patches", %{proj: proj} do
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{},
        commits: %{},
        comments: %{1 => []},
        pr_commits: %{1 => []},
        statuses: %{},
        files: %{}
      }
    })

    patch = new_patch(proj, 1, nil)
    _attempt = new_attempt(patch, 0)
    Attemptor.handle_cast({:tried, patch.id, ""}, proj.id)
    state = GitHub.ServerMock.get_state()

    assert state == %{
             {{:installation, 91}, 14} => %{
               branches: %{},
               commits: %{},
               comments: %{
                 1 => ["## try\n\nAlready running a review"]
               },
               pr_commits: %{1 => []},
               statuses: %{},
               files: %{}
             }
           }
  end

  test "infer from .travis.yml", %{proj: proj} do
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{"master" => "ini", "trying" => "", "trying.tmp" => ""},
        commits: %{},
        comments: %{1 => []},
        pr_commits: %{1 => []},
        statuses: %{"iniN" => []},
        files: %{"trying.tmp" => %{".travis.yml" => ""}}
      }
    })

    patch = new_patch(proj, 1, "N")
    Attemptor.handle_cast({:tried, patch.id, "test"}, proj.id)
    [status] = Repo.all(AttemptStatus)
    assert status.identifier == "continuous-integration/travis-ci/push"
  end

  test "infer from .travis.yml and appveyor.yml", %{proj: proj} do
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{"master" => "ini", "trying" => "", "trying.tmp" => ""},
        commits: %{},
        comments: %{1 => []},
        pr_commits: %{1 => []},
        statuses: %{"iniN" => []},
        files: %{"trying.tmp" => %{".travis.yml" => "", "appveyor.yml" => ""}}
      }
    })

    patch = new_patch(proj, 1, "N")
    Attemptor.handle_cast({:tried, patch.id, "test"}, proj.id)
    statuses = Repo.all(AttemptStatus)

    assert Enum.any?(
             statuses,
             &(&1.identifier == "continuous-integration/travis-ci/push")
           )

    assert Enum.any?(
             statuses,
             &(&1.identifier == "continuous-integration/appveyor/branch")
           )
  end

  test "respects use_squash_merge for try commits", %{proj: proj} do
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{"master" => "ini", "trying" => "", "trying.tmp" => ""},
        commits: %{},
        comments: %{1 => []},
        pr_commits: %{
          1 => [
            %Commit{
              sha: "c1",
              author_name: "Ada",
              author_email: "ada@example.com",
              commit_message: "feat: add stuff",
              tree_sha: "t1"
            }
          ]
        },
        pulls: %{
          1 => %Pr{
            number: 1,
            title: "Add feature",
            body: "Body",
            state: :open,
            base_ref: "master",
            head_sha: "N",
            head_ref: "update",
            base_repo_id: 14,
            head_repo_id: 14,
            user: %GitHubUser{id: 42, login: "ada", avatar_url: "https://example.com"}
          }
        },
        statuses: %{"iniN" => []},
        files: %{
          "trying.tmp" => %{
            "bors.toml" => ~s"""
            status = [ "ci/test" ]
            use_squash_merge = true
            """
          }
        }
      },
      users: %{
        "ada" => %FullUser{
          id: 42,
          login: "ada",
          avatar_url: "https://example.com",
          email: "ada@example.com",
          name: "Ada"
        }
      }
    })

    patch = new_patch(proj, 1, "N")
    Attemptor.handle_cast({:tried, patch.id, ""}, proj.id)
    state = GitHub.ServerMock.get_state()
    repo = state[{{:installation, 91}, 14}]

    assert repo.branches["trying"] == "iniN"

    expected_message =
      Batcher.Message.generate_squash_commit_message(
        repo.pulls[1],
        repo.pr_commits[1],
        "ada@example.com",
        "Ada",
        nil
      )

    assert repo.commits["iniN"].commit_message == expected_message
  end

  test "infer from .appveyor.yml", %{proj: proj} do
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{"master" => "ini", "trying" => "", "trying.tmp" => ""},
        commits: %{},
        comments: %{1 => []},
        pr_commits: %{1 => []},
        statuses: %{"iniN" => []},
        files: %{"trying.tmp" => %{".appveyor.yml" => ""}}
      }
    })

    patch = new_patch(proj, 1, "N")
    Attemptor.handle_cast({:tried, patch.id, "test"}, proj.id)
    [status] = Repo.all(AttemptStatus)
    assert status.identifier == "continuous-integration/appveyor/branch"
  end

  test "infer from circle.yml", %{proj: proj} do
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{"master" => "ini", "trying" => "", "trying.tmp" => ""},
        commits: %{},
        comments: %{1 => []},
        pr_commits: %{1 => []},
        statuses: %{"iniN" => []},
        files: %{"trying.tmp" => %{"circle.yml" => ""}}
      }
    })

    patch = new_patch(proj, 1, "N")
    Attemptor.handle_cast({:tried, patch.id, "test"}, proj.id)
    [status] = Repo.all(AttemptStatus)
    assert status.identifier == "ci/circleci"
  end

  test "infer from jet-steps.yml", %{proj: proj} do
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{"master" => "ini", "trying" => "", "trying.tmp" => ""},
        commits: %{},
        comments: %{1 => []},
        pr_commits: %{1 => []},
        statuses: %{"iniN" => []},
        files: %{"trying.tmp" => %{"jet-steps.yml" => ""}}
      }
    })

    patch = new_patch(proj, 1, "N")
    Attemptor.handle_cast({:tried, patch.id, "test"}, proj.id)
    [status] = Repo.all(AttemptStatus)
    assert status.identifier == "continuous-integration/codeship"
  end

  test "infer from jet-steps.json", %{proj: proj} do
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{"master" => "ini", "trying" => "", "trying.tmp" => ""},
        commits: %{},
        comments: %{1 => []},
        pr_commits: %{1 => []},
        statuses: %{"iniN" => []},
        files: %{"trying.tmp" => %{"jet-steps.json" => ""}}
      }
    })

    patch = new_patch(proj, 1, "N")
    Attemptor.handle_cast({:tried, patch.id, "test"}, proj.id)
    [status] = Repo.all(AttemptStatus)
    assert status.identifier == "continuous-integration/codeship"
  end

  test "infer from codeship-steps.yml", %{proj: proj} do
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{"master" => "ini", "trying" => "", "trying.tmp" => ""},
        commits: %{},
        comments: %{1 => []},
        pr_commits: %{1 => []},
        statuses: %{"iniN" => []},
        files: %{"trying.tmp" => %{"codeship-steps.yml" => ""}}
      }
    })

    patch = new_patch(proj, 1, "N")
    Attemptor.handle_cast({:tried, patch.id, "test"}, proj.id)
    [status] = Repo.all(AttemptStatus)
    assert status.identifier == "continuous-integration/codeship"
  end

  test "infer from codeship-steps.json", %{proj: proj} do
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{"master" => "ini", "trying" => "", "trying.tmp" => ""},
        commits: %{},
        comments: %{1 => []},
        pr_commits: %{1 => []},
        statuses: %{"iniN" => []},
        files: %{"trying.tmp" => %{"codeship-steps.json" => ""}}
      }
    })

    patch = new_patch(proj, 1, "N")
    Attemptor.handle_cast({:tried, patch.id, "test"}, proj.id)
    [status] = Repo.all(AttemptStatus)
    assert status.identifier == "continuous-integration/codeship"
  end

  test "infer from .semaphore/semaphore.yml", %{proj: proj} do
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{"master" => "ini", "trying" => "", "trying.tmp" => ""},
        commits: %{},
        comments: %{1 => []},
        pr_commits: %{1 => []},
        statuses: %{"iniN" => []},
        files: %{"trying.tmp" => %{".semaphore/semaphore.yml" => ""}}
      }
    })

    patch = new_patch(proj, 1, "N")
    Attemptor.handle_cast({:tried, patch.id, "test"}, proj.id)
    [status] = Repo.all(AttemptStatus)
    assert status.identifier == "continuous-integration/semaphoreci"
  end

  test "full runthrough (with polling fallback)", %{proj: proj} do
    # Attempts start running immediately
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{"master" => "ini", "trying" => "", "trying.tmp" => ""},
        commits: %{},
        comments: %{1 => []},
        pr_commits: %{1 => []},
        statuses: %{"iniN" => []},
        files: %{"trying.tmp" => %{"bors.toml" => ~s/status = [ "ci" ]/}}
      }
    })

    patch = new_patch(proj, 1, "N")
    commit_message = try_commit_message(patch, "try", "test")
    Attemptor.handle_cast({:tried, patch.id, "test"}, proj.id)

    assert GitHub.ServerMock.get_state() == %{
             {{:installation, 91}, 14} => %{
               branches: %{
                 "master" => "ini",
                 "trying" => "iniN"
               },
               commits: %{
                 "ini" => %{commit_message: "[ci skip][skip ci][skip netlify]", parents: ["ini"]},
                 "iniN" => %{commit_message: commit_message, parents: ["ini", "N"]}
               },
               comments: %{1 => []},
               pr_commits: %{1 => []},
               statuses: %{"iniN" => []},
               files: %{"trying.tmp" => %{"bors.toml" => ~s/status = [ "ci" ]/}}
             }
           }

    attempt = Repo.get_by!(Attempt, patch_id: patch.id)
    assert attempt.state == :running
    # Polling should not change that.
    Attemptor.handle_info(:poll, proj.id)

    assert GitHub.ServerMock.get_state() == %{
             {{:installation, 91}, 14} => %{
               branches: %{
                 "master" => "ini",
                 "trying" => "iniN"
               },
               commits: %{
                 "ini" => %{commit_message: "[ci skip][skip ci][skip netlify]", parents: ["ini"]},
                 "iniN" => %{commit_message: commit_message, parents: ["ini", "N"]}
               },
               comments: %{1 => []},
               pr_commits: %{1 => []},
               statuses: %{"iniN" => []},
               files: %{"trying.tmp" => %{"bors.toml" => ~s/status = [ "ci" ]/}}
             }
           }

    attempt = Repo.get_by!(Attempt, patch_id: patch.id)
    assert attempt.state == :running
    # Mark the CI as having finished.
    # At this point, just running should still do nothing.
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{
          "master" => "ini",
          "trying" => "iniN"
        },
        commits: %{
          "ini" => %{commit_message: "[ci skip][skip ci][skip netlify]", parents: ["ini"]},
          "iniN" => %{commit_message: commit_message, parents: ["ini", "N"]}
        },
        comments: %{1 => []},
        pr_commits: %{1 => []},
        statuses: %{"iniN" => [{"ci", :ok}]},
        files: %{"trying.tmp" => %{"bors.toml" => ~s/status = [ "ci" ]/}}
      }
    })

    Attemptor.handle_info(:poll, proj.id)
    attempt = Repo.get_by!(Attempt, patch_id: patch.id)
    assert attempt.state == :running

    assert GitHub.ServerMock.get_state() == %{
             {{:installation, 91}, 14} => %{
               branches: %{
                 "master" => "ini",
                 "trying" => "iniN"
               },
               commits: %{
                 "ini" => %{commit_message: "[ci skip][skip ci][skip netlify]", parents: ["ini"]},
                 "iniN" => %{commit_message: commit_message, parents: ["ini", "N"]}
               },
               comments: %{1 => []},
               pr_commits: %{1 => []},
               statuses: %{"iniN" => [{"ci", :ok}]},
               files: %{"trying.tmp" => %{"bors.toml" => ~s/status = [ "ci" ]/}}
             }
           }

    # Finally, an actual poll should finish it.
    attempt
    |> Attempt.changeset(%{last_polled: 0})
    |> Repo.update!()

    Attemptor.handle_info(:poll, proj.id)
    attempt = Repo.get_by!(Attempt, patch_id: patch.id)
    assert attempt.state == :ok

    assert GitHub.ServerMock.get_state() == %{
             {{:installation, 91}, 14} => %{
               branches: %{
                 "master" => "ini",
                 "trying" => "iniN"
               },
               commits: %{
                 "ini" => %{commit_message: "[ci skip][skip ci][skip netlify]", parents: ["ini"]},
                 "iniN" => %{commit_message: commit_message, parents: ["ini", "N"]}
               },
               comments: %{1 => ["## try\n\nBuild succeeded:\n  * ci"]},
               pr_commits: %{1 => []},
               statuses: %{"iniN" => [{"ci", :ok}]},
               files: %{"trying.tmp" => %{"bors.toml" => ~s/status = [ "ci" ]/}}
             }
           }
  end

  test "try commit message uses batcher formatting", %{proj: proj} do
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{"master" => "ini", "trying" => "", "trying.tmp" => ""},
        commits: %{},
        comments: %{1 => []},
        pr_commits: %{
          1 => [
            %GitHub.Commit{
              sha: "N",
              author_name: "Co Author",
              author_email: "co-author@example.com"
            }
          ]
        },
        statuses: %{"iniN" => []},
        files: %{"trying.tmp" => %{"bors.toml" => ~s/status = [ "ci" ]/}}
      }
    })

    author =
      %User{login: "patch-author", user_xref: 101}
      |> Repo.insert!()

    reviewer =
      %User{login: "reviewer", user_xref: 102}
      |> Repo.insert!()

    patch =
      %Patch{
        project_id: proj.id,
        pr_xref: 1,
        into_branch: "master",
        commit: "N",
        title: "Add feature",
        body: "Body line",
        author_id: author.id
      }
      |> Repo.insert!()

    Logging.log_cmd(patch, reviewer, {:try, "test"})
    Attemptor.handle_cast({:tried, patch.id, "test"}, proj.id)

    commit_message =
      GitHub.ServerMock.get_state()
      |> get_in([{{:installation, 91}, 14}, :commits, "iniN", :commit_message])

    assert String.starts_with?(commit_message, "Try #1:test")
    assert commit_message =~ "1: Add feature r=reviewer a=patch-author"
    assert commit_message =~ "Body line"
    assert commit_message =~ "Co-authored-by: Co Author <co-author@example.com>"
  end

  test "cancelling defuses polling", %{proj: proj} do
    # Attempts start running immediately
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{"master" => "ini", "trying" => "", "trying.tmp" => ""},
        commits: %{},
        comments: %{1 => []},
        pr_commits: %{1 => []},
        statuses: %{"iniN" => []},
        files: %{"trying.tmp" => %{"bors.toml" => ~s/status = [ "ci" ]/}}
      }
    })

    patch = new_patch(proj, 1, "N")
    commit_message = try_commit_message(patch, "try", "test")
    Attemptor.handle_cast({:tried, patch.id, "test"}, proj.id)

    assert GitHub.ServerMock.get_state() == %{
             {{:installation, 91}, 14} => %{
               branches: %{
                 "master" => "ini",
                 "trying" => "iniN"
               },
               commits: %{
                 "ini" => %{commit_message: "[ci skip][skip ci][skip netlify]", parents: ["ini"]},
                 "iniN" => %{commit_message: commit_message, parents: ["ini", "N"]}
               },
               comments: %{1 => []},
               pr_commits: %{1 => []},
               statuses: %{"iniN" => []},
               files: %{"trying.tmp" => %{"bors.toml" => ~s/status = [ "ci" ]/}}
             }
           }

    attempt = Repo.get_by!(Attempt, patch_id: patch.id)
    assert attempt.state == :running
    # Cancel.
    Attemptor.handle_cast({:cancel, patch.id}, proj.id)

    assert GitHub.ServerMock.get_state() == %{
             {{:installation, 91}, 14} => %{
               branches: %{
                 "master" => "ini",
                 "trying" => "iniN"
               },
               commits: %{
                 "ini" => %{commit_message: "[ci skip][skip ci][skip netlify]", parents: ["ini"]},
                 "iniN" => %{commit_message: commit_message, parents: ["ini", "N"]}
               },
               comments: %{1 => []},
               pr_commits: %{1 => []},
               statuses: %{"iniN" => []},
               files: %{"trying.tmp" => %{"bors.toml" => ~s/status = [ "ci" ]/}}
             }
           }

    attempt = Repo.get_by!(Attempt, patch_id: patch.id)
    assert attempt.state == :canceled
    # Mark the CI as having finished.
    # At this point, just running should still do nothing.
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{
          "master" => "ini",
          "trying" => "iniN"
        },
        commits: %{
          "ini" => %{commit_message: "[ci skip][skip ci][skip netlify]", parents: ["ini"]},
          "iniN" => %{commit_message: commit_message, parents: ["ini", "N"]}
        },
        comments: %{1 => []},
        pr_commits: %{1 => []},
        statuses: %{"iniN" => [{"ci", :ok}]},
        files: %{"trying.tmp" => %{"bors.toml" => ~s/status = [ "ci" ]/}}
      }
    })

    # Polling should not change the result after cancelling.
    attempt
    |> Attempt.changeset(%{last_polled: 0})
    |> Repo.update!()

    Attemptor.handle_info(:poll, proj.id)
    attempt = Repo.get_by!(Attempt, patch_id: patch.id)
    assert attempt.state == :canceled

    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{
          "master" => "ini",
          "trying" => "iniN"
        },
        commits: %{
          "ini" => %{commit_message: "[ci skip][skip ci][skip netlify]", parents: ["ini"]},
          "iniN" => %{commit_message: commit_message, parents: ["ini", "N"]}
        },
        comments: %{1 => []},
        pr_commits: %{1 => []},
        statuses: %{"iniN" => [{"ci", :ok}]},
        files: %{"trying.tmp" => %{"bors.toml" => ~s/status = [ "ci" ]/}}
      }
    })
  end

  test "full runthrough (with wildcard)", %{proj: proj} do
    # Attempts start running immediately
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{"master" => "ini", "trying" => "", "trying.tmp" => ""},
        commits: %{},
        comments: %{1 => []},
        pr_commits: %{1 => []},
        statuses: %{"iniN" => []},
        files: %{"trying.tmp" => %{"bors.toml" => ~s/status = [ "c%" ]/}}
      }
    })

    patch = new_patch(proj, 1, "N")
    commit_message = try_commit_message(patch, "try", "test")
    Attemptor.handle_cast({:tried, patch.id, "test"}, proj.id)

    assert GitHub.ServerMock.get_state() == %{
             {{:installation, 91}, 14} => %{
               branches: %{
                 "master" => "ini",
                 "trying" => "iniN"
               },
               commits: %{
                 "ini" => %{commit_message: "[ci skip][skip ci][skip netlify]", parents: ["ini"]},
                 "iniN" => %{commit_message: commit_message, parents: ["ini", "N"]}
               },
               comments: %{1 => []},
               pr_commits: %{1 => []},
               statuses: %{"iniN" => []},
               files: %{"trying.tmp" => %{"bors.toml" => ~s/status = [ "c%" ]/}}
             }
           }

    attempt = Repo.get_by!(Attempt, patch_id: patch.id)
    assert attempt.state == :running
    # Polling should not change that.
    Attemptor.handle_info(:poll, proj.id)

    assert GitHub.ServerMock.get_state() == %{
             {{:installation, 91}, 14} => %{
               branches: %{
                 "master" => "ini",
                 "trying" => "iniN"
               },
               commits: %{
                 "ini" => %{commit_message: "[ci skip][skip ci][skip netlify]", parents: ["ini"]},
                 "iniN" => %{commit_message: commit_message, parents: ["ini", "N"]}
               },
               comments: %{1 => []},
               pr_commits: %{1 => []},
               statuses: %{"iniN" => []},
               files: %{"trying.tmp" => %{"bors.toml" => ~s/status = [ "c%" ]/}}
             }
           }

    attempt = Repo.get_by!(Attempt, patch_id: patch.id)
    assert attempt.state == :running
    # Mark the CI as having finished.
    # At this point, just running should still do nothing.
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{
          "master" => "ini",
          "trying" => "iniN"
        },
        commits: %{
          "ini" => %{commit_message: "[ci skip][skip ci][skip netlify]", parents: ["ini"]},
          "iniN" => %{commit_message: commit_message, parents: ["ini", "N"]}
        },
        comments: %{1 => []},
        pr_commits: %{1 => []},
        statuses: %{"iniN" => [{"ci", :ok}]},
        files: %{"trying.tmp" => %{"bors.toml" => ~s/status = [ "c%" ]/}}
      }
    })

    Attemptor.handle_info(:poll, proj.id)
    attempt = Repo.get_by!(Attempt, patch_id: patch.id)
    assert attempt.state == :running

    assert GitHub.ServerMock.get_state() == %{
             {{:installation, 91}, 14} => %{
               branches: %{
                 "master" => "ini",
                 "trying" => "iniN"
               },
               commits: %{
                 "ini" => %{commit_message: "[ci skip][skip ci][skip netlify]", parents: ["ini"]},
                 "iniN" => %{commit_message: commit_message, parents: ["ini", "N"]}
               },
               comments: %{1 => []},
               pr_commits: %{1 => []},
               statuses: %{"iniN" => [{"ci", :ok}]},
               files: %{"trying.tmp" => %{"bors.toml" => ~s/status = [ "c%" ]/}}
             }
           }

    # Finally, an actual poll should finish it.
    attempt
    |> Attempt.changeset(%{last_polled: 0})
    |> Repo.update!()

    Attemptor.handle_info(:poll, proj.id)
    attempt = Repo.get_by!(Attempt, patch_id: patch.id)
    assert attempt.state == :ok

    assert GitHub.ServerMock.get_state() == %{
             {{:installation, 91}, 14} => %{
               branches: %{
                 "master" => "ini",
                 "trying" => "iniN"
               },
               commits: %{
                 "ini" => %{commit_message: "[ci skip][skip ci][skip netlify]", parents: ["ini"]},
                 "iniN" => %{commit_message: commit_message, parents: ["ini", "N"]}
               },
               comments: %{1 => ["## try\n\nBuild succeeded:\n  * ci"]},
               pr_commits: %{1 => []},
               statuses: %{"iniN" => [{"ci", :ok}]},
               files: %{"trying.tmp" => %{"bors.toml" => ~s/status = [ "c%" ]/}}
             }
           }
  end

  test "posts message if patch has ci skip", %{proj: proj} do
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{"master" => "ini", "trying" => "", "trying.tmp" => ""},
        commits: %{},
        comments: %{1 => []},
        pr_commits: %{1 => []},
        statuses: %{"iniN" => []},
        files: %{"trying.tmp" => %{"circle.yml" => ""}}
      }
    })

    patch =
      %Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "N",
        title: "[ci skip][skip ci][skip netlify]",
        into_branch: "master"
      }
      |> Repo.insert!()

    Attemptor.handle_cast({:tried, patch.id, "test"}, proj.id)
    state = GitHub.ServerMock.get_state()
    comments = state[{{:installation, 91}, 14}].comments[1]

    assert comments == [
             "## try\n\nHas [ci skip][skip ci][skip netlify], bors build will time out"
           ]
  end
end
