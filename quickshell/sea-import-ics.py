#!/usr/bin/env python3
# sea-shell — import .ics calendar files or URLs and merge them into ~/.config/sea-shell/calendar_events.json

import sys
import os
import re
import json
import urllib.request
from datetime import datetime

def parse_ics_content(content):
    events = []
    # Unfold lines (standard ICS files can wrap lines with leading whitespace)
    content = re.sub(r'\r?\n[ \t]', '', content)
    
    # Parse VEVENT blocks
    vevents = re.findall(r'BEGIN:VEVENT(.*?)END:VEVENT', content, re.DOTALL)
    for vevent in vevents:
        summary = "Untitled Event"
        date_formatted = ""
        time_formatted = ""
        description = ""
        
        # Summary
        m = re.search(r'^SUMMARY:(.*)', vevent, re.MULTILINE)
        if m:
            summary = m.group(1).strip()
            summary = summary.replace('\\,', ',').replace('\\;', ';').replace('\\n', '\n')
            
        # DTSTART
        m = re.search(r'^DTSTART(?:;[^:]*)?:(\d{8})(?:T(\d{4}))?', vevent, re.MULTILINE)
        if m:
            date_str = m.group(1)
            time_str = m.group(2) if m.group(2) else ""
            try:
                dt = datetime.strptime(date_str, "%Y%m%d")
                date_formatted = dt.strftime("%Y-%m-%d")
                if time_str:
                    time_formatted = f"{time_str[:2]}:{time_str[2:]}"
            except Exception:
                continue
                
        # Description
        m_desc = re.search(r'^DESCRIPTION:(.*)', vevent, re.MULTILINE)
        if m_desc:
            description = m_desc.group(1).strip().replace('\\,', ',').replace('\\;', ';').replace('\\n', '\n')
            
        if date_formatted:
            events.append({
                "title": summary,
                "date": date_formatted,
                "time": time_formatted,
                "desc": description
            })
            
    return events

def parse_ics(filepath):
    if not os.path.exists(filepath):
        print(json.dumps({"status": "error", "message": f"File not found: {filepath}"}))
        sys.exit(1)
        
    try:
        with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()
    except Exception as e:
        print(json.dumps({"status": "error", "message": f"Read failed: {str(e)}"}))
        sys.exit(1)
        
    return parse_ics_content(content)

def fetch_url(url):
    req = urllib.request.Request(
        url,
        headers={'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'}
    )
    with urllib.request.urlopen(req, timeout=12) as response:
        return response.read().decode('utf-8', errors='ignore')

def parse_ics_url(url):
    try:
        content = fetch_url(url)
    except Exception as e:
        print(json.dumps({"status": "error", "message": f"Download failed: {str(e)}"}))
        sys.exit(1)
    return parse_ics_content(content)

# ---------- storage ----------
CFG_DIR = os.path.expanduser("~/.config/sea-shell")
DB      = os.path.join(CFG_DIR, "calendar_events.json")
CAL     = os.path.join(CFG_DIR, "calendar.json")   # { subs: [url], remind: bool, lead: minutes }

def load_json(path, fallback):
    try:
        with open(path, 'r', encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return fallback

def save_json(path, data):
    os.makedirs(CFG_DIR, exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)

def load_cal():
    c = load_json(CAL, {})
    if not isinstance(c, dict):
        c = {}
    c.setdefault("subs", [])
    c.setdefault("remind", True)
    c.setdefault("lead", 30)
    return c

def evkey(e):
    return f"{e['date']}|{e['title']}|{e.get('time','')}"

def merge(existing, new_events):
    seen = {evkey(e) for e in existing}
    n = 0
    for e in new_events:
        if evkey(e) not in seen:
            existing.append(e); seen.add(evkey(e)); n += 1
    return n

def save_events(evs):
    evs.sort(key=lambda x: (x['date'], x.get('time', '')))
    save_json(DB, evs)

def main():
    args = sys.argv[1:]
    if not args:
        print(json.dumps({"status": "error", "message": "No file path or URL provided"}))
        sys.exit(1)

    # ---- re-sync every subscribed URL (bar runs this on a timer) ----
    if args[0] == "--resync":
        cal = load_cal(); evs = load_json(DB, []); added = 0; errors = []
        for url in cal.get("subs", []):
            try:
                added += merge(evs, parse_ics_content(fetch_url(url)))
            except Exception as ex:
                errors.append(f"{url}: {ex}")
        save_events(evs)
        print(json.dumps({"status": "success", "imported": added, "total": len(evs),
                          "subs": len(cal.get("subs", [])), "errors": errors}))
        return

    # ---- remove a subscription (leaves already-imported events in place) ----
    if args[0] == "--unsub" and len(args) > 1:
        cal = load_cal(); cal["subs"] = [u for u in cal["subs"] if u != args[1]]
        save_json(CAL, cal)
        print(json.dumps({"status": "success", "subs": len(cal["subs"])}))
        return

    # ---- delete a single event by "date|title|time" key ----
    if args[0] == "--delete" and len(args) > 1:
        evs = [e for e in load_json(DB, []) if evkey(e) != args[1]]
        save_events(evs)
        print(json.dumps({"status": "success", "total": len(evs)}))
        return

    # ---- set a preference: --set remind true|false  |  --set lead 30 ----
    if args[0] == "--set" and len(args) > 2:
        cal = load_cal()
        if args[1] == "remind":
            cal["remind"] = (args[2].lower() == "true")
        elif args[1] == "lead":
            try: cal["lead"] = max(0, int(args[2]))
            except Exception: pass
        save_json(CAL, cal)
        print(json.dumps({"status": "success", "remind": cal["remind"], "lead": cal["lead"]}))
        return

    # ---- default: import a file or URL (a URL is also remembered as a subscription) ----
    target = args[0].strip()
    if target.startswith("http://") or target.startswith("https://"):
        new_events = parse_ics_url(target)
        cal = load_cal()
        if target not in cal["subs"]:
            cal["subs"].append(target); save_json(CAL, cal)
    else:
        new_events = parse_ics(target)

    evs = load_json(DB, [])
    if not isinstance(evs, list):
        evs = []
    n = merge(evs, new_events)
    save_events(evs)
    print(json.dumps({"status": "success", "imported": n, "total": len(evs)}))

if __name__ == "__main__":
    main()
