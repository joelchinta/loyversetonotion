#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────
LOYVERSE_API_KEY="${LOYVERSE_API_KEY:-}"
NOTION_API_KEY="${NOTION_API_KEY:-}"
NOTION_DB_ID="${NOTION_DB_ID:-}"

if [[ -z "$LOYVERSE_API_KEY" || -z "$NOTION_API_KEY" || -z "$NOTION_DB_ID" ]]; then
  echo "Error: Required environment variables not set"
  exit 1
fi

CACHE_FILE=".loyverse_cache.json"
LAST_RECEIPT_FILE=".last_receipt.txt"

# ─────────────────────────────────────────────────────────────────────────────
# LOAD LAST RECEIPT NUMBER
# ─────────────────────────────────────────────────────────────────────────────
if [[ -f "$LAST_RECEIPT_FILE" ]]; then
  RECEIPTNUMBER=$(cat "$LAST_RECEIPT_FILE")
  echo "📋 Resuming from receipt: $RECEIPTNUMBER"
else
  RECEIPTNUMBER="Value"
  echo "📋 Starting fresh (no previous receipt number)"
fi

echo "🔄 Fetching receipts from Loyverse..."

RAW=$(curl -s -H "Authorization: Bearer $LOYVERSE_API_KEY" \
  "https://api.loyverse.com/v1.0/receipts?since_receipt_number=$RECEIPTNUMBER")

# Check if we got any receipts
RECEIPT_COUNT=$(jq -r '.receipts | length' <<<"$RAW")
echo "📦 Found $RECEIPT_COUNT receipt(s) to process"

if [[ "$RECEIPT_COUNT" == "0" ]]; then
  echo "✅ No new receipts. Exiting."
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# NOTION HELPERS
# ─────────────────────────────────────────────────────────────────────────────
notion_list_children() {
  local pid="$1"
  local cursor=""
  while :; do
    local url="https://api.notion.com/v1/blocks/${pid}/children?page_size=100"
    [[ -n "$cursor" ]] && url="${url}&start_cursor=${cursor}"
    local resp
    resp=$(curl -s -X GET "$url" \
      -H "Authorization: Bearer $NOTION_API_KEY" \
      -H "Notion-Version: 2022-06-28")
    jq -r '.results[]?.id' <<<"$resp"
    local has_more
    has_more=$(jq -r '.has_more' <<<"$resp")
    if [[ "$has_more" == "true" ]]; then
      cursor=$(jq -r '.next_cursor' <<<"$resp")
    else
      break
    fi
  done
}

notion_delete_block() {
  local bid="$1"
  curl -s -X DELETE "https://api.notion.com/v1/blocks/${bid}" \
    -H "Authorization: Bearer $NOTION_API_KEY" \
    -H "Notion-Version: 2022-06-28" >/dev/null
}

clear_page_children() {
  local pid="$1"
  while read -r bid; do
    [[ -n "$bid" ]] && notion_delete_block "$bid"
  done < <(notion_list_children "$pid")
}

# ─────────────────────────────────────────────────────────────────────────────
# LOAD OR BUILD ITEM→CATEGORY CACHE
# ─────────────────────────────────────────────────────────────────────────────
echo "🗂️  Loading item/category cache..."
if [[ -f "$CACHE_FILE" ]]; then
  CM=$(cat "$CACHE_FILE")
  echo "✓ Loaded cache with $(jq 'length' <<<"$CM") items"
else
  CM='{}'
  echo "✓ Starting with empty cache"
fi

# Get unique item IDs from receipts
UNIQUE_ITEMS=$(jq -r '.receipts[].line_items[].item_id' <<<"$RAW" | sort -u)
NEW_ITEMS=0

