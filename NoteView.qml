import QtQuick
import QtQuick.Controls
import qs.Commons
import "NoteParser.js" as NoteParser

Item {
  id: root

  signal taskClicked(int lineNo, bool checked)
  signal linkActivated(string link)
  signal taskAdded(string text)
  signal taskInputTab(int direction)
  signal taskInputEsc()
  signal taskInputTraverse(int delta)

  signal taskDeleted(int lineNo)
  signal exitDeleteButtonFocus()

  property color bodyText: "white"
  property color dimText: Qt.rgba(bodyText.r, bodyText.g, bodyText.b, 0.55)
  property color accent: "white"
  property color panelBackground: "transparent"
  property string fontFamily: "monospace"
  property string noteTitle: ""
  property bool noteOpen: false
  readonly property bool taskInputActive: taskInput.activeFocus
  property int bodyFontSize: Style.font.body
  property int horizontalPadding: Style.space(10)
  property int verticalPadding: Style.space(8)
  property var sourceBlocks: []
  property bool taskCursorActive: false
  property int taskCursorIndex: 0
  property int deleteButtonFocusedOrdinal: -1
  property var taskBlockIndexes: []
  readonly property bool hasTaskBlocks: taskBlockIndexes.length > 0
  readonly property int taskCount: taskBlockIndexes.length

  function setSource(source) {
    sourceBlocks = NoteParser.parseBlocks(source)
    blocks.clear()
    taskCursorIndex = 0
    deleteButtonFocusedOrdinal = -1
    var idxs = []
    var skipTitle = sourceBlocks.length > 0
      && sourceBlocks[0].type === "heading"
      && sourceBlocks[0].level === 1
      && sourceBlocks[0].text.trim() === noteTitle.trim()
    var ordinal = 0
    for (var i = 0; i < sourceBlocks.length; i++) {
      if (skipTitle && i === 0) continue
      var b = sourceBlocks[i]
      var taskOrdinal = -1
      if (b.type === "task") {
        taskOrdinal = ordinal
        idxs.push(blocks.count)
        ordinal++
      }
      blocks.append({
        type: b.type,
        text: b.text,
        level: b.level,
        checked: b.checked,
        marker: b.marker,
        gapBefore: b.gapBefore,
        lineNo: b.lineNo,
        taskOrdinal: taskOrdinal
      })
    }
    taskBlockIndexes = idxs
  }

  function updateTask(lineNo, checked) {
    for (var i = 0; i < blocks.count; i++) {
      if (blocks.get(i).lineNo === lineNo) {
        blocks.setProperty(i, "checked", checked)
        return
      }
    }
  }

  function focusTaskInput() {
    if (noteOpen) taskInput.forceActiveFocus()
  }

  function moveTaskCursor(delta) {
    if (taskBlockIndexes.length === 0) return
    taskCursorIndex = Math.min(Math.max(taskCursorIndex + delta, 0), taskBlockIndexes.length - 1)
  }

  function placeTaskCursorAtLast() {
    if (taskBlockIndexes.length === 0) return
    taskCursorIndex = taskBlockIndexes.length - 1
  }

  function toggleTaskAtCursor() {
    if (taskBlockIndexes.length === 0) return
    var b = blocks.get(taskBlockIndexes[taskCursorIndex])
    taskClicked(b.lineNo, b.checked)
  }

  function focusDeleteButton(ordinal) {
    deleteButtonFocusedOrdinal = ordinal
    // Ensure task cursor remains visible
    taskCursorActive = true
  }

  function clearDeleteButtonFocus() {
    deleteButtonFocusedOrdinal = -1
    taskCursorActive = true
  }

  function focusDeleteButtonWithFocus(ordinal) {
    deleteButtonFocusedOrdinal = ordinal
    taskCursorActive = true
    Qt.callLater(function() {
      var item = blocksRepeater.itemAt(taskBlockIndexes[ordinal])
      if (item && item.deleteButton) {
        item.deleteButton.forceActiveFocus()
      }
    })
  }

  function clearDeleteButtonFocusWithReturn() {
    deleteButtonFocusedOrdinal = -1
    taskCursorActive = true
    exitDeleteButtonFocus()
  }

  function taskCursorViewportY() {
    if (taskBlockIndexes.length === 0) return -1
    var item = blocksRepeater.itemAt(taskBlockIndexes[taskCursorIndex])
    if (!item) return -1
    return item.mapToItem(root, 0, 0).y
  }

  implicitHeight: contentColumn.implicitHeight + verticalPadding * 2

  ListModel { id: blocks }

  Column {
    id: contentColumn
    x: root.horizontalPadding
    y: root.verticalPadding
    width: Math.max(0, root.width - root.horizontalPadding * 2)
    spacing: 0

    Repeater {
      id: blocksRepeater
      model: blocks

      delegate: Item {
        id: blockItem
        required property string type
        required property string text
        required property int level
        required property bool checked
        required property int gapBefore
        required property int lineNo
        required property string marker
        required property int taskOrdinal

        width: contentColumn.width
        height: blockColumn.implicitHeight + gapHeight + taskSpacing

        readonly property real gapHeight: {
          var gap = gapBefore * Style.space(8)
          if (type === "heading" || type === "pseudoHeading") gap += Style.space(8)
          return gap
        }
        readonly property real taskSpacing: type === "task" ? Style.space(4) : 0
        readonly property bool isTaskCursor: root.taskCursorActive
          && type === "task"
          && taskOrdinal >= 0
          && taskOrdinal === root.taskCursorIndex

        Rectangle {
          visible: blockItem.isTaskCursor
          x: -Style.space(2)
          y: blockItem.gapHeight - Style.space(2)
          width: blockItem.width + Style.space(4)
          height: blockColumn.height + Style.space(4)
          radius: Style.space(4)
          color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.12)
          border.color: root.accent
          border.width: 1
        }

        Column {
          id: blockColumn
          y: blockItem.gapHeight
          width: blockItem.width
          spacing: Style.space(4)

          Text {
            id: headingText
            visible: blockItem.type === "heading"
            x: blockItem.level > 1 ? Style.space(2) : 0
            width: parent.width - x
            text: blockItem.text
            color: root.bodyText
            font.family: root.fontFamily
            font.pixelSize: Math.max(root.bodyFontSize, Style.font.display - (blockItem.level - 1) * Style.space(2))
            font.bold: true
            wrapMode: Text.Wrap
            lineHeight: 1.2
            lineHeightMode: Text.ProportionalHeight
            textFormat: Text.MarkdownText
            onLinkActivated: (link) => root.linkActivated(link)
          }

          Text {
            id: pseudoHeadingText
            visible: blockItem.type === "pseudoHeading"
            x: blockItem.level * Style.space(12)
            width: parent.width - x
            text: blockItem.text
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
            wrapMode: Text.Wrap
            lineHeight: 1.2
            lineHeightMode: Text.ProportionalHeight
            textFormat: Text.MarkdownText
            onLinkActivated: (link) => root.linkActivated(link)
          }

          Text {
            id: paragraphText
            visible: blockItem.type === "paragraph"
            x: blockItem.level * Style.space(12)
            width: parent.width - x
            text: blockItem.text
            color: root.bodyText
            font.family: root.fontFamily
            font.pixelSize: root.bodyFontSize
            wrapMode: Text.Wrap
            lineHeight: 1.35
            lineHeightMode: Text.ProportionalHeight
            textFormat: Text.MarkdownText
            onLinkActivated: (link) => root.linkActivated(link)
          }

          Row {
            id: taskItem
            property alias deleteButton: deleteButton
            focus: true
            visible: blockItem.type === "task"
            x: blockItem.level * Style.space(12)
            width: parent.width - x
            spacing: Style.space(8)

            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Right && blockItem.checked && blockItem.taskOrdinal >= 0) {
                root.focusDeleteButtonWithFocus(blockItem.taskOrdinal)
                event.accepted = true
                return
              }
            }

            Rectangle {
              id: checkbox
              width: Style.space(17)
              height: Style.space(17)
              radius: Style.space(4)
              anchors.top: taskText.top
              anchors.topMargin: Style.space(1)
              color: blockItem.checked ? root.accent : "transparent"
              border.width: blockItem.checked ? 0 : 1
              border.color: blockItem.checked ? root.accent : root.dimText

              Text {
                anchors.centerIn: parent
                visible: blockItem.checked
                text: "\u2713"
                color: root.panelBackground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.taskClicked(blockItem.lineNo, blockItem.checked)
              }
            }

            Text {
              id: taskText
              width: parent.width - checkbox.width - parent.spacing - (deleteButton.visible ? deleteButton.width + parent.spacing : 0)
              text: blockItem.text
              color: blockItem.checked ? root.dimText : root.bodyText
              font.family: root.fontFamily
              font.pixelSize: root.bodyFontSize
              wrapMode: Text.Wrap
              lineHeight: 1.35
              lineHeightMode: Text.ProportionalHeight
              textFormat: Text.MarkdownText
              onLinkActivated: (link) => root.linkActivated(link)
            }

            Rectangle {
              id: deleteButton
              visible: blockItem.checked
              focus: true
              width: Style.space(20)
              height: Style.space(20)
              radius: Style.space(4)
              color: deleteMouse.containsMouse || deleteMouse.pressed
                ? Style.hoverFillFor(root.bodyText, Color.urgent)
                : "transparent"
              border.color: deleteMouse.containsMouse || deleteMouse.pressed
                ? Color.urgent
                : root.dimText
              border.width: 1

              Text {
                anchors.centerIn: parent
                text: "×"
                color: deleteMouse.containsMouse || deleteMouse.pressed
                  ? Color.urgent
                  : root.dimText
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
              }

              MouseArea {
                id: deleteMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.taskDeleted(blockItem.lineNo)
              }

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                  root.taskDeleted(blockItem.lineNo)
                  root.clearDeleteButtonFocusWithReturn()
                  event.accepted = true
                  return
                }
                if (event.key === Qt.Key_Left || event.key === Qt.Key_Escape) {
                  root.clearDeleteButtonFocusWithReturn()
                  event.accepted = true
                  return
                }
              }

              Rectangle {
                id: deleteFocusRing
                visible: root.deleteButtonFocusedOrdinal === blockItem.taskOrdinal
                anchors.fill: parent
                radius: Style.space(4)
                color: "transparent"
                border.color: root.accent
                border.width: 2
              }
            }
          }

          Row {
            id: bulletRow
            visible: blockItem.type === "bullet"
            x: blockItem.level * Style.space(12)
            width: parent.width - x
            spacing: Style.space(8)

            Text {
              text: "\u2022"
              width: Style.space(10)
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: root.bodyFontSize
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              width: parent.width - Style.space(18)
              text: blockItem.text
              color: root.bodyText
              font.family: root.fontFamily
              font.pixelSize: root.bodyFontSize
              wrapMode: Text.Wrap
              lineHeight: 1.35
              lineHeightMode: Text.ProportionalHeight
              textFormat: Text.MarkdownText
              onLinkActivated: (link) => root.linkActivated(link)
            }
          }

          Row {
            id: orderedRow
            visible: blockItem.type === "ordered"
            x: blockItem.level * Style.space(12)
            width: parent.width - x
            spacing: Style.space(8)

            Text {
              text: blockItem.marker
              width: Style.space(24)
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: root.bodyFontSize
              horizontalAlignment: Text.AlignRight
            }

            Text {
              width: parent.width - Style.space(32)
              text: blockItem.text
              color: root.bodyText
              font.family: root.fontFamily
              font.pixelSize: root.bodyFontSize
              wrapMode: Text.Wrap
              lineHeight: 1.35
              lineHeightMode: Text.ProportionalHeight
              textFormat: Text.MarkdownText
              onLinkActivated: (link) => root.linkActivated(link)
            }
          }

          Rectangle {
            visible: blockItem.type === "divider"
            width: parent.width
            height: Style.space(1)
            color: root.dimText
          }
        }
      }
    }

    Item {
      visible: root.noteOpen
      width: 1
      height: Style.space(12)
    }

    TextArea {
      id: taskInput
      visible: root.noteOpen
      width: contentColumn.width - Style.space(12) * 2
      x: Style.space(12)
      color: root.bodyText
      font.family: root.fontFamily
      font.pixelSize: root.bodyFontSize
      wrapMode: TextArea.Wrap
      placeholderText: "Add a task..."
      placeholderTextColor: root.dimText
      selectByMouse: true
      clip: true
      background: Rectangle {
        radius: Style.space(4)
        color: "transparent"
        border.color: taskInput.activeFocus ? root.accent : Color.popups.border
        border.width: taskInput.activeFocus ? 2 : 1
      }
      topPadding: Style.space(8)
      bottomPadding: Style.space(8)
      leftPadding: Style.space(10)
      rightPadding: Style.space(10)
      selectionColor: Color.menu.selectedBackground
      selectedTextColor: root.bodyText

      Keys.onReturnPressed: {
        if (event.modifiers & Qt.ShiftModifier) {
          event.accepted = false
        } else {
          root.taskAdded(text)
          text = ""
          event.accepted = true
        }
      }
      Keys.onEscapePressed: {
        text = ""
        root.taskInputEsc()
      }
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Down) { root.taskInputTraverse(1); event.accepted = true }
        else if (event.key === Qt.Key_Up) { root.taskInputTraverse(-1); event.accepted = true }
        else if (event.key === Qt.Key_Tab) { root.taskInputTab(1); event.accepted = true }
        else if (event.key === Qt.Key_Backtab) { root.taskInputTab(-1); event.accepted = true }
      }
    }
  }
}
