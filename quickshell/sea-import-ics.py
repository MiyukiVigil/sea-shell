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

def parse_ics_url(url):
    try:
        req = urllib.request.Request(
            url, 
            headers={'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'}
        )
        with urllib.request.urlopen(req, timeout=12) as response:
            content = response.read().decode('utf-8', errors='ignore')
    except Exception as e:
        print(json.dumps({"status": "error", "message": f"Download failed: {str(e)}"}))
        sys.exit(1)
        
    return parse_ics_content(content)

def main():
    if len(sys.argv) < 2:
        print(json.dumps({"status": "error", "message": "No file path or URL provided"}))
        sys.exit(1)
        
    target = sys.argv[1].strip()
    if target.startswith("http://") or target.startswith("https://"):
        new_events = parse_ics_url(target)
    else:
        new_events = parse_ics(target)
    
    db_path = os.path.expanduser("~/.config/sea-shell/calendar_events.json")
    existing_events = []
    if os.path.exists(db_path):
        try:
            with open(db_path, 'r', encoding='utf-8') as f:
                existing_events = json.load(f)
        except Exception:
            pass
            
    # Merge without duplicates
    seen = {f"{e['date']}|{e['title']}|{e.get('time','')}" for e in existing_events}
    new_count = 0
    for e in new_events:
        key = f"{e['date']}|{e['title']}|{e.get('time','')}"
        if key not in seen:
            existing_events.append(e)
            seen.add(key)
            new_count += 1
            
    # Sort events by date and time
    existing_events.sort(key=lambda x: (x['date'], x.get('time', '')))
    
    try:
        os.makedirs(os.path.dirname(db_path), exist_ok=True)
        with open(db_path, 'w', encoding='utf-8') as f:
            json.dump(existing_events, f, indent=2, ensure_ascii=False)
        print(json.dumps({"status": "success", "imported": new_count, "total": len(existing_events)}))
    except Exception as e:
        print(json.dumps({"status": "error", "message": f"Write failed: {str(e)}"}))
        sys.exit(1)

if __name__ == "__main__":
    main()
