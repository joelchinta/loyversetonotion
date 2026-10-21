# Loyverse to Notion sync

Run `bash sync.sh` for incremental batches, or `RECEIPT_NUMBER=... bash webhook-sync.sh` for a single receipt. Both need `LOYVERSE_API_KEY`, `NOTION_API_KEY` and `NOTION_DB_ID`, plus Bash, curl and jq. Keep `sync-common.sh` beside the entry scripts.

The batch follows all source receipt pages and advances `.last_receipt.txt` only after every fetched receipt has been saved or confirmed unchanged. Failures return a nonzero exit status and retain the previous checkpoint. A single-receipt webhook never advances the batch checkpoint.

Requests check HTTP status and JSON errors. Rate-limit responses are retried within a bounded budget, respecting `Retry-After`; long waits are deferred to the next run. Ambiguous create/append failures are not blindly retried. A subsequent run looks up receipts by their exact number, stopping on duplicate pages rather than guessing which page to change.

Updates preserve the existing receipt table until a replacement is accepted. Cleanup removes only seven-column tables with the generated receipt headers, preserving unrelated notes. The source `updated_at` property is written after replacement and cleanup, so failed updates remain eligible for retry. Existing historical omissions are not automatically repaired.

The active GitHub workflow serializes sync runs, stops if its Gist checkpoint download fails, and uploads state only after a successful batch. `.github/workflows/webhook-sync.txt` remains an inactive template with matching protections; it has not been enabled.

Run the isolated regression suite with `python3 tests/sync-regression.py`. It uses synthetic receipts and a curl stub, with no external requests.
