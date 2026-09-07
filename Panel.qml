import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Opacity Control — floating panel that sets the focused window's opacity.
//
// Applies live through Hyprland's `hl.dsp.window.set_prop` dispatcher. The
// window is pinned by address at open time rather than left to the dispatcher's
// "active window" default: once this panel is on screen it holds exclusive
// keyboard focus as a layer-shell surface, and by the time a slider drag fires
// a dispatch, "active" can no longer be trusted to still mean the window the
// panel was opened over. Nothing is persisted: this is a runtime knob, not a
// window rule, so a value only sticks until Hyprland re-evaluates that
// window's rules (e.g. on focus change or reload).
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  property real opacityValue: 1.0
  property bool pending: false
  property string targetAddress: ""

  // decoration:active_opacity/inactive_opacity/fullscreen_opacity — Omarchy's
  // (or Omaland's) global dimming ceiling. Hyprland always multiplies this
  // into a window's rendered opacity, "override" or not, so it has to be
  // compensated for rather than fought: see applyOpacity().
  property real activeCeiling: 1.0
  property real inactiveCeiling: 1.0
  property real fullscreenCeiling: 1.0

  // Last desired value we set per window (keyed by address), so reopening
  // the panel over a window we've already touched shows what it's actually
  // at instead of resetting it. A window we've never touched has no entry:
  // its current opacity is approximated as activeCeiling, since with no
  // override in play that ceiling is exactly what's rendering.
  property var knownValues: ({})

  readonly property string pluginId: (manifest && manifest.id) || "opacity-control"

  function open(payloadJson) {
    // Resolve the target window and the current dimming ceiling before
    // showing anything: queryProc's completion is what actually opens the
    // panel and sets the slider to the window's current opacity.
    queryProc.running = true
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide(root.pluginId)
    else
      root.close()
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function setOpacity(value) {
    root.opacityValue = Math.max(0, Math.min(1, value))
    if (root.targetAddress !== "") {
      var next = {}
      for (var k in root.knownValues) next[k] = root.knownValues[k]
      next[root.targetAddress] = root.opacityValue
      root.knownValues = next
    }
    applyOpacity()
  }

  function nudge(delta) {
    setOpacity(root.opacityValue + delta)
  }

  // Cancels decoration:*_opacity's contribution to this one window: since
  // Hyprland always multiplies rendered = windowValue * decoration:*_opacity
  // regardless of "override" (confirmed against Omaland's own opacity rule,
  // which relies on exactly this — see Omaland's LuaConfig.js), sending the
  // raw slider value would cap out at whatever ceiling Omaland (or the
  // theme) set. Dividing by that ceiling first makes the product equal the
  // slider value again, e.g. ceiling 0.95 + slider 1.0 -> send ~1.0526.
  // Hyprland allows opacity above 1 for exactly this; the corrected product
  // never itself exceeds 1, so this doesn't introduce the blending glitches
  // an uncompensated value over 1 would.
  function compensate(ceiling) {
    return root.opacityValue / Math.max(0.001, ceiling)
  }

  // One dispatch in flight at a time with the newest value queued behind it,
  // so a fast slider drag or a J/K burst can't outrun hyprctl.
  //
  // "override" on each of the three slots (active, inactive, fullscreen)
  // stops this rule from also multiplying with other matching window rules
  // (e.g. Omarchy's default-opacity tag), which is still needed on top of
  // the ceiling compensation above.
  function applyOpacity() {
    if (root.targetAddress === "") return
    if (applyProc.running) { root.pending = true; return }
    var a = compensate(root.activeCeiling).toFixed(4)
    var i = compensate(root.inactiveCeiling).toFixed(4)
    var f = compensate(root.fullscreenCeiling).toFixed(4)
    var spec = a + " override " + i + " override " + f + " override"
    var body = 'hl.dsp.window.set_prop({ prop = "opacity", value = "' + spec
      + '", window = "address:' + root.targetAddress + '" })'
    applyProc.command = ["hyprctl", "dispatch", body]
    applyProc.running = true
  }

  Process {
    id: applyProc
    onExited: {
      if (!root.pending) return
      root.pending = false
      Qt.callLater(root.applyOpacity)
    }
  }

  // Resolves the window this panel controls and the current dimming
  // ceiling, once, before it opens. Not read at dispatch time: the panel
  // itself grabs exclusive keyboard focus as soon as it is shown, so
  // "active window" read after that point would no longer reliably mean the
  // window underneath, and re-reading the ceiling on every drag tick would
  // just add latency for a value that essentially never changes mid-drag.
  Process {
    id: queryProc
    command: ["hyprctl", "-j", "--batch",
      "activewindow ; getoption decoration:active_opacity ; getoption decoration:inactive_opacity ; getoption decoration:fullscreen_opacity"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // hyprctl separates each batched command's JSON with a blank line;
        // splitting on that sidesteps activewindow's nested braces, which
        // would otherwise break a naive "match every {...}" scan.
        var parts = String(text).split(/\n\s*\n/)

        var address = ""
        try {
          var info = JSON.parse(parts[0] || "{}")
          if (info && info.address) address = String(info.address)
        } catch (e) {
        }

        function floatOf(part) {
          try {
            var o = JSON.parse(part || "{}")
            return (o && typeof o.float === "number") ? o.float : 1.0
          } catch (e) {
            return 1.0
          }
        }

        root.targetAddress = address
        root.activeCeiling = floatOf(parts[1])
        root.inactiveCeiling = floatOf(parts[2])
        root.fullscreenCeiling = floatOf(parts[3])

        var known = root.knownValues[address]
        root.opacityValue = (known !== undefined) ? known : root.activeCeiling
        applyOpacity()
        root.opened = true
        Qt.callLater(function() { keyCatcher.forceActiveFocus() })
      }
    }
  }

  PanelWindow {
    id: window
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "opacity-control"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    Rectangle {
      anchors.fill: parent
      color: Color.menu.scrim

      MouseArea {
        anchors.fill: parent
        onClicked: root.dismiss()
      }
    }

    BorderSurface {
      id: card
      anchors.centerIn: parent
      width: Style.space(320)
      height: Style.space(150)
      radius: Style.cornerRadius
      color: Color.menu.background
      borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
      padding: Style.spacing.panelPadding

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.dismiss(); event.accepted = true
          } else if (event.key === Qt.Key_J || event.key === Qt.Key_Left || event.key === Qt.Key_Down) {
            root.nudge(-0.01); event.accepted = true
          } else if (event.key === Qt.Key_K || event.key === Qt.Key_Right || event.key === Qt.Key_Up) {
            root.nudge(0.01); event.accepted = true
          }
        }
      }

      ColumnLayout {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.spacing.panelGap

        Text {
          text: "Window Opacity"
          color: Color.menu.text
          font.pixelSize: Style.font.heading
          font.bold: true
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.md

          PanelSlider {
            Layout.fillWidth: true
            minimum: 0.0
            maximum: 1.0
            step: 0.01
            value: root.opacityValue
            trackColor: Qt.rgba(Color.menu.text.r, Color.menu.text.g, Color.menu.text.b, 0.18)
            fillColor: Color.accent
            knobColor: Color.accent
            onMoved: function(v) { root.setOpacity(v) }
          }

          Text {
            text: Math.round(root.opacityValue * 100) + "%"
            color: Color.menu.text
            font.pixelSize: Style.font.caption
            Layout.preferredWidth: Style.space(40)
            horizontalAlignment: Text.AlignRight
          }
        }

        Text {
          text: "↑↓ / j k  ±1%   ·   Enter / Esc  close"
          color: Qt.darker(Color.menu.text, 1.6)
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  IpcHandler {
    target: "opacity-control"
    function open(): void { root.open("{}") }
    function close(): void { root.dismiss() }
    function toggle(): void { root.toggle() }
  }
}
