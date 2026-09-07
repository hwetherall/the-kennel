-- Match the complete composite foreign key used by winner audit references.
CREATE INDEX markets_winner_reference_idx ON public.markets(id, winning_option_id);
DROP INDEX public.markets_winner_idx;
