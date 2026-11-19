---
name: macterm-palettes
description: Create or edit a Macterm extension, which is a folder in ~/.config/macterm/extensions with an extension.yaml and command-palette screens written as YAML files in its palettes folder. A palette has named nodes. The JSON or plain-line output of a command becomes rows that you can search. Each row opens another node or runs a command in a new tab or split. The values that you select travel down as environment variables. Then check with the macterm CLI that the file reads. Use when asked to add a palette, picker, launcher or quick-switcher to Macterm for things like Kubernetes namespaces and pods, Docker containers, git branches, SSH hosts, cloud resources, projects or scripts, or to fix a palette file that shows an error.
---

# Writing a Macterm palette

An extension is a folder in `~/.config/macterm/extensions/`, for example `kubernetes/`. It has an
`extension.yaml` file and a `palettes/` folder. Each palette is one YAML file in `palettes/`. Macterm
reads palettes only from extensions. It does not read `~/.config/macterm/palettes/`, which earlier
versions read. A palette appears as a row in the **Palettes** section of the command palette (⌘P).
It opens a screen of its own, and it can nest. A row can open another screen, and the pills above
the palette show the trail. Macterm reads the folder
again each time that the palette opens, so you deploy a palette when you save the file. If Macterm
cannot read a file, the file keeps its row, with a warning glyph. When you enter the row, it shows the
error. ⌘R reads the file again.

## Ground rules

- **Reaching the CLI.** Inside a Macterm pane, `macterm` is in `PATH`, and `$MACTERM_SESSION` names that
  pane. A pane command with no target acts on the pane that it runs in. In any other place, run
  `/Applications/Macterm.app/Contents/Resources/bin/macterm`. Macterm must be running.
- **Targeting.** `--session <name>` is the stable address. Session names come from `macterm pane list`.
  They stay the same after the user quits and starts Macterm again. The CLI finds a session in the project
  that holds it. `--pane pane:2` is the second pane of the active tab (add `--tab` for another tab). It
  changes when splits change. An explicit target always wins over the fallback. Inside Macterm, the
  fallback is your own pane. Outside Macterm, it is the focused pane of the user.
- **Text after `--`.** In `pane run`, put the text after `--`. Macterm types it exactly as you wrote it:
  `macterm pane run --session macterm-api-8f327ce4a3f8 -- "ls -la"`. Before `--`, `pane run` reads its own
  flags at any place. It refuses a word that starts with `-` and types nothing.
- **One argument.** `pane run` joins its arguments with spaces after your shell removes their quotes.
  Pass the command line as one quoted string. The quotes inside it then stay.
- **The user's shell.** Macterm types the text into the login shell of the user. This can be nushell or
  fish. Put redirects, pipes, `&&`, variables and globs in `/bin/sh -c '…'`. Or write a script file and
  type `/bin/sh /path/to/script.sh`.
- **No terminal yet.** A pane in a tab that was never on the screen has no terminal. `pane run`, `key`,
  `dump` and `inspect` answer `no_surface`, and its `--run` command did not start. `macterm tab select`
  shows the tab. It also changes what the user sees.
- **`read_only` means ask.** The user can make a pane read-only. Then `pane run` and `pane key` answer
  `read_only` and type nothing. `macterm pane inspect` shows `read-only`. Do not try to turn it off. Ask
  the user.
- **Wait for a sentinel, not for a fixed time.** Make the command create a file when it ends, or print a
  marker that you assemble at run time: `printf done-%s 4f1c` prints `done-4f1c`. The echoed command line
  never contains it. Use a new random token each time. Give each wait loop a deadline.
- **`busy` means ask.** Closing a pane, a tab or a project answers `busy` while a program runs there.
  `layout apply` answers `busy` each time that it would close a pane. Nothing changed at that point. Ask
  the user before you try again with `--force`. That flag closes them anyway and kills the programs that
  run in them.
