#!/usr/bin/env bash

api_json() {
  local method=GET url='' previous='' argument safe=0 attempt=0 status rc delay body headers result
  for argument in "$@"; do
    [[ "$previous" == '-X' ]] && method="$argument"
    [[ "$argument" == https://* ]] && url="$argument"
    previous="$argument"
  done
  case "$method:$url" in
    GET:*|DELETE:*|POST:*/query|PATCH:https://api.notion.com/v1/pages/*) safe=1 ;;
  esac
  body=$(mktemp) || return 1
  headers=$(mktemp) || { rm -f "$body"; return 1; }
  while :; do
    rc=0
    status=$(curl --silent --show-error --connect-timeout 10 --max-time 45 \
      --output "$body" --dump-header "$headers" --write-out '%{http_code}' "$@" 2>/dev/null) || rc=$?
    if [[ "$rc" == 0 && "$status" == 2?? ]] && jq -e 'type == "object" and .object != "error" and (has("errors") | not)' "$body" >/dev/null 2>&1; then
      cat "$body"
      rm -f "$body" "$headers"
      return 0
    fi
    attempt=$((attempt + 1))
    if [[ "$attempt" -ge 4 ]]; then break; fi
    if [[ "$status" == 429 || "$status" == 529 ]] && ! jq -e '.additional_data.rate_limit_reason == "public_api_request_blocked"' "$body" >/dev/null 2>&1; then
      delay=$(awk 'tolower($1)=="retry-after:" {gsub("\r", "", $2); print $2}' "$headers" | tail -1)
      if ! [[ "$delay" =~ ^[0-9]+$ ]]; then delay=$((2 ** attempt)); fi
      # A long server-requested delay is deferred to the next job, never shortened.
      if [[ "$delay" -gt 60 ]]; then break; fi
    elif [[ "$safe" == 1 && ( "$rc" != 0 || "$status" == 500 || "$status" == 502 || "$status" == 503 || "$status" == 504 ) ]]; then
      delay=$((2 ** attempt))
    else
      break
    fi
    sleep "$delay"
  done
  echo "API request failed ($method; HTTP ${status:-unknown}; transport $rc). Checkpoint retained." >&2
  rm -f "$body" "$headers"
  return 1
}

urlencode() { jq -rn --arg value "$1" '$value | @uri'; }

loyverse_receipts() {
  local since="$1" cursor='' seen='|' page all='{"receipts":[]}' endpoint
  endpoint="https://api.loyverse.com/v1.0/receipts?limit=250&since_receipt_number=$(urlencode "$since")"
  while :; do
    page=$(api_json -H "Authorization: Bearer $LOYVERSE_API_KEY" "$endpoint${cursor:+&cursor=$cursor}") || return 1
    jq -e '.receipts | type == "array"' <<<"$page" >/dev/null || return 1
    all=$(jq -cn --argjson all "$all" --argjson page "$page" '{receipts: ($all.receipts + $page.receipts)}') || return 1
    cursor=$(jq -r '.cursor // empty' <<<"$page") || return 1
    [[ -z "$cursor" ]] && break
    if [[ "$seen" == *"|$cursor|"* ]]; then echo 'Repeated receipt cursor; checkpoint retained.' >&2; return 1; fi
    seen="$seen$cursor|"
    cursor=$(urlencode "$cursor") || return 1
  done
  jq -ce '.receipts |= (unique_by(.receipt_number) | sort_by(.created_at))' <<<"$all"
}

notion_find_receipt() {
  local filter response
  filter=$(jq -cn --arg rn "$1" '{page_size:100,filter:{property:"receipt_number",title:{equals:$rn}}}') || return 1
  response=$(api_json -X POST "https://api.notion.com/v1/databases/$NOTION_DB_ID/query" \
    -H "Authorization: Bearer $NOTION_API_KEY" -H 'Notion-Version: 2022-06-28' \
    -H 'Content-Type: application/json' --data "$filter") || return 1
  jq -e '(.results | type == "array") and (.results | length) <= 1 and .has_more != true' <<<"$response" >/dev/null || {
    echo 'Ambiguous receipt lookup; resolve duplicate pages before retrying.' >&2; return 1;
  }
  jq -c '.results[0] // {}' <<<"$response"
}

notion_receipt_tables() {
  local pid="$1" cursor='' seen='|' response tables table first next
  while :; do
    response=$(api_json "https://api.notion.com/v1/blocks/$pid/children?page_size=100${cursor:+&start_cursor=$cursor}" \
      -H "Authorization: Bearer $NOTION_API_KEY" -H 'Notion-Version: 2022-06-28') || return 1
    jq -e '.results | type == "array"' <<<"$response" >/dev/null || return 1
    tables=$(jq -r '.results[] | select(.type == "table" and .table.table_width == 7) | .id' <<<"$response") || return 1
    if [[ -n "$tables" ]]; then
      while IFS= read -r table; do
        first=$(api_json "https://api.notion.com/v1/blocks/$table/children?page_size=1" \
          -H "Authorization: Bearer $NOTION_API_KEY" -H 'Notion-Version: 2022-06-28') || return 1
        if jq -e '[.results[0].table_row.cells[]? | map(.plain_text // .text.content // "") | join("")] == ["Item","Variant","Qty","Price","Note","Modifiers","Category"]' <<<"$first" >/dev/null; then
          printf '%s\n' "$table"
        fi
      done <<<"$tables"
    fi
    [[ $(jq -r '.has_more // false' <<<"$response") != true ]] && break
    next=$(jq -er '.next_cursor | select(type == "string" and length > 0)' <<<"$response") || return 1
    if [[ "$seen" == *"|$next|"* ]]; then return 1; fi
    seen="$seen$next|"
    cursor=$(urlencode "$next") || return 1
  done
}

persist_receipt() {
  local page_id="$1" props="$2" children="$3" payload response old_tables block
  if [[ -z "$page_id" ]]; then
    payload=$(jq -cn --argjson p "$props" --argjson c "$children" '$p + {children:$c}') || return 1
    response=$(api_json -X POST 'https://api.notion.com/v1/pages' \
      -H "Authorization: Bearer $NOTION_API_KEY" -H 'Notion-Version: 2022-06-28' \
      -H 'Content-Type: application/json' --data "$payload") || return 1
    jq -e '.object == "page" and (.id | type == "string" and length > 0)' <<<"$response" >/dev/null || return 1
    return 0
  fi

  old_tables=$(notion_receipt_tables "$page_id") || return 1
  payload=$(jq -cn --argjson children "$children" '{children:$children}') || return 1
  response=$(api_json -X PATCH "https://api.notion.com/v1/blocks/$page_id/children" \
    -H "Authorization: Bearer $NOTION_API_KEY" -H 'Notion-Version: 2022-06-28' \
    -H 'Content-Type: application/json' --data "$payload") || return 1
  jq -e '(.results | type == "array") and (.results | length) > 0 and all(.results[]; .type == "table" and (.id | type == "string" and length > 0))' <<<"$response" >/dev/null || return 1

  # Keep the previous receipt table until its replacement has been accepted.
  if [[ -n "$old_tables" ]]; then
    while IFS= read -r block; do
      api_json -X DELETE "https://api.notion.com/v1/blocks/$block" \
        -H "Authorization: Bearer $NOTION_API_KEY" -H 'Notion-Version: 2022-06-28' >/dev/null || return 1
    done <<<"$old_tables"
  fi
  # updated_at is the completion marker, so write it after content and cleanup.
  payload=$(jq -c '{properties:.properties}' <<<"$props") || return 1
  response=$(api_json -X PATCH "https://api.notion.com/v1/pages/$page_id" \
    -H "Authorization: Bearer $NOTION_API_KEY" -H 'Notion-Version: 2022-06-28' \
    -H 'Content-Type: application/json' --data "$payload") || return 1
  jq -e '.object == "page" and (.id | type == "string" and length > 0)' <<<"$response" >/dev/null
}

write_checkpoint() {
  local tmp
  tmp=$(mktemp "${LAST_RECEIPT_FILE}.XXXXXX") || return 1
  printf '%s\n' "$1" > "$tmp" && mv "$tmp" "$LAST_RECEIPT_FILE"
}
