# VulnWatch Scan — GitHub Action

Run a **VulnWatch** security scan against a live URL directly from your GitHub
Actions workflow. The action submits the URL to the VulnWatch API, waits for the
scan to complete, reports finding counts by severity plus a risk score, and can
**fail the job** when findings meet a severity threshold you choose.

## Quick start

```yaml
name: Scan my site

on:
  schedule:
    - cron: '0 6 * * 1'   # every Monday 06:00 UTC
  workflow_dispatch:

jobs:
  vulnwatch-scan:
    runs-on: ubuntu-latest
    steps:
      - uses: anton-kulyk/vulnwatch-scan@v1
        with:
          url: 'https://example.com/'
          api_token: ${{ secrets.VULNWATCH_API_TOKEN }}
          fail_on: 'high'
      # Optional: fail the build without looking at the report
```

## Inputs

| Input               | Required | Default                        | Description |
|---------------------|:--------:|--------------------------------|-------------|
| `url`               | **yes**  | —                              | Absolute URL to scan (e.g. `https://example.com/`). |
| `api_token`         | **yes**  | —                              | VulnWatch API token. Create it in the dashboard (Settings → API tokens) with the *start scans* ability, then store as a secret: `VULNWATCH_API_TOKEN`. There is no guest path on this endpoint. |
| `scan_type`         | no       | `standard`                     | Scan profile: `basic`, `standard`, `full`, or `custom`. |
| `tools`             | no       | (all allowed)                  | Comma-separated external scanners to run: `nmap`, `nuclei`, `zap`, `sqlmap`, `wpscan`. Only tools your token grants are actually run. Omit to use every tool the token allows. |
| `ai_analyst`        | no       | (account default)              | `true` to enable the AI analyst on this scan (requires the matching token ability). |
| `fail_on`           | no       | `critical`                     | Highest allowed severity before the job fails: `none`, `critical`, `high`, `medium`, `low`, `info`. `high` fails on any high or critical finding. |
| `timeout_seconds`   | no       | `900`                          | Max time (s) to wait for completion. |
| `report_artifact`   | no       | `true`                         | Save raw report JSON under `vulnwatch-report/<uuid>.json`. |

## Outputs

`check_uuid`, `url`, `findings_count`, `critical_count`, `high_count`,
`medium_count`, `low_count`, `info_count`, `risk_score`, `report_url`.

## Example: upload the report as an artifact

```yaml
- uses: anton-kulyk/vulnwatch-scan@v1
  id: scan
  with:
    url: 'https://example.com/'
    api_token: ${{ secrets.VULNWATCH_API_TOKEN }}
    fail_on: 'high'

- if: always()
  uses: actions/upload-artifact@v4
  with:
    name: vulnwatch-report
    path: vulnwatch-report/
```

The action also writes a **step summary** table (job summary) with the severity
breakdown so you can see results directly in the run page.

## Notes on the API token

- This endpoint is **token-authenticated only** — there is no guest path. The
  action fails fast if `api_token` is missing.
- Create a token in the VulnWatch dashboard (**Settings → API tokens**). Grant
  the *start scans* ability (plus *AI analyst* if you want to use
  `ai_analyst: true`). Only tools your token explicitly allows are ever run by
  the API — the `tools` input can request them, but the token grants final
  permission.
- Store the token as a GitHub Actions secret, e.g. `VULNWATCH_API_TOKEN`, and
  reference it with `${{ secrets.VULNWATCH_API_TOKEN }}`.

## Tools

`tools` controls which external scanners run: `nmap`, `nuclei`, `zap`,
`sqlmap`, `wpscan`. A token that does not grant a requested tool silently skips
it; omit `tools` entirely to run every scanner the token allows.

## Development

```bash
docker build -t vulnwatch-scan:test .
docker run --rm \
  -e INPUT_URL="https://example.com/" \
  -e INPUT_API_TOKEN="$VULNWATCH_API_TOKEN" \
  -e INPUT_TOOLS="nmap,nuclei" \
  -e INPUT_FAIL_ON="critical" \
  vulnwatch-scan:test
```

## License

MIT — see [LICENSE](LICENSE).
