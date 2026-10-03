#!/usr/bin/env bash
#
# VulnWatch Scan GitHub Action entrypoint.
#
# Drives the VulnWatch scan API:
#   1. POST    {base}/scan                  -> submit scan, returns check_uuid
#   2. GET     {base}/scan/{uuid}/status    -> poll until is_completed | is_error
#   3. GET     {base}/scan/report/{uuid}    -> fetch report payload
#   4. Evaluate findings severities, fail on threshold, emit outputs.
#
# All inputs are passed by the runner via env vars named INPUT_<UPPER_SNAKE>.

set -uo pipefail

# GitHub Actions injects GITHUB_OUTPUT/GITHUB_STEP_SUMMARY for docker actions.
GITHUB_OUTPUT="${GITHUB_OUTPUT:-}"
emit_output() { # name value
  local n="$1" v="$2"
  if [[ -n "$GITHUB_OUTPUT" ]] && [[ -f "$GITHUB_OUTPUT" ]]; then
    printf '%s=%s\n' "$n" "$v" >> "$GITHUB_OUTPUT"
  else
    echo "::set-output name=${n}::${v}"
  fi
}

# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------
URL="${INPUT_URL:-}"
SCAN_TYPE="${INPUT_SCAN_TYPE:-standard}"
API_TOKEN="${INPUT_API_TOKEN:-}"
BASE_URL="${INPUT_API_BASE_URL:-https://app.vulnwatch.tech/api}"
FAIL_ON="${INPUT_FAIL_ON:-critical}"
TIMEOUT="${INPUT_TIMEOUT_SECONDS:-900}"
REPORT_ARTIFACT="${INPUT_REPORT_ARTIFACT:-true}"

BASE_URL="${BASE_URL%/}"

if [[ -z "$URL" ]]; then
  echo "::error::Missing required input 'url'"
  exit 1
fi

# Normalize FAIL_ON to a rank. Higher = more severe.
severity_rank() {
  case "$1" in
    critical) echo 5 ;;
    high)     echo 4 ;;
    medium)   echo 3 ;;
    low)      echo 2 ;;
    info)     echo 1 ;;
    none)     echo 0 ;;
    *)        echo 0 ;;
  esac
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# GitHub Actions injects GITHUB_STEP_SUMMARY for docker actions too.
GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-}"
emit_summary() { # line
  if [[ -n "$GITHUB_STEP_SUMMARY" ]] && [[ -f "$GITHUB_STEP_SUMMARY" ]]; then
    printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
  fi
}

echo "==> VulnWatch Scan"
echo "    URL:      $URL"
echo "    ScanType: $SCAN_TYPE"
echo "    API:      $BASE_URL"
[[ -n "$API_TOKEN" ]] && echo "    Auth:     authenticated (token provided)"
[[ -z "$API_TOKEN" ]] && echo "    Auth:     guest (no token — limited preview scan)"

# ---------------------------------------------------------------------------
# 1. Submit scan
# ---------------------------------------------------------------------------
echo "==> Submitting scan..."

BODY_FILE=$(mktemp)
SUBMIT_PAYLOAD=$(mktemp)

# Build JSON body safely with jq
if [[ -n "$API_TOKEN" ]]; then
  jq -n \
    --arg url "$URL" \
    --arg scan_type "$SCAN_TYPE" \
    --arg notify_email "" \
    '{url: $url, scan_type: $scan_type, notify_email: $notify_email}' > "$BODY_FILE"
else
  jq -n \
    --arg url "$URL" \
    --arg scan_type "$SCAN_TYPE" \
    '{url: $url, scan_type: $scan_type}' > "$BODY_FILE"
fi

HTTP_CODE=$(curl -sS -o "$SUBMIT_PAYLOAD" -w '%{http_code}' \
  -X POST "${BASE_URL}/scan" \
  ${API_TOKEN:+-H "Authorization: Bearer $API_TOKEN"} \
  -H "Accept: application/json" \
  -H "Content-Type: application/json" \
  --data-binary @"$BODY_FILE")