for item_id in $UNIQUE_ITEMS; do
  # Check if already cached
  cached=$(jq -r --arg id "$item_id" '.[$id] // empty' <<<"$CM")
  if [[ -n "$cached" ]]; then
    continue
  fi
  
  echo "  → Fetching item: $item_id"
  ((NEW_ITEMS++))
  
  item_json=$(curl -s \
    -H "Authorization: Bearer $LOYVERSE_API_KEY" \
    "https://api.loyverse.com/v1.0/items/$item_id")
  
  cat_id=$(jq -r '.category_id // ""' <<<"$item_json")
  cat_name=""
  
  if [[ -n "$cat_id" ]]; then
    cat_name=$(curl -s \
      -H "Authorization: Bearer $LOYVERSE_API_KEY" \
      "https://api.loyverse.com/v1.0/categories/$cat_id" \
      | jq -r '.name // ""')
  fi
  
  CM=$(jq -c --argjson cm "$CM" --arg id "$item_id" --arg cat "$cat_name" \
    '$cm + {($id): $cat}' <<<"$CM")
done

echo "✓ Fetched $NEW_ITEMS new item(s)"

# Save updated cache
echo "$CM" > "$CACHE_FILE"

# ─────────────────────────────────────────────────────────────────────────────
# BATCH FETCH EXISTING NOTION PAGES
# ─────────────────────────────────────────────────────────────────────────────
echo "📊 Fetching existing Notion pages..."
EXISTING_PAGES=$(curl -s -X POST \
  "https://api.notion.com/v1/databases/$NOTION_DB_ID/query" \
  -H "Authorization: Bearer $NOTION_API_KEY" \
  -H "Notion-Version:2022-06-28" \
  -H "Content-Type:application/json" \
  --data '{"page_size": 100}')

