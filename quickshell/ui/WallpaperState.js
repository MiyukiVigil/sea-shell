.pragma library

// What a video wallpaper should be doing right now: "off" | "play" | "pause" | "freeze".
//
//   off     — the wallpaper is a still; awww shows it and the video surface stays hidden.
//   play    — visible, decoding.
//   pause   — covered, decoder kept warm so it comes back instantly.
//   freeze  — the player is unloaded (decoder + VRAM released) and the poster stands in.
//
// coveredAll is fullscreen on every monitor. occluded is a window covering the panel
// (a maximised editor, the dashboard): the clip is not on screen, so the decoder goes
// away instead of playing behind it. Coming back starts the player again; awww's poster
// is what you see for that moment.
function decide(s) {
    if (!s || !s.motion) return "off";
    if (s.gameOn) return "freeze";
    if (s.batteryStill && s.onBattery) return "freeze";
    if (s.coveredAll) return s.coverStill === false ? "pause" : "freeze";
    if (s.occluded) return "freeze";
    return "play";
}

function isMotion(path) {
    return /\.(mp4|webm|gif|mkv|mov)$/i.test("" + (path || ""));
}