CHECK_UUID=$(jq -r '.data.result.check_uuid // empty' "$SUBMIT_PAYLOAD" 2>/dev/null)

if [[ "$HTTP_CODE" != "200" ]] || [[ -z "$CHECK_UUID" ]]; then
  echo "::error::Scan submission failed (HTTP $HTTP_CODE)"
  jq -c '.' "$SUBMIT_PAYLOAD" 2>/dev/null | head -c 2000 || cat "$SUBMIT_PAYLOAD"
  echo ""
  exit 1
fi

echo "    check_uuid: $CHECK_UUID"
emit_output "check_uuid" "$CHECK_UUID"

# ---------------------------------------------------------------------------
# 2. Poll status
# ---------------------------------------------------------------------------
echo "==> Waiting for scan completion (timeout ${TIMEOUT}s)..."

START=$SECONDS
STATUS_FILE=$(mktemp)
while true; do
  ELAPSED=$((SECONDS - START))
  if [[ $ELAPSED -ge $TIMEOUT ]]; then
    echo "::error::Timed out after ${TIMEOUT}s waiting for scan $CHECK_UUID"
    exit 1
  fi

  CODE=$(curl -sS -o "$STATUS_FILE" -w '%{http_code}' \
    "${BASE_URL}/scan/${CHECK_UUID}/status" \
    ${API_TOKEN:+-H "Authorization: Bearer $API_TOKEN"} \
    -H "Accept: application/json")

  if [[ "$CODE" != "200" ]]; then
    echo "::warning::Status endpoint returned HTTP $CODE, retrying..."
    sleep 5
    continue
  fi

  IS_COMPLETED=$(jq -r '.data.is_completed // false' "$STATUS_FILE")
  IS_ERROR=$(jq -r '.data.is_error // false' "$STATUS_FILE")
  PROGRESS=$(jq -r '.data.progress // ""' "$STATUS_FILE")

  if [[ "$IS_ERROR" == "true" ]]; then
    echo "::error::Scan $CHECK_UUID failed on the VulnWatch side."
    jq -c '.' "$STATUS_FILE" | head -c 2000
    exit 1
  fi

  if [[ "$IS_COMPLETED" == "true" ]]; then
    echo "    completed in ${ELAPSED}s"
    break
  fi

  if [[ -n "$PROGRESS" ]] && [[ "$PROGRESS" != "null" ]]; then
    echo "    progress: $PROGRESS"
  fi

  sleep 5
done

# ---------------------------------------------------------------------------
# 3. Fetch report
# ---------------------------------------------------------------------------
echo "==> Fetching report..."
REPORT_FILE=$(mktemp)

# Guest report access requires the anonymous_check_uuid query param (matches
# how report-client.tsx calls it); an authorized token can access directly.
REPORT_QUERY=""
if [[ -z "$API_TOKEN" ]]; then
  REPORT_QUERY="?anonymous_check_uuid=${CHECK_UUID}"
fi

CODE=$(curl -sS -o "$REPORT_FILE" -w '%{http_code}' \
  "${BASE_URL}/scan/report/${CHECK_UUID}${REPORT_QUERY}" \
  ${API_TOKEN:+-H "Authorization: Bearer $API_TOKEN"} \
  -H "Accept: application/json")

if [[ "$CODE" != "200" ]]; then
  echo "::warning::Report fetch returned HTTP $CODE (report may be gated behind unlock)."
  head -c 800 "$REPORT_FILE"
  echo ""
  # Without a paid report there is nothing to evaluate; keep outputs empty and
  # succeed so the step does not fail on the paywall itself.
  emit_output "url" "$URL"
  emit_output "findings_count" "0"
  emit_output "risk_score" "n/a"
  emit_output "report_url" ""
  exit 0
fi

# ---------------------------------------------------------------------------
# 4. Summarize findings
# ---------------------------------------------------------------------------
echo "==> Report summary"

# findings: prefer all_findings (full), fall back to top-level findings list
FINDINGS_JSON=$(jq -c '{findings: (.data.all_findings // .data.findings // [])}' "$REPORT_FILE")
TOTAL=$(echo "$FINDINGS_JSON" | jq '.findings | length')