- **Results.** Exit 0 is success. Exit 1 means that Macterm refused the command (stderr says why). Exit 2
  means that no Macterm is reachable. Exit 64 means that the command line is malformed. stdout has output
  only on success. Every command except `macterm ssh` accepts `--json`.

## The extension

```yaml
# ~/.config/macterm/extensions/kubernetes/extension.yaml
# yaml-language-server: $schema=https://macterm.thdxg.dev/schemas/extension.schema.json
name: Kubernetes
description: Browse the namespaces and pods of a cluster
icon: shippingbox                      # an SF Symbol name; optional
```

`name` and `description` are required. They show on the card of the extension in Settings →
Extensions. `icon` is optional. It is an SF Symbol name, or the path of a PNG file in the extension
folder (exactly 128×128 pixels, the shape in the alpha channel). The card and the row and the pill of
each palette of the extension show it. `authors:` (GitHub usernames) is optional for an
extension that the user keeps for themselves.

## The palette file

```yaml
# ~/.config/macterm/extensions/kubernetes/palettes/kubernetes.yaml
# yaml-language-server: $schema=https://macterm.thdxg.dev/schemas/palette.schema.json
name: Kubernetes
description: Namespaces, pods and their logs
requires: [kubectl]
root: menu                             # the node to open on; defaults to a node called root
nodes:
  menu:
    items:
      - { title: Namespaces, enter: namespaces }
      - { title: Pods, subtitle: All namespaces, enter: pods }
  namespaces:
    list: kubectl get ns -o json
    rows: .items
    title: .metadata.name
    export: { NAMESPACE: .metadata.name }
    enter: namespace-menu
  namespace-menu:
    items:
      - { title: Pods, enter: pods }
      - { title: Set as current namespace, action: { run: kubectl config set-context --current --namespace "$NAMESPACE" } }
  pods:
    list: if [ -n "$NAMESPACE" ]; then set -- -n "$NAMESPACE"; else set -- -A; fi; kubectl get pods "$@" -o json
    rows: .items
    title: .metadata.name
    subtitle: .status.phase
    match: [.metadata.name, .metadata.namespace, .metadata.labels.app]
    export: { POD: .metadata.name, NAMESPACE: .metadata.namespace }
    action: { run: kubectl logs -f -n "$NAMESPACE" "$POD", in: split }
```

- `name` and `nodes` are required. The id of the palette is the folder of the extension and the stem
  of the file name (`kubernetes/kubernetes`). Settings and keybinds use it as a key. Do not rename the
  file or the folder after the user sets them.
- A **node** has `items:` (rows that you write), a `list:` (a command whose output becomes rows), or
  both. The items come first and show at once. The rows of the listing follow. Use this for fixed rows,
  such as "New" above a listing. Every row, each item and each row of a listing, has exactly one of
  `enter:` (a node name) or `action:`.
- **`export`** sets environment variables for everything below the row. In a menu item, the values are
  literal. In a listing, they are paths into the row. You can reach a node from several places (`pods`
  above, with and without `NAMESPACE`). The command handles the difference in the way that a shell
  does.
- An **action** is exactly one of these. `run:` runs the command in a new tab, or in a split with
  `in: split`. It runs before the shell of the new terminal starts, with the exported variables in its
  environment. The shell prompt follows when the command ends. `copy:` copies to the clipboard.
  `open:` opens a URL or a file. In a **remote project**, Macterm types a `run:` at the shell prompt of
  the host, as you wrote it. The shell of the host runs it, and the exported variables are not set
  there. Do not build the `run:` of a remote palette on `"$VAR"`.
- **`alt:`** is the second action of a row. ⌥↩ or ⌥-click runs it. Put it on an item, or on a listing
  for every row. It has the same keys as an action, and an optional `title:`. The subtitle of the row
  shows the title while the user holds ⌥ (`alt: { title: Open in a Split, run: claude, in: split }`).
  Use it for the choice of "the same thing in another place". Do not use a second row or a submenu for
  it.

