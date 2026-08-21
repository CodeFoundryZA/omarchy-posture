import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.codefoundryza.posture"
  ipcTarget: "io.github.codefoundryza.posture"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var posture: null
  property bool openedFromHotkey: false

  readonly property var barIdentity: hostWidget || root
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color cardFill: Style.selectedFillFor(foreground, Color.accent)

  readonly property bool bad: posture ? posture.bad : false
  readonly property var deltas: posture && posture.deltas ? posture.deltas : null

  function open() {
    openedFromHotkey = false
    root.controller.show()
    Qt.callLater(function () { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    Qt.callLater(function () { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function close() { root.controller.hide() }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function closeForPopoutSwitch() { root.close() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  readonly property var sensitivityPresets: [
    { value: "0.7", label: "Relaxed",  tooltip: "Only real slouches. Allows a 20% head drop." },
    { value: "1.0", label: "Normal",   tooltip: "Your calibrated tolerance. Allows a 14% head drop." },
    { value: "1.4", label: "Strict",   tooltip: "Nags earlier. Allows a 10% head drop." },
    { value: "2.0", label: "Strictest", tooltip: "Small movements trip it. Allows a 7% head drop." }
  ]

  // A value we have written but the daemon has not echoed back yet. Writing the
  // config, the daemon re-reading it and republishing state takes a few
  // seconds; without this the control would visibly snap back to the old value
  // in the gap and look broken.
  property real pendingSensitivity: -1

  readonly property real effectiveSensitivity: pendingSensitivity > 0
    ? pendingSensitivity
    : (posture ? posture.sensitivity : 1.0)

  // The CLI accepts any value in range, so a stored 1.9 still has to light up
  // a chip. Snap to whichever preset is closest.
  function nearestPreset(v) {
    var best = sensitivityPresets[0].value
    var bestGap = Infinity
    for (var i = 0; i < sensitivityPresets.length; i++) {
      var gap = Math.abs(parseFloat(sensitivityPresets[i].value) - v)
      if (gap < bestGap) { bestGap = gap; best = sensitivityPresets[i].value }
    }
    return best
  }

  // Every route (chips, keys, CLI) clamps identically and shows immediately.
  function setSensitivityTo(next) {
    if (!posture) return
    var clamped = Math.max(0.5, Math.min(2.5, Math.round(next * 10) / 10))
    pendingSensitivity = clamped
    posture.setSensitivity(clamped.toFixed(1))
  }

  function stepSensitivity(delta) {
    setSensitivityTo(effectiveSensitivity + delta)
  }

  // Drop the local override once the daemon agrees, or give up after a while
  // so a failed write cannot leave a permanently wrong reading on screen.
  Timer {
    interval: 1000
    running: root.pendingSensitivity > 0
    repeat: true
    property int waited: 0
    onTriggered: {
      waited++
      var live = root.posture ? root.posture.sensitivity : -1
      if (Math.abs(live - root.pendingSensitivity) < 0.05 || waited > 15) {
        root.pendingSensitivity = -1
        waited = 0
      }
    }
  }

  function pct(value) {
    if (value === undefined || value === null) return "—"
    return (Number(value) * 100).toFixed(1) + "%"
  }

  function deg(value) {
    if (value === undefined || value === null) return "—"
    return Number(value).toFixed(1) + "°"
  }

  // Each row is one posture axis: how far it has drifted, and its allowance.
  function driftRows() {
    if (!root.deltas) return []
    var s = Math.max(0.2, root.effectiveSensitivity)
    return [
      { label: "Head over shoulders", value: pct(root.deltas.neckDrop), limit: pct(0.14 / s) },
      { label: "Leaning in", value: pct(root.deltas.scaleGain), limit: pct(0.16 / s) },
      { label: "Sinking down", value: pct(root.deltas.frameRise), limit: pct(0.07 / s) },
      { label: "Side lean", value: deg(root.deltas.shoulderTilt), limit: deg(9.0 / s) },
      { label: "Head tilt", value: deg(root.deltas.headTilt), limit: deg(13.0 / s) }
    ]
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (text) {
        var key = String(text || "").toLowerCase()
        if (!root.posture) return
        if (key === "c") root.posture.recalibrate()
        else if (key === "p") root.posture.togglePause()
        else if (key === "h") { root.posture.openHistory(); root.close() }
        // Keyboard route for values between the presets.
        else if (key === "-" || key === "_") root.stepSensitivity(-0.1)
        else if (key === "+" || key === "=") root.stepSensitivity(0.1)
        else if (key === "0") root.setSensitivityTo(1.0)
      }

      Column {
        id: contentColumn
        width: parent.width
        spacing: Style.space(10)

        Text {
          width: parent.width
          text: "POSTURE"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.letterSpacing: 1
          font.bold: true
        }

        // Headline state card.
        Rectangle {
          width: parent.width
          height: headline.implicitHeight + Style.space(20)
          radius: Style.cornerRadius
          color: root.cardFill

          Column {
            id: headline
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: Style.space(10)
            spacing: Style.space(4)

            Text {
              width: parent.width
              text: root.posture ? root.posture.statusText : "Loading"
              color: root.bad ? root.urgent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
              wrapMode: Text.WordWrap
            }
            Text {
              // The detail usually explains the state, but for "good" it just
              // repeats the headline in lower case. Don't print it twice.
              visible: root.posture && root.posture.detail !== ""
                && root.posture.detail.toLowerCase() !== root.posture.statusText.toLowerCase()
              width: parent.width
              text: root.posture ? root.posture.detail : ""
              color: root.bad ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
            Text {
              visible: root.posture && root.posture.durationText !== ""
              width: parent.width
              text: root.posture ? "for " + root.posture.durationText : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        // Not calibrated is the one state where nothing else is meaningful.
        Text {
          visible: root.posture && !root.posture.calibrated
          width: parent.width
          text: "Calibrate first: sit the way you want to be reminded to sit, then press C."
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        PanelSectionHeader {
          visible: root.deltas !== null
          width: parent.width
          text: "DRIFT FROM BASELINE"
          foreground: root.dim
          fontFamily: root.fontFamily
        }

        Repeater {
          model: root.driftRows()
          delegate: Row {
            width: contentColumn.width
            spacing: Style.space(8)

            Text {
              width: parent.width * 0.5
              text: modelData.label
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }
            Text {
              width: parent.width * 0.22
              horizontalAlignment: Text.AlignRight
              text: modelData.value
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            Text {
              width: parent.width * 0.22
              horizontalAlignment: Text.AlignRight
              text: "/ " + modelData.limit
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }
        }

        PanelSeparator { visible: root.posture && root.posture.hasHistory; width: parent.width }

        PanelSectionHeader {
          visible: root.posture && root.posture.hasHistory
          width: parent.width
          text: "TODAY"
          foreground: root.dim
          fontFamily: root.fontFamily
        }

        // Headline number: share of monitored time spent sitting well.
        Row {
          visible: root.posture && root.posture.hasHistory
          width: parent.width
          spacing: Style.space(8)

          Text {
            text: root.posture && root.posture.todayGoodPct >= 0
              ? root.posture.todayGoodPct.toFixed(0) + "%"
              : "—"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            font.bold: true
          }
          Column {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)
            Text {
              text: "sitting well"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Text {
              text: root.posture
                ? root.posture.humanDuration(root.posture.todayMonitored) + " monitored"
                : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        Text {
          visible: root.posture && root.posture.hasHistory
          width: parent.width
          text: root.posture
            ? root.posture.todayBadEpisodes + " slouch"
              + (root.posture.todayBadEpisodes === 1 ? "" : "es")
              + (root.posture.todayLongestBad > 0
                  ? "   longest " + root.posture.humanDuration(root.posture.todayLongestBad)
                  : "")
            : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        // Last 12 hours, one column per hour. Height is the good share, and a
        // hollow column means the monitor was not watching during that hour.
        Item {
          visible: root.posture && root.posture.hasHistory
          width: parent.width
          height: Style.space(46)

          Row {
            id: sparkline
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: Style.space(34)
            spacing: Style.space(3)

            Repeater {
              model: root.posture ? root.posture.recentHours : []
              delegate: Item {
                width: (sparkline.width - sparkline.spacing * 11) / 12
                height: sparkline.height

                readonly property bool idle: modelData.goodPct === null
                  || modelData.goodPct === undefined
                readonly property real frac: idle ? 0 : Number(modelData.goodPct) / 100

                // Track behind each column, so a bad hour still reads as data.
                Rectangle {
                  anchors.fill: parent
                  radius: Style.cornerRadius > 0 ? 2 : 0
                  color: root.cardFill
                  opacity: parent.idle ? 0.35 : 0.7
                }
                Rectangle {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.bottom: parent.bottom
                  height: Math.max(parent.idle ? 0 : 2, parent.height * parent.frac)
                  radius: Style.cornerRadius > 0 ? 2 : 0
                  color: parent.frac < 0.6 ? root.urgent : root.foreground
                }
              }
            }
          }

          Row {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: sparkline.bottom
            anchors.topMargin: Style.space(4)
            spacing: Style.space(3)

            Repeater {
              model: root.posture ? root.posture.recentHours : []
              delegate: Text {
                width: (sparkline.width - sparkline.spacing * 11) / 12
                horizontalAlignment: Text.AlignHCenter
                // Every other hour, so the labels do not collide.
                text: (index % 2 === 0) ? modelData.hour : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }

        PanelSeparator { width: parent.width }

        PanelSectionHeader {
          width: parent.width
          text: "SENSITIVITY"
          foreground: root.dim
          fontFamily: root.fontFamily
        }

        Text {
          width: parent.width
          text: "How far you may drift from your calibrated baseline before it "
            + "complains. More sensitive means a smaller allowance, so it "
            + "notices sooner."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        // Spell out the actual allowance, so the number means something.
        Text {
          width: parent.width
          // Reflects the pending value too, so it updates the instant you click
          // rather than lagging behind the daemon.
          text: {
            var v = root.effectiveSensitivity
            if (!(v > 0)) return ""
            var s = Math.max(0.2, v)
            return v.toFixed(1) + "×   allows " + (14 / s).toFixed(0)
              + "% head drop, " + (9 / s).toFixed(0) + "° side lean"
          }
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        // Discrete presets rather than a slider. Sensitivity is a coarse
        // preference, not a continuous quantity, and a chip cannot disagree
        // with itself the way a slider knob did while waiting for the daemon
        // to echo a new value back.
        ButtonGroup {
          width: parent.width
          options: root.sensitivityPresets
          value: root.nearestPreset(root.effectiveSensitivity)
          foreground: root.foreground
          background: root.bar ? root.bar.background : Color.background
          accent: Color.accent
          fontFamily: root.fontFamily
          focusable: false
          onChanged: function (v) { root.setSensitivityTo(parseFloat(v)) }
        }

        PanelSeparator { width: parent.width }

        Text {
          width: parent.width
          text: "C calibrate   P " + (root.posture && root.posture.paused ? "resume" : "pause")
            + "   H history   -/+ tune   0 reset"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          text: "Samples the webcam every few seconds and speeds up when posture looks wrong, releasing the camera between samples."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
