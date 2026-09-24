# Command Parsing

bors reads commands out of pull request comments: a line such as `bors r+`
approves, `bors d=alice` delegates. This document sets out the rules the
parser follows, the invariants it keeps, and why, so that a change to one
command does not quietly break the others.

The parser lives in `lib/web/command.ex` (`parse/1` down to `match_cmd/1`),
the replies in `lib/worker/batcher/message.ex`. The invariants below are
checked across a corpus of lines by `test/command_parsing_invariants_test.exs`;
per-command behavior is tested in `test/command_test.exs`.

## Goal

> **A line that is an attempt at a command either runs exactly as written, or
> gets a reply saying what bors did not run and why. A line that is not an
> attempt gets nothing.**

Two failures motivate this. A silently ignored command (`bors delegate`,
`bors r+ p=5 single on` never setting `single`) leaves the author believing
something happened. A silently *misread* one is worse: `bors d- alice` used to
remove every delegation, and `bors d=alice thanks` could delegate a GitHub user
called `thanks`.

The limit is prose. Any line that starts with the trigger is read, so
`bors is slow today` has to stay quiet. The parser cannot reply to everything
it does not recognize; it replies to what is recognizably a command.

## How a comment is read

1. The comment is split into lines. Each line is read on its own, so a comment
   may hold several commands, one per line.
2. A line is a command line only if it starts with the trigger
   (`COMMAND_TRIGGER`, default `bors`, any case), an optional `:`, and
   whitespace. `bors:r+`, with no space after the colon, is not a command line
   but gets a correction (see below). `bros` is a joke trigger: a line it
   starts that reads as anything gets a fist bump and never runs.
3. The rest of the line is trimmed, and every run of whitespace is read as one
   space, except in `try` arguments, which reach CI as typed.
4. The run-on check drops prose (see "Prose stays quiet").
5. `match_cmd/1` reads the command with its exact syntax (see the reference
   below). Anything left over makes the line a refusal.
6. A line that reads as nothing, or only as a refusal, is tried again as a
   correction (see "Corrections are suggestions").
7. `run/1` then refuses a merge-bound command on a draft, checks permission,
   resolves every login a delegation names, and runs the commands in order.

## Principles

### Exact syntax, and nothing after it

Every command has a complete syntax, and text after it refuses the whole line.
There is no exception for punctuation (`bors merge!`) or for the stop commands
(`r-`, `try-`, `cancel`, `merge-`): a reply that says exactly what happened is
better than a guess at what was meant, and it arrives long before a build
finishes.

Two exceptions are deliberate:

- `try` takes free text after a space, which is passed to CI in the commit
  message (`Try #13: --layout`). There is no such thing as leftover text.
- `link` and `stack` take pull request references, and any other plain word
  between them is tolerated as a connective (`bors link #1 and #2`). A token
  that looks like a reference or another command is refused.

### Refuse, don't guess

When a line could mean two things, bors refuses it and suggests the command it
most likely meant. It never picks one.

- `bors d- alice` could mean "remove alice" (`d-=alice`) or "remove everyone".
  Refused, suggesting `bors d-=alice`.
- `bors d+ alice` could mean "delegate alice" (`d=alice`) or "delegate the
  author". Refused, suggesting `bors d=alice`.
- `bors r=alice bob` and `bors d=alice bob` do not say whether bob is a name.
  Names are separated by commas, so both are refused, pointing at
  `bors r=alice,bob`. A word after the names can never become a login.
- Two `for=` durations disagree. Refused.
- An unreadable argument is never replaced by a default. `bors d+ for=24m` is
  refused, not granted the `bors.toml` default expiry.
- A modifier that cannot be read swallows the command it modifies:
  `bors r+ p=abc` does not approve without the priority.

### Prose stays quiet

A command word followed directly by more of a word is prose, and reads as
nothing: `bors merged this`, `bors unlinked them`, `bors single-handedly`.

- A command word ends at a space, the end of the line, or punctuation. A
  letter, digit, `_` or `-` after it continues the word.
- The `-` of `merge-`, `link-` and `try-` is part of the command. After `try-`
  it must be followed by a space or the end of the line, so `try-cancel` is
  prose, not a build of `-cancel`; `try` arguments need a space.
- Bare `delegate` and `d` end only at a space or the end of the line, or `d`
  would read `bors does this work`.

Punctuation is not part of the word, so `bors merge!` is a command attempt.
Under the first principle it is then refused for its `!`.

### Replies say what happened

- Every refusal opens with `bors did not run` and the command as typed, then
  says why, then gives the command to use instead:

  > :-1: bors did not run `bors r- now`: `bors r-` takes nothing after it, but
  > `now` followed. Reply with just `bors r-`, and put any other command on a
  > line of its own.

- Every refusal (`{:malformed_args, hint}`) carries the command as typed as the
  second element of `hint`. The reply and the draft refusal both name it from
  there.
- No line of any reply may begin with the trigger. bors reads its own
  comments, so such a reply would run, or answer itself forever.
- A draft refusal names a refused command as typed, so running it again gets
  the same reply, not the command it was mistaken for.

### Check before acting

Nothing with a side effect runs until the input is known to be good.

- A token that cannot be a GitHub login (`p=5`, `r+`, `a.b`) is refused before
  GitHub is asked about it.
- Every login a comment's delegation commands name is resolved before any of
  them runs. One that GitHub does not know, or cannot look up, refuses every
  delegation command in the comment, including a `d-` meant to clear the way
  for a misspelled `d=`. Other commands in the comment still run.
- A priority outside the 32-bit column is refused before it reaches the
  batcher.

### Corrections are suggestions

A line that reads as nothing, or only as a refusal, is corrected by:

