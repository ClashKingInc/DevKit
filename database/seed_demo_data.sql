-- Coherent local-only demo data for browsing the ClashKing schema.
--
-- The script intentionally reuses an existing server, its configured clans,
-- current players, player links, and wars. It is safe to rerun: deterministic
-- keys and ON CONFLICT clauses prevent duplicate fixture rows.
--
-- Run inside the local Timescale container with ON_ERROR_STOP enabled.

BEGIN;

DO $seed$
DECLARE
    i integer;
    demo_uuid uuid;
    panel_uuid uuid;
    roster_uuid uuid;
    roster_group_uuid uuid;
    v_server_id text;
    v_clans text[];
    v_primary_clan text;
    v_players text[];
    v_player_names text[];
    v_link_tags text[];
    v_war_ids text[];
    v_war_end_times timestamptz[];
    v_users text[] := ARRAY[
        'demo-seed-user-01', 'demo-seed-user-02', 'demo-seed-user-03',
        'demo-seed-user-04', 'demo-seed-user-05'
    ];
BEGIN
    SELECT s.id
    INTO v_server_id
    FROM servers s
    WHERE s.id = '1317858645349765150';

    IF v_server_id IS NULL THEN
        RAISE EXCEPTION 'Seed requires server 1317858645349765150';
    END IF;

    SELECT array_fill(sc.tag, ARRAY[5])
    INTO v_clans
    FROM (
        SELECT sc.tag
        FROM server_clans sc
        JOIN basic_clan clan ON clan.tag = sc.tag
        WHERE sc.server_id = v_server_id
        ORDER BY tag
        LIMIT 1
    ) sc;

    IF coalesce(cardinality(v_clans), 0) < 5 THEN
        RAISE EXCEPTION 'Seed requires an existing server_clan with basic_clan data for server %', v_server_id;
    END IF;

    -- basic_player has no clan_tag index, so discovering members by scanning its
    -- tens of millions of rows is inappropriate for a local fixture. Attach a
    -- small, explicit demo roster to the first existing configured clan instead.
    v_primary_clan := v_clans[1];
    v_players := ARRAY[
        '#DEMO0001', '#DEMO0002', '#DEMO0003', '#DEMO0004', '#DEMO0005'
    ];
    v_player_names := ARRAY[
        'Demo Player 1', 'Demo Player 2', 'Demo Player 3', 'Demo Player 4', 'Demo Player 5'
    ];

    SELECT array_agg(pl.tag ORDER BY pl.tag)
    INTO v_link_tags
    FROM (
        SELECT tag
        FROM player_links
        ORDER BY tag
        LIMIT 5
    ) pl;

    SELECT array_agg(w.war_id ORDER BY w.end_time DESC),
           array_agg(w.end_time ORDER BY w.end_time DESC)
    INTO v_war_ids, v_war_end_times
    FROM (
        SELECT war_id, end_time
        FROM wars
        ORDER BY end_time DESC
        LIMIT 5
    ) w;

    -- Keep every server-scoped fixture attached to the requested existing server.
    FOR i IN 1..5 LOOP
        INSERT INTO basic_player (tag, name, league_id, clan_tag, townhall_level, trophies)
        VALUES (v_players[i], v_player_names[i], 29000022 + i, v_primary_clan, 17, 5000 + i * 100)
        ON CONFLICT (tag) DO NOTHING;

        INSERT INTO auth_users (user_id, discord_user_id)
        VALUES (v_users[i], format('demo-discord-%02s', i))
        ON CONFLICT (user_id) DO NOTHING;

        INSERT INTO app_announcements (
            id, title, subtitle, body, status, target, starts_at, ends_at, min_app_version
        ) VALUES (
            md5(format('demo:announcement:%s', i))::uuid,
            format('Demo announcement %s', i),
            'Example mobile announcement',
            format('This is fixture announcement %s used to demonstrate the published content shape.', i),
            (ARRAY['draft', 'scheduled', 'published', 'published', 'archived'])[i],
            (ARRAY['all', 'ios', 'android', 'all', 'ios'])[i],
            now() - make_interval(days => 6 - i),
            CASE WHEN i = 5 THEN now() + interval '30 days' ELSE now() + make_interval(days => i) END,
            format('1.%s.0', i)
        )
        ON CONFLICT (id) DO NOTHING;

        INSERT INTO audit_history (id, resource_id, resource_type, description, user_id)
        VALUES (
            md5(format('demo:audit:%s', i))::uuid,
            md5(format('demo:announcement:%s', i))::uuid,
            'app_announcement', format('Demo user published announcement %s', i), v_users[i]
        )
        ON CONFLICT (id) DO NOTHING;

        INSERT INTO autoboards (
            id, identifier, server_id, type, board_type, channel_id, webhook_id,
            interval_minutes, next_run_at, enabled, button_id, days, locale, data
        ) VALUES (
            md5(format('demo:autoboard:%s', i))::uuid,
            format('demo-autoboard-%s', i), v_server_id, 'clan',
            (ARRAY['donations', 'activity', 'legend', 'war', 'capital'])[i],
            format('demo-board-channel-%s', i), format('demo-webhook-%s', i),
            i * 15, now() + make_interval(mins => i * 15), true,
            format('demo-board-button-%s', i), ARRAY['monday', 'friday'], 'en-US',
            jsonb_build_object('clan_tag', v_clans[i], 'fixture', true)
        )
        ON CONFLICT (id) DO NOTHING;

        INSERT INTO bases (
            id, message_id, base_link, downloaders, server_id, channel_id,
            images, description, upvoter_ids, downvoter_ids
        ) VALUES (
            md5(format('demo:base:%s', i))::uuid,
            format('demo-base-message-%s', i), format('https://link.clashofclans.com/demo-base-%s', i),
            ARRAY[format('demo-discord-%s', i)],
            v_server_id, format('demo-base-channel-%s', i),
            ARRAY[format('https://cdn.example.invalid/demo-base-%s.png', i)],
            format('Demo base layout %s', i),
            CASE
                WHEN i % 2 = 1 THEN ARRAY[format('demo-discord-%s', i)]
                ELSE '{}'::text[]
            END,
            CASE
                WHEN i % 2 = 0 THEN ARRAY[format('demo-discord-%s', i)]
                ELSE '{}'::text[]
            END
        )
        ON CONFLICT (id) DO NOTHING;

        INSERT INTO battlelogs (
            battle_id, player_tag, player_th, opponent_tag, opponent_th, battle_type,
            attack, stars, destruction_percentage, gold, elixir, dark_elixir, "timestamp",
            army_items, army_counts, player_name, opponent_name, duration, army_share_code
        ) VALUES (
            md5(format('demo:battle:%s', i))::uuid,
            v_players[i], 17, format('#DEMOOPP%s', i), 17, 'multiplayer', true,
            (i % 3) + 1, 70 + i * 5, 500000 + i * 10000, 450000 + i * 10000,
            5000 + i * 500, now() - make_interval(hours => i),
            ARRAY['u_1', 'u_5', 's_1'], jsonb_build_object('u_1', 5 + i, 'u_5', 2, 's_1', 3),
            v_player_names[i], format('Demo Opponent %s', i), 120 + i * 5,
            format('demo-army-share-%s', i)
        )
        ON CONFLICT (battle_id, "timestamp") DO NOTHING;

        demo_uuid := md5(format('demo:clan-category:%s', i))::uuid;
        INSERT INTO clan_categories (id, server_id, name)
        VALUES (demo_uuid, v_server_id, format('Demo Clan Category %s', i))
        ON CONFLICT (id) DO NOTHING;

        UPDATE server_clans
        SET category_id = demo_uuid
        WHERE server_id = v_server_id AND tag = v_clans[i]
          AND category_id IS NULL;

        INSERT INTO server_logs (server_id, clan_tag, type, webhook_id, thread_id)
        VALUES (
            v_server_id, v_clans[i],
            (ARRAY['join_log', 'leave_log', 'war_log', 'capital_attacks', 'donation_log'])[i],
            format('demo-webhook-id-%s', i), format('demo-thread-%s', i)
        )
        ON CONFLICT (server_id, clan_tag, type) DO NOTHING;

        INSERT INTO server_roles (id, server_id, clan_tag, type, option, role_id, mode)
        VALUES (
            md5(format('demo:clan-position-role:%s', i))::uuid,
            v_server_id, v_clans[i], 'clan_role',
            (ARRAY['member', 'elder', 'co_leader', 'leader', 'member'])[i],
            format('demo-position-role-%s', i), 'both'
        )
        ON CONFLICT (id) DO NOTHING;

        UPDATE basic_clan
        SET builder_base_points = CASE
                WHEN builder_base_points = 0 THEN 45000 - i * 100
                ELSE builder_base_points
            END,
            capital_points = CASE
                WHEN capital_points = 0 THEN 2500 - i * 10
                ELSE capital_points
            END
        WHERE tag = v_clans[i];

        INSERT INTO clan_rankings_current (
            clan_tag, ranking_type, location_id, rank, points
        )
        SELECT clan.tag, ranking.ranking_type, 'global', i, ranking.points
        FROM basic_clan AS clan
        CROSS JOIN LATERAL (
            VALUES
                ('home'::text, clan.clan_points),
                ('builder_base'::text, clan.builder_base_points),
                ('capital'::text, clan.capital_points)
        ) AS ranking(ranking_type, points)
        WHERE clan.tag = v_clans[i]
        ON CONFLICT (clan_tag, ranking_type, location_id) DO NOTHING;

        INSERT INTO clan_rankings_current (
            clan_tag, ranking_type, location_id, rank, points
        )
        SELECT clan.tag, 'home', clan.location_id::text, i, clan.clan_points
        FROM basic_clan AS clan
        WHERE clan.tag = v_clans[i]
          AND clan.location_id IS NOT NULL
        ON CONFLICT (clan_tag, ranking_type, location_id) DO NOTHING;

        INSERT INTO current_war_timers (
            player_tag, war_id, clan_tag, opponent_tag, end_time
        ) VALUES (
            v_players[i], coalesce(v_war_ids[i], format('demo-war-%s', i)), v_primary_clan,
            format('#DEMOOPP%s', i), now() + make_interval(hours => i)
        )
        ON CONFLICT (player_tag) DO NOTHING;

        INSERT INTO server_custom_embeds (server_id, name, data)
        VALUES (
            v_server_id, format('Demo Embed %s', i),
            jsonb_build_object('title', format('Demo Embed %s', i), 'description', 'Reusable embed fixture', 'color', 4886754)
        )
        ON CONFLICT (server_id, name) DO NOTHING;

        INSERT INTO dashboard_role_grants (
            server_id, role_id, section, access_level, created_by_user_id
        ) VALUES (
            v_server_id, format('demo-dashboard-role-%s', i),
            (ARRAY['settings', 'clans', 'rosters', 'moderation', 'tickets'])[i],
            CASE WHEN i % 2 = 0 THEN 'view' ELSE 'manage' END, v_users[i]
        )
        ON CONFLICT (server_id, role_id, section) DO NOTHING;

        INSERT INTO server_custom_embeds (server_id, name, data)
        VALUES (
            v_server_id, format('Demo Ticket Embed %s', i),
            jsonb_build_object('title', format('Apply to %s', v_clans[i]), 'description', 'Ticket panel example')
        )
        ON CONFLICT (server_id, name) DO NOTHING;

        INSERT INTO giveaways (
            id, server_id, prize, channel_id, status, start_time, end_time, winners,
            mentions, text_above_embed, text_in_embed, text_on_end, roles_mode,
            roles, entries, winners_list, message_id
        ) VALUES (
            format('demo-giveaway-%s', i), v_server_id, format('%s gem pack', i),
            format('demo-giveaway-channel-%s', i),
            (ARRAY['scheduled', 'ongoing', 'ongoing', 'ended', 'ended'])[i],
            now() - interval '1 day', now() + make_interval(days => i), 1,
            ARRAY['@everyone'], 'A demo giveaway is starting', 'React to enter', 'Thanks for entering',
            'required', ARRAY[format('demo-role-%s', i)],
            jsonb_build_array(jsonb_build_object('user_id', v_users[i], 'entries', i)),
            CASE WHEN i >= 4 THEN jsonb_build_array(v_users[i]) ELSE '[]'::jsonb END,
            format('demo-giveaway-message-%s', i)
        )
        ON CONFLICT (id) DO NOTHING;

        INSERT INTO hall_counts (village_type, level, total_count)
        VALUES (0, 12 + i, 1000 * i)
        ON CONFLICT (village_type, level) DO NOTHING;

        INSERT INTO server_roles (id, server_id, type, option, role_id, mode)
        VALUES (
            md5(format('demo:townhall-role:%s', i))::uuid, v_server_id,
            'townhall', (12 + i)::text, format('demo-th-role-%s', i), 'both'
        )
        ON CONFLICT (id) DO NOTHING;

        INSERT INTO leaderboard_snapshot_items (kind, location_id, date, tag, name, rank, data)
        VALUES (
            CASE WHEN i % 2 = 0 THEN 'clan' ELSE 'player' END, 'global', current_date - i,
            CASE WHEN i % 2 = 0 THEN v_clans[i] ELSE v_players[i] END,
            CASE WHEN i % 2 = 0 THEN format('Configured Clan %s', i) ELSE v_player_names[i] END,
            i, jsonb_build_object('trophies', 6000 - i * 50, 'fixture', true)
        )
        ON CONFLICT (kind, location_id, date, tag) DO NOTHING;

        INSERT INTO server_roles (id, server_id, type, option, role_id, mode)
        VALUES (
            md5(format('demo:league-role:%s', i))::uuid, v_server_id,
            'league', (29000020 + i)::text, format('demo-league-role-%s', i), 'both'
        )
        ON CONFLICT (id) DO NOTHING;

        INSERT INTO legend_history_snapshots (season, player_tag, rank, trophies, data)
        VALUES (
            to_char(current_date - make_interval(months => i), 'YYYY-MM'), v_players[i],
            i * 100, 6000 - i * 25, jsonb_build_object('name', v_player_names[i], 'fixture', true)
        )
        ON CONFLICT (season, player_tag) DO NOTHING;

        INSERT INTO legend_rankings_current (
            player_tag, rank, trophies, player_name, clan_tag, clan_name, data
        ) VALUES (
            format('#DEMOLEG%s', i), i, 6500 - i * 20, format('Demo Legend %s', i),
            v_primary_clan, 'The Order', jsonb_build_object('fixture', true, 'country', 'US')
        )
        ON CONFLICT (player_tag) DO NOTHING;

        INSERT INTO mobile_push_devices (
            id, user_id, device_id, platform, provider, environment, token_ciphertext,
            token_hash, app_version, build_number, os_version, device_model, enabled
        ) VALUES (
            md5(format('demo:push-device:%s', i))::uuid, v_users[i], format('demo-device-%s', i),
            CASE WHEN i % 2 = 0 THEN 'android' ELSE 'ios' END,
            CASE WHEN i % 2 = 0 THEN 'fcm' ELSE 'apns' END,
            CASE WHEN i = 5 THEN 'sandbox' ELSE 'production' END,
            format('encrypted-demo-token-%s', i), md5(format('demo-push-token-%s', i)),
            format('1.%s.0', i), format('%s0', i), format('DemoOS %s', i),
            CASE WHEN i % 2 = 0 THEN 'Pixel Demo' ELSE 'iPhone Demo' END, i <> 5
        )
        ON CONFLICT (id) DO NOTHING;

        INSERT INTO mobile_war_subscriptions (
            id, user_id, device_id, clan_tag, war_start_enabled, score_change_enabled,
            war_end_enabled, cwl_rank_enabled, live_activity_enabled, enabled
        ) VALUES (
            md5(format('demo:war-subscription:%s', i))::uuid,
            v_users[i], format('demo-device-%s', i), v_clans[i], true, true, true,
            i % 2 = 1, i % 2 = 1, true
        )
        ON CONFLICT (id) DO NOTHING;

        INSERT INTO mobile_live_activities (
            id, user_id, device_id, activity_id, clan_tag, war_id, environment,
            push_token_ciphertext, push_token_hash, status, last_payload_hash
        ) VALUES (
            md5(format('demo:live-activity:%s', i))::uuid,
            v_users[i], format('demo-device-%s', i), format('demo-activity-%s', i),
            v_clans[i], coalesce(v_war_ids[i], format('demo-war-%s', i)),
            CASE WHEN i = 5 THEN 'sandbox' ELSE 'production' END,
            format('encrypted-demo-activity-token-%s', i), md5(format('demo-activity-token-%s', i)),
            (ARRAY['active', 'active', 'ended', 'stale', 'disabled'])[i],
            md5(format('demo-payload-%s', i))
        )
        ON CONFLICT (id) DO NOTHING;

        INSERT INTO one_time_login_tokens (id, user_id, token_hash, expires_at, used_at)
        VALUES (
            md5(format('demo:login-token:%s', i))::uuid, v_users[i],
            md5(format('demo-login-token-%s', i)), now() + make_interval(mins => i * 10),
            CASE WHEN i = 1 THEN now() ELSE NULL END
        )
        ON CONFLICT (id) DO NOTHING;

        INSERT INTO open_tickets (
            server_id, channel_id, panel_name, status, user_id, set_clan, data
        ) VALUES (
            v_server_id, format('demo-open-ticket-channel-%s', i), format('Demo Panel %s', i),
            CASE WHEN i = 5 THEN 'closed' ELSE 'open' END, v_users[i], v_clans[i],
            jsonb_build_object('subject', format('Application %s', i), 'fixture', true)
        )
        ON CONFLICT (server_id, channel_id) DO NOTHING;

        INSERT INTO player_current_stats (
            player_tag, clan_tag, name, townhall_level, last_online_at, legends,
            donations, activity, data
        ) VALUES (
            v_players[i], v_primary_clan, v_player_names[i], 17, now() - make_interval(mins => i * 5),
            jsonb_build_object('trophies', 5500 + i * 20, 'rank', i * 100),
            jsonb_build_object('donated', 1000 * i, 'received', 800 * i),
            jsonb_build_object('lastOnline', now() - make_interval(mins => i * 5), 'score', 100 * i),
            jsonb_build_object('fixture', true)
        )
        ON CONFLICT (player_tag) DO NOTHING;

        INSERT INTO player_equipment (player_tag, name, level, max_level, village, rarity)
        VALUES (v_players[i], format('Demo Equipment %s', i), i + 10, 27, 'home', 'epic')
        ON CONFLICT (player_tag, name, village) DO NOTHING;

        INSERT INTO player_heroes (player_tag, name, level, max_level, village)
        VALUES (v_players[i], 'Barbarian King', 90 + i, 100, 'home')
        ON CONFLICT (player_tag, name, village) DO NOTHING;

        INSERT INTO player_history_events (
            event_time, player_tag, clan_tag, season, event_type, value, data
        )
        SELECT now() - make_interval(hours => i), v_players[i], v_primary_clan,
               to_char(current_date, 'YYYY-MM'), 'demo_seed_donations', 100 * i,
               jsonb_build_object('previous', 100 * i - 10, 'fixture', true)
        WHERE NOT EXISTS (
            SELECT 1 FROM player_history_events
            WHERE player_tag = v_players[i] AND event_type = 'demo_seed_donations'
        );

        INSERT INTO player_links_settings (tag, server_id, is_main)
        VALUES (v_link_tags[i], v_server_id, i = 1)
        ON CONFLICT (tag, server_id) DO NOTHING;

        INSERT INTO player_online_events (seen_at, tag, clan_tag, townhall_level)
        SELECT now() - make_interval(mins => i), v_players[i], v_primary_clan, 17
        WHERE NOT EXISTS (
            SELECT 1 FROM player_online_events
            WHERE tag = v_players[i] AND clan_tag = v_primary_clan
              AND seen_at >= now() - interval '1 day'
        );

        INSERT INTO player_profile_changes (
            event_time, player_tag, clan_tag, townhall_level, change_type, previous_value, current_value
        )
        SELECT now() - make_interval(days => i), v_players[i], v_primary_clan, 17,
               'demo_seed_name', to_jsonb(format('Old Demo Name %s', i)), to_jsonb(v_player_names[i])
        WHERE NOT EXISTS (
            SELECT 1 FROM player_profile_changes
            WHERE player_tag = v_players[i] AND change_type = 'demo_seed_name'
        );

        INSERT INTO player_rankings_current (
            player_tag, country_code, country_name, rank, global_rank, local_rank, data
        ) VALUES (
            format('#DEMOPR%s', i), 'US', 'United States', i, i * 100, i,
            jsonb_build_object('name', format('Demo Ranked Player %s', i), 'trophies', 6000 - i * 25)
        )
        ON CONFLICT (player_tag) DO NOTHING;

        INSERT INTO player_season_stats (
            player_tag, season, clan_tag, donated, received, capital_gold_donos,
            activity_score, last_online_at, name, townhall_level, donations,
            clan_games, activity, data
        ) VALUES (
            v_players[i], to_char(current_date, 'YYYY-MM'), v_primary_clan,
            1000 * i, 750 * i, 5000 * i, 100 * i, now() - make_interval(mins => i * 5),
            v_player_names[i], 17,
            jsonb_build_object('donated', 1000 * i, 'received', 750 * i),
            jsonb_build_object('points', 1000 * i),
            jsonb_build_object('onlineCount', 10 * i), jsonb_build_object('fixture', true)
        )
        ON CONFLICT (player_tag, season, clan_tag) DO NOTHING;

        INSERT INTO player_spells (player_tag, name, level, max_level, village)
        VALUES (v_players[i], 'Rage Spell', 5 + i, 12, 'home')
        ON CONFLICT (player_tag, name, village) DO NOTHING;

        INSERT INTO player_troops (
            player_tag, name, level, max_level, village, super_troop_is_active
        ) VALUES (v_players[i], 'Barbarian', 10 + i, 13, 'home', i = 1)
        ON CONFLICT (player_tag, name, village) DO NOTHING;

        INSERT INTO raid_weekends (
            clan_tag, start_time, end_time, state, total_attacks, capital_total_loot,
            raids_completed, offensive_reward, defensive_reward, members, attack_log,
            defense_log, data
        ) VALUES (
            v_clans[i], date_trunc('week', now()) - make_interval(weeks => i),
            date_trunc('week', now()) - make_interval(weeks => i) + interval '3 days',
            'ended', 250 + i, 500000 + i * 25000, 10 + i, 1200 + i * 10, 500 + i * 5,
            jsonb_build_array(jsonb_build_object('tag', v_players[i], 'name', v_player_names[i], 'loot', 10000 * i)),
            jsonb_build_array(jsonb_build_object('district', i, 'attacks', 5)),
            jsonb_build_array(jsonb_build_object('attacker', format('Demo Enemy %s', i))),
            jsonb_build_object('fixture', true, 'server_id', v_server_id)
        )
        ON CONFLICT (clan_tag, start_time) DO NOTHING;

        INSERT INTO ranked_league_group_members (
            season_id, group_tag, league_tier_id, player_tag, player_name, clan_tag,
            clan_name, placement, league_trophies, attack_win_count, attack_lose_count,
            defense_win_count, defense_lose_count
        ) VALUES (
            202607, 'demo-group', 1, v_players[i], v_player_names[i], v_primary_clan,
            'The Order', i, 5000 - i * 50, 10 + i, i, 8 + i, i + 1
        )
        ON CONFLICT (season_id, group_tag, player_tag) DO NOTHING;

        INSERT INTO ranking_snapshots (ranking_type, location, snapshot_date, data)
        VALUES (
            (ARRAY['players', 'clans', 'capital', 'builder', 'legend'])[i], 'global',
            to_char(current_date - i, 'YYYY-MM-DD'),
            jsonb_build_object('items', jsonb_build_array(jsonb_build_object('rank', i, 'tag', v_players[i])), 'fixture', true)
        )
        ON CONFLICT (ranking_type, location, snapshot_date) DO NOTHING;

        INSERT INTO reminders (
            id, server_id, type, clan_tag, webhook_token, thread_id, minutes_remaining,
            custom_text, clan_roles, townhalls, war_types, trigger_threshold, type_name,
            channel_id, trigger_time, roles, war_type_names, point_threshold,
            attack_threshold, ping_type, data
        ) VALUES (
            md5(format('demo:reminder:%s', i))::uuid, v_server_id, i, v_clans[i],
            format('demo-reminder-webhook-%s', i), format('demo-reminder-thread-%s', i),
            i * 15, format('Demo reminder %s', i), 1, ARRAY[15,16,17], 1, i,
            (ARRAY['war', 'capital', 'clan_games', 'inactivity', 'roster'])[i],
            format('demo-reminder-channel-%s', i), format('%s minutes', i * 15),
            ARRAY[format('demo-role-%s', i)], ARRAY['random'],
            jsonb_build_object('minimum', 1000 * i), jsonb_build_object('remaining', i),
            'role', jsonb_build_object('fixture', true)
        )
        ON CONFLICT (id) DO NOTHING;

        INSERT INTO server_roles (id, server_id, type, option, role_id, mode)
        VALUES (
            md5(format('demo:role-binding:%s', i))::uuid, v_server_id,
            (ARRAY['family', 'family', 'achievement', 'status', 'builder_league'])[i],
            (ARRAY['family', 'not_family', 'demo-key-3', 'demo-key-4', 'demo-key-5'])[i],
            format('demo-bound-role-%s', i), 'both'
        )
        ON CONFLICT (id) DO NOTHING;

        roster_group_uuid := md5(format('demo:roster-group:%s', i))::uuid;
        INSERT INTO roster_groups (id, server_id, name, group_id, alias, description)
        VALUES (
            roster_group_uuid, v_server_id, format('Demo Roster Group %s', i),
            format('demo-roster-group-%s', i), format('Demo Group %s', i),
            'Example grouping for related rosters'
        )
        ON CONFLICT (id) DO NOTHING;

        roster_uuid := md5(format('demo:roster:%s', i))::uuid;
        INSERT INTO rosters (
            id, server_id, custom_id, group_id, clan_tag, alias, description,
            roster_type, signup_scope, roster_size
        )
        VALUES (
            roster_uuid, v_server_id, format('demo-roster-%s', i),
            format('demo-roster-group-%s', i), v_clans[i], format('Demo Team %s', i),
            'Example normalized roster', 'clan', 'clan-only', 15
        )
        ON CONFLICT (id) DO NOTHING;

        INSERT INTO roster_members (tag, roster_id, name, townhall, position)
        VALUES (v_players[i], roster_uuid, v_player_names[i], 17, i)
        ON CONFLICT (tag, roster_id) DO NOTHING;

        INSERT INTO roster_automation_rules (
            automation_id, server_id, roster_id, group_id, enabled, trigger_type,
            action_type, offset_seconds, executed
        ) VALUES (
            format('demo-automation-%s', i), v_server_id, roster_uuid::text,
            format('demo-roster-group-%s', i), true,
            (ARRAY['daily', 'war_start', 'war_end', 'signup_close', 'manual'])[i],
            'notify', 0, false
        )
        ON CONFLICT (automation_id) DO NOTHING;

        INSERT INTO roster_signup_categories (
            custom_id, server_id, name, alias, description, sort_order
        ) VALUES (
            format('demo-signup-category-%s', i), v_server_id, format('Demo Signup Category %s', i),
            format('Category %s', i), 'Example self-selected roster signup category', i
        )
        ON CONFLICT (custom_id) DO NOTHING;

        INSERT INTO server_bans (
            server_id, player_tag, player_name, reason, added_by, edited_by, data
        ) VALUES (
            v_server_id, v_players[i], v_player_names[i], format('Demo moderation reason %s', i),
            v_users[1], jsonb_build_array(jsonb_build_object('user_id', v_users[2], 'reason', 'Example edit')),
            jsonb_build_object('fixture', true, 'active', i <> 5)
        )
        ON CONFLICT (server_id, player_tag) DO NOTHING;

        INSERT INTO server_roles (id, server_id, type, option, role_id, mode)
        VALUES
            (md5(format('demo:family-role:%s', i))::uuid, v_server_id,
             'family', 'family', format('demo-family-role-%s', i), 'both'),
            (md5(format('demo:not-family-role:%s', i))::uuid, v_server_id,
             'family', 'not_family', format('demo-guest-role-%s', i), 'remove')
        ON CONFLICT (id) DO NOTHING;

        INSERT INTO short_links (id, url, data)
        VALUES (
            format('demo%s', i), format('https://example.invalid/clashking/demo/%s', i),
            jsonb_build_object('owner', v_users[i], 'clicks', i * 10, 'fixture', true)
        )
        ON CONFLICT (id) DO NOTHING;

        INSERT INTO strikes (
            id, server_id, tag, date_created, reason, added_by, strike_weight,
            rollover_date, image, data
        ) VALUES (
            format('demo-strike-%s', i), v_server_id, v_players[i],
            now() - make_interval(days => i), format('Demo strike reason %s', i), v_users[1],
            i, now() + make_interval(days => i * 30), format('https://example.invalid/strike/%s.png', i),
            jsonb_build_object('fixture', true, 'player_name', v_player_names[i])
        )
        ON CONFLICT (id, server_id) DO NOTHING;

        panel_uuid := md5(format('demo:ticket-panel:%s', i))::uuid;
        INSERT INTO ticket_panel (
            id, server_id, name, description, parent_channel_id, open_category_id,
            closed_category_id, log_channel_id, naming_convention, embed_server_id, embed_name
        ) VALUES (
            panel_uuid, v_server_id, format('Demo Application Panel %s', i),
            format('Applications for configured clan %s', v_clans[i]),
            format('demo-parent-%s', i), format('demo-open-category-%s', i),
            format('demo-closed-category-%s', i), format('demo-log-channel-%s', i),
            'ticket-{number}-{user}', v_server_id, format('Demo Ticket Embed %s', i)
        )
        ON CONFLICT (id) DO NOTHING;

        INSERT INTO ticket_panel_buttons (
            id, panel_id, server_id, open_message_embed_server_id,
            open_message_embed_name, questions, staff_roles,
            roles_add_on_open, roles_remove_on_open, roles_add_on_close,
            roles_remove_on_close, allow_account_apply, min_townhall_level,
            max_townhall_level, staff_private_thread, send_player_info_to_channel,
            send_player_info_to_private_thread, auto_transcript, staff_to_ping,
            parent_channel_id, open_category_id, closed_category_id, log_channel_id,
            naming_convention
        ) VALUES (
            md5(format('demo:ticket-button:%s', i))::uuid, panel_uuid, v_server_id,
            v_server_id, format('Demo Ticket Embed %s', i),
            ARRAY['Why do you want to join?', 'What is your timezone?']::varchar[],
            ARRAY[format('demo-staff-role-%s', i)], ARRAY['demo-applicant-role'], ARRAY[]::text[],
            ARRAY['demo-member-role'], ARRAY['demo-applicant-role'], 1, 12, 17,
            true, true, true, true, ARRAY[format('demo-staff-user-%s', i)],
            format('demo-parent-%s', i), format('demo-open-category-%s', i),
            format('demo-closed-category-%s', i), format('demo-log-channel-%s', i),
            'ticket-{number}-{user}'
        )
        ON CONFLICT (id) DO NOTHING;

        INSERT INTO ticket_panel_staff_permissions (panel_id, role_id, permissions)
        VALUES (panel_uuid, format('demo-staff-role-%s', i), 7)
        ON CONFLICT (panel_id, role_id) DO NOTHING;

        INSERT INTO ticket_panels (server_id, name, components, data)
        VALUES (
            v_server_id, format('Demo Legacy Panel %s', i),
            jsonb_build_array(jsonb_build_object('type', 'button', 'label', format('Apply %s', i), 'custom_id', format('demo-apply-%s', i))),
            jsonb_build_object('fixture', true, 'clan_tag', v_clans[i])
        )
        ON CONFLICT (server_id, name) DO NOTHING;

        INSERT INTO tickets (
            id, server_id, channel_id, is_thread, status_id, panel_id, applicant_accounts, closed_at
        ) VALUES (
            md5(format('demo:ticket:%s', i))::uuid, v_server_id,
            format('demo-ticket-channel-%s', i), i % 2 = 0, CASE WHEN i = 5 THEN 2 ELSE 1 END,
            panel_uuid, ARRAY[v_players[i]], CASE WHEN i = 5 THEN now() ELSE NULL END
        )
        ON CONFLICT (id) DO NOTHING;

        INSERT INTO tracked_player_targets (tag, enabled, source)
        VALUES (v_players[i], true, 'demo_seed')
        ON CONFLICT (tag) DO NOTHING;

        INSERT INTO tracking_domain_stats (
            interval_start, interval_end, run_id, script, name, last_success, last_error,
            requests, writes, errors, request_latency_ms, queue_depth, healthy,
            last_ready_change, processing_count, total_process_time_ms, store_batches,
            store_rows_requested, store_rows_affected, store_duration_ms, target_count,
            target_cycle, target_processed
        )
        SELECT now() - make_interval(mins => i * 10), now() - make_interval(mins => (i - 1) * 10),
               900000 + i, 'demo-seed', (ARRAY['clans', 'players', 'wars', 'raids', 'rankings'])[i],
               now() - make_interval(mins => i), NULL, 100 * i, 80 * i, i - 1,
               25.5 + i, i, true, now() - interval '1 day', 50 * i, 1000.5 * i,
               5 * i, 80 * i, 78 * i, 200.25 * i, 1000 * i, i, 950 * i
        WHERE NOT EXISTS (
            SELECT 1 FROM tracking_domain_stats
            WHERE script = 'demo-seed' AND run_id = 900000 + i
        );

        INSERT INTO tracking_process_stats (
            interval_start, interval_end, run_id, script, process_started_at,
            uptime_ms, goroutines, alloc_bytes, heap_objects, gc_cycles
        )
        SELECT now() - make_interval(mins => i * 10), now() - make_interval(mins => (i - 1) * 10),
               900000 + i, 'demo-seed', now() - interval '2 hours',
               3600000 + i * 1000, 20 + i, 100000000 + i * 1000000,
               50000 + i * 1000, 100 + i
        WHERE NOT EXISTS (
            SELECT 1 FROM tracking_process_stats
            WHERE script = 'demo-seed' AND run_id = 900000 + i
        );

        INSERT INTO user_recent_searches (user_id, entity_type, tag, data, created_at)
        SELECT
            v_users[i], CASE WHEN i % 2 = 0 THEN 'clan' ELSE 'player' END,
            CASE WHEN i % 2 = 0 THEN v_clans[i] ELSE v_players[i] END,
            jsonb_build_object('name', CASE WHEN i % 2 = 0 THEN format('Configured Clan %s', i) ELSE v_player_names[i] END, 'fixture', true),
            now() - make_interval(mins => i)
        WHERE NOT EXISTS (
            SELECT 1
            FROM user_recent_searches
            WHERE user_id = v_users[i] AND data ->> 'fixture' = 'true'
        )
        ON CONFLICT (user_id, entity_type, tag, created_at) DO NOTHING;

        INSERT INTO user_settings (user_id, search, app, data)
        VALUES (
            v_users[i], jsonb_build_object('defaultType', 'player', 'showHistory', true),
            jsonb_build_object('theme', CASE WHEN i % 2 = 0 THEN 'light' ELSE 'dark' END, 'locale', 'en-US'),
            jsonb_build_object('fixture', true, 'homeClan', v_clans[i])
        )
        ON CONFLICT (user_id) DO NOTHING;
    END LOOP;
END
$seed$;

COMMIT;
