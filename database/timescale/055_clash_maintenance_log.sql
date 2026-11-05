-- +goose Up
ALTER TABLE public.server_logs DROP CONSTRAINT server_logs_type_check;
ALTER TABLE public.server_logs ADD CONSTRAINT server_logs_type_check CHECK (type = ANY (ARRAY['clash_maintenance'::text, 'join_log'::text, 'leave_log'::text, 'donation_log'::text, 'clan_achievement_log'::text, 'clan_requirements_log'::text, 'clan_description_log'::text, 'war_log'::text, 'war_panel'::text, 'cwl_lineup_change_log'::text, 'capital_donations'::text, 'capital_attacks'::text, 'raid_panel'::text, 'capital_weekly_summary'::text, 'role_change'::text, 'troop_upgrade'::text, 'super_troop_boost'::text, 'th_upgrade'::text, 'league_change'::text, 'spell_upgrade'::text, 'hero_upgrade'::text, 'hero_equipment_upgrade'::text, 'name_change'::text, 'legend_log_attacks'::text, 'legend_log_defenses'::text, 'ban_alert'::text, 'reddit_feed'::text]));
ALTER TABLE public.server_logs ADD CONSTRAINT server_logs_maintenance_scope CHECK (type <> 'clash_maintenance' OR clan_tag IS NULL);

-- +goose Down
DELETE FROM public.server_logs WHERE type = 'clash_maintenance';
ALTER TABLE public.server_logs DROP CONSTRAINT server_logs_maintenance_scope;
ALTER TABLE public.server_logs DROP CONSTRAINT server_logs_type_check;
ALTER TABLE public.server_logs ADD CONSTRAINT server_logs_type_check CHECK (type = ANY (ARRAY['join_log'::text, 'leave_log'::text, 'donation_log'::text, 'clan_achievement_log'::text, 'clan_requirements_log'::text, 'clan_description_log'::text, 'war_log'::text, 'war_panel'::text, 'cwl_lineup_change_log'::text, 'capital_donations'::text, 'capital_attacks'::text, 'raid_panel'::text, 'capital_weekly_summary'::text, 'role_change'::text, 'troop_upgrade'::text, 'super_troop_boost'::text, 'th_upgrade'::text, 'league_change'::text, 'spell_upgrade'::text, 'hero_upgrade'::text, 'hero_equipment_upgrade'::text, 'name_change'::text, 'legend_log_attacks'::text, 'legend_log_defenses'::text, 'ban_alert'::text, 'reddit_feed'::text]));
