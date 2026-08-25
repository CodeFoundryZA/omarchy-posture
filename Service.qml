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
  // Distinct from `stale` above, which means the daemon stopped writing.
  // This means no calibrated profile describes what the camera is seeing.
  readonly property bool baselineStale: state === "stale"
  readonly property string profile: snapshot && snapshot.profile ? String(snapshot.profile) : ""
  readonly property var profiles: snapshot && snapshot.profiles ? snapshot.profiles : []

  // ---- first-run setup ----
  //
  // `omarchy plugin add` clones the repo and loads this, but a clone cannot
  // install python-opencv or a systemd user unit, so a fresh install sits
  // there inert. Rather than look broken, ask posture-setup-check what is
  // still missing and let the widget offer to finish the job.
  property var setupReport: null
  property bool setupChecked: false
  property int setupProbes: 0

  readonly property bool setupReady: setupReport ? setupReport.ready === true : false
  readonly property string setupBlocker: setupReport && setupReport.blocker
    ? String(setupReport.blocker) : ""
  readonly property string setupSummary: setupReport && setupReport.summary
    ? String(setupReport.summary) : ""
  // Nothing is claimed until the first check lands, so a slow check never
  // flashes "needs setup" at someone whose monitor is running perfectly well.
  readonly property bool needsSetup: setupChecked && !setupReady

  readonly property string setupHint: {
    switch (setupBlocker) {
      case "opencv": return "Click to install python-opencv and start monitoring"
      case "tools": return "Click to install the missing tools"
      case "unit": return "Click to install the background service"
      case "unit-stale": return "Click to update the background service"
      case "camera": return "Plug in a webcam, then click to finish setup"
      case "location": return "Click to see how to fix the plugin folder name"
      default: return "Click to finish setting up the posture monitor"
    }
  }

  readonly property bool needsAttention: needsSetup || bad || blocked || baselineStale
    || (!calibrated && !!snapshot)

  // The icon carries the state too, not just the colour: an upright seated
  // figure for good posture and a reclined one for bad, so the widget still
  // reads correctly for anyone who cannot rely on the red.
  readonly property string glyph: {
    if (needsSetup) return "󰯠"                    // md-wrench_outline
    if (stale || state === "unknown") return "󰘥"   // md-help_circle_outline
    if (blocked) return "󱜷"                        // md-webcam_off
    if (paused) return "󰏦"                         // md-pause_circle_outline
    if (!calibrated) return "󱄶"                    // md-crosshairs_question
    if (baselineStale) return "󱄶"                  // md-crosshairs_question
    if (away) return "󰳄"                           // md-seat_outline, empty chair
    if (bad) return "󰒁"                            // md-seat_recline_extra, slouched
    return "󰒂"                                     // md-seat_recline_normal, upright
  }

  readonly property string statusText: {
    if (needsSetup) return "Posture monitor needs setup"
    if (!snapshot) return "Posture monitor not running"
    if (stale) return "Posture monitor stopped"
    if (!calibrated) return "Not calibrated yet"
    switch (state) {
      case "good": return "Posture looks good"
      case "bad": return "Fix your posture"
      case "away": return "No one at the desk"
      case "paused": return "Paused"
      case "stale": return "Calibration looks stale"
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

  readonly property string tooltipText: {
    // Before setup finishes there is nothing to pause or recalibrate, so
    // promising those keys would only mislead.
    if (needsSetup) {
      return [statusText, setupSummary, setupHint]
        .filter(function (line) { return line !== ""; }).join("\n")
    }
    return [
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
  }

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

  function useProfile(name) { run(["profiles", "--use", String(name)]) }

  // Prompt for a name through the Omarchy menu, then calibrate it in a
  // terminal, because calibration needs a visible countdown to sit up for.
  //
  // The name reaches both shells as an argv element and never as script text.
  // Interpolating it into the inner command string instead, as this first did,
  // let a name containing a single quote close that string and run whatever
  // followed it. `omarchy launch tui` execs its arguments, so positional
  // parameters survive the trip into the terminal intact.
  function calibrateNewProfile() {
    Quickshell.execDetached(["bash", "-lc",
      "name=$(omarchy menu input 'Name this seating setup' --width 400) || exit 0; "
      + "[ -n \"$name\" ] || exit 0; "
      + "exec omarchy launch tui bash -lc "
      + "'\"$1\" calibrate --profile \"$2\"; echo; "
      + "read -n1 -r -p \"Press any key to close...\"' posture \"$0\" \"$name\"",
      root.cli])
  }

  // Opens the full report in a terminal; the panel only has room for today.
  function openHistory() {
    Quickshell.execDetached(["omarchy", "launch", "tui", "bash", "-lc",
      root.cli + " history; echo; read -n1 -r -p 'Press any key to close...'"])
  }
  function start() { run(["start"]) }

  // Setup runs in a terminal rather than detached: it asks before it installs
  // anything, and the password prompt `omarchy pkg add` raises has to land
  // somewhere the user can actually answer it.
  //
  // The path travels as a positional parameter rather than as script text,
  // for the same reason calibrateNewProfile does it that way.
  function runSetup() {
    Quickshell.execDetached(["omarchy", "launch", "tui", "bash", "-lc",
      "\"$1\"; echo; read -n1 -r -p 'Press any key to close...'",
      "posture-install", root.pluginDir + "/bin/posture-install"])
  }

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

  Process {
    id: setupCheck
    command: [root.pluginDir + "/bin/posture-setup-check"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(String(text || ""))
          root.setupReport = (parsed && typeof parsed === "object") ? parsed : null
        } catch (error) {
          root.setupReport = null
        }
        root.setupChecked = true
      }
    }
  }

  // Polls quickly until the first answer lands, then slowly, then stops for
  // good once setup is complete. After that the daemon's own state file says
  // whether the monitor is alive, so there is nothing left to poll for.
  //
  // The probe cap covers a clone that arrived without the check script, or
  // without the bit set on it. Retrying forever would log a failed spawn every
  // couple of seconds for the life of the session, so give up and leave the
  // widget behaving exactly as it did before any of this existed.
  Timer {
    interval: root.setupChecked ? 20000 : 2000
    running: !root.setupReady && (root.setupChecked || root.setupProbes < 5)
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (setupCheck.running) return
      root.setupProbes++
      setupCheck.running = true
    }
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
