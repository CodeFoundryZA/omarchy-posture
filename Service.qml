import QtQuick
import Quickshell
import Quickshell.Io

// Headless singleton. Mirrors the daemon's state file into properties the bar
// widget and panel bind to, and forwards user actions back to the CLI.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property string omarchyPath: ""

  readonly property string pluginId: "io.github.codefoundryza.posture"
  readonly property string home: Quickshell.env("HOME")
  readonly property string pluginDir: home + "/.config/omarchy/plugins/" + pluginId
  readonly property string cli: pluginDir + "/bin/posture"
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state"))
    + "/omarchy/posture"
  readonly property string statePath: stateDir + "/state.json"
  readonly property string summaryPath: stateDir + "/summary.json"

  property var snapshot: null
  property bool serviceActive: false
  // Bumped by the timer below so time-derived bindings re-evaluate.
  property int tick: 0

  readonly property string state: snapshot && snapshot.state ? String(snapshot.state) : "unknown"
  readonly property string detail: snapshot && snapshot.detail ? String(snapshot.detail) : ""
  readonly property var metrics: snapshot && snapshot.metrics ? snapshot.metrics : null
  readonly property var deltas: snapshot && snapshot.deltas ? snapshot.deltas : null
  readonly property bool calibrated: snapshot ? snapshot.calibrated === true : false
  readonly property real sensitivity: snapshot && snapshot.sensitivity ? Number(snapshot.sensitivity) : 1.0
  readonly property real since: snapshot && snapshot.since ? Number(snapshot.since) : 0
  readonly property real updatedAt: snapshot && snapshot.updatedAt ? Number(snapshot.updatedAt) : 0

  // The daemon writes every interval. If the file goes cold the daemon is gone,
  // and reporting "good" then would be a lie.
  readonly property bool stale: (root.tick, updatedAt > 0 && (Date.now() / 1000 - updatedAt) > 60)

  readonly property bool bad: state === "bad" && !stale
  readonly property bool paused: state === "paused"
  readonly property bool blocked: state === "blocked"
  readonly property bool away: state === "away"
  readonly property bool needsAttention: bad || blocked || (!calibrated && !!snapshot)

  // The icon carries the state too, not just the colour: an upright seated
  // figure for good posture and a reclined one for bad, so the widget still
  // reads correctly for anyone who cannot rely on the red.
  readonly property string glyph: {
    if (stale || state === "unknown") return "󰘥"   // md-help_circle_outline
    if (blocked) return "󱜷"                        // md-webcam_off
    if (paused) return "󰏦"                         // md-pause_circle_outline
    if (!calibrated) return "󱄶"                    // md-crosshairs_question
    if (away) return "󰳄"                           // md-seat_outline, empty chair
    if (bad) return "󰒁"                            // md-seat_recline_extra, slouched
    return "󰒂"                                     // md-seat_recline_normal, upright
  }

  readonly property string statusText: {
    if (!snapshot) return "Posture monitor not running"
    if (stale) return "Posture monitor stopped"
    if (!calibrated) return "Not calibrated yet"
    switch (state) {
      case "good": return "Posture looks good"
      case "bad": return "Fix your posture"
      case "away": return "No one at the desk"
      case "paused": return "Paused"
      case "blocked": return "Camera is covered"
      case "unavailable": return "Camera unavailable"
      default: return state
    }
  }

  readonly property string durationText: {
    root.tick
    if (!since) return ""
    var secs = Math.max(0, Math.floor(Date.now() / 1000 - since))
    if (secs < 60) return secs + "s"
    if (secs < 3600) return Math.floor(secs / 60) + "m"
    return Math.floor(secs / 3600) + "h " + Math.floor((secs % 3600) / 60) + "m"
  }

  readonly property string tooltipText: [
    statusText,
    detail ? detail : "",
    durationText ? "for " + durationText : "",
    hasHistory && todayGoodPct >= 0
      ? "today: " + todayGoodPct.toFixed(0) + "% sitting well, "
        + todayBadEpisodes + " slouch" + (todayBadEpisodes === 1 ? "" : "es")
      : "",
    "",
    "Left click: details   Right click: pause   Middle click: recalibrate"
  ].filter(function (line) { return line !== ""; }).join("\n")

  // ---- history rollups, written by the daemon ----
  property var summary: null

  readonly property var today: summary && summary.today ? summary.today : null
  readonly property var recentHours: summary && summary.recentHours ? summary.recentHours : []
  readonly property real todayGoodPct: today && today.goodPct !== null && today.goodPct !== undefined
    ? Number(today.goodPct) : -1
  readonly property real todayMonitored: today ? Number(today.monitored || 0) : 0
  readonly property int todayBadEpisodes: today ? Number(today.badEpisodes || 0) : 0
  readonly property real todayLongestBad: today ? Number(today.longestBad || 0) : 0
  readonly property bool hasHistory: todayMonitored > 0

  function humanDuration(seconds) {
    var s = Math.max(0, Math.floor(Number(seconds) || 0))
    if (s < 60) return s + "s"
    if (s < 3600) return Math.floor(s / 60) + "m"
    return Math.floor(s / 3600) + "h " + Math.floor((s % 3600) / 60) + "m"
  }

  function run(args) {
    Quickshell.execDetached([root.cli].concat(args))
  }

  function togglePause() { run(["toggle"]) }
  // Calibration is interactive: it counts down, then samples you for several
  // seconds. Firing it detached ran it blind, with no countdown to sit up for
  // and no way to abort, silently replacing the baseline with whatever posture
  // happened to be in frame. It has to own a terminal.
  function recalibrate() {
    Quickshell.execDetached(["omarchy", "launch", "tui", "bash", "-lc",
      root.cli + " calibrate; echo; read -n1 -r -p 'Press any key to close...'"])
  }
  function setSensitivity(value) { run(["sensitivity", String(value)]) }

  // Opens the full report in a terminal; the panel only has room for today.
  function openHistory() {
    Quickshell.execDetached(["omarchy", "launch", "tui", "bash", "-lc",
      root.cli + " history; echo; read -n1 -r -p 'Press any key to close...'"])
  }
  function start() { run(["start"]) }

  function parse(content) {
    try {
      var parsed = JSON.parse(String(content || ""))
      root.snapshot = (parsed && typeof parsed === "object") ? parsed : null
    } catch (error) {
      root.snapshot = null
    }
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.parse(text())
    onLoadFailed: root.snapshot = null
  }

  FileView {
    id: summaryFile
    path: root.summaryPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        var parsed = JSON.parse(String(text() || ""))
        root.summary = (parsed && typeof parsed === "object") ? parsed : null
      } catch (error) {
        root.summary = null
      }
    }
    onLoadFailed: root.summary = null
  }

  // Drives the time-derived bindings, and re-reads both files.
  //
  // The reload is not belt and braces. The daemon publishes with an atomic
  // os.replace, which swaps in a new inode, and an inotify watch bound to the
  // old inode stops delivering events. When that happens the panel silently
  // freezes on whatever it last read, so the poll is what actually guarantees
  // the displayed values are live.
  Timer {
    interval: 3000
    running: true
    repeat: true
    onTriggered: {
      root.tick++
      stateFile.reload()
      summaryFile.reload()
    }
  }
}