## Commands and their output

- Commands are **POSIX sh** with errexit (`sh -o errexit -c`), for any shell that the user has. Write
  them in sh. Do not use the syntax of nushell or fish. A command that starts with a `#!` line runs as
  a script with that interpreter instead (a YAML `|` block). Commands still see the `PATH` of the
  user. Name the programs that they need in `requires:`, so Macterm reports a missing program by name.
- **`when: { run: <check>, unavailable: <reason> }`** mutes the palette (at the top level) or a menu
  item while the check exits with a non-zero code. Use it for a cluster that does not answer or a tool
  that is not set up. It runs in the background each time that the row is shown. Keep it fast and
  quiet, with its own short timeout (`--request-timeout=2s`). Items that share a check run it one time.
  Use a YAML anchor to reuse a check (`when: &cluster {…}`, then `when: *cluster`). Leave a way out that
  has no check. An example is Contexts in a Kubernetes palette. To switch the context is how a user
  fixes a cluster that is not reachable.
- A listing runs one time when its screen opens, in the directory of the active project. The variables
  `MACTERM_PROJECT_DIR`, `MACTERM_PROJECT_NAME` and the exported variables are set. ⌘R runs it again. A
  listing that takes more than 30 seconds fails.
- **Read exported values as variables** (`"$NAMESPACE"`). Do not paste them into another command.
  Macterm never puts the text of a row into a command. A value with spaces or quotes therefore cannot
  break the command. Keep this property in everything that you write.
- The **output** of a listing is JSON: an array, newline-delimited objects (`jq -c '.items[]'`), or an
  object with the rows at `rows:`. If the output does not start with `[` or `{`, it is plain lines,
  one row each (`git branch --format='%(refname:short)'`, `ls`).
- In a listing node, a value that starts with `.` is a **path** into the row. `.` is the row itself
  (the whole line for plain output). `.metadata.name` is a field. `.items[0].name` is an index. Any
  other value is literal. `title:` has the default `.`. `match:` (what the search looks in) has the
  default title and subtitle. `subtitle`, `icon`, `export`, `copy` and `open` take paths too. Macterm
  drops a row whose title resolves to nothing. Inside a `{ }` flow mapping, put quotes around a path
  with an index, as in `PORT: '.spec.ports[0].port'`. Without quotes, YAML reads the brackets as a
  list. The same is true for a value that contains `: ` or ` #`.
- Use the output of `-o json`, `--format json` or `--json` with `rows:`. Do not cut up text. Name the
  fields that users search by in `match:` (an app label, a host, a branch). Then a search finds a pod
  by its deployment.

## Check it reads

```sh
macterm palette list
```

This prints the id of each palette, its keybind (or `-`), and its name. For a file that Macterm
could not read, it prints `error:` and the reason. The reason names the node and the field, for
example `pods: enter: no node named pod`. Fix the file and run the command again. The palette itself
opens with ⌘P. There is no CLI verb for that. If a listing has side effects, never run its command yourself to test
it. The shell of the user runs it.

## Keeping it theirs

- Select the icon of the extension from SF Symbols. The default is `puzzlepiece.extension`.
- Do not put secrets in the file. It is plain text in the config folder of the user.
- Settings → Extensions removes an extension (Installed → Uninstall). Settings → Keymaps gives it
  a keybind. Tell the user about both. Do not do either for the user.
- The reference for users is https://macterm.thdxg.dev/docs/extension-palettes. Git, Docker
  and SSH examples are in https://macterm.thdxg.dev/docs/extensions and
  https://macterm.thdxg.dev/docs/extension-examples. The extensions in
  https://github.com/macterm/macterm/tree/main/extensions are complete examples too.

## Keeping this skill current

This file came from `macterm skills macterm-palettes`. If Macterm rejects a command shown here, the CLI changed
after you installed the skill. Install the skill again from the output of that command.
