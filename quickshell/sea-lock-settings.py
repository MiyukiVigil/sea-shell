#!/usr/bin/env python3
import sys
import os
import re
import json

HOME = os.path.expanduser("~")
HYPRIDLE_PATH = os.path.join(HOME, ".config/hypr/hypridle.conf")
HYPRLOCK_PATH = os.path.join(HOME, ".config/hypr/hyprlock.conf")

def get_repo_path():
    repo_file = os.path.join(HOME, ".config/sea-shell/.repo")
    if os.path.exists(repo_file):
        with open(repo_file, "r") as f:
            return f.read().strip()
    return None

REPO_DIR = get_repo_path()

def get_file_content(path, repo_subpath):
    if os.path.exists(path):
        with open(path, "r") as f:
            return f.read()
    if REPO_DIR:
        repo_path = os.path.join(REPO_DIR, repo_subpath)
        if os.path.exists(repo_path):
            with open(repo_path, "r") as f:
                return f.read()
    return ""

def save_file_content(path, repo_subpath, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(content)
    if REPO_DIR:
        repo_path = os.path.join(REPO_DIR, repo_subpath)
        if os.path.exists(repo_path) and repo_path != path:
            with open(repo_path, "w") as f:
                f.write(content)

def parse_hypridle():
    content = get_file_content(HYPRIDLE_PATH, "hypr/hypridle.conf")
    
    # Match listener blocks: ((?:#\s*)?listener\s*\{[^{}]*\})
    pattern = r'((?:#\s*)?listener\s*\{[^{}]*\})'
    blocks = re.findall(pattern, content)
    
    settings = {
        "idle_dim": 150,
        "idle_lock": 300,
        "idle_dpms": 600,
        "idle_suspend": 1800,
        "idle_suspend_enabled": True
    }
    
    for block in blocks:
        is_commented = block.strip().startswith("#")
        timeout_match = re.search(r'timeout\s*=\s*(\d+)', block)
        if not timeout_match:
            continue
        timeout_val = int(timeout_match.group(1))
        
        if "brightnessctl" in block:
            settings["idle_dim"] = timeout_val
        elif "loginctl lock-session" in block:
            settings["idle_lock"] = timeout_val
        elif "hyprctl dispatch dpms" in block:
            settings["idle_dpms"] = timeout_val
        elif "systemctl suspend" in block:
            settings["idle_suspend"] = timeout_val
            settings["idle_suspend_enabled"] = not is_commented
            
    return settings

def update_hypridle(new_settings):
    content = get_file_content(HYPRIDLE_PATH, "hypr/hypridle.conf")
    pattern = r'((?:#\s*)?listener\s*\{[^{}]*\})'
    
    def repl(match):
        block = match.group(1)
        is_commented = block.strip().startswith("#")
        
        if "brightnessctl" in block:
            if "idle_dim" in new_settings:
                block = re.sub(r'timeout\s*=\s*\d+', f'timeout = {new_settings["idle_dim"]}', block)
        elif "loginctl lock-session" in block:
            if "idle_lock" in new_settings:
                block = re.sub(r'timeout\s*=\s*\d+', f'timeout = {new_settings["idle_lock"]}', block)
        elif "hyprctl dispatch dpms" in block:
            if "idle_dpms" in new_settings:
                block = re.sub(r'timeout\s*=\s*\d+', f'timeout = {new_settings["idle_dpms"]}', block)
        elif "systemctl suspend" in block:
            if "idle_suspend" in new_settings:
                block = re.sub(r'timeout\s*=\s*\d+', f'timeout = {new_settings["idle_suspend"]}', block)
            if "idle_suspend_enabled" in new_settings:
                want_enabled = new_settings["idle_suspend_enabled"]
                if want_enabled and is_commented:
                    # Remove comment characters
                    lines = block.split('\n')
                    uncommented = []
                    for line in lines:
                        uncommented.append(re.sub(r'^(\s*)#\s*', r'\1', line))
                    block = '\n'.join(uncommented)
                elif not want_enabled and not is_commented:
                    # Comment out
                    lines = block.split('\n')
                    commented = []
                    for line in lines:
                        if line.strip():
                            commented.append("# " + line if not line.strip().startswith("#") else line)
                        else:
                            commented.append(line)
                    block = '\n'.join(commented)
        return block

    updated = re.sub(pattern, repl, content)
    save_file_content(HYPRIDLE_PATH, "hypr/hypridle.conf", updated)

def parse_hyprlock():
    content = get_file_content(HYPRLOCK_PATH, "hypr/hyprlock.conf")
    settings = {
        "lock_grace": 2,
        "lock_hide_cursor": True,
        "lock_ignore_empty": True,
        "lock_blur_passes": 3,
        "lock_blur_size": 6,
        "lock_vibrancy": 0.15,
        "lock_bg": "~/.config/sea-shell/sea-lockwall.png"
    }
    
    gen_match = re.search(r'general\s*\{([^{}]*)\}', content)
    if gen_match:
        body = gen_match.group(1)
        m = re.search(r'grace\s*=\s*(\d+)', body)
        if m: settings["lock_grace"] = int(m.group(1))
        m = re.search(r'hide_cursor\s*=\s*(true|false)', body)
        if m: settings["lock_hide_cursor"] = m.group(1) == "true"
        m = re.search(r'ignore_empty_input\s*=\s*(true|false)', body)
        if m: settings["lock_ignore_empty"] = m.group(1) == "true"
        
    bg_match = re.search(r'background\s*\{([^{}]*)\}', content)
    if bg_match:
        body = bg_match.group(1)
        m = re.search(r'path\s*=\s*([^\n#]+)', body)
        if m: settings["lock_bg"] = m.group(1).strip()
        m = re.search(r'blur_passes\s*=\s*(\d+)', body)
        if m: settings["lock_blur_passes"] = int(m.group(1))
        m = re.search(r'blur_size\s*=\s*(\d+)', body)
        if m: settings["lock_blur_size"] = int(m.group(1))
        m = re.search(r'vibrancy\s*=\s*([0-9.]+)', body)
        if m: settings["lock_vibrancy"] = float(m.group(1))
        
    return settings

def update_hyprlock(new_settings):
    content = get_file_content(HYPRLOCK_PATH, "hypr/hyprlock.conf")
    
    def repl_gen(match):
        body = match.group(1)
        if "lock_grace" in new_settings:
            body = re.sub(r'(\bgrace\s*=\s*)\d+', r'\g<1>' + str(new_settings["lock_grace"]), body)
        if "lock_hide_cursor" in new_settings:
            val = "true" if new_settings["lock_hide_cursor"] else "false"
            body = re.sub(r'(\bhide_cursor\s*=\s*)(?:true|false)', r'\g<1>' + val, body)
        if "lock_ignore_empty" in new_settings:
            val = "true" if new_settings["lock_ignore_empty"] else "false"
            body = re.sub(r'(\bignore_empty_input\s*=\s*)(?:true|false)', r'\g<1>' + val, body)
        return f"general {{{body}}}"
        
    content = re.sub(r'general\s*\{([^{}]*)\}', repl_gen, content)
    
    def repl_bg(match):
        body = match.group(1)
        if "lock_bg" in new_settings:
            body = re.sub(r'(\bpath\s*=\s*)[^\n#\s]+', r'\g<1>' + str(new_settings["lock_bg"]), body)
        if "lock_blur_passes" in new_settings:
            body = re.sub(r'(\bblur_passes\s*=\s*)\d+', r'\g<1>' + str(new_settings["lock_blur_passes"]), body)
        if "lock_blur_size" in new_settings:
            body = re.sub(r'(\bblur_size\s*=\s*)\d+', r'\g<1>' + str(new_settings["lock_blur_size"]), body)
        if "lock_vibrancy" in new_settings:
            body = re.sub(r'(\bvibrancy\s*=\s*)[0-9.]+', r'\g<1>' + str(new_settings["lock_vibrancy"]), body)
        return f"background {{{body}}}"
        
    content = re.sub(r'background\s*\{([^{}]*)\}', repl_bg, content)
    
    save_file_content(HYPRLOCK_PATH, "hypr/hyprlock.conf", content)

if len(sys.argv) > 1 and sys.argv[1] == "set":
    try:
        new_data = json.load(sys.stdin)
        update_hypridle(new_data)
        update_hyprlock(new_data)
        print(json.dumps({"status": "success"}))
    except Exception as e:
        print(json.dumps({"status": "error", "message": str(e)}), file=sys.stderr)
        sys.exit(1)
else:
    try:
        idle = parse_hypridle()
        lock = parse_hyprlock()
        combined = {**idle, **lock}
        print(json.dumps(combined))
    except Exception as e:
        print(json.dumps({"status": "error", "message": str(e)}), file=sys.stderr)
        sys.exit(1)
