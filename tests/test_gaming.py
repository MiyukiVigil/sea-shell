import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('sea_gaming', ROOT / 'quickshell/scripts/system/sea-gaming.py')
gaming = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gaming)


class GamingTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)
        self.cfg = self.home / 'config' / 'sea-shell'
        self.cfg.mkdir(parents=True)
        env = patch.dict(os.environ, {
            'HOME': str(self.home),
            'XDG_CONFIG_HOME': str(self.home / 'config'),
            'XDG_DATA_HOME': str(self.home / '.local/share'),
            'XDG_CACHE_HOME': str(self.home / 'cache'),
        })
        env.start()
        self.addCleanup(env.stop)
        fetch = patch.object(gaming, '_start_art_fetch')
        self.art_fetch = fetch.start()
        self.addCleanup(fetch.stop)
        lookup = patch.object(gaming, '_start_art_lookup')
        self.art_lookup = lookup.start()
        self.addCleanup(lookup.stop)
        gaming.DATA_FILE = self.cfg / 'gaming.json'
        gaming.PROFILES_FILE = self.cfg / 'gaming-profiles.json'
        gaming.CFG = self.cfg
        steamapps = self.home / '.local/share/Steam/steamapps'
        steamapps.mkdir(parents=True)
        (steamapps / 'appmanifest_570.acf').write_text(
            '"appid"\t"570"\n"name"\t"Dota 2"\n"StateFlags"\t"4"\n')

    def test_library_reads_installed_game(self):
        lib = gaming.library()
        self.assertEqual(len(lib), 1)
        self.assertEqual(lib[0]['appid'], '570')
        self.assertEqual(lib[0]['name'], 'Dota 2')

    def test_append_session_updates_playtime(self):
        gaming.append_session({
            'appid': '570',
            'title': 'Dota 2',
            'seconds': 600,
            'game_mode': True,
            'stats': {'gpu_avg': 55},
        })
        data = json.loads(gaming.DATA_FILE.read_text())
        self.assertEqual(data['playtime']['570'], 600)
        self.assertEqual(data['sessions'][0]['stats']['gpu_avg'], 55)

    def test_short_sessions_ignored(self):
        gaming.append_session({'appid': '570', 'seconds': 10})
        self.assertFalse(gaming.DATA_FILE.exists())

    def _twintail(self, folder=True):
        import sqlite3
        base = self.home / 'share/twintaillauncher'
        (base / 'games/sr').mkdir(parents=True)
        (base / 'games/sr/data.bin').write_bytes(b'x' * 500)
        db = sqlite3.connect(base / 'storage.db')
        db.executescript(
            'CREATE TABLE manifest (id TEXT, display_name TEXT);'
            'CREATE TABLE install (id TEXT, manifest_id TEXT, version TEXT, name TEXT, directory TEXT,'
            ' game_icon TEXT, game_background TEXT, last_played_time INT, total_playtime INT);'
            "INSERT INTO manifest VALUES ('m', 'Honkai: StarRail (Global)');")
        db.execute('INSERT INTO install VALUES (?,?,?,?,?,?,?,?,?)',
                   ('abc', 'm', '4.6.0', 'Honkai: StarRail 4.6.0 (Global)',
                    str(base / 'games/sr') if folder else str(base / 'gone'),
                    'http://i/icon.png', 'http://i/bg.webp', 2000000000, 9334))
        db.commit()
        db.close()
        return patch.dict(os.environ, {'XDG_DATA_HOME': str(self.home / 'share')})

    def test_library_includes_twintail_games(self):
        with self._twintail():
            lib = gaming.library()
        game = lib[0]
        self.assertEqual(game['appid'], 'twintail:abc')
        self.assertEqual(game['source'], 'twintail')
        self.assertEqual(game['name'], 'Honkai: StarRail')
        self.assertEqual(game['seconds'], 9334)
        self.assertEqual(game['size'], 500)
        self.assertEqual(lib[1]['source'], 'steam')

    def test_twintail_art_is_fetched_once_then_served_locally(self):
        with self._twintail():
            first = gaming.library()[0]
            self.assertEqual(first['art'], '')
            self.assertEqual(first['icon'], 'http://i/icon.png')
            self.assertEqual(self.art_fetch.call_count, 1)
            gaming.library()
            self.assertEqual(self.art_fetch.call_count, 1)
            done = gaming._art_file('http://i/bg.webp')
            done.write_bytes(b'jpeg')
            second = gaming.library()[0]
        self.assertEqual(second['art'], done.as_uri())
        self.assertEqual(second['hero'], done.as_uri())

    def test_art_cache_refuses_anything_but_web_addresses(self):
        self.assertEqual(gaming._cached_art('file:///etc/passwd'), '')
        with self.assertRaises(SystemExit):
            gaming.cache_art('file:///etc/passwd')

    def test_twintail_game_whose_folder_is_gone_is_hidden(self):
        with self._twintail(folder=False):
            self.assertEqual([g for g in gaming.library() if g['source'] == 'twintail'], [])

    def test_twintail_play_uses_its_own_shortcut_command_and_leaves_steam_alone(self):
        with patch.object(gaming.shutil, 'which', lambda n: '/usr/bin/' + n), \
                patch.object(gaming.subprocess, 'Popen') as popen, \
                patch.object(gaming, '_ensure_wrap_launch_options') as wrap:
            gaming.launch('twintail:abc')
        self.assertEqual(popen.call_args[0][0], ['/usr/bin/twintaillauncher', '--install=abc'])
        wrap.assert_not_called()

    def _lutris(self, installed=1):
        import sqlite3
        base = self.home / '.local/share/lutris'
        (base / 'coverart').mkdir(parents=True)
        (base / 'coverart/nikke.jpg').write_bytes(b'jpeg')
        game_dir = self.home / 'Games/nikke'
        game_dir.mkdir(parents=True)
        (game_dir / 'game.exe').write_bytes(b'x' * 300)
        db = sqlite3.connect(base / 'pga.db')
        db.execute('CREATE TABLE games (id INT, slug TEXT, name TEXT, directory TEXT, playtime REAL,'
                   ' lastplayed INT, installed INT, installed_at INT)')
        db.execute('INSERT INTO games VALUES (?,?,?,?,?,?,?,?)',
                   (7, 'nikke', 'goddess of victory: nikke', str(game_dir), 1.5, 2000000001, installed, 1))
        db.commit()
        db.close()

    def test_library_includes_lutris_games(self):
        self._lutris()
        lib = gaming.library()
        game = lib[0]
        self.assertEqual(game['appid'], 'lutris:7')
        self.assertEqual(game['source'], 'lutris')
        self.assertEqual(game['name'], 'Goddess Of Victory: Nikke')
        self.assertEqual(game['seconds'], 5400)
        self.assertEqual(game['size'], 300)
        self.assertTrue(game['art'].endswith('/lutris/coverart/nikke.jpg'))
        self.assertEqual(lib[1]['source'], 'steam')

    def test_uninstalled_lutris_game_is_hidden(self):
        self._lutris(installed=0)
        self.assertEqual([g for g in gaming.library() if g['source'] == 'lutris'], [])

    def test_lutris_play_uses_its_rungameid_uri_and_leaves_steam_alone(self):
        with patch.object(gaming.shutil, 'which', lambda n: '/usr/bin/' + n), \
                patch.object(gaming.subprocess, 'Popen') as popen, \
                patch.object(gaming, '_ensure_wrap_launch_options') as wrap:
            gaming.launch('lutris:7')
        self.assertEqual(popen.call_args[0][0], ['/usr/bin/lutris', 'lutris:rungameid/7'])
        wrap.assert_not_called()

    def _lutris_without_cover(self):
        self._lutris()
        (self.home / '.local/share/lutris/coverart/nikke.jpg').unlink()

    def test_game_without_background_is_looked_up_once_in_the_background(self):
        self._lutris_without_cover()
        self.assertEqual(gaming.library()[0]['hero'], '')
        gaming.library()
        self.art_lookup.assert_called_once_with('lutris:7', 'Goddess Of Victory: Nikke')

    def test_found_background_is_used_once_cached(self):
        self._lutris_without_cover()
        url = 'https://cdn2.steamgriddb.com/hero/x.png'
        (self.cfg / 'art-lookup.json').write_text(json.dumps(
            {'lutris:7': {'url': url, 'at': 0, 'name': 'Goddess Of Victory: Nikke', 'keyed': True}}))
        done = gaming._art_file(url)
        done.parent.mkdir(parents=True, exist_ok=True)
        done.write_bytes(b'jpeg')
        self.assertEqual(gaming.library()[0]['hero'], done.as_uri())
        self.art_lookup.assert_not_called()

    def test_missed_lookup_is_retried_when_a_steamgriddb_key_is_added(self):
        self._lutris_without_cover()
        (self.cfg / 'art-lookup.json').write_text(json.dumps(
            {'lutris:7': {'url': '', 'at': 9e12, 'name': 'Goddess Of Victory: Nikke', 'keyed': False}}))
        gaming.library()
        self.art_lookup.assert_not_called()
        (self.cfg / 'steamgriddb-key').write_text('k\n')
        gaming.library()
        self.art_lookup.assert_called_once()

    def test_picked_background_overrides_any_game_and_can_be_reset(self):
        pic = self.home / 'bg.png'
        pic.write_bytes(b'png')

        def fake_jpeg(src, out):
            out.write_bytes(src.read_bytes())
            return True
        with patch.object(gaming, '_to_jpeg', fake_jpeg):
            gaming.set_art('570', str(pic))
        game = gaming.library()[0]
        self.assertTrue(game['custom_hero'])
        self.assertIn('/game-art/570.jpg?v=', game['hero'])
        gaming.set_art('570', '')
        game = gaming.library()[0]
        self.assertFalse(game['custom_hero'])
        self.assertNotIn('game-art', game['hero'])

    def test_store_match_must_be_the_exact_title(self):
        reply = {'items': [{'id': 3596190, 'type': 'app', 'name': 'Stellar Blade™ x GODDESS OF VICTORY: NIKKE'}]}
        with patch.object(gaming, '_get_json', return_value=reply), \
                patch.object(gaming, '_url_ok', return_value=True):
            self.assertEqual(gaming._steam_store_hero('Goddess Of Victory: Nikke'), '')
            self.assertTrue(gaming._steam_store_hero('Stellar Blade x Goddess of Victory: NIKKE')
                            .endswith('/3596190/library_hero.jpg'))

    def test_lutris_two_week_time_is_the_growth_of_its_total(self):
        self._lutris()
        with patch.object(gaming.time, 'time', return_value=1_000_000_000):
            self.assertEqual(gaming.library()[0]['recent_seconds'], 0)
        import sqlite3
        db = sqlite3.connect(self.home / '.local/share/lutris/pga.db')
        db.execute('UPDATE games SET playtime = 2.0')
        db.commit()
        db.close()
        with patch.object(gaming.time, 'time', return_value=1_000_000_000 + 86400):
            self.assertEqual(gaming.library()[0]['recent_seconds'], 1800)
        with patch.object(gaming.time, 'time', return_value=1_000_000_000 + 20 * 86400):
            self.assertEqual(gaming.library()[0]['recent_seconds'], 0)

    def test_saved_runs_count_toward_any_games_two_weeks(self):
        self._lutris()
        gaming.append_session({'appid': 'lutris:7', 'title': 'Nikke', 'seconds': 900})
        game = gaming.library()[0]
        self.assertEqual(game['recent_seconds'], 900)
        self.assertEqual(game['last_session']['seconds'], 900)

    def test_wine_window_is_matched_to_its_game_by_install_folder(self):
        self._lutris()
        game_dir = str(self.home / 'Games/nikke')
        paths = {40: ['C:/users/x'], 30: ['/usr/bin', game_dir + '/drive_c/NIKKE']}
        with patch.object(gaming, '_proc_paths', lambda pid: paths.get(pid, [])), \
                patch.object(gaming, '_parent_pid', lambda pid: {40: 30, 30: 1}.get(pid, 0)):
            self.assertEqual(gaming.which_game(40), {'appid': 'lutris:7', 'title': 'Goddess Of Victory: Nikke'})
            self.assertEqual(gaming.which_game(99), {})

    def test_wine_paths_come_back_as_unix_paths(self):
        self.assertTrue(any(p == str(Path.cwd()) for p in gaming._proc_paths(os.getpid())))

    def _heroic(self):
        base = self.home / 'config/heroic'
        game_dir = self.home / 'Games/Heroic/Hades'
        game_dir.mkdir(parents=True)
        (game_dir / 'Hades.exe').write_bytes(b'x' * 700)
        for rel, data in {
            'legendaryConfig/legendary/installed.json': {'Min': {'app_name': 'Min', 'title': 'Hades', 'install_path': str(game_dir)},
                                                         'Dlc': {'app_name': 'Dlc', 'is_dlc': True, 'install_path': '/x'}},
            'store_cache/legendary_library.json': {'library': [{'app_name': 'Min', 'title': 'Hades',
                                                                'art_square': 'https://cdn/tall.jpg', 'art_cover': 'https://cdn/wide.jpg'}]},
            'gog_store/installed.json': {'installed': [{'appName': '1207', 'install_path': '/nowhere'}]},
            'store_cache/gog_library.json': {'games': [{'app_name': '1207', 'title': 'Stardew Valley'}]},
            'store/timestamp.json': {'Min': {'totalPlayed': 90, 'lastPlayed': '2026-11-01T10:00:00.000Z'}},
        }.items():
            (base / rel).parent.mkdir(parents=True, exist_ok=True)
            (base / rel).write_text(json.dumps(data))

    def test_library_includes_heroic_games_from_each_store(self):
        self._heroic()
        heroic = {g['appid']: g for g in gaming.library() if g['source'] == 'heroic'}
        self.assertEqual(set(heroic), {'heroic:legendary:Min', 'heroic:gog:1207'})
        hades = heroic['heroic:legendary:Min']
        self.assertEqual(hades['name'], 'Hades')
        self.assertEqual(hades['seconds'], 5400)
        self.assertEqual(hades['size'], 700)
        self.assertGreater(hades['last_played'], 0)
        self.assertEqual(heroic['heroic:gog:1207']['name'], 'Stardew Valley')

    def test_heroic_play_opens_its_launch_link_without_its_window(self):
        with patch.object(gaming.shutil, 'which', lambda n: '/usr/bin/' + n), \
                patch.object(gaming.subprocess, 'Popen') as popen:
            gaming.launch('heroic:legendary:Min')
        self.assertEqual(popen.call_args[0][0],
                         ['/usr/bin/heroic', '--no-gui', 'heroic://launch?appName=Min&runner=legendary'])

    def _prism(self, feral=None):
        for name in ('_notify', '_mark_game_mode_skip'):
            quiet = patch.object(gaming, name)
            quiet.start()
            self.addCleanup(quiet.stop)
        base = self.home / '.local/share/PrismLauncher'
        inst = base / 'instances/BMC4'
        (inst / 'minecraft').mkdir(parents=True)
        (inst / 'minecraft/mod.jar').write_bytes(b'x' * 300)
        (inst / 'instance.cfg').write_text(
            '[General]\nname=Better MC\niconKey=bmc\ntotalTimePlayed=7200\nlastLaunchTime=1800000000000\n'
            '[UI]\nname=ignored\n')
        (base / 'icons').mkdir()
        (base / 'icons/bmc.png').write_bytes(b'png')
        cfg = '[General]\nApplicationTheme=dark\n'
        if feral is not None:
            cfg += f'EnableFeralGamemode={feral}\n'
        (base / 'prismlauncher.cfg').write_text(cfg + '\n[UI]\nx=1\n')
        return base

    def test_library_includes_prism_instances(self):
        base = self._prism()
        game = next(g for g in gaming.library() if g['source'] == 'prism')
        self.assertEqual(game['appid'], 'prism:BMC4')
        self.assertEqual(game['name'], 'Better MC')
        self.assertEqual(game['seconds'], 7200)
        self.assertEqual(game['last_played'], 1800000000)
        self.assertEqual(game['art'], (base / 'icons/bmc.png').as_uri())
        self.assertEqual(game['directory'], str(base / 'instances/BMC4/minecraft'))

    def test_prism_icon_that_cannot_be_converted_leaves_the_library_working(self):
        base = self._prism()
        (base / 'icons/bmc.png').unlink()
        (base / 'icons/bmc.webp').write_bytes(b'webp')
        with patch.object(gaming, '_to_jpeg', return_value=False):
            game = next(g for g in gaming.library() if g['source'] == 'prism')
        self.assertEqual(game['art'], '')

    def test_prism_play_turns_on_its_feral_gamemode_when_closed(self):
        base = self._prism()
        with patch.object(gaming.shutil, 'which', lambda n: '/usr/bin/' + n), \
                patch.object(gaming, '_prism_running', return_value=False), \
                patch.object(gaming.subprocess, 'Popen') as popen:
            gaming.launch('prism:BMC4')
        self.assertEqual(popen.call_args[0][0], ['/usr/bin/prismlauncher', '--launch', 'BMC4'])
        self.assertEqual(popen.call_count, 1)
        cfg = (base / 'prismlauncher.cfg').read_text()
        self.assertEqual(gaming._ini_general(base / 'prismlauncher.cfg')['EnableFeralGamemode'], 'true')
        self.assertLess(cfg.index('EnableFeralGamemode'), cfg.index('[UI]'))

    def test_prism_play_while_it_runs_watches_minecraft_instead(self):
        base = self._prism()
        with patch.object(gaming.shutil, 'which', lambda n: '/usr/bin/' + n), \
                patch.object(gaming, '_prism_running', return_value=True), \
                patch.object(gaming.subprocess, 'Popen') as popen:
            gaming.launch('prism:BMC4')
        watch = popen.call_args_list[0][0][0]
        self.assertEqual(watch[-2:], ['prism-watch', str(base / 'instances/BMC4/minecraft')])
        self.assertNotIn('EnableFeralGamemode', (base / 'prismlauncher.cfg').read_text())

    def test_prism_play_with_feral_on_leaves_its_settings_alone(self):
        base = self._prism(feral='true')
        before = (base / 'prismlauncher.cfg').read_text()
        with patch.object(gaming.shutil, 'which', lambda n: '/usr/bin/' + n), \
                patch.object(gaming, '_prism_running', return_value=True), \
                patch.object(gaming.subprocess, 'Popen') as popen:
            gaming.launch('prism:BMC4')
        self.assertEqual(popen.call_count, 1)
        self.assertEqual((base / 'prismlauncher.cfg').read_text(), before)

    def test_favourites_are_marked_and_can_be_cleared(self):
        gaming.set_favourite('570', True)
        self.assertTrue(gaming.library()[0]['favourite'])
        gaming.set_favourite('570', False)
        self.assertFalse(gaming.library()[0]['favourite'])

    def test_library_hides_proton_and_runtimes(self):
        steamapps = self.home / '.local/share/Steam/steamapps'
        (steamapps / 'appmanifest_1493710.acf').write_text(
            '"appid"\t"1493710"\n"name"\t"Proton Experimental"\n"StateFlags"\t"4"\n')
        lib = gaming.library()
        names = [g['name'] for g in lib]
        self.assertIn('Dota 2', names)
        self.assertNotIn('Proton Experimental', names)

    def test_library_merges_steam_play_records(self):
        config = self.home / '.local/share/Steam/userdata/42/config'
        config.mkdir(parents=True)
        (config / 'localconfig.vdf').write_text(
            '"UserLocalConfigStore"\n{\n\t"Software"\n\t{\n\t\t"Valve"\n\t\t{\n\t\t\t"Steam"\n\t\t\t{\n'
            '\t\t\t\t"apps"\n\t\t\t\t{\n\t\t\t\t\t"570"\n\t\t\t\t\t{\n'
            '\t\t\t\t\t\t"cloud"\n\t\t\t\t\t\t{\n\t\t\t\t\t\t\t"last_sync_state"\t\t"synchronized"\n\t\t\t\t\t\t}\n'
            '\t\t\t\t\t\t"LastPlayed"\t\t"1700000000"\n\t\t\t\t\t\t"Playtime2wks"\t\t"30"\n'
            '\t\t\t\t\t\t"Playtime"\t\t"90"\n\t\t\t\t\t}\n\t\t\t\t}\n'
            '\t\t\t}\n\t\t}\n\t}\n}\n')
        game = gaming.library()[0]
        self.assertEqual(game['seconds'], 5400)
        self.assertEqual(game['recent_seconds'], 1800)
        self.assertEqual(game['last_played'], 1700000000)

    def test_library_keeps_longer_tracked_playtime_and_sorts_recent_first(self):
        steamapps = self.home / '.local/share/Steam/steamapps'
        (steamapps / 'appmanifest_10.acf').write_text(
            '"appid"\t"10"\n"name"\t"Zeta"\n"StateFlags"\t"4"\n"LastPlayed"\t"200"\n"SizeOnDisk"\t"1000"\n')
        gaming.add_playtime('570', 120)
        lib = gaming.library()
        self.assertEqual([g['name'] for g in lib], ['Zeta', 'Dota 2'])
        self.assertEqual(lib[0]['size'], 1000)
        self.assertEqual(lib[1]['seconds'], 120)

    def test_profile_merge_and_gamescope(self):
        gaming.profile_patch('570', {'mangohud': True, 'gamescope': '-W 1280 -H 720 -f --'})
        prof = gaming.profile_for('570')
        self.assertTrue(prof['mangohud'])
        cmd = gaming._gamescope_cmd(prof['gamescope'], ['steam', '-applaunch', '570'])
        self.assertEqual(cmd[0], 'gamescope')
        self.assertIn('--', cmd)
        self.assertIn('steam', cmd)

    def test_preflight_returns_checks(self):
        out = gaming.preflight()
        self.assertIn('checks', out)
        self.assertTrue(any(c['id'] == 'disk' for c in out['checks']))

    def test_defaults_patch(self):
        gaming.defaults_patch({'mangohud': True, 'gamemode': False})
        d = gaming.defaults()
        self.assertTrue(d['mangohud'])
        self.assertFalse(d['gamemode'])

    def test_search_library(self):
        hits = gaming.search_library('dota')
        self.assertEqual(len(hits), 1)
        self.assertEqual(hits[0]['appid'], '570')

    def _wrapped(self, profile, argv):
        gaming.profile_patch('570', profile)
        with patch.object(gaming.os, 'execvpe') as run, patch.object(gaming.shutil, 'which', lambda n: '/bin/' + n):
            gaming.wrap_exec('570', argv)
        return run.call_args[0][1], run.call_args[0][2]

    STEAM = ['/s/steam-launch-wrapper', '--', '/s/reaper', 'SteamLaunch', 'AppId=570', '--', '/s/proton', 'run', 'g.exe']

    def test_wrap_keeps_steams_own_separators(self):
        cmd, _ = self._wrapped({'gamemode': False, 'mangohud': False, 'gamescope': ''}, ['--', *self.STEAM])
        self.assertEqual(cmd, self.STEAM)

    def test_wrap_applies_mangohud_and_gamemode_without_touching_steam(self):
        cmd, _ = self._wrapped({'gamemode': True, 'mangohud': True, 'gamescope': ''}, ['--', *self.STEAM])
        self.assertEqual(cmd[:2], ['mangohud', 'gamemoderun'])
        self.assertEqual(cmd[2:], self.STEAM)

    def test_mangohud_still_reads_the_users_config(self):
        with patch.dict(os.environ):
            os.environ.pop('MANGOHUD_CONFIG', None)
            os.environ.pop('MANGOHUD_CONFIGFILE', None)
            _, env = self._wrapped({'gamemode': False, 'mangohud': True, 'gamescope': ''}, ['--', 'game'])
        self.assertTrue(env['MANGOHUD_CONFIG'].startswith('read_cfg,output_folder='))
        self.assertNotIn('MANGOHUD_CONFIGFILE', env)

    def test_mangohud_profile_overrides_the_file(self):
        cfg = gaming._mangohud_config({'mh_fps': '60', 'mh_look': 'fps', 'mh_corner': 'top-right'})
        self.assertTrue(cfg.startswith('read_cfg,'))
        self.assertIn('fps_only', cfg)
        self.assertIn('fps_limit=60,0', cfg)
        self.assertIn('position=top-right', cfg)

    def test_wrap_gamescope_on_hyprland_holds_the_overlay_back(self):
        with patch.dict(os.environ, {'HYPRLAND_INSTANCE_SIGNATURE': 'x', 'LD_PRELOAD': '/s/overlay.so'}):
            cmd, env = self._wrapped({'gamemode': False, 'mangohud': False, 'gamescope': '-W 1920 -H 1080 -f --'},
                                     ['--', *self.STEAM])
        self.assertEqual(cmd[:cmd.index('--')], ['gamescope', '-W', '1920', '-H', '1080', '-f'])
        self.assertNotIn('LD_PRELOAD', env)
        self.assertIn('LD_PRELOAD=/s/overlay.so', cmd)
        self.assertEqual(cmd[-len(self.STEAM):], self.STEAM)

    def test_old_windowed_preset_no_longer_swallows_the_separator(self):
        cmd = gaming._gamescope_cmd('-W 1920 -H 1080 -w --', ['game'])
        self.assertEqual(cmd, ['gamescope', '-W', '1920', '-H', '1080', '-w', '1920', '-h', '1080', '--', 'game'])

    def test_game_mode_on_play_off_marks_the_feral_hook(self):
        with patch.dict(os.environ, {'XDG_RUNTIME_DIR': str(self.home)}):
            marker = self.home / 'sea-gamemode-skip'
            self._wrapped({'game_mode_on_play': False}, ['--', 'game'])
            self.assertTrue(marker.exists())
            self._wrapped({'game_mode_on_play': True}, ['--', 'game'])
            self.assertFalse(marker.exists())

    def _localconfig(self, body):
        path = self.home / '.local/share/Steam/userdata/1/config/localconfig.vdf'
        path.parent.mkdir(parents=True)
        path.write_text('"apps"\n{\n\t"570"\n\t{\n' + body + '\t}\n}\n')
        return path

    def test_wrapper_installs_while_steam_is_closed_and_keeps_own_options(self):
        path = self._localconfig('\t\t"LaunchOptions"\t\t"PROTON_LOG=1 %command%"\n')
        with patch.object(gaming, '_steam_running', return_value=False):
            self.assertTrue(gaming._ensure_wrap_launch_options('570', 'steam'))
        self.assertIn('sea-steam-wrap.sh %command%', path.read_text())
        self.assertEqual(gaming.profile_for('570')['steam_launch_options'], 'PROTON_LOG=1 %command%')

    def test_steam_restarts_only_when_the_wrapper_is_missing(self):
        path = self._localconfig('\t\t"LastPlayed"\t\t"1"\n')
        with patch.object(gaming, '_steam_running', return_value=True), \
                patch.object(gaming, '_game_running', return_value=False), \
                patch.object(gaming, '_notify'), \
                patch.object(gaming, '_stop_steam', return_value=True) as stop:
            self.assertTrue(gaming._ensure_wrap_launch_options('570', 'steam'))
            self.assertEqual(stop.call_count, 1)
            self.assertTrue(gaming._ensure_wrap_launch_options('570', 'steam'))
            self.assertEqual(stop.call_count, 1)
        self.assertIn('sea-steam-wrap.sh', path.read_text())

    def test_running_game_is_never_cut_off_to_apply_settings(self):
        path = self._localconfig('\t\t"LastPlayed"\t\t"1"\n')
        before = path.read_text()
        with patch.object(gaming, '_steam_running', return_value=True), \
                patch.object(gaming, '_game_running', return_value=True), \
                patch.object(gaming, '_notify'), \
                patch.object(gaming, '_stop_steam') as stop:
            self.assertFalse(gaming._ensure_wrap_launch_options('570', 'steam'))
        stop.assert_not_called()
        self.assertEqual(path.read_text(), before)

    def test_vdf_value_with_quotes_stays_one_string(self):
        out = gaming._vdf_set_launch_options('"570"\n{\n}\n', '570', 'A="b c" %command%')
        self.assertIn(r'"A=\"b c\" %command%"', out)
        self.assertEqual(gaming._vdf_set_launch_options(out, '570', 'x %command%').count('LaunchOptions'), 1)

    def test_profile_keeps_steam_launch_options(self):
        gaming.profile_patch('570', {'steam_launch_options': 'PROTON_LOG=1 %command%'})
        self.assertEqual(gaming.profile_for('570')['steam_launch_options'], 'PROTON_LOG=1 %command%')

    def test_vdf_sets_launch_options(self):
        text = '"apps"\n{\n\t"570"\n\t{\n\t\t"LastPlayed"\t\t"1"\n\t}\n}\n'
        out = gaming._vdf_set_launch_options(text, '570', '/wrap.sh %command%')
        self.assertIn('LaunchOptions', out)
        self.assertIn('/wrap.sh %command%', out)

    def test_fps_stats_from_log(self):
        log_dir = self.cfg / 'mangohud-logs'
        log_dir.mkdir()
        path = log_dir / 'test.log'
        path.write_text('# comment\n0,16.6,60.0\n0,20.0,50.0\n')
        stats = gaming._fps_stats_since(0)
        self.assertEqual(stats['fps_avg'], 55)
        self.assertEqual(stats['fps_1pct_low'], 50)


if __name__ == '__main__':
    unittest.main()
