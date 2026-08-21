import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.codefoundryza.posture"

  property var posture: null

  function bindService() {
    var shell = bar && bar.shell
    if (!shell || typeof shell.serviceFor !== "function") return
    var service = shell.serviceFor(root.moduleName)
    if (service) posture = service
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("posture" in target) target.posture = root.posture
  }

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
    else if (panelLoader.item && panelLoader.item.open) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  function toggle() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item && panelLoader.item.closeForPopoutSwitch)
      panelLoader.item.closeForPopoutSwitch()
    else close()
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: {
    bindService()
    injectPanel()
  }
  onSettingsChanged: injectPanel()
  onPostureChanged: injectPanel()

  Timer {
    interval: 250
    running: root.posture === null
    repeat: true
    onTriggered: root.bindService()
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar

    readonly property bool showLabel: root.settings && root.settings.showLabel === true

    // active paints the widget with bar.urgent, so "go red" stays theme correct.
    active: root.posture ? root.posture.needsAttention : false
    dimmed: root.posture ? (root.posture.away || root.posture.paused || root.posture.stale) : true

    text: {
      if (!root.posture) return "󰒂"
      if (!showLabel) return root.posture.glyph
      return root.posture.glyph + " " + root.posture.statusText
    }

    tooltipText: root.posture ? root.posture.tooltipText : "Posture monitor loading"

    onPressed: function (mouseButton) {
      if (!root.posture) return
      if (mouseButton === Qt.RightButton) root.posture.togglePause()
      else if (mouseButton === Qt.MiddleButton) root.posture.recalibrate()
      else root.toggle()
    }
  }
}
