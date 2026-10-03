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
| `api_token`         | no       | —                              | VulnWatch API token. **Recommended.** Without it only a *guest preview* scan runs (1 per day, limited findings). Store as a secret: `VULNWATCH_API_TOKEN`. |
| `scan_type`         | no       | `standard`                     | `standard`, `deep`, or `quick`. |
| `api_base_url`      | no       | `https://app.vulnwatch.tech/api` | Override for custom deployments. |
| `fail_on`           | no       | `critical`                     | Highest allowed severity before the job fails: `none`, `critical`, `high`, `medium`, `low`, `info`. `high` fails on any high or critical finding. |
| `timeout_seconds`   | no       | `900`                          | Max time (s) to wait for completion. Standard scans take ~15 min. |
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

## Notes on tokens and guest scans

- **Without a token:** VulnWatch allows only **one guest scan per day** and the
  reported findings are a limited preview. The daily limit returns a clean
  GitHub error (`guest_scan_limit`).
- **With a token:** you get full reports (all findings, complete severity
  counts, risk score) and a meaningful `fail_on` gate. This is the intended
  production use.

## Development

```bash
docker build -t vulnwatch-scan:test .
docker run --rm \
  -e INPUT_URL="https://example.com/" \
  -e INPUT_API_BASE_URL="https://app.vulnwatch.tech/api" \
  -e INPUT_FAIL_ON="critical" \
  vulnwatch-scan:test
```

## License

MIT — see [LICENSE](LICENSE).
