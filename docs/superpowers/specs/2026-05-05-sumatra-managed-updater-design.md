# SumatraPDF Action1 Managed Updater — Design

Status: Approved (brainstorm phase). Author: collaborative session, 2026-05-05.

## Purpose

Mirror the architecture of `Brown-Industries/action1-fusion-managed-updater` for SumatraPDF, with two material differences driven by Sumatra being a real installer catalog (not an audit log):

1. Action1 versions are pinned, deployable installers — the actual `SumatraPDF-{version}-64-install.exe` is uploaded as the Windows_64 binary so endpoints can be deployed to a specific historical version.
2. Version discovery uses GitHub Releases (Sumatra publishes tagged releases there) instead of a vendor "always-latest" installer URL. Latest stable only — no pre-releases, no backfill of historical versions.

We only support 64-bit Windows installer builds. 32-bit, ARM, and portable builds are out of scope.

## Repo and image

- Repo: `Brown-Industries/action1-sumatra-managed-updater`
- Image: `brownindustries/action1-sumatra-managed-updater:latest`
- Base image: `mcr.microsoft.com/powershell:7.4-ubuntu-22.04`

## Repo layout

```
src/
  SumatraManagedUpdate.Common.psm1     # version compare, GitHub API, URL construction, install body builder
  Action1Repository.psm1               # ports Fusion's verbatim (auth, package, version, upload)
  Sync-SumatraAction1Release.ps1       # main entry: discover latest, ensure package, create+upload version
container/
  entrypoint.ps1                       # one-shot or interval/cron loop, ported from Fusion
tests/
  SumatraManagedUpdate.Tests.ps1
  fixtures/                            # offline GitHub API + Action1 fixtures
  run-tests.ps1
.github/workflows/docker-publish.yml   # ported from Fusion
Dockerfile
docker-compose.example.yml
README.md
.dockerignore
```

Material differences from Fusion's repo:

