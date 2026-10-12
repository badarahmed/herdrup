# Herdr Core

An iPad client for stock Herder: saved SSH hosts, per-host session selection,
agent status, a SwiftTerm terminal, prompts, and terminal keys.

The core target does not include Gram, push notifications, Live Activities,
guest sharing, accounts, transfers, archives, federation management, update
helpers, or the tip store. The older client sources remain in this checkout but
are excluded from the app target's explicit source list in `project.yml`.

## Host setup

Use stock **Herder 0.9.3** with its matching CLI and running daemon. This client
uses `herdr remote-api-bridge` for JSON API requests and
`herdr terminal session control TARGET` for the terminal. It does not require
the HerdrUp daemon fork, `herdr pair`, a relay, or a socket proxy.

1. Install stock Herder on the host and start `herdr` there. Keep its CLI and
   daemon versions compatible. The daemon must already have agents to list.
2. Enable SSH access and make the host reachable from the iPad, for example
   through your local network or VPN. `herdr` must be available on the SSH
   account's noninteractive command PATH.
3. In Herdr Core, tap **Add SSH host**, enter the host (optionally `:port`) and
   username, and supply a password or ed25519 private key. Save & Connect opens
   that host; Save without connecting stores it locally.
4. Select a running session and agent. Use the terminal keyboard or quick keys
   for interactive menus; use the prompt field for deliberate agent prompts.

Credentials remain in the device Keychain; host names and usernames are in
UserDefaults. Host keys are pinned on first contact and a changed key is
rejected. The app polls status every three seconds while active and closes its
SSH/controller channels when inactive. It reconnects and reloads status when
foregrounded. A terminal has one writable controller: contention is shown
instead of taking over another controller.

## Build and test

Requires macOS, Xcode, XcodeGen, and iPadOS 17 or newer. Generate the project:

```sh
xcodegen generate
```

Open `Herdr.xcodeproj`, choose the **Herdr** scheme and an iPad destination, then
build/run. The app identifier is `com.badarahmed.herdr.core` and automatic signing
uses development team `FA2N3ZW6ZV`; select your own team for another account.
The generated scheme runs only the focused `HerdrUITests/CoreUITests` launch
and saved-host tests. Protocol tests are separate:

```sh
xcodebuildmcp swift-package test --package-path . --filter Upstream
```

The app target compiles only `CoreApp`, `CoreRootView`, `UpstreamTerminalView`,
`HostEditor`, `SavedHosts`, and `DesignSystem`, plus fonts and asset resources.
Its only package products are HerdrKit (Citadel SSH) and SwiftTerm.

## Scope and verification

Validated: eight upstream transport tests (including real SSH), two diagnostic
tests, and three core UI checks on an iPad Pro simulator. Keep normal simulator
signing enabled when testing saved credentials: Keychain access needs the
simulated application identity.

The real Swift transport passed an isolated stock-daemon test over loopback SSH,
covering JSON bridge requests, status events, terminal frames, input, resize,
controller release, and reconnect with a fresh full screen. The fixture is retained at
[`Tests/HerdrKitTests/Fixtures/upstream_ssh_fixture.py`](Tests/HerdrKitTests/Fixtures/upstream_ssh_fixture.py).
With stock `herdr`, `sshd`, `ssh-keygen`, and XcodeBuildMCP installed, run from this
checkout:

```sh
python3 Tests/HerdrKitTests/Fixtures/upstream_ssh_fixture.py
```

It creates disposable keys, config, sockets, and sessions, runs the focused
upstream unit and SSH tests, and cleans up. It does not use existing Herder
sessions or authorized keys. The live Swift test skips unless explicitly opted
in by the fixture. This integration uses rendered ANSI viewports rather than
fork byte-stream offsets. Scrolling belongs to the host
controller, and uncertain prompt or terminal input is never retried automatically.
No full-history terminal search, graphics parity, or background notifications
are promised. Real iPad-to-SSH testing is required beyond protocol/unit tests.

## License

[Apache-2.0](LICENSE).