- lowercasing the command word (`bors Merge`, `bors R+`), but never its
  argument, since `try` passes that to CI as typed;
- closing up the spaces around `+`, `-` or `=` (`bors r +`, `bors p = 5`);
- turning `+r`, `-r`, `+` and `-` round into `r+` and `r-`;
- adding the missing space after `bors:`.

If the corrected text would run, bors replies "Did you mean `bors merge`?" and
runs nothing. If it would only be refused, the line gets that refusal instead
(`bors R+ now` is told about `now`). Lowercasing is tried before closing up
spaces, so `bors Try -` is corrected to `try -`, a build of `-`, as it would be
if typed in lowercase.

The correction goes only to someone who could run the corrected command. It is
checked with `Permission.permission?/3` when it runs, never through the
merge-time delegation gate, which revokes as a side effect.

### A reply never needs more than its command

| Line | Required level |
|---|---|
| `ping` | `:none` |
| `try`, `try-`, `r-`, `retry` | `:member` |
| `link`, `stack`, `unlink`, and their refusals | `:project_member` |
| everything else (`r+`, `r=`, `p=`, `single`, delegation) | `:reviewer` |
| a refusal | `:member`, or `:none` for a refusal of `ping` |
| a correction | `:none` to parse; checked at run time against the corrected command |

A per-patch delegate satisfies `:member` and `:reviewer` on their own pull
request, never the `:project_*` levels. A refusal is gated at `:member` so an
outsider cannot make bors post comments, and never at `:reviewer`, so a typo
never reaches `DelegationInvalidator.verify_for_merge/2`.

### Drafts

A draft refuses every command that can lead to a merge, and runs the rest:
`try`, `try-`, `r-` (and `merge-`, `cancel`), `unlink`, `delegate-`,
`delegate-=` and `ping`. A refusal is
allowed on a draft exactly when the command it refuses would be: `bors r- now`
is answered on a draft, `bors r+ now` is part of the draft refusal.

### Aliases

- A bare word is its `+` form: `merge` is `r+` (beside `merge-` and `merge=`),
  and `delegate` is `delegate+`.
- `d` is short for `delegate` in every form: `d`, `d+`, `d=`, `d+=`, `d-`,
  `d-=`.

### One parser

The check that refuses other commands among `link` arguments asks
`parse_cmd/1` and the corrections, rather than keeping its own list, so it
cannot drift as commands are added.

## Invariants

`test/command_parsing_invariants_test.exs` checks each of these across a
corpus of command attempts and a corpus of prose:

1. Every attempt at a command reads as something: commands or a reply.
2. A line that starts with the trigger but is a sentence reads as nothing.
3. A line reads as commands or as replies, never both. A refused line runs
   nothing from that line.
4. Every refusal opens with `bors did not run` and the command as typed.
5. No reply, and no draft refusal of a reply, reads as a command.
6. No reply is gated at `:reviewer`.
7. A draft refusal names a refused command as typed.
8. A line under the `bros` trigger never runs, in any capitalization.

## Syntax reference

A duration is a whole number of hours, days or weeks (`24h`, `7d`, `2w`),
from `1h` up to `90d`. A name is a GitHub login, with an optional `@`.

| Command | Syntax |
|---|---|
| `r+`, `merge` | nothing after, or one of ` p=N`, ` single on`, ` single off` |
| `r=`, `merge=` | names separated by commas (`, ` too), then optionally ` p=N` |
| `r-`, `merge-`, `cancel` | nothing after |
| `p=N` | an integer from -2147483648 to 2147483647, nothing after |
| `single on`, `single off` | nothing after |
| `try` | nothing, or a space and any text for CI |
| `try-`, `retry`, `ping` | nothing after |
| `d+`, `delegate+`, `d`, `delegate` | nothing after, or one `for=DURATION` |
| `d=`, `d+=`, `delegate=`, `delegate+=` | names separated by commas (`, ` too), then optionally ` for=DURATION` |
| `d-`, `delegate-` | nothing after |
| `d-=`, `delegate-=` | names separated by commas (`, ` too), nothing after |
| `link`, `stack` | `#N` references, with connective words between them; bare `stack` infers its parent |
| `unlink`, `link-` | nothing after |

## Changing a command

- Write its whole syntax in a `match_cmd/1` clause. Finish a command that
  takes nothing more with `no_args/3`, and refuse a tail with `leftover/3`.
- Give every new refusal the typed command as the second element of its hint,
  and a reply that opens `bors did not run` and never starts a line with the
  trigger.
- A new command word goes into `run_on_word?/1`, or `bors <word>ed` becomes a
  command.
- Decide its permission level and whether a draft allows it, and make its
  refusals agree (see the tables above).
- Add lines to the corpora in `command_parsing_invariants_test.exs`: the command
  well formed, with something left over, miscased, and run into a longer word.

## Known gaps

These are not handled yet:

- `@bors r+` (the syntax of homu, the bot bors-ng was modelled on), indented or
  list-item lines (`- bors r+`), and a non-breaking space after the trigger are
  not read as commands.
- An unknown word (`bors approve`, `bors help`, homu's `r?` and `rollup`) reads
  as nothing, since it cannot be told apart from prose in general.
- Edited comments are not read again, so fixing a typo by editing does nothing.
  The replies say "reply with", which steers toward a new comment.
- A line inside a fenced code block is read as a command.
- Only the correction reply names the configured trigger; other replies say
  `bors`.
- `link` and `stack` tolerate any plain word between references, not a fixed
  list of connectives.
- A refusal of a reviewer-level command is shown to members who could not run
  the command, and an outsider gets the permission-denied reply for it, where a
  correction is shown only to those who could run it.
- Text echoed in a reply is quoted with single backticks, so a backtick in it
  breaks the quoting.
