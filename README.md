# buru

A small task tracker that lives in your project as plain Markdown:
`private/tasks.md` for open tasks and `private/done.md` for completed ones.

```sh
buru init            # create private/tasks.md
buru                 # add a task: pick a priority, name it, add points
buru h               # add a high priority task (m, l and b work too)
buru done H004       # move it to done.md
buru status          # progress bars per priority
```

## Install

```sh
brew install zmscode/buru/buru
```

Or from source. This needs **Zig 0.17-dev**, not 0.16:

```sh
zig build --release=safe --prefix ~/.local
buru completions fish > ~/.config/fish/completions/buru.fish
```

## Usage

```
buru                    add a task (interactive)
buru h|m|l|b            add a high/medium/low/broken task (skips the menu)
buru done ID...         move task(s) to done.md
buru reopen ID...       move task(s) back to tasks.md
buru edit ID            edit an open task
buru move ID [h|m|l|b]  change a task's priority (new id)
buru status             show the progress bars
buru init               create private/tasks.md here
buru completions fish   print fish completions
buru --version          print the version
```

IDs are case-insensitive and can be short: `buru done h4` means `H004`.

`buru` looks for `private/tasks.md` from the current directory upwards, so it
works from anywhere inside a project. Add `private/*` to `.gitignore` if the
tasks should stay out of the repository; `buru init` reminds you if it isn't.

## The files

```markdown
# tasks

<!-- task:progress -->
...progress bars, redrawn on every command...
<!-- /task:progress -->

## broken

- [ ] `B001` | **Inspector panel sizing**
    - **Related task:** [ [`H005`](done.md) ]
    - The Inspector panel does not appear full sized by default

## high

- [ ] `H004` | **Panel item tooltips**
    - Add hover tooltips for items in the panels
```

- **Priorities:** `broken`, `high`, `medium` and `low`, numbered `B001`,
  `H001`, `M001`, `L001`. A broken task is a bug in something already done;
  its first point links the related tasks, and the links follow those tasks
  between `tasks.md` and `done.md`.
- **IDs are never reused.** The highest number used per priority is kept in a
  hidden `<!-- task:last-ids ... -->` comment, so moving or deleting a task
  doesn't free its ID.
- **Hand edits are fine.** Everything outside the `task:progress` markers is
  yours; buru only rewrites the managed block and the "Related task" links.

The interactive prompts accept arrow keys, Ctrl-A/E/U/W and Esc to cancel.
When stdin isn't a terminal, buru reads plain lines instead, so it can be
scripted:

```sh
printf 'Fix login\nrepro on staging\n\n' | buru h
```

## Releasing

```sh
just release
```

Builds Apple Silicon and Intel binaries, publishes a GitHub release for the
version in `build.zig.zon`, and updates the formula in
[zmscode/homebrew-buru](https://github.com/zmscode/homebrew-buru).
