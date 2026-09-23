import QtQuick
import qs.Ui
import qs.Commons

PopupCard {
    id: root
    property QtObject bar
    property Item anchorItem
    property bool open: false
    property int contentWidth: Style.space(380)
    property int contentHeight: Style.space(520)
    property string triggerMode: "click"
    property bool centerOnBar: true
    onOpenChanged: { if (!open && anchorItem) anchorItem.forceActiveFocus() }

    property var globalKeys: [
        { key: "Ctrl+K", desc: "Toggle Quick Keys panel" },
        { key: "Ctrl+N", desc: "New note" },
        { key: "Ctrl+X", desc: "Delete note (read mode)" },
        { key: "Ctrl+D", desc: "Delete task (on completed)" },
        { key: "Ctrl+Enter", desc: "Toggle edit / read-only" },
        { key: "Ctrl+S", desc: "Search notes" },
        { key: "Ctrl+M", desc: "Move note" }
    ]

    property var navigationKeys: [
        { key: "↑ / ↓  |  J / K", desc: "Navigate rows / task cursor" },
        { key: "PgUp / PgDn", desc: "Scroll note" },
        { key: "Tab / Shift+Tab", desc: "Cycle focus between sections" },
        { key: "← / →  |  H / L", desc: "Horizontal navigation" }
    ]

    property var readModeKeys: [
        { key: "Enter / Space / L", desc: "Toggle task" },
        { key: "→", desc: "Focus delete button (on completed task)" },
        { key: "←", desc: "Return from delete button" }
    ]

    property var createMoveKeys: [
        { key: "Tab", desc: "Cycle: Title → Folder grid → Buttons" },
        { key: "→", desc: "Submit (Create / Move)" },
        { key: "←", desc: "Cancel" }
    ]

    property var searchKeys: [
        { key: "↑ / ↓", desc: "Select result" },
        { key: "→ / Enter", desc: "Open selected note" },
        { key: "←", desc: "Return to search input" }
    ]

    property var settingsKeys: [
        { key: "↑ / ↓ / ← / →", desc: "Navigate buttons" },
        { key: "Enter / Space", desc: "Activate button" }
    ]

    property var deleteConfirmKeys: [
        { key: "← / →", desc: "Select No / Yes" },
        { key: "Enter", desc: "Confirm selection" }
    ]

    Column {
        id: content
        anchors.fill: contentHolder
        spacing: Style.space(10)

        Text {
            width: parent.width
            text: "KEYBOARD SHORTCUTS"
            color: Color.accent
            font.family: bar.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1
            padding: Style.space(4)
        }

        HotKeysSection { title: "GLOBAL (Ctrl+)"; keys: globalKeys }
        HotKeysSection { title: "NAVIGATION"; keys: navigationKeys }
        HotKeysSection { title: "READ MODE"; keys: readModeKeys }
        HotKeysSection { title: "CREATE / MOVE"; keys: createMoveKeys }
        HotKeysSection { title: "SEARCH"; keys: searchKeys }
        HotKeysSection { title: "SETTINGS"; keys: settingsKeys }
        HotKeysSection { title: "DELETE CONFIRM"; keys: deleteConfirmKeys }

        Rectangle {
            width: parent.width
            height: 1
            color: Color.popups.border
            opacity: 0.3
        }

        Text {
            width: parent.width
            text: "Press ESC or click outside to close"
            color: bar.dimText
            font.family: bar.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            padding: Style.space(6)
        }
    }

    Component {
        id: hotKeysSection
        Item {
            required property string title
            required property var keys
            width: parent.width
            implicitHeight: sectionContent.implicitHeight + Style.space(8)

            Column {
                id: sectionContent
                spacing: Style.space(4)

                Text {
                    width: parent.width
                    text: title
                    color: root.bar.dimText
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    font.letterSpacing: 1
                    padding: Style.space(2)
                }

                Column {
                    spacing: Style.space(2)
                    Repeater {
                        model: keys
                        delegate: Row {
                            width: parent.width
                            spacing: Style.space(12)
                            Text {
                                width: Style.space(140)
                                text: modelData.key
                                color: Color.accent
                                font.family: "Monospace"
                                font.pixelSize: Style.font.body
                                elide: Text.ElideRight
                            }
                            Text {
                                anchors.right: parent.right
                                text: modelData.desc
                                color: root.bar.bodyText
                                font.family: root.bar.fontFamily
                                font.pixelSize: Style.font.body
                                wrapMode: Text.WordWrap
                                elide: Text.ElideRight
                            }
                        }
                    }
                }
            }
        }
    }
}