- No `dist/` and no `packaging/build-action1-payload.ps1`. There is no PS1 payload to build; the Action1 binary is the actual installer EXE.
- No `state/` directory. The Action1 package's `versions[]` list is the source of truth for what has already been recorded.
- No watcher / repository-sync split. `Sync-SumatraAction1Release.ps1` does discovery and Action1 write in one pass. (Fusion split them because it runs dry-run-then-live across two cron jobs; that gate isn't useful here since each Sumatra version is independently deployable.)
- No endpoint script. Action1 runs the installer EXE directly via the package's `silent_install_switches`. There is no `Invoke-SumatraManagedUpdate.ps1` and no `RunningProcessPolicy`.

## Approach 3 was selected

Considered three approaches:

1. Direct port of Fusion architecture. Familiar but carries dead weight (base64 payload builder, endpoint script, state file, RunningProcessPolicy, "build version from Action1 inventory" logic — none of which fit Sumatra's model).
2. Single collapsed script. Smallest possible repo. Rejected for losing the cross-repo familiarity with Fusion's layout and the useful seam between common-module and entry-script.
3. Same shape as Fusion, drop what doesn't fit. Selected.

## Data flow (one sync run)

```
1. GitHub Releases API
   GET https://api.github.com/repos/sumatrapdfreader/sumatrapdf/releases/latest
   The /latest endpoint returns the latest non-prerelease, non-draft release by definition.
   No client-side filtering needed; one API call per run.
   Extract: tag_name, normalize to bare version (e.g. "3.5.2-rel" -> "3.5.2").

2. Construct installer URL from version
   https://www.sumatrapdfreader.org/dl/rel/{version}/SumatraPDF-{version}-64-install.exe
   Verify with HTTP HEAD: must return 200 and a non-empty Content-Length, else fail loudly.
   No silent fallback — if the URL pattern ever shifts we want a hard failure, not a wrong upload.

3. Action1 auth and package lookup
   POST /oauth2/token  (grant_type=client_credentials)
   GET  /software-repository/{org}?custom=yes&filter={PACKAGE_NAME}&fields=*&limit=100
   If exact-name match exists, reuse it; else POST to create with New-Action1SumatraPackageBody.

4. Idempotency check against Action1
   GET /software-repository/{org}/{pkg}?fields=versions
   If version == latest GitHub version AND record has Windows_64 binary AND filename matches expected name:
     log NoOp, exit 0.

5. Download installer
   curl.exe (or Invoke-WebRequest fallback) to /tmp/SumatraPDF-{version}-64-install.exe.
   Verify: file exists, size > 0. SHA256 logged for audit.

6. Create or complete Action1 version
   - If no version record for {version} yet:
       POST /software-repository/{org}/{pkg}/versions  (body via New-Action1SumatraVersionBody)
   - If record exists but missing binary:
       PATCH file_name to expected name, then upload.
   Then upload the EXE: POST /upload?platform=Windows_64 → PUT to X-Upload-Location.
   Re-GET the version, verify binary_id.Windows_64 + filename match. Fail if not.
```

### Idempotency model

No state file. Re-running on an unchanged GitHub state is a NoOp (step 4 returns early). The Action1 package's `versions[]` is the durable state — same idempotency property as Fusion's repo sync, without needing an HTTP HEAD watcher state file because GitHub gives us the version string directly.

### `New-Action1SumatraVersionBody` shape

```powershell
[ordered]@{
  version                 = '3.5.2'
  app_name_match          = '^SumatraPDF$'
  release_date            = '2026-05-05'             # detection date (sync run date)
  security_severity       = 'Unspecified'
  silent_install_switches = '-install -silent'       # to be confirmed against installer help during impl
  success_exit_codes      = '0'
  reboot_exit_codes       = ''                       # Sumatra installer does not signal reboot
  install_type            = 'exe'
  EULA_accepted           = 'no'
  update_type             = 'Regular Updates'
  os                      = @('Windows 10','Windows 11')
  file_name               = @{ Windows_64 = @{ name = 'SumatraPDF-3.5.2-64-install.exe'; type = 'cloud' } }
}
```

Two flagged risks to verify during implementation:

1. **Installer URL pattern is an assumption.** The pattern `https://www.sumatrapdfreader.org/dl/rel/{v}/SumatraPDF-{v}-64-install.exe` will be verified against the current release and at least two prior versions during implementation. If older releases use a different pattern, restrict to the latest-known-good pattern and hard-fail when it breaks.
2. **Silent install switches.** `-install -silent` is the standard Sumatra installer interface, but will be confirmed against actual installer `--help` output during implementation. Older NSIS-style builds may use `/S`.

## Error handling and failure modes

### Hard-fail (exit non-zero)

- GitHub `/releases/latest` returns 4xx/5xx, including rate-limit (anonymous: 60/hr). The container does not retry within a run; the next scheduled run retries.
- `tag_name` normalization produces an empty or non-semver string.
- Constructed installer URL HEAD ≠ 200, or returns 0 Content-Length.
- Installer download produces a 0-byte or partial file.
- Action1 OAuth token request fails or response is missing `access_token`.
- Multiple Action1 packages exact-match `PACKAGE_NAME` (refuses to act on ambiguous state — same guard Fusion has).
- Upload init returns unexpected status, or `X-Upload-Location` host doesn't match Action1 base URL host (port + scheme + host equality, ported from `Assert-Action1UploadLocationAllowed`).
- Post-upload verification: re-fetched version doesn't report `binary_id.Windows_64` or filename doesn't match.

### NoOp (exit 0)

- Latest GitHub version already exists in Action1 with matching binary and filename. Logged with explicit reason.

### Soft-fail in long-running mode

- In `ONE_SHOT=false` mode, a thrown error is caught, written to stderr, and the next interval still fires. Mirrors Fusion's `entrypoint.ps1`.

### Logging

- All progress to stdout, picked up by Action1 history / Docker logs.
- Step prefixes: `SUMATRA_STEP github_query_start`, `github_release_selected`, `installer_url_resolved`, `installer_download_start`, `action1_package_resolved`, `action1_version_create`, `action1_upload_start`, `verification_success`, `failure`.
- No durable on-disk log inside the container — the container is stateless.

### Secret handling

- `ACTION1_CLIENT_SECRET` never logged.
- The Action1-issued signed `X-Upload-Location` URL is host-validated but never echoed.

## Container and runtime

### Environment variables

| Name | Required | Default | Purpose |
| --- | --- | --- | --- |
| `ACTION1_CLIENT_ID` | yes | none | Action1 API client ID |
| `ACTION1_CLIENT_SECRET` | yes | none | Action1 API client secret |
| `ACTION1_BASE_URL` | no | `https://app.action1.com/api/3.0` | Action1 API base URL |
| `ACTION1_ORG_ID` | no | `all` | Action1 organization scope |
| `PACKAGE_NAME` | no | `SumatraPDF` | Action1 custom package name |
| `ONE_SHOT` | no | `true` | `true` exits after one sync; `false` schedules repeating runs |
| `CHECK_FREQUENCY_MINUTES` | no | `1440` | Interval used when `ONE_SHOT=false` and no cron is set |
| `CHECK_FREQUENCY_CRON` | no | none | Cron schedule used when `ONE_SHOT=false` |

The default `PACKAGE_NAME` is the app name itself (`SumatraPDF`), not a "Managed Updater" suffix. Fusion uses the suffix because its package is an audit log; Sumatra's package is the deployable installer catalog, so the package name should match the app.

GitHub API is used at the anonymous rate limit (60 req/hr). At one sync per day this is one request per run; even at one per minute we stay well under the limit. The operator is expected to keep `CHECK_FREQUENCY_MINUTES` reasonable.

### Run modes

- **One-shot** (default) — single sync, exit 0 or non-zero.
- **Interval** — `ONE_SHOT=false` + `CHECK_FREQUENCY_MINUTES` (default `1440`).
- **Cron** — `ONE_SHOT=false` + `CHECK_FREQUENCY_CRON` (5-field cron expression).

`container/entrypoint.ps1` ports straight from Fusion (replace the script path).

### Runtime invariants

- Stateless container: no volumes, no on-disk state. Re-running is safe.
- The Action1 package itself is the durable state.
- Concurrent replicas could race on the same package version. Not a concern at daily-cron cadence; if it ever happens, Action1 rejects duplicate version creation and the loser exits non-zero.

## Testing

### Pester offline tests

`tests/SumatraManagedUpdate.Tests.ps1` covers unit-level seams without hitting any network:

- The GitHub `/releases/latest` response shape is parsed correctly into version + published_at.
- Tag → version normalization across observed Sumatra tag forms (`3.5.2-rel`, `3.5.2`, leading `v`).
- Installer URL construction matches the documented pattern; rejected for malformed versions.
- `Resolve-Action1VersionSyncAction` returns `NoOp` / `UploadMissingBinary` / `UploadCurrentPayload` / `CreateAndUpload` correctly given fixture package responses.
- `Select-Action1PackageByExactName` rejects multi-match.
- `Assert-Action1UploadLocationAllowed` rejects mismatched host/scheme/port.
- `New-Action1SumatraVersionBody` produces the expected ordered shape.

### Offline-fixture integration test

`Sync-SumatraAction1Release.ps1 -OfflineFixtureRoot ./tests/fixtures/sync` runs the full flow against canned GitHub + Action1 JSON, writing a request log so we can assert the exact API call sequence. Same pattern Fusion uses.

### No live endpoint test in this repo

Action1 itself runs the EXE on real endpoints. We validate the upload, then deploy to a pilot machine following the same runbook pattern Fusion's repo describes.

### CI

Port Fusion's `.github/workflows/docker-publish.yml` verbatim; retarget the image to `brownindustries/action1-sumatra-managed-updater`. Same publish gates (default-branch + `v*` tags), same secrets (`DOCKER_HUB_REG_USERNAME`, `DOCKER_HUB_REG_PASSWORD`).

## Deployment notes

### First-deploy Action1 cleanup

During initial rollout, any existing Action1 packages named `SumatraPDF` (or matching installed-software inventory under that name) may be removed or superseded if their shape conflicts with the new package's `app_name_match` / version layout. The user has authorized this. This is a one-time first-deploy concern; recurring runs treat the package they created as the source of truth and never delete versions.

### Suggested rollout

1. Run offline tests (`pwsh ./tests/run-tests.ps1`).
2. Run `Sync-SumatraAction1Release.ps1 -OfflineFixtureRoot ./tests/fixtures/sync` and assert the captured request log.
3. Reconcile any pre-existing `SumatraPDF` package(s) in Action1 (rename, delete, or accept reuse).
4. Run the container in one-shot mode against the live Action1 tenant; verify the new version is created with the correct binary attached.
5. Deploy to one pilot endpoint via Action1; confirm install + version reported in inventory.
6. Switch the container to scheduled mode (`ONE_SHOT=false` with cron or interval) for ongoing automation.