EXISTING_MAP=$(jq -c '[.results[] | {
  id: .id,
  receipt_number: (.properties.receipt_number.title[0].text.content // ""),
  updated_at: (.properties.updated_at.date.start // "")
}] | map({key: .receipt_number, value: {id: .id, updated_at: .updated_at}}) | from_entries' <<<"$EXISTING_PAGES")

echo "✓ Found $(jq 'length' <<<"$EXISTING_MAP") existing page(s)"

# ─────────────────────────────────────────────────────────────────────────────
# PROCESS EACH RECEIPT
# ─────────────────────────────────────────────────────────────────────────────
CREATED=0
UPDATED=0
SKIPPED=0

echo "🔨 Processing receipts..."

echo "$RAW" | jq -c '.receipts // [] | .[]' | while read -r rec; do
  RN=$(jq -r '.receipt_number // empty' <<<"$rec")
  [[ -z "$RN" ]] && continue
  
  # Extract all fields in one jq call for efficiency
  read -r CA RD UA CA2 RT OR NT SRC SID EID PID CID PS TM TAX DISC TP SRG PE PD PB < <(
    jq -r '[
      .created_at,
      .receipt_date,
      .updated_at,
      (.cancelled_at // ""),
      .receipt_type,
      (.order // ""),
      (.note // ""),
      .source,
      .store_id,
      .employee_id,
      .pos_device_id,
      (.customer_id // ""),
      ([.payments[]?.name] | join(", ")),
      .total_money,
      .total_tax,
      .total_discount,
      .tip,
      .surcharge,
      .points_earned,
      .points_deducted,
      .points_balance
    ] | @tsv' <<<"$rec"
  )
  
  # Additional fields that need special processing
  PMDATA=""
  INOTE=$(jq -r '[.line_items[]?.line_note] | map(select(.!=null)) | join("; ")' <<<"$rec")
  IMOD_LIST=$(jq -r '[.line_items[]?.line_modifiers[]? | "\(.name): \(.option)"] | join("; ")' <<<"$rec")
  ITX=$(jq -r '[.line_items[]?.line_taxes | length] | add // 0' <<<"$rec")
  IDISC=$(jq -r '[.line_items[]?.line_discounts | length] | add // 0' <<<"$rec")
  LSUM=$(jq -r '[.line_items[]?.item_name] | join(", ")' <<<"$rec")
  
  # Multi-select fields
  DINE=$(jq -c '[.dining_option? | select(.!="" and .!=null) | {name:.}]' <<<"$rec")
  LI=$(jq -c '[.line_items[]? | {name:(.item_name + (if .variant_name then " ("+.variant_name+")" else "" end))}]' <<<"$rec")
  PM=$(jq -c '[.payments[]? | {name:.name}]' <<<"$rec")
  
  # Categories for parent multi_select
  CATS=$(jq -c --argjson cm "$CM" '
    [ .line_items[]? | ($cm[.item_id] // "") ] | unique | map(select(.!="")) | map({name:.})
  ' <<<"$rec")
  
  # Check if page exists and if it needs updating
  EXISTING=$(jq -r --arg rn "$RN" '.[$rn] // empty' <<<"$EXISTING_MAP")
  
  if [[ -n "$EXISTING" ]]; then
    PAGE_ID=$(jq -r '.id' <<<"$EXISTING")
    EXISTING_UA=$(jq -r '.updated_at' <<<"$EXISTING")
    
    # Skip if not updated
    if [[ "$UA" == "$EXISTING_UA" ]]; then
      echo "  ⏭️  Skipping unchanged receipt: $RN"
      ((SKIPPED++))
      continue
    fi
    
    echo "  🔄 Updating receipt: $RN"
  else
    PAGE_ID=""
    echo "  ✨ Creating receipt: $RN"
  fi
  
  # ───────────────────────────────────────────────────────────────────────────
  # BUILD PARENT PROPS
  # ───────────────────────────────────────────────────────────────────────────
  PROPS=$(jq -n \
    --arg rn "$RN" --arg ca "$CA" --arg rd "$RD" --arg ua "$UA" --arg ca2 "$CA2" \
    --arg rt "$RT" --arg ordr "$OR" --arg nt "$NT" --arg src "$SRC" \
    --arg sid "$SID" --arg eid "$EID" --arg pid "$PID" --arg cid "$CID" \
    --arg ps "$PS" --arg pmdata "$PMDATA" --arg inote "$INOTE" \
    --arg imod "$IMOD_LIST" --arg itx "$ITX" --arg idisc "$IDISC" --arg lsum "$LSUM" \
    --argjson dine "$DINE" --argjson li "$LI" --argjson pm "$PM" \
    --argjson tm "$TM" --argjson tax "$TAX" --argjson disc "$DISC" \
    --argjson tp "$TP" --argjson srg "$SRG" --argjson pe "$PE" \
    --argjson pd "$PD" --argjson pb "$PB" \
    --argjson cats "$CATS" \
    '{ parent: { database_id: "'"$NOTION_DB_ID"'" },
       properties: {
         receipt_number: { title: [ { text:{ content:$rn } } ] },
         created_at: { date: { start:$ca } },
         receipt_date: { date: { start:$rd } },
         updated_at: { date: { start:$ua } },
         cancelled_at: { rich_text: [ { text:{ content:$ca2 } } ] },
         receipt_type: { multi_select:[{name:$rt}] },
         order: { rich_text: [ { text:{ content:$ordr } } ] },
         note: { rich_text: [ { text:{ content:$nt } } ] },
         source: { rich_text: [ { text:{ content:$src } } ] },
         store_id: { rich_text: [ { text:{ content:$sid } } ] },
         employee_id: { rich_text: [ { text:{ content:$eid } } ] },
         pos_device_id: { rich_text: [ { text:{ content:$pid } } ] },
         customer_id: { rich_text: [ { text:{ content:$cid } } ] },
         payments_summary: { rich_text: [ { text:{ content:$ps } } ] },
         payment_metadata: { rich_text: [ { text:{ content:$pmdata } } ] },
         item_note: { rich_text: [ { text:{ content:$inote } } ] },
         item_modifiers_summary:{ rich_text: [ { text:{ content:$imod } } ] },
         item_taxes_summary: { rich_text: [ { text:{ content:$itx } } ] },
         item_discounts_summary:{ rich_text: [ { text:{ content:$idisc } } ] },
         line_items_summary: { rich_text: [ { text:{ content:$lsum } } ] },
         dining_option: { multi_select:$dine },
         line_items_only: { multi_select:$li },
         payment_method: { multi_select:$pm },
         total_money: { number: $tm },
         total_tax: { number: $tax },
         total_discount: { number: $disc },
         tip: { number: $tp },
         surcharge: { number: $srg },
         points_earned: { number: $pe },
         points_deducted: { number: $pd },
         points_balance: { number: $pb },
         item_categories: { multi_select:$cats }
       }
     }')
  
  # ───────────────────────────────────────────────────────────────────────────
  # BUILD CHILD TABLE
  # ───────────────────────────────────────────────────────────────────────────
  ROWS=$(jq -c --argjson cm "$CM" '
    # header row
    [ { object:"block", type:"table_row", table_row:{ cells:[
        [{type:"text", text:{content:"Item"}}],
        [{type:"text", text:{content:"Variant"}}],
        [{type:"text", text:{content:"Qty"}}],
        [{type:"text", text:{content:"Price"}}],
        [{type:"text", text:{content:"Note"}}],
        [{type:"text", text:{content:"Modifiers"}}],
        [{type:"text", text:{content:"Category"}}]
    ]}} ] +
    # data rows
    [ .line_items[]? | {
        object:"block", type:"table_row", table_row:{ cells:[
          [{type:"text", text:{content:.item_name}}],
          [{type:"text", text:{content:(.variant_name//"")}}],
          [{type:"text", text:{content:(.quantity|tostring)}}],
          [{type:"text", text:{content:(.price|tostring)}}],
          [{type:"text", text:{content:(.line_note//"")}}],
          [{type:"text", text:{content:( [.line_modifiers[]? | "\(.name): \(.option)"] | join("; ") )}}],
          [{type:"text", text:{content:( $cm[.item_id] // "")}}]
        ]}
      }]
  ' <<<"$rec")
  
  CHILDREN=$(jq -n --argjson rows "$ROWS" '
    [ { object:"block", type:"table", table:{ table_width:7, has_column_header:true, has_row_header:false, children: $rows }} ]
  ')
  
  # ───────────────────────────────────────────────────────────────────────────
  # SEND TO NOTION
  # ───────────────────────────────────────────────────────────────────────────
  if [[ -n "$PAGE_ID" ]]; then
    # Update existing page
    curl -s -X PATCH "https://api.notion.com/v1/pages/$PAGE_ID" \
      -H "Authorization: Bearer $NOTION_API_KEY" \
      -H "Notion-Version: 2022-06-28" \
      -H "Content-Type: application/json" \
      --data "$PROPS" >/dev/null
    
    clear_page_children "$PAGE_ID"
    
    curl -s -X PATCH "https://api.notion.com/v1/blocks/$PAGE_ID/children" \
      -H "Authorization: Bearer $NOTION_API_KEY" \
      -H "Notion-Version: 2022-06-28" \
      -H "Content-Type: application/json" \
      --data "{ \"children\": $CHILDREN }" >/dev/null
    
    ((UPDATED++))
  else
    # Create new page
    FULL=$(jq -n --argjson p "$PROPS" --argjson c "$CHILDREN" '$p + { children: $c }')
    curl -s -X POST "https://api.notion.com/v1/pages" \
      -H "Authorization: Bearer $NOTION_API_KEY" \
      -H "Notion-Version: 2022-06-28" \
      -H "Content-Type: application/json" \
      --data "$FULL" >/dev/null
    
    ((CREATED++))
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
# SAVE LATEST RECEIPT NUMBER
# ─────────────────────────────────────────────────────────────────────────────
LATEST_NUMBER=$(jq -r '(.receipts // []) | max_by(.created_at)? .receipt_number // empty' <<<"$RAW")

if [[ -n "$LATEST_NUMBER" ]]; then
  echo "$LATEST_NUMBER" > "$LAST_RECEIPT_FILE"
  echo "💾 Saved latest receipt number: $LATEST_NUMBER"
fi

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "✅ Sync complete!"
echo "   📝 Created: $CREATED"
echo "   🔄 Updated: $UPDATED"
echo "   ⏭️  Skipped: $SKIPPED"
