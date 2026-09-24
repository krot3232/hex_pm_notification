# hex_pm_notification

A small Bash script that watches [hex.pm](https://hex.pm) packages and notifies you
when a new version is released. It prints every event to stdout and, when configured,
sends a message to a Telegram chat. It is meant to be run periodically from cron.

```
2026-09-24T10:59:30+0300 NEW jason 1.4.4 -> 1.4.5
```

Telegram message:

```
📦 jason: 1.4.4 → 1.4.5
https://hex.pm/packages/jason/1.4.5
```

## Requirements

- Linux (uses `flock` from util-linux)
- Bash 4+
- `curl`
- `jq` built with regex support (Oniguruma), which is the default in Debian/Ubuntu packages

The script checks that `curl`, `jq`, `flock`, `sort` and `mktemp` are available before
doing anything else.

## Quick start

```bash
cp packages.txt.example packages.txt
cp hex_pm_notification.conf.example hex_pm_notification.conf
chmod 600 hex_pm_notification.conf   # it holds the bot token and is sourced as code

# edit packages.txt and hex_pm_notification.conf, then:
./hex_pm_notification.sh
```

The first run only records the current version of every package and sends nothing.
Notifications start with the next release after that.

## Configuration

Settings come from environment variables. If `hex_pm_notification.conf` exists next to
the script (or the file named by `CONFIG_FILE`), it is sourced **after** the environment
is read, so any assignment in it overrides the variable of the same name, even with an
empty value. Keep unused lines commented out.

| Variable             | Default                     | Description                                                        |
| -------------------- | --------------------------- | ------------------------------------------------------------------ |
| `PACKAGES_FILE`      | `packages.txt` next to script | Packages to watch                                               |
| `STATE_FILE`         | `state.txt` next to script  | Last known versions                                                |
| `INCLUDE_PRERELEASE` | `0`                         | `1` to also notify about pre-releases (`-rc.1`, `-alpha`, ...)     |
| `TELEGRAM_BOT_TOKEN` | empty                       | Bot token; Telegram is disabled unless both token and chat id are set |
| `TELEGRAM_CHAT_ID`   | empty                       | Chat to send messages to                                           |
| `CONFIG_FILE`        | `hex_pm_notification.conf` next to script | Config file to source; `/dev/null` disables it       |

Relative paths in the config file are resolved against the current working directory,
not the script directory. Cron starts jobs in your home directory, so use absolute paths.

### Packages file

One package name per line. Empty lines and `#` comments (including trailing ones) are
ignored; surrounding whitespace is trimmed.

```
# web
phoenix
ecto   # database
jason
```

### Telegram

1. Create a bot with [@BotFather](https://t.me/BotFather) and copy its token.
2. Send any message to the bot (or add it to a group), then find the chat id in
   `https://api.telegram.org/bot<TOKEN>/getUpdates`.
3. Put both values into `hex_pm_notification.conf`.

## Running from cron

```cron
*/30 * * * * /path/to/hex_pm_notification/hex_pm_notification.sh >> /var/log/hex_pm_notification.log 2>&1
```

Only one instance runs at a time: a second instance started while the first is still
running exits immediately with `another instance is running`.

## How it works

For every package the script requests `https://hex.pm/api/packages/<name>` and takes
`latest_stable_version` (falling back to `latest_version` for packages without stable
releases), or `latest_version` when `INCLUDE_PRERELEASE=1`. The result is compared with
the version stored in the state file:

| Log line  | Meaning                                                                          |
| --------- | -------------------------------------------------------------------------------- |
| `TRACK`   | Package seen for the first time; version recorded, no notification               |
| `NEW`     | Newer version (by semver); notification sent                                     |
| `IGNORE`  | Reported version is older than the stored one (e.g. a reverted release, or `INCLUDE_PRERELEASE` turned off); state kept, no notification |
| `WARN`    | Versions could not be compared as semver; notification sent anyway               |
| `ERROR`   | A package could not be fetched or a notification could not be sent               |

Delivery guarantees:

- The stored version is updated only after the Telegram message was sent successfully,
  so a failed notification is retried on the next run.
- The state file is written atomically right after each change, so an interrupted run
  does not send the same notification twice.
- Requests to hex.pm are retried (`curl --retry 3`) on network errors, 5xx and 429.
  Telegram requests are not retried within a run, because a retry after a timeout could
  deliver the message twice; the next run retries instead.
- If several versions are released between two runs, only the latest one is reported.

### Exit codes

- `0` - everything succeeded
- `1` - at least one package could not be fetched or notified, another instance is
  running, the packages file is missing, or a required command is not installed.
  Other packages are still processed.

## Tests

```bash
tests/run_tests.sh                               # all tests
tests/run_tests.sh test_same_version_is_silent   # selected tests
```

The tests are plain Bash and need no network: `tests/fake_bin/curl` replaces `curl`
and serves fixtures.

To try the script against the real hex.pm without touching your config and state:

```bash
CONFIG_FILE=/dev/null PACKAGES_FILE=/tmp/packages.txt STATE_FILE=/tmp/state.txt ./hex_pm_notification.sh
```

## Known limitations

- While the state holds a pre-release (e.g. `2.0.0-rc.1`) and `INCLUDE_PRERELEASE` is off,
  patch releases of the previous stable line (`1.9.x`) are ignored until `2.0.0` is out.
- Package names are not validated; a misspelled name is reported as a fetch error.
- When hex.pm is unreachable, each package may take up to about two minutes because of
  retries.