CRITICAL=$(echo "$FINDINGS_JSON" | jq '[.findings[]? | select((.severity // "info") == "critical")] | length')
HIGH=$(echo "$FINDINGS_JSON" | jq '[.findings[]? | select((.severity // "info") == "high")] | length')
MEDIUM=$(echo "$FINDINGS_JSON" | jq '[.findings[]? | select((.severity // "info") == "medium")] | length')
LOW=$(echo "$FINDINGS_JSON" | jq '[.findings[]? | select((.severity // "info") == "low")] | length')
INFO=$(echo "$FINDINGS_JSON" | jq '[.findings[]? | select((.severity // "info") == "info" or (.severity // "info") == "informational")] | length')

RISK_SCORE=$(jq -r '.data.score // (.data.score_summary.risk_score // "n/a")' "$REPORT_FILE")
REPORT_URL=$(jq -r '.data.report_url // empty' "$STATUS_FILE")

echo "    findings:   $TOTAL (critical: $CRITICAL, high: $HIGH, medium: $MEDIUM, low: $LOW, info: $INFO)"
echo "    risk_score: $RISK_SCORE"
[[ -n "$REPORT_URL" ]] && echo "    report:     $REPORT_URL"

emit_summary "## VulnWatch Scan Summary"
emit_summary ""
emit_summary "| Metric | Value |"
emit_summary "|---|---|"
emit_summary "| URL | \`$URL\` |"
emit_summary "| Findings | $TOTAL |"
emit_summary "| Risk score | $RISK_SCORE |"
emit_summary "| Critical | $CRITICAL |"
emit_summary "| High | $HIGH |"
emit_summary "| Medium | $MEDIUM |"
emit_summary "| Low | $LOW |"
emit_summary "| Info | $INFO |"
[[ -n "$REPORT_URL" ]] && emit_summary "| Report | [$REPORT_URL]($REPORT_URL) |"
emit_summary ""

emit_output "url" "$URL"
emit_output "findings_count" "$TOTAL"
emit_output "critical_count" "$CRITICAL"
emit_output "high_count" "$HIGH"
emit_output "medium_count" "$MEDIUM"
emit_output "low_count" "$LOW"
emit_output "info_count" "$INFO"
emit_output "risk_score" "$RISK_SCORE"
emit_output "report_url" "$REPORT_URL"

# Save report artifact
if [[ "$REPORT_ARTIFACT" == "true" ]]; then
  mkdir -p /github/workspace/vulnwatch-report
  cp "$REPORT_FILE" "/github/workspace/vulnwatch-report/${CHECK_UUID}.json"
  echo "    artifact:   vulnwatch-report/${CHECK_UUID}.json"
fi

# ---------------------------------------------------------------------------
# 5. Fail on threshold
# ---------------------------------------------------------------------------
THRESHOLD=$(severity_rank "$FAIL_ON")
if [[ "$THRESHOLD" -gt 0 ]]; then
  # rank of a finding's severity (1-5); severity_rank's mapping duplicated for jq
  RANK='( .severity // "info" ) as $s | ( {"critical":5,"high":4,"medium":3,"low":2,"info":1}[$s] // 0 )'
  FAILED_COUNT=$(echo "$FINDINGS_JSON" | jq --argjson f "$THRESHOLD" \
    "[.findings[]? | select($RANK >= \$f)] | length")
  FAILED_LABEL=$(echo "$FINDINGS_JSON" | jq --argjson f "$THRESHOLD" -r \
    "[.findings[]? | select($RANK >= \$f) | (.severity // \"info\")] | group_by(.) | map({k:.[0], n:length}) | map(\"\\(.k)x\\(.n)\") | join(\", \")")

  if [[ "$FAILED_COUNT" -gt 0 ]]; then
    echo "::error::Found $FAILED_COUNT finding(s) at or above severity '$FAIL_ON' ($FAILED_LABEL). Report: $REPORT_URL"
    exit 1
  fi
  echo "==> No findings at or above severity '$FAIL_ON'. Build passes."
fi

exit 0
