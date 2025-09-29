# Loyverse to Notion Sync

⚠️ **IMPORTANT:** Never commit API keys to this repository. All secrets must be stored in GitHub Secrets.

## Setup

1. Fork this repository
2. Add these secrets in Settings → Secrets → Actions:
   - `LOYVERSE_API_KEY`
   - `NOTION_API_KEY`
   - `NOTION_DB_ID`
3. Set your starting receipt number (optional)
4. Enable GitHub Actions

## Security Notes

- API keys are stored as GitHub Secrets (encrypted)
- Never hardcode keys in the script
- The `.last_receipt.txt` and `.loyverse_cache.json` contain only non-sensitive data
