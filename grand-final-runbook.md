# Grand Final night runbook

Friday 25 September 2026. Fremantle (home, down the side of the board) v Brisbane
(away, across the top). Branch `claude/grand-final-night`.

## 1. Go live (needs Harry's go-ahead, in this order)

Production is untouched until this section runs. The dev branch preview,
<https://bk8ptwjs-yw5.insforge.site>, already runs this code.

1. Review and merge the backend branch. The merge applies the four Phase 3
   migrations and the edge function; no branch data is promoted.
   ```sh
   npx -y @insforge/cli branch merge phase-3-studs-futures --dry-run --save-sql merge-preview.sql
   npx -y @insforge/cli branch merge phase-3-studs-futures
   npx -y @insforge/cli branch switch --parent
   npx -y @insforge/cli deployments deploy .
   ```
2. Load the night's setup (teams, athletes, Futures, Studs rounds) into production.
   Pass the production URL explicitly; `.env.local` points at the dev branch.
   ```sh
   KENNEL_FUNCTION_URL=https://bk8ptwjs.function2.insforge.app/kennel-api HOST_PIN=<production pin> \
     node scripts/setup-grand-final.mjs
   ```
3. Import the drawn board. It refuses if Fremantle is not home, and reads all 100
   squares back against the CSV.
   ```sh
   INSFORGE_URL=https://bk8ptwjs.us-west.insforge.app INSFORGE_API_KEY=<production key> \
     node scripts/import-grid.mjs "AFL Grand Final - Squares Board - SQUARES.csv"
   ```
4. Print `/host/print` and check a few squares against the paper board, for example
   Fremantle 5 / Brisbane 8 is Taylor McHale.
5. Production already has one guest, `Haz`. To give it Harry Wetherall's two
   squares, link that board name to `Haz` under Purchase matching in the console.

## 2. Before the first bounce

- Host console → Futures → **Open both Futures**.
- Host console → Studs v Spuds → **Open Q1 Studs**.
- Guests join by picking their name from the board, or with a nickname if not on it.

Both Futures and the Q1 matchups lock by themselves at **Start Q1**.

## 3. At each siren

1. **Sound the siren.** The Squares winner shows at once. The next quarter's
   matchups open by themselves for the break.
2. The stats helper reads **cumulative game totals** from the AFL app for:
   - this quarter's matchups: enter them as the siren totals, then **Review result**
     and **Confirm**. The console shows the quarter numbers before you confirm.
   - next quarter's matchups: enter them as **baselines**, before the next bounce.
     (Q1 baselines are zero and need nothing.)
3. The quarter ladder is final once the quarter's last matchup is settled or voided.
   Until then the app shows it as awaiting Studs results.
4. Level on the quarter refunds automatically. Unresolvable stats: void with a reason.

Studs is decided on the quarter's own numbers, never the game totals.

## 4. Full time

Sound the Q4 siren first, then in Futures:
- **Settle match winner from the final score** (the server works out the winner).
- Choose the Norm Smith medallist, or "Any other player", then confirm.

Top Dog includes both Futures.

## 5. The rounds

Paired on 2026 season and last-five-game averages from AFL Tables.

| Quarter | Round | Stat | Matchups |
|---|---|---|---|
| Q1 | Ruck Round | Hit-outs | Luke Jackson v Sam Draper; Mason Cox v Darcy Fort |
| Q2 | Forwards Round | Disposals | Shai Bolton v Zac Bailey; Josh Treacy v Eric Hipwood; Michael Frederick v Charlie Cameron |
| Q3 | Midfield Round | Disposals | Andrew Brayshaw v Will Ashcroft; Caleb Serong v Lachie Neale; Hayden Young v Josh Dunkley |
| Q4 | Back Round | Disposals | Jordan Clark v Dayne Zorko; Luke Ryan v Darcy Wilmot; Heath Chapman v Ryan Lester |

Any matchup can be changed in the console until it opens.
