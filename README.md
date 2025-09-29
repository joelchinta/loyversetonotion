# Loyverse to Notion Sync

Automated hourly synchronization of Loyverse POS receipts to a Notion database using GitHub Actions.

## Overview

This script automatically fetches receipt data from Loyverse POS and creates/updates pages in a Notion database. It runs every hour during business hours (7 AM - 12 AM Brunei time) via GitHub Actions, maintaining a complete record of all sales transactions.

## Features

- **Automatic Sync**: Runs hourly during business hours (7 AM - 12 AM BNT)
- **Incremental Updates**: Only processes new or modified receipts
- **Smart Caching**: Caches item and category data to minimize API calls
- **Detailed Records**: Creates comprehensive Notion pages with:
  - Receipt metadata (date, time, source, employee)
  - Line items table with quantities, prices, and modifiers
  - Payment information
  - Customer data
  - Itemized categories

## Prerequisites

- A Loyverse POS account with API access
- A Notion workspace with integration access
- A GitHub account (free tier includes 2,000 Actions minutes/month)

## Setup

### 1. Notion Database Setup

Create a Notion database with these properties (exact names required):

| Property Name | Type | Description |
|--------------|------|-------------|
| `receipt_number` | Title | Unique receipt identifier |
| `created_at` | Date | Receipt creation timestamp |
| `receipt_date` | Date | Transaction date |
| `updated_at` | Date | Last modification time |
| `cancelled_at` | Rich Text | Cancellation timestamp (if applicable) |
| `receipt_type` | Multi-select | SALE, REFUND, etc. |
| `order` | Rich Text | Order number |
| `note` | Rich Text | Receipt notes |
| `source` | Rich Text | POS, online, etc. |
| `store_id` | Rich Text | Store identifier |
| `employee_id` | Rich Text | Employee identifier |
| `pos_device_id` | Rich Text | POS device identifier |
| `customer_id` | Rich Text | Customer identifier |
| `payments_summary` | Rich Text | Payment methods used |
| `payment_metadata` | Rich Text | Additional payment data |
| `item_note` | Rich Text | Item-specific notes |
| `item_modifiers_summary` | Rich Text | Item modifications |
| `item_taxes_summary` | Rich Text | Tax information |
| `item_discounts_summary` | Rich Text | Applied discounts |
| `line_items_summary` | Rich Text | List of items sold |
| `dining_option` | Multi-select | Dine-in, takeout, etc. |
| `line_items_only` | Multi-select | Item names |
| `payment_method` | Multi-select | Payment types |
| `total_money` | Number | Total amount |
| `total_tax` | Number | Tax amount |
| `total_discount` | Number | Discount amount |
| `tip` | Number | Tip amount |
| `surcharge` | Number | Additional charges |
| `points_earned` | Number | Loyalty points earned |
| `points_deducted` | Number | Loyalty points used |
| `points_balance` | Number | Current points balance |
| `item_categories` | Multi-select | Product categories |

### 2. Loyverse API Key

1. Log into your Loyverse backend
2. Navigate to Settings → Integrations → API
3. Generate or copy your API key

### 3. Notion Integration

1. Go to https://www.notion.so/my-integrations
2. Click "New integration"
3. Name it (e.g., "Loyverse Sync")
4. Select your workspace
5. Copy the Internal Integration Token
6. Share your database with the integration:
   - Open your Notion database
   - Click "..." (top right) → Add connections
   - Select your integration

### 4. Fork This Repository

1. Click "Fork" at the top of this page
2. Clone to your account

### 5. Create GitHub Secrets

Go to Settings → Secrets and variables → Actions → New repository secret

Add these secrets:

| Secret Name | Value |
|------------|-------|
| `LOYVERSE_API_KEY` | Your Loyverse API key |
| `NOTION_API_KEY` | Your Notion integration token (starts with `secret_`) |
| `NOTION_DB_ID` | Your Notion database ID (from database URL) |
| `GIST_ID` | Your secret Gist ID (see below) |
| `GIST_TOKEN` | GitHub Personal Access Token with `gist` scope |

### 6. Create Secret Gist for Cache Storage

1. Go to https://gist.github.com
2. Click "Create secret gist"
3. Add two files:
   - `loyverse_cache.json` with content: `{}`
   - `last_receipt.txt` with content: `Value`
4. Click "Create secret gist"
5. Copy the Gist ID from the URL

### 7. Create Personal Access Token

1. GitHub Settings → Developer settings → Personal access tokens → Tokens (classic)
2. Generate new token (classic)
3. Name: "Gist access for Loyverse sync"
4. Select scope: **gist** only
5. Generate and copy the token

### 8. Set Starting Receipt Number

To avoid syncing all historical receipts on first run:

1. Go to Actions tab
2. Click "Loyverse to Notion Sync"
3. Click "Run workflow"
4. Enter your starting receipt number (e.g., `2-1028`)
5. Run workflow

## Usage

The sync runs automatically every hour from 7 AM to 12 AM (Brunei time). 

To trigger a manual sync:
1. Go to the Actions tab
2. Select "Loyverse to Notion Sync"
3. Click "Run workflow"

## How It Works

1. **Fetch Receipts**: Retrieves new receipts from Loyverse API since last sync
2. **Cache Items**: Stores item and category information to reduce API calls
3. **Query Notion**: Checks which receipts already exist
4. **Skip Unchanged**: Only processes new or modified receipts
5. **Create/Update**: Writes receipt data to Notion with detailed line item tables
6. **Save State**: Updates cache with latest receipt number for next run

## Cost & Limits

**GitHub Actions (Free Tier):**
- 2,000 minutes/month for private repos
- This script uses ~1,020 minutes/month (17 runs/day × 2 min × 30 days)
- Well within free tier limits

**API Calls:**
- Loyverse: No documented rate limits
- Notion: 3 requests/second (this script stays well below)

## File Structure
.
├── .github/
│   └── workflows/
│       └── sync.yml          # GitHub Actions workflow
├── sync.sh                   # Main sync script
├── .gitignore               # Excludes cache files
├── LICENSE                  # MIT License
└── README.md               # This file
## Troubleshooting

**No receipts syncing:**
- Check that your starting receipt number is correct
- Verify API keys are valid
- Check Actions logs for errors

**"Missing properties" error:**
- Ensure all required Notion properties exist with exact names
- Property names are case-sensitive

**Rate limit errors:**
- Reduce sync frequency in workflow file
- Increase delays between API calls in script

**Gist not updating:**
- Verify `GIST_TOKEN` has `gist` scope
- Check that Gist ID is correct
- Ensure Gist is marked as "Secret"

## Security Notes

- Never commit API keys to the repository
- All secrets are stored as encrypted GitHub Secrets
- Cache files contain only non-sensitive data (item IDs, receipt numbers)
- Gist storage keeps cache private even if repo is public

## Limitations

- Only processes receipts created after the starting receipt number
- Historical data must be manually imported if needed
- Requires GitHub Actions to be enabled
- Notion database schema must match exactly

## Legal

**License:** MIT License - see LICENSE file for details

**Disclaimer:** This software is provided "as-is" without warranty of any kind. Use at your own risk. The author is not responsible for data loss, API costs, or other issues arising from use of this software.

**Support:** This is a personal project. No support, feature requests, or bug fixes are guaranteed.

## Attribution

If you use or modify this code, please provide attribution by linking back to this repository.

## Contributing

This is a personal automation script. Forks and modifications for personal use are welcome, but pull requests are not accepted.

---

**Author:** joelchinta
**Created:** September 2025  
**Last Updated:** September 2025
