# SumatraPDF Action1 Managed Updater

Stateless Action1 updater for SumatraPDF. Each Action1 package version is a real,
pinned 64-bit Windows installer that can be deployed to any endpoint independently
of the latest release.

## How it works

On each run the container:

1. Queries `GET https://api.github.com/repos/sumatrapdfreader/sumatrapdf/releases/latest`
2. Constructs the installer URL as `https://www.sumatrapdfreader.org/dl/rel/{version}/SumatraPDF-{version}-64-install.exe`
3. HEAD-verifies the URL returns 200 with a non-zero `Content-Length`
4. Authenticates to Action1 (OAuth2 client credentials)
5. Finds or creates the Action1 package named `SumatraPDF` (or `PACKAGE_NAME`)
6. If the latest version is already recorded with a binary attached, exits 0 (NoOp)
7. Otherwise downloads the installer, creates the version, uploads the binary, and
   re-fetches to verify `binary_id.Windows_64` is set

## Run tests

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

## Container usage

The intended public image is:

```
brownindustries/action1-sumatra-managed-updater:latest
```

One-shot mode is the default:

```bash
docker run --rm \
  -e ACTION1_CLIENT_ID="..." \
  -e ACTION1_CLIENT_SECRET="..." \
  -e ACTION1_ORG_ID="all" \
  brownindustries/action1-sumatra-managed-updater:latest
```

Long-running mode starts once immediately, then checks on an interval or cron schedule:

```bash
docker run -d --name action1-sumatra-updater \
  -e ACTION1_CLIENT_ID="..." \
  -e ACTION1_CLIENT_SECRET="..." \
  -e ONE_SHOT="false" \
  -e CHECK_FREQUENCY_MINUTES="1440" \
  brownindustries/action1-sumatra-managed-updater:latest
```

`CHECK_FREQUENCY_CRON` can be used instead of `CHECK_FREQUENCY_MINUTES` for standard
five-field cron expressions.

### Environment variables

| Name | Required | Default | Purpose |
| --- | --- | --- | --- |
| `ACTION1_CLIENT_ID` | yes | none | Action1 API client ID |
| `ACTION1_CLIENT_SECRET` | yes | none | Action1 API client secret |
| `ACTION1_BASE_URL` | no | `https://app.action1.com/api/3.0` | Action1 API base URL |
| `ACTION1_ORG_ID` | no | `all` | Action1 organization scope |
| `PACKAGE_NAME` | no | `SumatraPDF` | Action1 custom package name |
| `ONE_SHOT` | no | `true` | `true` exits after one sync; `false` keeps scheduling |
| `CHECK_FREQUENCY_MINUTES` | no | `1440` | Interval used when `ONE_SHOT=false` and no cron is set |
| `CHECK_FREQUENCY_CRON` | no | none | Cron schedule used when `ONE_SHOT=false` |

GitHub API is used at the anonymous rate limit (60 req/hr). At one sync per day this
is one request per run; keep `CHECK_FREQUENCY_MINUTES` reasonable.

## Public image publishing

`.github/workflows/docker-publish.yml` builds and publishes to Docker Hub as
`brownindustries/action1-sumatra-managed-updater`.

Publishing events match the Fusion repo convention:

- Pull requests build the image but do not log in to Docker Hub and do not push
- Pushes to the default branch publish `latest`, branch, and `sha-*` tags
- `v*` tag pushes publish the matching version tag and `sha-*` tag
- Manual workflow runs publish only when run from the default branch or a `v*` tag
- If Docker Hub secrets are missing, eligible publish runs build only and emit a warning

Required GitHub repository secrets:

```
DOCKER_HUB_REG_USERNAME
DOCKER_HUB_REG_PASSWORD
```

## Recommended deployment

1. Run tests: `pwsh ./tests/run-tests.ps1`
2. Build the image locally: `docker build -t action1-sumatra-managed-updater:dev .`
3. If a `SumatraPDF` package already exists in your Action1 tenant with a different
   shape (e.g. created manually before this updater existed), reconcile it
   (rename, delete, or accept reuse).
4. Run one-shot against the live tenant: `docker run --rm -e ACTION1_CLIENT_ID=... -e ACTION1_CLIENT_SECRET=... action1-sumatra-managed-updater:dev`
5. Confirm the new version is created with the correct binary attached in the Action1 UI
6. Deploy the version to one pilot endpoint via Action1 and confirm install
7. Switch the container to scheduled mode (`ONE_SHOT=false`) for ongoing automation
