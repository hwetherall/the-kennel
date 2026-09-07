-- Base tables are private by design. Public and player reads go through
-- SECURITY DEFINER snapshot RPCs; writes go through the kennel-api function.
-- These explicit policies document the deny-by-default boundary for auditors.
create policy "client access denied" on public.event_config
  for all to anon, authenticated using (false) with check (false);
create policy "client access denied" on public.grid_config
  for all to anon, authenticated using (false) with check (false);
create policy "client access denied" on public.players
  for all to anon, authenticated using (false) with check (false);
create policy "client access denied" on public.square_import_batches
  for all to anon, authenticated using (false) with check (false);
create policy "client access denied" on public.squares_purchases
  for all to anon, authenticated using (false) with check (false);
create policy "client access denied" on public.squares
  for all to anon, authenticated using (false) with check (false);
create policy "client access denied" on public.game_state
  for all to anon, authenticated using (false) with check (false);
create policy "client access denied" on public.score_events
  for all to anon, authenticated using (false) with check (false);
create policy "client access denied" on public.quarter_results
  for all to anon, authenticated using (false) with check (false);
create policy "client access denied" on public.host_sessions
  for all to anon, authenticated using (false) with check (false);
create policy "client access denied" on public.mutation_receipts
  for all to anon, authenticated using (false) with check (false);
create policy "client access denied" on public.game_events
  for all to anon, authenticated using (false) with check (false);

create index if not exists game_state_last_score_event_idx
  on public.game_state (last_score_event_id);
create index if not exists quarter_results_winning_square_idx
  on public.quarter_results (winning_square_id);
