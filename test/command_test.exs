defmodule BorsNG.CommandTest do
  use ExUnit.Case
  use ExUnit.Parameterized

  alias BorsNG.Command
  alias BorsNG.Database.Context.Logging
  alias BorsNG.Database.Installation
  alias BorsNG.Database.Project
  alias BorsNG.Database.Repo
  alias BorsNG.GitHub

  doctest BorsNG.Command

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    inst =
      %Installation{installation_xref: 91}
      |> Repo.insert!()

    proj =
      %Project{
        installation_id: inst.id,
        repo_xref: 14,
        staging_branch: "staging"
      }
      |> Repo.insert!()

    {:ok, inst: inst, proj: proj}
  end

  # bors.toml fixture with a delegation default. Tests that exercise the
  # no-`for=` path inject this into the ServerMock's `files` map so the
  # delegate command can read the default from the PR's base branch.
  defp delegation_toml(seconds \\ 24 * 60 * 60) do
    ~s(status = ["ci"]\n[delegation]\ndefault_expiry_sec = #{seconds}\n)
  end

  test "reject the empty string" do
    assert [] == Command.parse("")
    assert [] == Command.parse(nil)
  end

  test "reject strings without the phrase" do
    assert [] == Command.parse("doink!")
  end

  test "reject a string that merely starts out like a command" do
    assert [] == Command.parse("bors doink")
  end

  test "accept the bare command" do
    assert [{:try, ""}] == Command.parse("bors try")
    assert [:activate] == Command.parse("bors r+")
    assert [:activate] == Command.parse("bors merge")
    assert [:deactivate] == Command.parse("bors r-")
    assert [:deactivate] == Command.parse("bors merge-")
    assert [:deactivate] == Command.parse("bors cancel")
  end

  test "accept the case insensitive bare command" do
    assert [{:try, ""}] == Command.parse("Bors try")
    assert [:activate] == Command.parse("Bors r+")
    assert [:activate] == Command.parse("Bors merge")
    assert [:deactivate] == Command.parse("Bors r-")
    assert [:deactivate] == Command.parse("Bors merge-")
    assert [:deactivate] == Command.parse("Bors cancel")
  end

  test "accept single patch" do
    assert [{:set_is_single, true}, :activate] == Command.parse("bors r+ single on")
    assert [{:set_is_single, false}, :activate] == Command.parse("bors r+ single off")
    assert [{:set_is_single, true}] == Command.parse("bors single on")
    assert [{:set_is_single, false}] == Command.parse("bors single off")
  end

  test "do not parse single patch after try command" do
    assert [{:try, " single on"}] == Command.parse("bors try single on")
    assert [{:try, " single screwy"}] == Command.parse("bors try single screwy")
  end

  test "accept priority" do
    assert [{:set_priority, 1}, :activate] == Command.parse("bors r+ p=1")
    assert [{:set_priority, 1}, :activate] == Command.parse("bors merge p=1")

    assert [{:set_priority, 1}, {:activate_by, "me"}] ==
             Command.parse("bors r=me p=1")

    assert [{:set_priority, 1}, {:activate_by, "me"}] ==
             Command.parse("bors merge=me p=1")

    assert [{:set_priority, 1}] == Command.parse("bors p=1")
  end

  test "accept priority case insensitive" do
    assert [{:set_priority, 1}, :activate] == Command.parse("Bors r+ p=1")
    assert [{:set_priority, 1}, :activate] == Command.parse("Bors merge p=1")

    assert [{:set_priority, 1}, {:activate_by, "me"}] ==
             Command.parse("Bors r=me p=1")

    assert [{:set_priority, 1}, {:activate_by, "me"}] ==
             Command.parse("Bors merge=me p=1")

    assert [{:set_priority, 1}] == Command.parse("Bors p=1")
  end

  test "accept negative priority" do
    assert [{:set_priority, -1}, :activate] == Command.parse("bors r+ p=-1")
    assert [{:set_priority, -1}, :activate] == Command.parse("bors merge p=-1")

    assert [{:set_priority, -1}, {:activate_by, "me"}] ==
             Command.parse("bors r=me p=-1")

    assert [{:set_priority, -1}, {:activate_by, "me"}] ==
             Command.parse("bors merge=me p=-1")

    assert [{:set_priority, -1}] == Command.parse("bors p=-1")
  end

  test "do not parse priority after try command" do
    assert [{:try, " p=1"}] == Command.parse("bors try p=1")
    assert [{:try, " p=screwy"}] == Command.parse("bors try p=screwy")
  end

  test "accept command with colon after it" do
    assert [{:try, ""}] == Command.parse("bors: try")
    assert [:activate] == Command.parse("bors: r+")
    assert [:activate] == Command.parse("bors: merge")
    assert [:deactivate] == Command.parse("bors: r-")
    assert [:deactivate] == Command.parse("bors: merge-")
    assert [:deactivate] == Command.parse("bors: cancel")
  end

  test "accept the try command with an argument" do
    assert [{:try, "-layout"}] == Command.parse("bors try-layout")
  end

  test "accept more than one command in a single comment" do
    expected_1 = [
      {:try, ""},
      :deactivate
    ]

    command_1 = """
    bors try
    bors r-
    """

    assert expected_1 == Command.parse(command_1)

    expected_2 = [
      {:try, ""},
      :deactivate
    ]

    command_2 = """
    bors try
    bors merge-
    """

    assert expected_2 == Command.parse(command_2)
  end

  test "accept the try command with more argumentation" do
    assert [{:try, " --layout --script"}] ==
             Command.parse("bors try --layout --script")
  end

  test "do not accept the command with a prefix" do
    assert [] == Command.parse("Xbors tryZ")
  end

  test "accept bros with a valid command" do
    assert [:bros] == Command.parse("bros ping")
  end

  test "do not accept any bros without a valid command" do
    assert [] == Command.parse("bros talk")
  end

  test "command permissions" do
    assert :none == Command.required_permission_level([])
    assert :none == Command.required_permission_level([:ping])
    assert :member == Command.required_permission_level([{:try, ""}])
    assert :member == Command.required_permission_level([{:try, ""}, :ping])

    assert :reviewer ==
             Command.required_permission_level([:approve, {:try, ""}])

    assert :reviewer ==
             Command.required_permission_level([{:try, ""}, :approve])
  end

  test "running ping command should post comment", %{proj: proj} do
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{},
        comments: %{1 => []},
        statuses: %{}
      }
    })

    c = %Command{
      project: proj,
      commenter: nil,
      comment: "bors ping",
      pr_xref: 1
    }

    Command.run(c, :ping)

    assert GitHub.ServerMock.get_state() == %{
             {{:installation, 91}, 14} => %{
               branches: %{},
               comments: %{1 => ["pong"]},
               statuses: %{}
             }
           }
  end

  test "running ping when commenter is not reviewer", %{proj: proj} do
    pr = %BorsNG.GitHub.Pr{
      number: 1,
      title: "Test",
      body: "Mess",
      state: :open,
      base_ref: "master",
      head_sha: "00000001",
      head_ref: "update",
      base_repo_id: 13,
      head_repo_id: 13,
      user: %{
        id: 1,
        login: "user"
      }
    }

    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{},
        comments: %{1 => ["bors ping"]},
        statuses: %{},
        pulls: %{
          1 => pr
        }
      }
    })

    {:ok, _} =
      Repo.insert(%BorsNG.Database.Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "N",
        into_branch: "master"
      })

    {:ok, commenter} =
      Repo.insert(%BorsNG.Database.User{
        user_xref: 1,
        login: "commenter"
      })

    c = %Command{
      project: proj,
      commenter: commenter,
      comment: "bors ping",
      pr_xref: 1
    }

    Command.run(c)
  end

  test_with_params "delegate+ delegates to patch creator", %{proj: proj}, fn delegate_command ->
    pr = %BorsNG.GitHub.Pr{
      number: 1,
      title: "Test",
      body: "Mess",
      state: :open,
      base_ref: "master",
      head_sha: "00000001",
      head_ref: "update",
      base_repo_id: 13,
      head_repo_id: 13,
      user: %{
        id: 2,
        login: "pr_author"
      }
    }

    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{},
        comments: %{1 => ["bors #{delegate_command}"]},
        statuses: %{},
        files: %{"master" => %{"bors.toml" => delegation_toml()}},
        pulls: %{
          1 => pr
        }
      }
    })

    {:ok, user} =
      Repo.insert(%BorsNG.Database.User{
        user_xref: 1,
        is_admin: true,
        login: "repo_owner"
      })

    {:ok, _} =
      Repo.insert(%BorsNG.Database.Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "N",
        into_branch: "master"
      })

    Repo.insert(%BorsNG.Database.LinkUserProject{
      user_id: user.id,
      project_id: proj.id
    })

    c = %Command{
      project: proj,
      commenter: user,
      comment: "bors #{delegate_command}",
      pr_xref: 1
    }

    Command.run(c)

    [p] = Repo.all(BorsNG.Database.UserPatchDelegation)
    p = Repo.preload(p, :user)
    assert p.user.user_xref == 2
  end do
    [
      {"delegate+"},
      {"d+"}
    ]
  end

  test "explicit-duration delegate also backfills a lingering forever-delegation",
       %{proj: proj} do
    # A pre-existing no-expiry ("forever") delegation should be stamped with the
    # bors.toml default whenever someone delegates on the patch — even when the
    # current command carries its own explicit `for=` duration. This pins that
    # reconcile_default_expiry runs on the explicit-duration path, not only the
    # no-`for=` path it used to be limited to.
    pr = %BorsNG.GitHub.Pr{
      number: 1,
      title: "Test",
      body: "Mess",
      state: :open,
      base_ref: "master",
      head_sha: "00000001",
      head_ref: "update",
      base_repo_id: 13,
      head_repo_id: 13,
      user: %{id: 2, login: "pr_author"}
    }

    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{},
        comments: %{1 => ["bors delegate+ for=2w"]},
        statuses: %{},
        files: %{"master" => %{"bors.toml" => delegation_toml()}},
        pulls: %{1 => pr}
      }
    })

    {:ok, owner} =
      Repo.insert(%BorsNG.Database.User{user_xref: 1, is_admin: true, login: "repo_owner"})

    {:ok, patch} =
      Repo.insert(%BorsNG.Database.Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "N",
        into_branch: "master"
      })

    Repo.insert(%BorsNG.Database.LinkUserProject{user_id: owner.id, project_id: proj.id})

    # A lingering forever-delegation (no expiry) for a different user.
    {:ok, bob} = Repo.insert(%BorsNG.Database.User{user_xref: 99, login: "bob"})

    BorsNG.Database.Context.Permission.delegate(bob, patch, delegated_at_commit: "old")

    c = %Command{
      project: proj,
      commenter: owner,
      comment: "bors delegate+ for=2w",
      pr_xref: 1
    }

    Command.run(c)

    bob_delegation =
      Repo.get_by!(BorsNG.Database.UserPatchDelegation, user_id: bob.id, patch_id: patch.id)

    # Backfilled from forever to the toml default, despite the command's
    # explicit for=2w applying only to the new delegatee.
    refute is_nil(bob_delegation.expires_at)
  end

  test_with_params "delegate= delegates properly", %{proj: proj}, fn delegate_command ->
    pr = %BorsNG.GitHub.Pr{
      number: 1,
      title: "Test",
      body: "Mess",
      state: :open,
      base_ref: "master",
      head_sha: "00000001",
      head_ref: "update",
      base_repo_id: 13,
      head_repo_id: 13,
      user: %{
        id: 2,
        login: "pr_author"
      }
    }

    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{},
        comments: %{1 => ["bors #{delegate_command}pr_author,reviewer"]},
        statuses: %{},
        files: %{"master" => %{"bors.toml" => delegation_toml()}},
        pulls: %{
          1 => pr
        }
      }
    })

    {:ok, user} =
      Repo.insert(%BorsNG.Database.User{
        user_xref: 1,
        is_admin: true,
        login: "repo_owner"
      })

    {:ok, _} =
      Repo.insert(%BorsNG.Database.User{
        user_xref: 3,
        is_admin: false,
        login: "reviewer"
      })

    {:ok, _} =
      Repo.insert(%BorsNG.Database.Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "N",
        into_branch: "master"
      })

    Repo.insert(%BorsNG.Database.LinkUserProject{
      user_id: user.id,
      project_id: proj.id
    })

    c = %Command{
      project: proj,
      commenter: user,
      comment: "bors #{delegate_command}pr_author,reviewer",
      pr_xref: 1
    }

    Command.run(c)

    [p1, p2] = Repo.all(BorsNG.Database.UserPatchDelegation)
    p1 = Repo.preload(p1, :user)
    assert p1.user.user_xref == 2
    p2 = Repo.preload(p2, :user)
    assert p2.user.user_xref == 3
  end do
    [
      {"delegate+="},
      {"delegate="},
      {"d+="},
      {"d="}
    ]
  end

  test_with_params "delegate- removes all delegations", %{proj: proj}, fn undelegate_command ->
    pr = %BorsNG.GitHub.Pr{
      number: 1,
      title: "Test",
      body: "Mess",
      state: :open,
      base_ref: "master",
      head_sha: "00000001",
      head_ref: "update",
      base_repo_id: 13,
      head_repo_id: 13,
      user: %{
        id: 2,
        login: "pr_author"
      }
    }

    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{},
        comments: %{
          1 => ["bors d+"],
          2 => ["bors d=reviewer"],
          3 => ["bors #{undelegate_command}"]
        },
        statuses: %{},
        files: %{"master" => %{"bors.toml" => delegation_toml()}},
        pulls: %{
          1 => pr
        }
      }
    })

    {:ok, user} =
      Repo.insert(%BorsNG.Database.User{
        user_xref: 1,
        is_admin: true,
        login: "repo_owner"
      })

    {:ok, _} =
      Repo.insert(%BorsNG.Database.User{
        user_xref: 3,
        is_admin: false,
        login: "reviewer"
      })

    {:ok, _} =
      Repo.insert(%BorsNG.Database.Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "N",
        into_branch: "master"
      })

    Repo.insert(%BorsNG.Database.LinkUserProject{
      user_id: user.id,
      project_id: proj.id
    })

    c1 = %Command{
      project: proj,
      commenter: user,
      comment: "bors d+",
      pr_xref: 1
    }

    Command.run(c1)

    c2 = %Command{
      project: proj,
      commenter: user,
      comment: "bors d=reviewer",
      pr_xref: 1
    }

    Command.run(c2)

    [p1, p2] = Repo.all(BorsNG.Database.UserPatchDelegation)
    p1 = Repo.preload(p1, :user)
    assert p1.user.user_xref == 2
    p2 = Repo.preload(p2, :user)
    assert p2.user.user_xref == 3

    c3 = %Command{
      project: proj,
      commenter: user,
      comment: "bors #{undelegate_command}",
      pr_xref: 1
    }

    Command.run(c3)

    [] = Repo.all(BorsNG.Database.UserPatchDelegation)
  end do
    [
      {"delegate-"},
      {"d-"}
    ]
  end

  test_with_params "delegate-= removes delegations properly",
                   %{proj: proj},
                   fn undelegate_command ->
                     pr = %BorsNG.GitHub.Pr{
                       number: 1,
                       title: "Test",
                       body: "Mess",
                       state: :open,
                       base_ref: "master",
                       head_sha: "00000001",
                       head_ref: "update",
                       base_repo_id: 13,
                       head_repo_id: 13,
                       user: %{
                         id: 2,
                         login: "pr_author"
                       }
                     }

                     GitHub.ServerMock.put_state(%{
                       {{:installation, 91}, 14} => %{
                         branches: %{},
                         comments: %{
                           1 => ["bors d+"],
                           2 => ["bors d=reviewer"],
                           3 => ["bors #{undelegate_command}"]
                         },
                         statuses: %{},
                         files: %{"master" => %{"bors.toml" => delegation_toml()}},
                         pulls: %{
                           1 => pr
                         }
                       }
                     })

                     {:ok, user} =
                       Repo.insert(%BorsNG.Database.User{
                         user_xref: 1,
                         is_admin: true,
                         login: "repo_owner"
                       })

                     {:ok, _} =
                       Repo.insert(%BorsNG.Database.User{
                         user_xref: 3,
                         is_admin: false,
                         login: "reviewer1"
                       })

                     {:ok, _} =
                       Repo.insert(%BorsNG.Database.User{
                         user_xref: 4,
                         is_admin: false,
                         login: "reviewer2"
                       })

                     {:ok, _} =
                       Repo.insert(%BorsNG.Database.Patch{
                         project_id: proj.id,
                         pr_xref: 1,
                         commit: "N",
                         into_branch: "master"
                       })

                     Repo.insert(%BorsNG.Database.LinkUserProject{
                       user_id: user.id,
                       project_id: proj.id
                     })

                     c1 = %Command{
                       project: proj,
                       commenter: user,
                       comment: "bors d+",
                       pr_xref: 1
                     }

                     Command.run(c1)

                     c2 = %Command{
                       project: proj,
                       commenter: user,
                       comment: "bors d=reviewer1,reviewer2",
                       pr_xref: 1
                     }

                     Command.run(c2)

                     [p1, p2, p3] = Repo.all(BorsNG.Database.UserPatchDelegation)
                     p1 = Repo.preload(p1, :user)
                     assert p1.user.user_xref == 2
                     p2 = Repo.preload(p2, :user)
                     assert p2.user.user_xref == 3
                     p3 = Repo.preload(p3, :user)
                     assert p3.user.user_xref == 4

                     c3 = %Command{
                       project: proj,
                       commenter: user,
                       comment: "bors #{undelegate_command}pr_author,reviewer2",
                       pr_xref: 1
                     }

                     Command.run(c3)

                     [p4] = Repo.all(BorsNG.Database.UserPatchDelegation)
                     p4 = Repo.preload(p4, :user)
                     assert p4.user.user_xref == 3
                   end do
    [
      {"delegate-="},
      {"d-="}
    ]
  end

  test "retry fails for non-members", %{proj: proj} do
    pr = %BorsNG.GitHub.Pr{
      number: 1,
      title: "Test",
      body: "Mess",
      state: :open,
      base_ref: "master",
      head_sha: "00000001",
      head_ref: "update",
      base_repo_id: 13,
      head_repo_id: 13,
      user: %{
        id: 2,
        login: "pr_author"
      }
    }

    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{},
        comments: %{1 => []},
        statuses: %{},
        pulls: %{
          1 => pr
        }
      }
    })

    {:ok, commenter} =
      Repo.insert(%BorsNG.Database.User{
        user_xref: 1,
        login: "commenter"
      })

    {:ok, patch} =
      Repo.insert(%BorsNG.Database.Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "N",
        into_branch: "master"
      })

    c = %Command{
      project: proj,
      commenter: commenter,
      comment: "bors ping",
      patch: patch,
      pr_xref: 1
    }

    Command.run(c)

    c = %Command{
      project: proj,
      commenter: commenter,
      comment: "bors retry",
      patch: patch,
      pr_xref: 1
    }

    Command.run(c)

    assert %{
             {{:installation, 91}, 14} => %{
               comments: %{1 => [":lock:" <> _, _]}
             }
           } = GitHub.ServerMock.get_state()
  end

  test "retry does nothing useful after ping and posts nothing to retry message", %{proj: proj} do
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{},
        comments: %{1 => []},
        statuses: %{}
      }
    })

    {:ok, commenter} =
      Repo.insert(%BorsNG.Database.User{
        user_xref: 1,
        login: "commenter"
      })

    {:ok, patch} =
      Repo.insert(%BorsNG.Database.Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "N",
        into_branch: "master"
      })

    {:ok, _} =
      Repo.insert(%BorsNG.Database.LinkMemberProject{
        user_id: commenter.id,
        project_id: proj.id
      })

    Command.run(%Command{
      project: proj,
      commenter: commenter,
      comment: "bors ping",
      patch: patch,
      pr_xref: 1
    })

    Command.run(%Command{
      project: proj,
      commenter: commenter,
      comment: "bors retry",
      patch: patch,
      pr_xref: 1
    })

    assert %{
             {{:installation, 91}, 14} => %{
               comments: %{1 => ["Nothing to retry.", "pong"]}
             }
           } = GitHub.ServerMock.get_state()
  end

  test "retry does nothing after deactivate and posts nothing to retry message", %{proj: proj} do
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{},
        comments: %{1 => []},
        statuses: %{}
      }
    })

    {:ok, commenter} =
      Repo.insert(%BorsNG.Database.User{
        user_xref: 1,
        login: "commenter"
      })

    {:ok, patch} =
      Repo.insert(%BorsNG.Database.Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "N",
        into_branch: "master"
      })

    {:ok, _} =
      Repo.insert(%BorsNG.Database.LinkMemberProject{
        user_id: commenter.id,
        project_id: proj.id
      })

    # Seed command history directly to avoid permission checks and worker GenServers
    Logging.log_cmd(patch, commenter, :activate)
    Logging.log_cmd(patch, commenter, :deactivate)

    Command.run(%Command{
      project: proj,
      commenter: commenter,
      comment: "bors retry",
      patch: patch,
      pr_xref: 1
    })

    assert %{
             {{:installation, 91}, 14} => %{
               comments: %{1 => ["Nothing to retry."]}
             }
           } = GitHub.ServerMock.get_state()
  end

  test "run ping does not require a GitHub PR fetch", %{proj: proj} do
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{},
        comments: %{1 => []},
        statuses: %{}
      }
    })

    c = %Command{
      project: proj,
      commenter: nil,
      comment: "bors ping",
      pr_xref: 1
    }

    Command.run(c)

    assert %{
             {{:installation, 91}, 14} => %{
               comments: %{1 => ["pong"]}
             }
           } = GitHub.ServerMock.get_state()
  end

  test "retry posts nothing-to-retry when patch exists but no replayable history", %{proj: proj} do
    # Verifies retry handles the case where the patch is in the DB (but the
    # GitHub PR is unavailable) and there is no replayable prior command.
    # This is distinct from the next test where no patch exists at all.
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{},
        comments: %{1 => []},
        statuses: %{}
      }
    })

    {:ok, commenter} =
      Repo.insert(%BorsNG.Database.User{
        user_xref: 1,
        login: "commenter"
      })

    {:ok, patch} =
      Repo.insert(%BorsNG.Database.Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "N",
        into_branch: "master"
      })

    {:ok, _} =
      Repo.insert(%BorsNG.Database.LinkMemberProject{
        user_id: commenter.id,
        project_id: proj.id
      })

    Command.run(%Command{
      project: proj,
      commenter: commenter,
      comment: "bors retry",
      patch: patch,
      pr_xref: 1
    })

    assert %{
             {{:installation, 91}, 14} => %{
               comments: %{1 => ["Nothing to retry."]}
             }
           } = GitHub.ServerMock.get_state()
  end

  test "member command exits cleanly when patch and GitHub PR are unavailable", %{proj: proj} do
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{},
        comments: %{1 => []},
        statuses: %{}
      }
    })

    {:ok, commenter} =
      Repo.insert(%BorsNG.Database.User{
        user_xref: 1,
        login: "commenter"
      })

    {:ok, _} =
      Repo.insert(%BorsNG.Database.LinkMemberProject{
        user_id: commenter.id,
        project_id: proj.id
      })

    Command.run(%Command{
      project: proj,
      commenter: commenter,
      comment: "bors retry",
      pr_xref: 1
    })

    assert %{
             {{:installation, 91}, 14} => %{
               comments: %{1 => []}
             }
           } = GitHub.ServerMock.get_state()
  end

  test "running bros command should post brofist", %{proj: proj} do
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{},
        comments: %{1 => []},
        statuses: %{}
      }
    })

    c = %Command{
      project: proj,
      commenter: nil,
      comment: "bros ping",
      pr_xref: 1
    }

    Command.run(c, :bros)

    assert GitHub.ServerMock.get_state() == %{
             {{:installation, 91}, 14} => %{
               branches: %{},
               comments: %{1 => ["👊"]},
               statuses: %{}
             }
           }
  end

  test "command trigger is dynamically set by env" do
    old_env = System.get_env("COMMAND_TRIGGER")
    System.put_env("COMMAND_TRIGGER", "popo")

    assert [] == Command.parse("bors try")
    assert [] == Command.parse("bors r+")
    assert [] == Command.parse("bors merge")
    assert [] == Command.parse("bors r-")
    assert [] == Command.parse("bors merge-")
    assert [] == Command.parse("bors cancel")

    assert [{:try, ""}] == Command.parse("popo try")
    assert [:activate] == Command.parse("popo r+")
    assert [:activate] == Command.parse("popo merge")
    assert [:deactivate] == Command.parse("popo r-")
    assert [:deactivate] == Command.parse("popo merge-")
    assert [:deactivate] == Command.parse("popo cancel")

    if old_env do
      System.put_env("COMMAND_TRIGGER", old_env)
    else
      System.delete_env("COMMAND_TRIGGER")
    end
  end

  describe "delegation for= duration parsing" do
    test "delegate+ accepts for= duration" do
      assert [{:delegate, 86_400}] == Command.parse("bors delegate+ for=24h")
      assert [{:delegate, 86_400}] == Command.parse("bors d+ for=24h")
      assert [{:delegate, 604_800}] == Command.parse("bors delegate+ for=7d")
      assert [{:delegate, 1_209_600}] == Command.parse("bors d+ for=2w")
    end

    test "delegate+ without for= remains the bare command" do
      assert [:delegate] == Command.parse("bors delegate+")
      assert [:delegate] == Command.parse("bors d+")
    end

    test "delegate= accepts for= duration after username list" do
      assert [{:delegate_to, "alice", 86_400}] ==
               Command.parse("bors delegate=alice for=24h")

      assert [
               {:delegate_to, "alice", 86_400},
               {:delegate_to, "bob", 86_400}
             ] == Command.parse("bors d=alice,bob for=24h")
    end

    test "delegate= without for= preserves the original 2-tuple shape" do
      assert [{:delegate_to, "alice"}] == Command.parse("bors delegate=alice")

      assert [{:delegate_to, "alice"}, {:delegate_to, "bob"}] ==
               Command.parse("bors d=alice,bob")
    end

    test "rejects out-of-range or malformed durations" do
      # Too long (>90d cap)
      assert [:delegate] == Command.parse("bors delegate+ for=100d")
      # Zero
      assert [:delegate] == Command.parse("bors delegate+ for=0h")
      # Unrecognized unit
      assert [:delegate] == Command.parse("bors delegate+ for=24m")
      # Garbage
      assert [:delegate] == Command.parse("bors delegate+ for=foo")
    end

    test "for= token may appear anywhere in the argument list" do
      # for= in the middle
      assert [
               {:delegate_to, "alice", 86_400},
               {:delegate_to, "bob", 86_400}
             ] == Command.parse("bors d=alice for=24h bob")

      # for= at the very front
      assert [
               {:delegate_to, "alice", 86_400},
               {:delegate_to, "bob", 86_400}
             ] == Command.parse("bors d=for=24h alice,bob")

      # Mixed comma/space separators with for= mid-list
      assert [
               {:delegate_to, "alice", 86_400},
               {:delegate_to, "bob", 86_400}
             ] == Command.parse("bors d=alice,for=24h,bob")
    end

    test "with multiple for= tokens, the last valid one wins" do
      assert [{:delegate_to, "alice", 604_800}] ==
               Command.parse("bors d=alice for=24h for=7d")

      # Last malformed → falls back to earlier valid
      assert [{:delegate_to, "alice", 86_400}] ==
               Command.parse("bors d=alice for=24h for=garbage")
    end
  end

  test "delegate+ refuses when no for= and no bors.toml default", %{inst: inst} do
    proj_no_default =
      %Project{
        installation_id: inst.id,
        repo_xref: 15,
        staging_branch: "staging"
      }
      |> Repo.insert!()

    pr = %BorsNG.GitHub.Pr{
      number: 1,
      title: "Test",
      body: "Mess",
      state: :open,
      base_ref: "master",
      head_sha: "00000001",
      head_ref: "update",
      base_repo_id: 13,
      head_repo_id: 13,
      user: %{id: 2, login: "pr_author"}
    }

    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 15} => %{
        branches: %{},
        comments: %{1 => ["bors delegate+"]},
        statuses: %{},
        pulls: %{1 => pr}
      }
    })

    {:ok, user} =
      Repo.insert(%BorsNG.Database.User{user_xref: 1, is_admin: true, login: "owner"})

    {:ok, _} =
      Repo.insert(%BorsNG.Database.Patch{
        project_id: proj_no_default.id,
        pr_xref: 1,
        commit: "N",
        into_branch: "master"
      })

    Repo.insert(%BorsNG.Database.LinkUserProject{user_id: user.id, project_id: proj_no_default.id})

    c = %Command{
      project: proj_no_default,
      commenter: user,
      comment: "bors delegate+",
      pr_xref: 1
    }

    Command.run(c)

    assert [] == Repo.all(BorsNG.Database.UserPatchDelegation)
    state = GitHub.ServerMock.get_state()
    comments = get_in(state, [{{:installation, 91}, 15}, :comments, 1])

    assert Enum.any?(
             comments,
             &String.contains?(&1, "Delegation requires an explicit expiration")
           )
  end

  test "delegate+ uses bors.toml default when no for= given", %{proj: proj} do
    pr = %BorsNG.GitHub.Pr{
      number: 1,
      title: "Test",
      body: "Mess",
      state: :open,
      base_ref: "master",
      head_sha: "00000001",
      head_ref: "update",
      base_repo_id: 13,
      head_repo_id: 13,
      user: %{id: 2, login: "pr_author"}
    }

    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{},
        comments: %{1 => ["bors delegate+"]},
        statuses: %{},
        files: %{"master" => %{"bors.toml" => delegation_toml()}},
        pulls: %{1 => pr}
      }
    })

    {:ok, user} =
      Repo.insert(%BorsNG.Database.User{user_xref: 1, is_admin: true, login: "owner"})

    {:ok, _} =
      Repo.insert(%BorsNG.Database.Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "headsha123",
        into_branch: "master"
      })

    Repo.insert(%BorsNG.Database.LinkUserProject{user_id: user.id, project_id: proj.id})

    c = %Command{
      project: proj,
      commenter: user,
      comment: "bors delegate+",
      pr_xref: 1
    }

    Command.run(c)

    [d] = Repo.all(BorsNG.Database.UserPatchDelegation)
    refute is_nil(d.expires_at)
    # Syncer.sync_patch overwrites patch.commit with the PR's head_sha during run.
    assert d.delegated_at_commit == "00000001"
  end

  test "delegate+ echoes invalidate_on_paths in the success comment", %{proj: proj} do
    pr = %BorsNG.GitHub.Pr{
      number: 1,
      title: "Test",
      body: "Mess",
      state: :open,
      base_ref: "master",
      head_sha: "00000001",
      head_ref: "update",
      base_repo_id: 13,
      head_repo_id: 13,
      user: %{id: 2, login: "pr_author"}
    }

    toml = ~s"""
    status = ["ci"]
    [delegation]
    default_expiry_sec = #{24 * 60 * 60}
    invalidate_on_paths = ["Cargo.toml", ".github/**"]
    """

    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{},
        comments: %{1 => ["bors delegate+"]},
        statuses: %{},
        files: %{"master" => %{"bors.toml" => toml}},
        pulls: %{1 => pr}
      }
    })

    {:ok, user} =
      Repo.insert(%BorsNG.Database.User{user_xref: 1, is_admin: true, login: "owner"})

    {:ok, _} =
      Repo.insert(%BorsNG.Database.Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "headsha123",
        into_branch: "master"
      })

    Repo.insert(%BorsNG.Database.LinkUserProject{user_id: user.id, project_id: proj.id})

    Command.run(%Command{
      project: proj,
      commenter: user,
      comment: "bors delegate+",
      pr_xref: 1
    })

    state = GitHub.ServerMock.get_state()
    comments = get_in(state, [{{:installation, 91}, 14}, :comments, 1])

    assert Enum.any?(comments, fn c ->
             String.contains?(c, "revoke this delegation") and
               String.contains?(c, "`Cargo.toml`") and
               String.contains?(c, "`.github/**`")
           end)
  end

  test "delegate+ omits the paths note when invalidate_on_paths is empty", %{proj: proj} do
    pr = %BorsNG.GitHub.Pr{
      number: 1,
      title: "Test",
      body: "Mess",
      state: :open,
      base_ref: "master",
      head_sha: "00000001",
      head_ref: "update",
      base_repo_id: 13,
      head_repo_id: 13,
      user: %{id: 2, login: "pr_author"}
    }

    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{},
        comments: %{1 => ["bors delegate+"]},
        statuses: %{},
        files: %{"master" => %{"bors.toml" => delegation_toml()}},
        pulls: %{1 => pr}
      }
    })

    {:ok, user} =
      Repo.insert(%BorsNG.Database.User{user_xref: 1, is_admin: true, login: "owner"})

    {:ok, _} =
      Repo.insert(%BorsNG.Database.Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "headsha123",
        into_branch: "master"
      })

    Repo.insert(%BorsNG.Database.LinkUserProject{user_id: user.id, project_id: proj.id})

    Command.run(%Command{
      project: proj,
      commenter: user,
      comment: "bors delegate+",
      pr_xref: 1
    })

    state = GitHub.ServerMock.get_state()
    comments = get_in(state, [{{:installation, 91}, 14}, :comments, 1])

    refute Enum.any?(comments, &String.contains?(&1, "revoke this delegation"))
  end

  test "delegate+ describes the delegated scope and the too-many-files caveat", %{proj: proj} do
    pr = %BorsNG.GitHub.Pr{
      number: 1,
      title: "Test",
      body: "Mess",
      state: :open,
      base_ref: "master",
      head_sha: "00000001",
      head_ref: "update",
      base_repo_id: 13,
      head_repo_id: 13,
      user: %{id: 2, login: "pr_author"}
    }

    toml = ~s"""
    status = ["ci"]
    [delegation]
    default_expiry_sec = #{24 * 60 * 60}
    restrict_to_paths = ["src/**"]
    """

    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{},
        comments: %{1 => ["bors delegate+"]},
        statuses: %{},
        files: %{"master" => %{"bors.toml" => toml}},
        pulls: %{1 => pr}
      }
    })

    {:ok, user} =
      Repo.insert(%BorsNG.Database.User{user_xref: 1, is_admin: true, login: "owner"})

    {:ok, _} =
      Repo.insert(%BorsNG.Database.Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "headsha123",
        into_branch: "master"
      })

    Repo.insert(%BorsNG.Database.LinkUserProject{user_id: user.id, project_id: proj.id})

    Command.run(%Command{
      project: proj,
      commenter: user,
      comment: "bors delegate+",
      pr_xref: 1
    })

    state = GitHub.ServerMock.get_state()
    comments = get_in(state, [{{:installation, 91}, 14}, :comments, 1])

    assert Enum.any?(comments, fn c ->
             String.contains?(c, "only covers changes within") and String.contains?(c, "`src/**`")
           end)

    assert Enum.any?(comments, &String.contains?(&1, "too many files"))
  end

  test "re-delegating the same user replaces expires_at", %{proj: proj} do
    pr = %BorsNG.GitHub.Pr{
      number: 1,
      title: "Test",
      body: "Mess",
      state: :open,
      base_ref: "master",
      head_sha: "00000001",
      head_ref: "update",
      base_repo_id: 13,
      head_repo_id: 13,
      user: %{id: 2, login: "pr_author"}
    }

    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{},
        comments: %{1 => []},
        statuses: %{},
        pulls: %{1 => pr}
      }
    })

    {:ok, user} =
      Repo.insert(%BorsNG.Database.User{user_xref: 1, is_admin: true, login: "owner"})

    {:ok, _} =
      Repo.insert(%BorsNG.Database.Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "abc",
        into_branch: "master"
      })

    Repo.insert(%BorsNG.Database.LinkUserProject{user_id: user.id, project_id: proj.id})

    Command.run(%Command{
      project: proj,
      commenter: user,
      comment: "bors delegate+ for=1h",
      pr_xref: 1
    })

    [d1] = Repo.all(BorsNG.Database.UserPatchDelegation)

    Command.run(%Command{
      project: proj,
      commenter: user,
      comment: "bors delegate+ for=7d",
      pr_xref: 1
    })

    [d2] = Repo.all(BorsNG.Database.UserPatchDelegation)

    assert d2.id == d1.id
    assert NaiveDateTime.compare(d2.expires_at, d1.expires_at) == :gt
  end
end
