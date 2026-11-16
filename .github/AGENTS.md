# CI, releases and the website

This file loads when you work in `.github/`. The root `AGENTS.md` has the build, the architecture and the conventions.

## Runners and required checks

Every macOS job that builds the app runs on `xcode-27` (macOS 27), except `Test / Smoke`. `Session Layer (macOS)` runs on `macos-26`, because it builds nothing and `macos-15` runners are often not available. The server jobs (`server-build.yml`, `Test (macOS)` of `server.yml`) run on `macos-26` with Xcode 26.3, because zig cannot link with Xcode 26.4 or later (zig#31658). **Runners are chosen by cost.** Every macOS job runs on GitHub-hosted runners, which are free for this public repository. Blacksmith bills a macOS minute 20 times a 2 vCPU Linux minute and has no macOS runner under 6 vCPU: Unit, End-to-end and Release Build there cost about $900 a month at the volume of 2026-11 (about 300 full Test runs a week), for checks about twice as fast. Linux jobs run on Blacksmith's 2 vCPU runners, except the two Linux server tests (4 vCPU, because Zig uses every core) and Session Layer (Linux) (GitHub, for netem). The ghostty fork runs on GitHub-hosted runners.

`Release Build`, `Smoke (macos-26)` and `Smoke (macos-15)` are required checks on main, next to `Format`, `Lint`, `Unit` and `End-to-end`. **The Smoke checks are two jobs, not a matrix.** A matrix job that its `if:` skips reports its unexpanded name (`Smoke (${{ matrix.runner }})`). A required check with the expanded name then never reports, and a pull request that changes no Swift can never merge. The server checks of `server.yml` (`Test (macOS)`, `Test (Linux x86_64)` and `Test (Linux aarch64)`) are required on main only, in their own ruleset, because `v1` has no `server.yml`. They are a matrix, so they skip at step level. The workflow starts on every pull request, and the Linux job `Detect Changes` finds the server changes. When no server file changed, each step of a Test job skips, and the job runs on a 2 vCPU Linux runner. Thus a pull request with no server change takes no macOS runner for the server checks. `server-build.yml` takes no macOS runner when the `server-prebuilt` release has the build of the key.

**One table decides what a commit changed.** `.github/path-areas` lists the path areas (`app`, `extensions`, `style`, `server`, `bench`, `docs`), and `scripts/changed-areas.sh` reads it in every workflow: the merge commit against its first parent on a pull request, the commit before the push on `main`, and every area for any other event. It uses git and no API call. A change to the table or the script sets every area. Do not add a `paths:` trigger or a filter of a workflow's own. **Every job that builds the app starts with `.github/actions/app-setup`**: mise, the pinned Xcode, the GhosttyKit cache, the `server` artifact and setup.

## The website

The site at `macterm.thdxg.dev` (landing page, docs, changelog, and the proxy of the update feed) is the `macterm/website` repository. This repository keeps what the site renders and serves:

- `assets/`: the JSON schemas and the icons. The demo clips are in `macterm/website`.
  - **The schemas are served at `https://macterm.thdxg.dev/schemas/<name>.schema.json`.** That is the `$id`, and the `$schema` line that the app writes. The website build copies the files from here, so this folder stays their one source and the unit tests keep reading it.
  - **The old address `https://raw.githubusercontent.com/macterm/macterm/main/assets/<name>.schema.json` must keep answering.** Files that users and the extensions of the repository wrote name it. Never delete or rename a schema file here. The extensions keep the old line, because a change to a file of an extension makes each installed copy look outdated.

The docs pages (`docs/*.md`) are in `macterm/website`, with the site that renders them. The site build checks out this repository at `main` and reads `assets/` from it.

- **A feature and its docs are two PRs.** The docs PR goes to `macterm/website`, and you file it with the feature PR. The feature PR names the docs PR, and the docs PR names the feature PR. A feature that needs no docs change says so in its PR text. Merge the docs PR with the feature PR.
- **Three unit test suites read the docs pages**: `DocsLinkTests` (each Settings help button finds its heading), `TextFileDefaultsTests` (the table of file types) and `CustomPaletteFileTests` (each captioned example reads through the validator). They read `docs/` of a checkout of `macterm/website` (`WebsiteDocs`): `MACTERM_WEBSITE_DIR`, else `./website` in this checkout (git ignores it). **Without a checkout, a test is off with a message. On CI (`CI` is set) it fails**, so a missing checkout never passes. A local run without `./website` therefore does not cover the docs checks. The Unit job of `test.yml` checks out the website branch with the name of the PR branch if there is one, else `main`. A PR in the website repository calls `docs-tests.yml` with its own commit and an `app_ref` (the branch of the app change that goes with it, default `main`), which runs only these three suites. Use the same branch name in both repositories.

- **`website-dispatch.yml` starts the site build.** It sends a `repository_dispatch` (`macterm-content`) to `macterm/website` on a push to `main` that changes `assets/**`, and on a release that a person publishes, edits or deletes. Events that `GITHUB_TOKEN` raises start no runs, so a release that a workflow publishes does not start a build. The dispatch uses a token of the org's `macterm-ci` GitHub App (org variable `MACTERM_APP_CLIENT_ID`, org secret `MACTERM_APP_PRIVATE_KEY`), for `macterm/website` only.
- **`Docs / Site Build` runs the site build on a pull request that changes `assets/**`**, against `macterm/website` at `main`. An asset that breaks the build fails here, before it reaches `main`.

## The GhosttyKit pin

A weekly auto-PR changes the GhosttyKit pin (`.github/workflows/bump-ghosttykit.yml`). It opens the PR with a token of the org's `macterm-ci` GitHub App (org variable `MACTERM_APP_CLIENT_ID`, org secret `MACTERM_APP_PRIVATE_KEY`), so that CI runs on it. It attaches an API review from `scripts/ghosttykit-api-diff.sh`. Read the section "renumbered enum constants" in that report. Swift imports enum constants by name, so a new constant in the middle of an enum compiles with no error.

## Releasing

Macterm updates itself with Sparkle. `SUFeedURL` is `https://macterm.thdxg.dev/appcast.xml`. The Caddyfile of the `macterm/website` repository serves it straight from the `main` branch of the `macterm/appcast` repository, which is a store and not a site. `FEED_REPOSITORY` and `FEED_BRANCH` in `scripts/publish-appcast.sh`, the fetch in `release-tip.yml` and the proxy rewrite in the Caddyfile name it. The feed lived on the orphan `appcast` branch of this repository until 2026-11. That branch stays as it was. Remove it only after one tip release has published to the new repository. `UpdaterChannelTests` pins the two files in this repository, and `check-feed.mjs` of macterm/website pins its Caddyfile and `SITE_URL` to them. A build that a pushed tag starts releases through `release.yml`. `release.yml`, `release-tip.yml` and `Test / Release Build` share one build recipe, `.github/actions/build-release`.

Secrets:

- `SPARKLE_ED_PUBLIC_KEY` and `SPARKLE_ED_PRIVATE_KEY`.
- The org secret `MACTERM_APP_PRIVATE_KEY` and the org variable `MACTERM_APP_CLIENT_ID` of the `macterm-ci` GitHub App. The jobs that write to another repository (the cask bump to `macterm/homebrew-tap`, the GhosttyKit bump PR, the website dispatch). The push of `publish-appcast.sh` to `macterm/appcast` uses it too, so the app is the commit author. These jobs take a short-lived token of it from `actions/create-github-app-token`, for the repositories that they write (`macterm` and `appcast` for a publish). No workflow uses a personal access token.
- `MACTERM_SIGNING_CERT_P12` and `MACTERM_SIGNING_CERT_PASSWORD`. This is a stable self-signed certificate. It keeps TCC grants across updates. **Back up the private key and the certificate**. If you lose either one, users are stranded.

The release notes come from the generator of GitHub (`.github/release.yml`). A person chooses the version number. The `/release` skill walks through the ceremony. The recipe for the certificate is in the git history of the root `AGENTS.md`.

- **The website's `/changelog` shows the notes of every stable release** (`releases.mjs` of macterm/website, rendered by its `build-docs.mjs`). The GitHub release is the only copy of the notes. An edit there reaches the page at the next site build. `website-dispatch.yml` starts that build for each release that a person publishes, edits or deletes. The page links `#123` and `@user` itself and drops HTML comments, so write the notes in the same Markdown as before.

- **There are three Sparkle channels and one feed**. A prerelease item carries `<sparkle:channel>beta|tip</sparkle:channel>`. Settings → Updates → Channel opts in (`Preferences.updateChannel`, the raw values are the wire names). A channel on an item that is not a prerelease is a hard error in `publish-appcast.sh`. Homebrew stays stable-only.
- **Read the prerelease flag live** (the job `flag`, through `gh release view`). Never read it from `github.event.release.prerelease`. The payload is frozen at dispatch, and an edit does not fire the event again. Job outputs are strings. Compare with `== 'false'`.
- **Version ordering** (`sparkle_comparison_version` in `_lib.sh`):
  - `0.9.0-beta.1` becomes `0.9.0.1`.
  - Stable `1.8.0` becomes `1.8.0.9999`.
  - Tip `1.24.2-tip.7` becomes `1.24.2.9999.7`.
  - `build.sh` and `publish-appcast.sh` must both use it.
  - `macterm_tip_version` filters tags to `^v[0-9]+\.[0-9]+\.[0-9]+$`, because the rolling `tip` tag breaks `git describe`.
- **Tip channel** (`release-tip.yml`).
  - Every commit on main for which CI *passed* (Test success and Checks polled) publishes to ONE permanent prerelease that Macterm edits in place.
  - The rolling `tip` tag moves **last**, as the commit point.
  - The build job is in one concurrency group with `cancel-in-progress: true`. A newer commit that passed the gate replaces an older build. The setting is at job level, so that a commit that is red, or that only changes docs, cannot cancel a good build. The gate skips a commit when a newer commit already passed Test and Checks, because Test runs finish out of order.
  - There is one tip item in the appcast. Macterm keeps the newest 3 DMGs.
  - The check for staleness asks if the `tip` tag is an ancestor of the built commit. It never compares against HEAD of main.
  - **Macterm never builds a version again that is already in the appcast**. A run whose tag push failed has shipped everything else. A re-run for the same commit would `--clobber` the DMG with new bytes, while `publish-appcast.sh` keeps the old signature for the equal version. The build job therefore first reads `appcast.xml` from `macterm/appcast`. If the version is there, it only moves the tag.
  - `build.sh` bakes `MactermUpdateChannel` into `Info.plist`. A tip build that you install by hand therefore uses the tip channel by default. Beta stamps `stable`.
- `release.yml` skips itself for `ref_name == 'tip'`.
- **GitHub Pages is retired, and the `gh-pages` branch with it**. The feed was at thdxg.github.io/macterm/appcast.xml before 1.26.0. An install from before that version asks that URL for ever, gets a 404 and reports no update. Such an install updates only by hand.
- **Never delete `macterm/appcast` or its `main` branch**. `publish-appcast.sh` creates a missing `main` again as an empty orphan (it cannot make a missing repository), and the feed then names only the one release that it publishes. Every other channel is empty until its next publish. The 2026-10-29 deletion of `gh-pages` lost every item in this way, and the branch was rebuilt from a local clone.
