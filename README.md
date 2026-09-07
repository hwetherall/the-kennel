# The Kennel

Denver Bulldogs Grand Final Night companion app. Phase 1 delivers a live
100-square board, host-operated AFL scoring and undo, quarter settlement,
projector mode, and a print-friendly grid.

Phase 1 preview: <https://bk8ptwjs-nwa.insforge.site>

The app never handles money. Square purchases stay in Zeffy and enter the app
only through a CSV import; imported files are reduced to purchaser name, email,
quantity, and assigned square IDs.

## Local development

```bash
npm install
cp .env.example .env.local
npm run dev
```

Without InsForge variables, the app runs a deterministic local demo. The demo
host PIN is `2468`.

Routes:

- `/` — phone-first guest board
- `/host` — single-operator scoring console
- `/screen` — projector display
- `/host/print` — printable grid

## Verification

```bash
npm test
npm run build
npm run test:e2e
```

The backend integration verifier needs the deployed function endpoint and host
PIN:

```bash
KENNEL_FUNCTION_URL=https://your-function-host/kennel-api \
HOST_PIN=your-branch-pin \
node scripts/verify-backend.mjs
```

The deployed UI smoke test uses the same PIN:

```bash
APP_URL=https://your-preview-url \
HOST_PIN=your-branch-pin \
node scripts/verify-ui.mjs
```

## Backend and square imports

InsForge migrations live in `migrations/`; the public API dispatcher lives in
`functions/kennel-api.ts`. Base tables are private behind RLS. Public/player
reads and all host mutations run server-side through the edge function and
transactional RPCs.

To import a Zeffy CSV, set `INSFORGE_URL` and `INSFORGE_API_KEY` in `.env.local`,
then run:

```bash
npm run import:squares -- path/to/zeffy-export.csv
```

The importer accepts common name/email/quantity headings, deterministically
assigns up to 100 squares, and uses a file checksum to make repeat imports
idempotent. It deliberately ignores payment amounts and status.
