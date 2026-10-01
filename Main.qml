import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import QtQuick.Effects
import qs.Commons
import qs.Ui
import "PathGuard.js" as PathGuard

Panel {
  id: root

  moduleName: "veilios.nether"
  ipcTarget: "veilios.nether"
  manageIpc: false
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property string home: Quickshell.env("HOME")
  // All filesystem mutation goes through this helper rather than through shell
  // commands. Path-based tools cannot defend against symlinks inside the vault
  // — and a vault can be a clone, a synced folder, or something shared with
  // you — while the helper resolves every component from a descriptor with
  // O_NOFOLLOW, so the open that writes is also the check that confines it.
  readonly property string vaultHelper: Qt.resolvedUrl("nether_vault.py").toLocalFile()
  property bool overrideActive: false
  property string overrideValue: ""
  readonly property string vaultPathRaw: overrideActive ? overrideValue : setting("vaultPath", "~/Documents/Obsidian Vault")
  property bool settingsOpen: false
  property bool quickKeysOpen: false
  property bool hotKeysOpen: false
  property bool createOpen: false
  property bool moveOpen: false
  property bool deleteConfirmOpen: false
  property string draftVaultPath: ""
  property string noteSearch: ""
  property string createTitle: ""
  property string folderDraft: ""
  property string renameDraft: ""
  property string actionError: ""
  property var filteredNotes: []
  property var folders: [""]
  property var folderModel: []
  property bool creatingNewFolder: false
  property string newFolderDraft: ""
  property bool contentSearchRunning: false
  property int searchDebounceMs: 150

  function rebuildFolderModel() {
    var model = []
    for (var i = 0; i < folders.length; i++) {
      model.push({ path: folders[i], isPlus: false })
    }
    model.push({ path: "__PLUS__", isPlus: true })
    folderModel = model
  }

  // A vault of "/" or the home directory is almost certainly a mis-pick, and
  // it would put every note operation outside any real vault. Refuse it here
  // so the mistake is caught at the point it is made. An empty value is the
  // deliberate "disconnect" action and stays allowed.
  function plausibleVault(v) {
    var val = String(v || "").trim()
    if (val === "") return true
    if (val.indexOf("~/") === 0) val = home + val.slice(1)
    if (val === "/" || val === home) return false
    return true
  }

  function applyVaultPath(v) {
    flushSave()
    var val = v.trim()
    if (!plausibleVault(val)) {
      actionError = "Pick a folder for your notes, not / or your home directory."
      settingsOpen = true
      return
    }
    overrideActive = true
    overrideValue = val
    settingsOpen = false
    quickKeysOpen = false
    hotKeysOpen = false
    createOpen = false
    moveOpen = false
    deleteConfirmOpen = false
    resetFocus("header")
    currentNote = ""
    pendingAbsPath = ""
    loadingNote = false
    dirty = false
    applyingText = true
    noteView.setSource("")
    editor.text = ""
    applyingText = false
    persistVaultPath(val)
    rescanNotes()
  }

  // Persist the vault through the shell's own settings API rather than
  // rewriting shell.json ourselves. The previous python3 json.dump() opened
  // the shell's primary config for writing and truncated it before dumping, so
  // an interrupted write left the desktop's bar config corrupt. updateEntryInline
  // does the read-modify-write inside the shell, keeps the rest of the file
  // intact, and keeps ownership of shell.json with the shell.
  function persistVaultPath(val) {
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry.vaultPath = val

    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function") {
      root.bar.shell.updateEntryInline(root.moduleName, entry)
      return
    }
    // No writable bar entry (widget not in the layout): keep the session-only
    // override we already applied rather than writing the file behind the shell.
    actionError = "Vault path applies to this session only."
  }

  readonly property string vaultPath: vaultPathRaw.indexOf("~/") === 0 ? home + vaultPathRaw.slice(1) : vaultPathRaw

  property string currentNote: ""
  property bool editMode: false
  property bool dirty: false
  property bool loadingNote: false
  property string pendingAbsPath: ""
  property string lastKnownFileText: ""
  property string rawText: ""
  property bool applyingText: false
  property bool dropdownOpen: false
  property var notes: []
  property bool vaultMissing: false
  property string restoredLastNote: ""
  property bool stateResolved: false
  property bool pendingEditOnLoad: false
  property int dropdownIndex: 0
  property int folderIndex: 0
  property string keyboardSection: "header"
  property int headerIndex: 0
  property int settingsIndex: 0
  property string actionMessage: ""
  Timer {
    id: actionMessageTimer
    interval: 1500
    repeat: false
    onTriggered: actionMessage = ""
  }
  property int footerIndex: 0
  property bool keyDebugEnabled: false

  // Content search runs inside the long-lived shell process, so every stage of
  // it is bounded. rg's own limits cut the work it does, the byte cap caps what
  // can reach us at all, and the file/snippet caps cap what we then retain.
  // A vault large enough to hit these is a signal to narrow the query, not a
  // reason to spend the shell's memory on it.
  readonly property int contentSearchMaxFiles: 200
  readonly property int contentSearchMaxSnippetsPerFile: 3
  readonly property int contentSearchMaxBytes: 4000000
  readonly property int contentSearchMaxFileSize: 2 * 1024 * 1024
  readonly property int contentSearchMaxDepth: 24
  property bool contentSearchTruncated: false
  // The note scan is bounded too, for the same reason: a vault with a very
  // large number of notes would otherwise grow an unbounded list in the
  // shell. head -n is used rather than head -c so the list is never cut
  // mid-path, which would invent a note that does not exist.
  readonly property int scanMaxNotes: 20000
  property bool notesTruncated: false
  // Set when the note on disk changed while we had unsaved edits, so the
  // conflict is visible and recoverable rather than a silent overwrite.
  property bool externalConflict: false
  property string conflictingText: ""
  // Set while an autosave we issued is in flight, so the change watcher does
  // not report our own write as somebody else editing the note.
  property bool selfWriteSeen: false

  function noteTruncationMessage() {
    if (root.notesTruncated) return "This vault has more notes than Nether lists; showing the first " + root.scanMaxNotes + "."
    if (root.contentSearchTruncated) return "Too many matches to show — narrow the search."
    return ""
  }

  function keyLog(msg) {
    if (!keyDebugEnabled) return
    console.log("[nether] " + msg)
  }

  function resetFocus(section) {
    keyboardSection = section
    keyLog("resetFocus -> " + section)
    if (opened) Qt.callLater(function() { if (opened) keyCatcher.forceActiveFocus() })
  }

  readonly property color iconTint: barForeground
  readonly property color bodyText: Color.popups.text
  readonly property color dimText: Qt.rgba(bodyText.r, bodyText.g, bodyText.b, 0.55)
  readonly property string fontFamily: Style.font.menuFamily

  function closeCards() {
    dropdownOpen = false
    settingsOpen = false
    quickKeysOpen = false
    hotKeysOpen = false
    createOpen = false
    moveOpen = false
    creatingNewFolder = false
    newFolderDraft = ""
    resetFocus("header")
  }

  function recomputeNotes() {
    var q = noteSearch.trim().toLowerCase()
    if (q === "") {
      filteredNotes = notes
      if (dropdownIndex >= filteredNotes.length) dropdownIndex = Math.max(0, filteredNotes.length - 1)
      return
    }
    var result = []
    for (var i = 0; i < notes.length; i++) {
      var item = notes[i]
      if (item.name.toLowerCase().indexOf(q) >= 0 || item.rel.toLowerCase().indexOf(q) >= 0) {
        result.push({ rel: item.rel, folder: item.folder, name: item.name, matchType: "name", snippets: [] })
      }
    }
    filteredNotes = result
    if (dropdownIndex >= filteredNotes.length) dropdownIndex = Math.max(0, filteredNotes.length - 1)
    searchDebounceTimer.restart()
  }

  function performContentSearch() {
    var q = noteSearch.trim()
    contentSearchTruncated = false
    if (q.length < 2) return
    // A search already in flight is for a query the user has since typed past.
    // Killing it stops its results arriving late and overwriting fresher ones.
    if (contentSearchProc.running) contentSearchProc.kill()
    contentSearchRunning = true
    contentSearchProc.query = q
    contentSearchProc.vault = vaultPath
    contentSearchProc.running = true
  }

  function onContentSearchResults(output) {
    contentSearchRunning = false
    // head -c has already bounded this, but a truncated stream can end
    // mid-record; treat reaching the cap as a clipped result set.
    if (String(output).length >= root.contentSearchMaxBytes) contentSearchTruncated = true
    var lines = String(output).split("\n")
    var contentMatches = {}
    var files = 0
    var dropped = 0
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (!line) continue
      try {
        var parsed = JSON.parse(line)
        if (parsed.type === "match") {
          var absPath = parsed.data.path
          // A plain indexOf(0) prefix test would also accept a sibling like
          // ~/Vault-old, so re-derive the relative path and let PathGuard
          // decide whether it is a real in-vault path.
          var rel = absPath.indexOf(vaultPath + "/") === 0 ? absPath.slice(vaultPath.length + 1) : ""
          if (rel !== "" && PathGuard.safeRel(rel) !== "") {
            if (!contentMatches[rel]) {
              files++
              // Stop accumulating once we have enough files, and drop the
              // remainder rather than growing an object no dropdown will show.
              if (files > root.contentSearchMaxFiles) { dropped++; continue }
            }
            var snippet = parsed.data.lines.text.trim()
            if (contentMatches[rel].length < root.contentSearchMaxSnippetsPerFile) {
              contentMatches[rel].push({ line: parsed.data.line_number, text: snippet })
            }
          }
        }
      } catch (e) {}
    }
    if (dropped > 0) contentSearchTruncated = true
    mergeSearchResults(contentMatches)
    if (contentSearchTruncated) { actionMessage = noteTruncationMessage(); actionMessageTimer.restart() }
  }

  function mergeSearchResults(contentMatches) {
    var q = noteSearch.trim().toLowerCase()
    if (q === "") {
      filteredNotes = notes
      if (dropdownIndex >= filteredNotes.length) dropdownIndex = Math.max(0, filteredNotes.length - 1)
      return
    }
    var nameMatches = []
    for (var i = 0; i < notes.length; i++) {
      var item = notes[i]
      var nameMatch = item.name.toLowerCase().indexOf(q) >= 0
      var pathMatch = item.rel.toLowerCase().indexOf(q) >= 0
      if (nameMatch || pathMatch) {
        nameMatches.push(item.rel)
        var existingIdx = filteredNotes.findIndex(function(x) { return x.rel === item.rel })
        if (existingIdx >= 0) {
          filteredNotes[existingIdx].matchType = "name"
        } else {
          filteredNotes.push({ rel: item.rel, folder: item.folder, name: item.name, matchType: "name", snippets: [] })
        }
      }
    }
    for (var rel in contentMatches) {
      if (nameMatches.indexOf(rel) === -1) {
        var note = null
        for (var j = 0; j < notes.length; j++) {
          if (notes[j].rel === rel) { note = notes[j]; break }
        }
        if (note) {
          filteredNotes.push({ rel: note.rel, folder: note.folder, name: note.name, matchType: "content", snippets: contentMatches[rel] })
        }
      } else {
        var idx = filteredNotes.findIndex(function(x) { return x.rel === rel })
        if (idx >= 0) {
          filteredNotes[idx].matchType = "both"
          filteredNotes[idx].snippets = contentMatches[rel]
        }
      }
    }
    if (dropdownIndex >= filteredNotes.length) dropdownIndex = Math.max(0, filteredNotes.length - 1)
  }

  // Returns "" for the vault root, null for anything PathGuard rejects, else
  // the folder's relative path. PathGuard is the authority on what may sit
  // inside the vault; the old substring test for ".." also refused the
  // perfectly legitimate folder "notes..archive".
  function folderValue(value) {
    var folder = String(value || "").trim().replace(/^\/+|\/+$/g, "")
    if (folder === "" || folder === ".") return ""
    if (folder.indexOf("\\") >= 0) return null
    var safe = PathGuard.safeRel(folder)
    return safe === "" ? null : safe
  }

  function noteFileName(value) {
    var name = String(value || "").trim().replace(/[\\/]/g, "")
    if (name.toLowerCase().slice(-3) !== ".md") name += ".md"
    return name
  }

  function handleShortcut(event) {
    if (!(event.modifiers & Qt.ControlModifier)) return false
    if (event.key === Qt.Key_K) { var opening = !quickKeysOpen; closeCards(); quickKeysOpen = opening; keyboardSection = opening ? "quickKeys" : "header"; keyCatcher.forceActiveFocus(); event.accepted = true; return true }
    if (event.key === Qt.Key_N) { beginCreate(); event.accepted = true; return true }
    if (event.key === Qt.Key_X && !editMode) { if (currentNote !== "") beginDelete(); event.accepted = true; return true }
    if (event.key === Qt.Key_D) {
      if (keyboardSection === "read" && noteView.hasTaskBlocks && noteView.taskCursorActive) {
        var cursorIdx = noteView.taskCursorIndex
        if (cursorIdx >= 0 && cursorIdx < noteView.taskCount) {
          var taskBlockIdx = noteView.taskBlockIndexes[cursorIdx]
          var block = noteView.blocks.get(taskBlockIdx)
          if (block && block.checked) {
            deleteTask(block.lineNo)
            actionMessage = "Task deleted"
            actionMessageTimer.restart()
            event.accepted = true
            return true
          }
        }
      }
      return false
    }
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { setEditMode(!editMode); event.accepted = true; return true }
    if (event.key === Qt.Key_S) { closeCards(); dropdownOpen = true; keyboardSection = "search"; noteSearch = ""; dropdownIndex = 0; recomputeNotes(); Qt.callLater(function() { noteSearchInput.forceActiveFocus() }); event.accepted = true; return true }
    if (event.key === Qt.Key_M && !editMode && currentNote !== "") { beginMove(); event.accepted = true; return true }
    return false
  }

  readonly property string noteName: currentNote === ""
    ? "No note selected"
    : currentNote.split("/").pop().replace(/\.md$/, "")

  readonly property string noteDirectory: {
    if (currentNote === "") return vaultPath
    var i = currentNote.lastIndexOf("/")
    if (i < 0) return vaultPath
    return PathGuard.inVault(vaultPath, currentNote.slice(0, i)) || vaultPath
  }

  function dirUrl(p) {
    var segs = String(p).split("/")
    for (var i = 0; i < segs.length; i++) segs[i] = encodeURIComponent(segs[i])
    return "file://" + segs.join("/")
  }

  readonly property url noteBaseUrl: dirUrl(noteDirectory)

  function persistState() {
    stateFile.setText(JSON.stringify({ lastNote: currentNote }) + "\n")
  }

  // Exit 3 from the helper means "refused for safety", and it explains why on
  // stderr. Anything else is a plain failure. Either way the panel says what
  // happened rather than a generic failure.
  function vaultOpError(stderrText, fallback) {
    var msg = String(stderrText || "").trim()
    if (msg === "") return fallback
    // The helper reports raw errno text for genuine I/O errors; keep the
    // refusal messages, which are written for a person, and drop the rest.
    if (msg.indexOf("os error:") === 0) return fallback
    return msg.charAt(0).toUpperCase() + msg.slice(1) + "."
  }

  function flushSave() {
    saveTimer.stop()
    if (!dirty || currentNote === "" || pendingAbsPath === "") {
      dirty = false
      return
    }
    if (saveProc.running) return // a save is already carrying this note's text
    lastKnownFileText = rawText
    // Our own write will show up on the watcher; flag it so handleExternalChange
    // does not mistake it for somebody else editing the note.
    selfWriteSeen = true
    saveProc.rel = currentNote
    saveProc.body = rawText
    saveProc.running = true
    dirty = false
  }

  function setEditMode(on) {
    if (on === editMode) return
    if (!on) flushSave()
    editMode = on
    if (on) renameDraft = noteName
    applyingText = true
    editor.text = rawText
    applyingText = false
    if (!on) renderView()
    keyboardSection = on ? "editor" : "read"
    if (on && opened) Qt.callLater(function() { editor.forceActiveFocus(); editor.cursorPosition = editor.length })
    if (!on && opened) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function commitRenameAndExit() {
    if (!editMode || currentNote === "") return
    var nextName = noteFileName(renameDraft)
    if (nextName === ".md") { actionError = "Enter a note name."; return }
    var folder = currentNote.lastIndexOf("/") >= 0 ? currentNote.slice(0, currentNote.lastIndexOf("/")) : ""
    var nextRel = folder === "" ? nextName : folder + "/" + nextName
    var nextAbs = PathGuard.inVault(vaultPath, nextRel)
    if (nextAbs === "") { actionError = "Use a name inside the vault."; return }
    for (var i = 0; i < notes.length; i++) if (notes[i].rel === nextRel) { actionError = "A note with that name already exists."; return }
    if (nextRel !== currentNote) {
      flushSave()
      actionError = ""
      renameProc.oldRel = currentNote
      renameProc.newRel = nextRel
      renameProc.running = true
    }
    setEditMode(false)
  }

  function beginCreate() {
    closeCards(); createOpen = true; createTitle = ""; folderDraft = ""; folderIndex = 0; actionError = ""
    rebuildFolderModel()
    folderDraft = folderModel.length > 0 ? folderModel[0].path : ""
    keyboardSection = "create"
    Qt.callLater(function() { createTitleInput.forceActiveFocus() })
  }

  function beginMove() {
    if (currentNote === "" || editMode) return
    closeCards(); moveOpen = true; folderDraft = ""; folderIndex = 0; actionError = ""
    rebuildFolderModel()
    folderDraft = folderModel.length > 0 ? folderModel[0].path : ""
    keyboardSection = "move"
    Qt.callLater(function() { moveFolderGrid.forceActiveFocus() })
  }

  function beginDelete() {
    if (currentNote !== "" && !editMode) {
      deleteConfirmOpen = true
      deleteDialog.selectedIndex = 0
      resetFocus("deleteConfirm")
    }
  }

  function submitCreate() {
    var file = noteFileName(createTitle)
    var folder = folderValue(folderDraft)
    if (file === ".md") { actionError = "Enter a note title."; return }
    if (folder === null) { actionError = "Use a folder inside the vault."; return }
    var rel = folder === "" ? file : folder + "/" + file
    var absPath = PathGuard.inVault(vaultPath, rel)
    if (absPath === "") { actionError = "Use a folder inside the vault."; return }
    for (var i = 0; i < notes.length; i++) if (notes[i].rel === rel) { actionError = "A note with that name already exists."; return }
    // inVault is only the fast local check, so a bad path is reported without
    // spawning a process. It is deliberately not the last word: the helper
    // re-validates this same relative path against the filesystem before it
    // writes anything.
    createProc.rel = rel
    createProc.body = ""
    resetFocus("header")
    createProc.running = true
  }

  function submitMove() {
    if (currentNote === "") return
    var folder = folderValue(folderDraft)
    if (folder === null) { actionError = "Use a folder inside the vault."; return }
    var file = currentNote.slice(currentNote.lastIndexOf("/") + 1)
    var nextRel = folder === "" ? file : folder + "/" + file
    if (nextRel === currentNote) { actionError = "Choose a different folder."; return }
    var nextAbs = PathGuard.inVault(vaultPath, nextRel)
    if (nextAbs === "") { actionError = "Use a folder inside the vault."; return }
    for (var i = 0; i < notes.length; i++) if (notes[i].rel === nextRel) { actionError = "A note already exists there."; return }
    flushSave()
    moveProc.oldRel = currentNote
    moveProc.newRel = nextRel
    resetFocus("header")
    moveProc.running = true
  }

  function completeDelete() {
    deleteConfirmOpen = false
    rmProc.rel = currentNote
    rmProc.running = true
  }

  property bool pendingDropdown: false

  function switchTo(rel, keepOpen) {
    // Defence in depth: callers are expected to have vetted rel already, but
    // every path that reaches FileView goes through PathGuard so no future
    // caller can reintroduce a traversal by forgetting to check.
    var absPath = PathGuard.inVault(vaultPath, rel)
    if (rel !== "" && absPath === "") {
      actionError = "That note path is outside the vault."
      return
    }
    if (rel === currentNote) {
      dropdownOpen = false
      resetFocus("header")
      return
    }
    flushSave()
    editMode = false
    resetFocus("header")
    dirty = false
    if (!keepOpen) dropdownOpen = false
    loadingNote = true
    currentNote = rel
    pendingAbsPath = absPath
    if (pendingAbsPath !== "") {
      noteFile.path = pendingAbsPath
    } else {
      applyingText = true
      noteView.setSource("")
      editor.text = ""
      applyingText = false
      rawText = ""
      loadingNote = false
    }
    persistState()
  }

  function applyLoadedNote() {
    if (pendingAbsPath === "" || noteFile.path !== pendingAbsPath) return
    var t = noteFile.text()
    lastKnownFileText = t
    loadingNote = false
    rawText = t
    dirty = false
    applyingText = true
    editor.text = t
    applyingText = false
    Qt.callLater(function() { root.renderView() })
    if (root.pendingEditOnLoad) {
      root.pendingEditOnLoad = false
      root.setEditMode(true)
    }
  }

  function noteLoadFailed() {
    if (noteFile.path !== pendingAbsPath || pendingAbsPath === "") return
    loadingNote = false
    pendingEditOnLoad = false
    lastKnownFileText = ""
    rawText = ""
    dirty = false
    applyingText = true
    noteView.setSource("# Note not found\n\nCould not read `" + currentNote + "`.")
    editor.text = "# Note not found\n\nCould not read `" + currentNote + "`."
    applyingText = false
  }

  function handleExternalChange() {
    if (loadingNote || pendingAbsPath === "") return
    if (noteFile.path !== pendingAbsPath) return
    if (selfWriteSeen) {
      // Our own autosave landing. Nothing to reconcile.
      selfWriteSeen = false
      noteFile.reload()
      return
    }
    if (dirty) {
      // Somebody else wrote the note while we held unsaved edits. Reloading now
      // would throw ours away, and staying silent meant the next autosave
      // silently overwrote theirs. Say so instead, and keep their version
      // around so the note can be recovered.
      if (root.externalConflict) return
      root.externalConflict = true
      root.conflictingText = noteFile.text()
      root.actionMessage = "This note changed elsewhere. Reload to take theirs, or keep editing to overwrite."
      root.actionMessageTimer.restart()
      return
    }
    noteFile.reload()
  }

  function renderView() {
    // Preserve scroll across external reloads while rebuilding the blocks.
    var fy = 0
    try { if (scrollArea.contentItem) fy = scrollArea.contentItem.contentY } catch (e) {}
    applyingText = true
    noteView.setSource(rawText)
    applyingText = false
    Qt.callLater(function() {
      try {
        if (scrollArea.contentItem) {
          var maxY = Math.max(0, noteView.implicitHeight - scrollArea.height)
          scrollArea.contentItem.contentY = Math.min(Math.max(fy, 0), maxY)
        }
      } catch (e) {}
    })
  }

  function pageScroll(delta) {
    if (!scrollArea.contentItem) return
    var flick = scrollArea.contentItem
    var contentHeight = root.editMode ? editor.implicitHeight : noteView.implicitHeight
    var maxY = Math.max(0, contentHeight - scrollArea.height)
    flick.contentY = Math.min(Math.max(flick.contentY + delta, 0), maxY)
  }

  function moveFolderSelection(delta) {
    if (folders.length === 0) return
    folderIndex = Math.min(Math.max(folderIndex + delta, 0), folders.length - 1)
    folderDraft = folders[folderIndex]
  }

  function addTask(value) {
    var taskText = String(value || "").trim()
    if (taskText === "") return
    var lines = rawText.split("\n")
    var insertAt = lines.length
    var indent = ""
    for (var i = lines.length - 1; i >= 0; i--) {
      var match = /^(\s*)[-*+]\s+\[[ xX]\]/.exec(lines[i])
      if (match) {
        insertAt = i + 1
        indent = match[1]
        break
      }
    }
    lines.splice(insertAt, 0, indent + "- [ ] " + taskText)
    rawText = lines.join("\n")
    dirty = true
    flushSave()
    renderView()
    Qt.callLater(function() {
      if (scrollArea.contentItem) scrollArea.contentItem.contentY = Math.max(0, noteView.implicitHeight - scrollArea.height)
    })
  }

function toggleTask(lineNo, wasChecked) {
    var lines = rawText.split("\n")
    if (lineNo < 0 || lineNo >= lines.length) return
    var timestamp = !wasChecked ? " <!-- completed: " + new Date().toISOString() + " -->" : ""
    lines[lineNo] = lines[lineNo].replace(/^(\s*[-*+]\s+\[)([ xX])(\].*?)(?:\s*<!--\s*completed:\s*[^>]+\s*-->)?$/,
                                        function(all, a, mark, b) {
                                          return a + (wasChecked ? " " : "x") + b + timestamp
                                        })
    rawText = lines.join("\n")
    dirty = true
    saveTimer.restart()
    noteView.updateTask(lineNo, !wasChecked)
  }

  function deleteTask(lineNo) {
    var lines = rawText.split("\n")
    if (lineNo < 0 || lineNo >= lines.length) return
    lines.splice(lineNo, 1)
    rawText = lines.join("\n")
    dirty = true
    saveTimer.restart()
    renderView()
  }

  function rescanNotes() {
    if (!scanProc.running) scanProc.running = true
  }

  function toggleDropdown() {
    var opening = !dropdownOpen
    closeCards()
    dropdownOpen = opening
    if (dropdownOpen) {
      keyboardSection = "search"
      noteSearch = ""
      dropdownIndex = 0
      recomputeNotes()
      rescanNotes()
      Qt.callLater(function() { noteSearchInput.forceActiveFocus() })
    } else {
      keyboardSection = "header"
      keyCatcher.forceActiveFocus()
    }
  }

  function moveDropdownSelection(delta) {
    if (filteredNotes.length === 0) return
    dropdownIndex = Math.min(Math.max(dropdownIndex + delta, 0), filteredNotes.length - 1)
    notesList.positionViewAtIndex(dropdownIndex, ListView.Contain)
  }

  function activateHeaderItem() {
    if (headerIndex === 0) toggleDropdown()
    else if (headerIndex === 1 && !vaultMissing) beginCreate()
    else if (headerIndex === 2 && !editMode && currentNote !== "") beginDelete()
    else if (headerIndex === 3) {
      var opening = !settingsOpen
      closeCards()
      settingsOpen = opening
      keyboardSection = opening ? "settings" : "header"
      if (opening) {
        settingsIndex = 0
        draftVaultPath = vaultPathRaw
        Qt.callLater(function() { pathInput.forceActiveFocus() })
      } else keyCatcher.forceActiveFocus()
    } else if (headerIndex === 4) {
      var quickOpening = !quickKeysOpen
      closeCards()
      quickKeysOpen = quickOpening
      keyboardSection = quickOpening ? "quickKeys" : "header"
      keyCatcher.forceActiveFocus()
    } else if (headerIndex === 5) {
      setEditMode(!editMode)
      keyboardSection = editMode ? "editor" : "header"
    }
  }

  function moveHeader(delta) {
    var next = headerIndex
    for (var i = 0; i < 6; i++) {
      next = Math.min(Math.max(next + delta, 0), 5)
      if (next === headerIndex || next === 0 || next === 3 || next === 4 || next === 5
          || (next === 1 && !vaultMissing)
          || (next === 2 && !editMode && currentNote !== "")) {
        headerIndex = next
        return
      }
    }
  }

  function enterContent() {
    if (editMode) {
      keyboardSection = "editor"
      Qt.callLater(function() { editor.forceActiveFocus() })
    } else {
      resetFocus("read")
    }
  }

  function enterFooter() {
    footerIndex = (!editMode && currentNote !== "") ? 0 : 1
    resetFocus("footer")
  }

  function enterTaskInput() {
    noteView.focusTaskInput()
    keyboardSection = "taskInput"
    Qt.callLater(function() {
      if (scrollArea.contentItem)
        scrollArea.contentItem.contentY = Math.max(0, scrollArea.contentItem.contentHeight - scrollArea.height)
    })
  }

  function enterReadAtLastTask() {
    resetFocus("read")
    noteView.placeTaskCursorAtLast()
    Qt.callLater(function() { revealTaskCursor() })
  }

  function revealTaskCursor() {
    var flick = scrollArea.contentItem
    if (!flick) return
    var y = noteView.taskCursorViewportY()
    if (y < 0) return
    var margin = Style.space(40)
    var top = flick.contentY + margin
    var bottom = flick.contentY + scrollArea.height - margin
    if (y < top) flick.contentY = Math.max(0, y - margin)
    else if (y > bottom) flick.contentY = Math.min(Math.max(0, flick.contentHeight - scrollArea.height), y - scrollArea.height + margin)
  }

  function moveFooterIndex(delta) {
    if (!editMode && currentNote !== "") footerIndex = Math.min(Math.max(footerIndex + delta, 0), 1)
    else footerIndex = 1
  }

  // Vertical row traversal driven by Up/Down arrows. Menu sections keep their
  // own vertical list semantics so arrows still navigate notes and folders.
  function moveBetweenRows(delta) {
    if (keyboardSection === "header") {
      if (delta > 0) enterContent()
      return
    }
    if (keyboardSection === "read") {
      if (delta > 0) {
        if (noteView.hasTaskBlocks && noteView.taskCursorIndex < noteView.taskCount - 1) {
          noteView.moveTaskCursor(1); revealTaskCursor()
        } else if (noteView.noteOpen) enterTaskInput()
        else enterFooter()
      } else {
        if (noteView.hasTaskBlocks && noteView.taskCursorIndex > 0) {
          noteView.moveTaskCursor(-1); revealTaskCursor()
        } else resetFocus("header")
      }
      return
    }
    if (keyboardSection === "footer") {
      if (delta < 0) {
        if (noteView.noteOpen) enterTaskInput()
        else resetFocus("read")
      }
      return
    }
    if (keyboardSection === "taskInput") {
      if (delta > 0) enterFooter()
      else enterReadAtLastTask()
      return
    }
    if (keyboardSection === "editor") {
      Qt.callLater(function() { editor.forceActiveFocus() })
      return
    }
    if (keyboardSection === "search") { moveDropdownSelection(delta); return }
    if (keyboardSection === "settings") { settingsIndex = Math.min(Math.max(settingsIndex + delta, 0), 4); return }
  }

  function handlePanelMove(dx, dy) {
    if (keyboardSection === "header") {
      if (dx !== 0) moveHeader(dx)
      else if (dy > 0) enterContent()
      return
    }
    if (keyboardSection === "footer") {
      if (dx !== 0) moveFooterIndex(dx)
      else if (dy < 0) resetFocus("read")
      return
    }
    if (keyboardSection === "search") {
      if (dx > 0) { handlePanelActivate(); return }
      if (dx < 0) { noteSearchInput.forceActiveFocus(); return }
      moveDropdownSelection(dy)
      return
    }
    if (keyboardSection === "create" || keyboardSection === "move") {
      if (dx > 0) { if (moveOpen) submitMove(); else submitCreate(); return }
      if (dx < 0) { closeCards(); keyboardSection = "header"; keyCatcher.forceActiveFocus(); return }
      return
    }
    if (keyboardSection === "settings") {
      settingsIndex = Math.min(Math.max(settingsIndex + (dy !== 0 ? dy : dx), 0), 4)
      return
    }
    if (keyboardSection === "deleteConfirm") {
      if (dx !== 0) deleteDialog.selectedIndex = deleteDialog.selectedIndex === 0 ? 1 : 0
      return
    }
    if (keyboardSection === "read") {
      if (dy !== 0) {
        if (noteView.hasTaskBlocks) { noteView.moveTaskCursor(dy); revealTaskCursor() }
        else pageScroll(dy * Style.space(48))
      }
    }
  }

  function handlePanelActivate() {
    if (keyboardSection === "header") { activateHeaderItem(); return }
    if (keyboardSection === "create") { submitCreate(); return }
    if (keyboardSection === "move") { submitMove(); return }
    if (keyboardSection === "search") {
      if (filteredNotes.length > 0 && dropdownIndex < filteredNotes.length) switchTo(filteredNotes[dropdownIndex].rel)
      return
    }
    if (keyboardSection === "settings") {
      if (settingsIndex === 0) {
        if (draftVaultPath !== vaultPathRaw) applyVaultPath(draftVaultPath)
        else settingsOpen = false
      } else if (settingsIndex === 1) vaultPickerProc.running = true
      else if (settingsIndex === 2) rescanNotes()
      else if (settingsIndex === 3) applyVaultPath("")
      else if (settingsIndex === 4) hotKeysOpen = true
      if (!settingsOpen) { keyboardSection = "header"; keyCatcher.forceActiveFocus() }
      return
    }
    if (keyboardSection === "deleteConfirm") {
      if (deleteDialog.selectedIndex === 0) deleteConfirmOpen = false
      else completeDelete()
      keyboardSection = "header"
      keyCatcher.forceActiveFocus()
      return
    }
    if (keyboardSection === "footer") {
      if (footerIndex === 0) beginMove()
      else setEditMode(!editMode)
      return
    }
    if (keyboardSection === "read") {
      if (noteView.hasTaskBlocks) noteView.toggleTaskAtCursor()
    }
  }

  function handlePanelCloseRequest() {
    if (deleteConfirmOpen) deleteConfirmOpen = false
    else if (hotKeysOpen) hotKeysOpen = false
    else if (dropdownOpen || settingsOpen || quickKeysOpen || createOpen || moveOpen) closeCards()
    else close()
    if (opened) resetFocus("header")
  }

  function cycleKeyboardFocus(direction) {
    if (keyboardSection === "search") {
      if (direction > 0) { keyboardSection = "search"; keyCatcher.forceActiveFocus() }
      else noteSearchInput.forceActiveFocus()
      return
    }
    if (keyboardSection === "create") {
      if (direction > 0) {
        // Tab forward: title input -> GridView -> CREATE/CANCEL buttons
        if (createTitleInput.activeFocus) {
          createFolderGrid.forceActiveFocus()
        } else {
          keyCatcher.forceActiveFocus()
        }
      } else {
        // Shift+Tab backward: buttons -> GridView -> title input
        if (createTitleInput.activeFocus) {
          resetFocus("header")
        } else {
          createTitleInput.forceActiveFocus()
        }
      }
      return
    }
    if (keyboardSection === "move") {
      if (direction > 0) {
        // Tab forward: GridView -> MOVE/CANCEL buttons
        if (moveFolderGrid.activeFocus) {
          keyCatcher.forceActiveFocus()
        } else {
          moveFolderGrid.forceActiveFocus()
        }
      } else {
        // Shift+Tab backward: buttons -> GridView -> header
        if (moveFolderGrid.activeFocus) {
          resetFocus("header")
        } else {
          moveFolderGrid.forceActiveFocus()
        }
      }
      return
    }
    if (keyboardSection === "settings") {
      if (direction > 0) { settingsIndex = Math.min(settingsIndex + 1, 4); keyCatcher.forceActiveFocus() }
      else pathInput.forceActiveFocus()
      return
    }
    if (keyboardSection === "header") {
      if (direction > 0) enterContent()
      else resetFocus("footer")
      return
    }
    if (keyboardSection === "read") {
      if (direction > 0) {
        if (noteView.noteOpen) enterTaskInput()
        else enterFooter()
      } else resetFocus("header")
      return
    }
    if (keyboardSection === "footer") {
      if (direction > 0) resetFocus("header")
      else if (noteView.noteOpen) enterTaskInput()
      else resetFocus("read")
      return
    }
    if (keyboardSection === "editor") {
      resetFocus("footer")
      return
    }
    if (keyboardSection === "taskInput") {
      if (direction > 0) enterFooter()
      else enterReadAtLastTask()
      return
    }
    if (keyboardSection === "quickKeys") {
      resetFocus("header")
      return
    }
    if (keyboardSection === "deleteConfirm") {
      deleteDialog.selectedIndex = deleteDialog.selectedIndex === 0 ? 1 : 0
    }
  }

  function onNotesScanned(output) {
    var lines = String(output).split("\n")
    vaultMissing = lines.length > 0 && lines[0] === "__MISSING__"
    var arr = []
    if (!vaultMissing) {
      for (var i = 0; i < lines.length; i++) {
        var rel = lines[i]
        if (!rel) continue
        var slash = rel.lastIndexOf("/")
        arr.push({
          rel: rel,
          folder: slash >= 0 ? rel.slice(0, slash) : "",
          name: rel.slice(slash + 1).replace(/\.md$/, "")
        })
      }
    }
    notes = arr
    notesTruncated = !vaultMissing && arr.length >= root.scanMaxNotes
    if (notesTruncated) { actionMessage = noteTruncationMessage(); actionMessageTimer.restart() }
    var folderMap = { "": true }
    for (var f = 0; f < arr.length; f++) {
      var path = arr[f].rel
      var parts = path.split("/")
      parts.pop()
      for (var p = 1; p <= parts.length; p++) folderMap[parts.slice(0, p).join("/")] = true
    }
    var folderArr = Object.keys(folderMap).sort()
    folders = folderArr
    rebuildFolderModel()
    recomputeNotes()
    if (currentNote === "" && arr.length > 0) {
      var pick = ""
      for (var j = 0; j < arr.length; j++)
        if (arr[j].rel === restoredLastNote) { pick = restoredLastNote; break }
      switchTo(pick !== "" ? pick : arr[0].rel, root.pendingDropdown)
      root.pendingDropdown = false
    }
  }

  onOpenedChanged: {
    if (opened) return
    closeCards()
    deleteConfirmOpen = false
    flushSave()
  }

  onStateResolvedChanged: {
    if (stateResolved) {
      rescanNotes()
    }
  }

  Timer {
    id: saveTimer
    interval: 500
    onTriggered: root.flushSave()
  }

  Timer {
    id: searchDebounceTimer
    interval: root.searchDebounceMs
    repeat: false
    onTriggered: root.performContentSearch()
  }

  Process {
    id: contentSearchProc
    property string query: ""
    property string vault: ""
    command: {
      // head -c is the hard producer-side bound the shell is missing: without
      // it a broad query over a large vault streams unbounded --json into a
      // long-lived process. It closes the pipe early, so rg takes SIGPIPE.
      // "$@" keeps the query out of the script text entirely; -e before --
      // makes the query a pattern even when it starts with "-", and -- stops
      // anything after it being read as an option.
      return ["bash", "-c", 'exec rg "$@" | head -c ' + root.contentSearchMaxBytes, "bash",
              "--json", "--no-heading", "--line-number", "--smart-case",
              "--max-count", String(root.contentSearchMaxSnippetsPerFile),
              "--max-filesize", String(root.contentSearchMaxFileSize),
              "--max-depth", String(root.contentSearchMaxDepth),
              "--glob", "*.md", "--glob", "!.obsidian/**",
              "-e", query, "--", vault]
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onContentSearchResults(text)
    }
  }

  Process {
    id: linkLaunchProc
  }

  Process {
    id: vaultPickerProc
    command: ["bash", "-c",
      'if command -v zenity >/dev/null 2>&1; then zenity --file-selection --directory --title="Select Obsidian Vault"; ' +
      'elif command -v kdialog >/dev/null 2>&1; then kdialog --getexistingdirectory --title "Select Obsidian Vault"; fi']
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var p = text.trim()
        if (p.length > 0) {
          root.draftVaultPath = p
          root.pendingDropdown = true
          root.applyVaultPath(p)
          root.open()
        }
      }
    }
  }

  Process {
    id: scanProc
    command: ["bash", "-c",
      'if [ ! -d "$1" ]; then printf "__MISSING__\\n"; exit 0; fi; find "$1" -type f -name "*.md" -not -path "*/.obsidian/*" -printf "%P\\n" | sort | head -n ' + root.scanMaxNotes,
      "bash", root.vaultPath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onNotesScanned(text)
    }
  }

  Process {
    id: createProc
    property string rel: ""
    property string body: ""
    command: ["python3", root.vaultHelper, "create", root.vaultPath, rel]
    onStarted: write(body)
    stderr: StdioCollector { id: createErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) { root.actionError = root.vaultOpError(createErr.text, "Could not create the note."); return }
      root.createOpen = false
      root.pendingEditOnLoad = true
      root.rescanNotes()
      root.resetFocus("header")
      Qt.callLater(function() { root.switchTo(rel) })
    }
  }

  Process {
    id: renameProc
    property string oldRel: ""
    property string newRel: ""
    command: ["python3", root.vaultHelper, "move", root.vaultPath, oldRel, newRel]
    stderr: StdioCollector { id: renameErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) { root.actionError = root.vaultOpError(renameErr.text, "Could not rename the note."); return }
      root.currentNote = newRel
      root.pendingAbsPath = PathGuard.inVault(root.vaultPath, newRel)
      root.persistState()
      root.renameDraft = root.noteName
      root.actionError = ""
      root.noteFile.path = root.pendingAbsPath
      root.rescanNotes()
    }
  }

  Process {
    id: moveProc
    property string oldRel: ""
    property string newRel: ""
    command: ["python3", root.vaultHelper, "move", root.vaultPath, oldRel, newRel]
    stderr: StdioCollector { id: moveErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) { root.actionError = root.vaultOpError(moveErr.text, "Could not move the note."); return }
      root.currentNote = newRel
      root.pendingAbsPath = PathGuard.inVault(root.vaultPath, newRel)
      root.persistState()
      root.moveOpen = false
      root.actionError = ""
      root.noteFile.path = root.pendingAbsPath
      root.resetFocus("header")
      root.rescanNotes()
    }
  }

  Process {
    id: rmProc
    property string rel: ""
    command: ["python3", root.vaultHelper, "delete", root.vaultPath, rel]
    stderr: StdioCollector { id: rmErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) { root.actionError = root.vaultOpError(rmErr.text, "Could not delete the note."); return }
      root.currentNote = ""
      root.pendingAbsPath = ""
      root.rawText = ""
      root.noteView.setSource("")
      root.deleteConfirmOpen = false
      root.editMode = false
      root.editor.text = ""
      root.persistState()
      root.resetFocus("header")
      root.rescanNotes()
    }
  }

  // Autosave writes through the same helper. Quickshell's FileView gives no
  // way to ask for O_NOFOLLOW, so leaving the write to it would keep a narrow
  // window in which a folder swapped for a symlink just before the save
  // redirects the write outside the vault. FileView stays as the reader and
  // the change watcher, so external-edit detection is unaffected.
  Process {
    id: saveProc
    property string rel: ""
    property string body: ""
    command: ["python3", root.vaultHelper, "write", root.vaultPath, rel]
    onStarted: write(body)
    stderr: StdioCollector { id: saveErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.selfWriteSeen = false
      if (exitCode !== 0) {
        // Keep the edits: mark dirty again so the next autosave retries, and
        // say why rather than dropping the user's typing on the floor.
        root.dirty = true
        root.externalConflict = true
        root.actionMessage = root.vaultOpError(saveErr.text, "Could not save the note.")
        root.actionMessageTimer.restart()
        return
      }
      root.noteFile.reload()
    }
  }

  FileView {
    id: stateFile
    path: Quickshell.stateDir + "/veilios.nether.state.json"
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: {
      try {
        var parsed = JSON.parse(text())
        if (parsed && typeof parsed.lastNote === "string") root.restoredLastNote = parsed.lastNote
      } catch (e) {}
      root.stateResolved = true
    }
    onLoadFailed: function(error) { root.stateResolved = true }
  }

  FileView {
    id: noteFile
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.applyLoadedNote()
    onLoadFailed: function(error) { root.noteLoadFailed() }
    onFileChanged: root.handleExternalChange()
  }

  IpcHandler {
    target: "veilios.nether"

    function ping(): string { return "ok" }

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }

    // Only a path the vault scan actually produced is accepted. Any process
    // running as the user can reach this socket, and noteFile both reads and
    // writes its path, so an unchecked rel was an arbitrary file read/write.
    function selectNote(rel: string): string {
      if (!PathGuard.isKnownNote(root.notes, rel)) return "unknown-note"
      root.switchTo(rel)
      return "ok"
    }

    function selectIndex(index: string): string {
      var i = parseInt(index)
      if (!isFinite(i) || i < 0 || i >= root.notes.length) return "out-of-range"
      root.switchTo(root.notes[i].rel)
      return "ok"
    }

    function toggleEdit(): string {
      root.setEditMode(!root.editMode)
      return root.editMode ? "editing" : "read-only"
    }

    function status(): string {
      return JSON.stringify({
        note: root.currentNote,
        editMode: root.editMode,
        dirty: root.dirty,
        notes: root.notes.length,
        vaultMissing: root.vaultMissing,
        notesTruncated: root.notesTruncated,
        externalConflict: root.externalConflict,
        colH: Math.round(panelColumn.implicitHeight),
        cardH: Math.round(panel.contentHeight),
        cardW: Math.round(panel.contentWidth)
      })
    }

    function rescan(): string {
      root.rescanNotes()
      return "ok"
    }

    function dropdown(): string {
      if (!root.opened) root.open()
      root.toggleDropdown()
      return root.dropdownOpen ? "open" : "closed"
    }

    function settings(): string {
      if (!root.opened) root.open()
      var opening = !root.settingsOpen
      root.closeCards()
      root.settingsOpen = opening
      if (root.settingsOpen) root.draftVaultPath = root.vaultPathRaw
      return root.settingsOpen ? "open" : "closed"
    }
  }

  Component {
    id: obsidianIconComponent

    Item {
      anchors.fill: parent

      Image {
        id: glyphImage
        anchors.centerIn: parent
        width: parent.width * 0.85
        height: parent.height * 0.85
        source: Qt.resolvedUrl("./assets/obsidian.svg")
        fillMode: Image.PreserveAspectFit
        mipmap: true
        sourceSize.width: Math.round(width * Screen.devicePixelRatio)
        sourceSize.height: Math.round(height * Screen.devicePixelRatio)
        visible: false
        layer.enabled: true
      }

      MultiEffect {
        anchors.fill: glyphImage
        source: glyphImage
        colorization: 1.0
        colorizationColor: root.iconTint
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: "Nether"
    iconComponent: obsidianIconComponent
    onPressed: function(b) {
      if (b === Qt.LeftButton) root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    // No cap: the dropdown list is self-bounded (max Style.space(230)), so
    // the column height stays sane and the card must grow to contain it.
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight)

    // Gives the panel a Qt active-focus target on open so key events are
    // delivered; hands keys to the editor while it is editing.
    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: editor.activeFocus
        || renameInput.activeFocus
        || noteSearchInput.activeFocus
        || pathInput.activeFocus
        || createTitleInput.activeFocus
        || noteView.taskInputActive

      // Authoritative dispatcher. Replaces PanelKeyCatcher's internal handler
      // (one Keys.onPressed per item) so Ctrl shortcuts and navigation share a
      // single deterministic path. Text fields own their keys via `blocked`.
      Keys.onPressed: function(event) {
        if (blocked) return

        if (event.modifiers & Qt.ControlModifier) {
          root.handleShortcut(event)
          return
        }

        if (event.key === Qt.Key_Escape) {
          if (root.hotKeysOpen) {
            root.hotKeysOpen = false
            event.accepted = true
            return
          }
          root.handlePanelCloseRequest()
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
          root.cycleKeyboardFocus((event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab ? -1 : 1)
          event.accepted = true
          return
        }

        var mods = event.modifiers & ~Qt.KeypadModifier
        if (mods === Qt.NoModifier) {
          // Up/Down traverse rows (header / content / footer); hjkl keep their
          // per-section meanings (j/k scroll the note, navigate lists, etc.).
          if (event.key === Qt.Key_Down) {
            root.moveBetweenRows(1); event.accepted = true; return
          }
          if (event.key === Qt.Key_Up) {
            root.moveBetweenRows(-1); event.accepted = true; return
          }
          if (event.key === Qt.Key_J) {
            root.moveBetweenRows(1); event.accepted = true; return
          }
          if (event.key === Qt.Key_K) {
            root.moveBetweenRows(-1); event.accepted = true; return
          }
          if (event.key === Qt.Key_L) {
            // vim-style activate: toggle the highlighted task in the read view
            if (root.keyboardSection === "read" && noteView.hasTaskBlocks) {
              noteView.toggleTaskAtCursor(); event.accepted = true; return
            }
            root.handlePanelMove(1, 0); event.accepted = true; return
          }
          if (event.key === Qt.Key_Right) {
            if (root.keyboardSection === "read" && noteView.hasTaskBlocks && noteView.taskCursorActive) {
              var cursorIdx = noteView.taskCursorIndex
              if (cursorIdx >= 0 && cursorIdx < noteView.taskCount) {
                var taskBlockIdx = noteView.taskBlockIndexes[cursorIdx]
                var block = noteView.blocks.get(taskBlockIdx)
                if (block && block.checked) {
                  noteView.focusDeleteButtonWithFocus(block.taskOrdinal)
                  event.accepted = true
                  return
                }
              }
            }
            root.handlePanelMove(1, 0); event.accepted = true; return
          }
          if (event.key === Qt.Key_Left || event.key === Qt.Key_H) {
            if (root.keyboardSection === "read" && noteView.deleteButtonFocusedOrdinal >= 0) {
              noteView.clearDeleteButtonFocusWithReturn()
              event.accepted = true
              return
            }
            root.handlePanelMove(-1, 0); event.accepted = true; return
          }
        }
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.handlePanelActivate()
            event.accepted = true
            return
          }
        if (event.key === Qt.Key_PageDown) {
          root.pageScroll(scrollArea.height * 0.9); event.accepted = true; return
        }
        if (event.key === Qt.Key_PageUp) {
          root.pageScroll(-scrollArea.height * 0.9); event.accepted = true; return
        }
if (event.key === Qt.Key_Space) {
          if (root.keyboardSection === "read" && noteView.hasTaskBlocks) {
            noteView.toggleTaskAtCursor()
            event.accepted = true
            return
          }
        }
        if (root.keyboardSection === "search" && event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32) {
          noteSearchInput.forceActiveFocus()
          noteSearchInput.insert(noteSearchInput.cursorPosition, event.text)
          event.accepted = true
          return
        }
      }
    }

    Column {
      id: panelColumn
      width: parent.width
      spacing: Style.space(10)

      Item {
        id: headerRow
        width: parent.width
        implicitHeight: Math.max(headerBg.height, hotKeysButton.height)

        Rectangle {
          id: settingsButton
          anchors.right: hotKeysButton.left
          anchors.rightMargin: Style.space(3)
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(24)
          height: Style.space(24)
          radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(4)
          color: root.keyboardSection === "header" && root.headerIndex === 3
            ? Qt.rgba(root.bodyText.r, root.bodyText.g, root.bodyText.b, 0.32)
            : (gearMouse.containsMouse || gearMouse.pressed
            ? Style.hoverFillFor(root.bodyText, Color.accent)
            : "transparent")

          Text {
            anchors.centerIn: parent
            text: "\uF013"
            color: root.settingsOpen ? Color.accent : root.bodyText
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
          }

          MouseArea {
            id: gearMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              var opening = !root.settingsOpen
              root.closeCards()
              root.settingsOpen = opening
              if (root.settingsOpen) {
                root.draftVaultPath = root.vaultPathRaw
              }
            }
          }
        }

        Rectangle {
          id: hotKeysButton
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(24)
          height: Style.space(24)
          radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(4)
          color: root.keyboardSection === "header" && root.headerIndex === 4
            ? Qt.rgba(root.bodyText.r, root.bodyText.g, root.bodyText.b, 0.32)
            : (hotKeysMouse.containsMouse || hotKeysMouse.pressed
            ? Style.hoverFillFor(root.bodyText, Color.accent)
            : "transparent")

          Text {
            anchors.centerIn: parent
            text: "?"
            color: root.quickKeysOpen ? Color.accent : root.bodyText
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }

          MouseArea {
            id: hotKeysMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              var opening = !root.quickKeysOpen
              root.closeCards()
              root.quickKeysOpen = opening
              root.keyboardSection = opening ? "quickKeys" : "header"
              root.keyCatcher.forceActiveFocus()
            }
          }
        }

        Rectangle {
          id: headerBg
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: innerRow.implicitWidth + Style.space(12)
          height: innerRow.height + Style.space(8)
          radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(4)
          color: root.keyboardSection === "header" && root.headerIndex === 0
            ? Qt.rgba(root.bodyText.r, root.bodyText.g, root.bodyText.b, 0.32)
            : (headerBgMouse.containsMouse
            ? Qt.rgba(root.bodyText.r, root.bodyText.g, root.bodyText.b, 0.15)
            : Qt.rgba(root.bodyText.r, root.bodyText.g, root.bodyText.b, 0.1))

          MouseArea {
            id: headerBgMouse
            anchors.fill: parent
            enabled: !root.editMode
            cursorShape: Qt.PointingHandCursor
            onClicked: root.toggleDropdown()
          }

          Row {
            id: innerRow
            anchors.centerIn: parent
            spacing: Style.space(4)

            Text {
              id: nameText
              visible: !root.editMode
              width: Math.min(implicitWidth, headerRow.width - arrowButton.width - innerRow.spacing - headerActions.width - Style.space(6) - settingsButton.width - Style.space(3) - hotKeysButton.width - Style.space(12))
              text: root.vaultMissing ? "Vault not found" : root.noteName
              elide: Text.ElideRight
              color: root.bodyText
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              verticalAlignment: Text.AlignVCenter
            }

            TextInput {
              id: renameInput
              visible: root.editMode
              width: Math.min(Style.space(190), headerRow.width - arrowButton.width - innerRow.spacing - headerActions.width - Style.space(6) - settingsButton.width - Style.space(3) - hotKeysButton.width - Style.space(12))
              text: root.renameDraft
              color: root.bodyText
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              selectByMouse: true
              clip: true
              onTextEdited: root.renameDraft = text
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  if (event.modifiers & Qt.ControlModifier) {
                    root.commitRenameAndExit()
                    event.accepted = true
                    return
                  }
                  root.commitRenameAndExit()
                  event.accepted = true
                  return
                }
                if (event.key === Qt.Key_Escape) {
                  root.flushSave()
                  root.setEditMode(false)
                  event.accepted = true
                  return
                }
              }
            }

            Rectangle {
              id: arrowButton
              width: Style.space(24)
              height: Style.space(24)
              radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(4)
              color: arrowMouse.containsMouse || arrowMouse.pressed
                ? Style.hoverFillFor(root.bodyText, Color.accent)
                : "transparent"

              Text {
                anchors.centerIn: parent
                text: "󰅀"
                color: root.bodyText
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                rotation: root.dropdownOpen ? 180 : 0

                Behavior on rotation {
                  NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
                }
              }

              MouseArea {
                id: arrowMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.toggleDropdown()
              }
            }
          }
        }

        Row {
          id: headerActions
          anchors.left: headerBg.right
          anchors.leftMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(3)

          Rectangle {
            visible: !root.vaultMissing
            width: Style.space(24)
            height: Style.space(24)
            radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(4)
              color: root.keyboardSection === "header" && root.headerIndex === 1
                ? Qt.rgba(root.bodyText.r, root.bodyText.g, root.bodyText.b, 0.32)
                : (addHeaderMouse.containsMouse ? Style.hoverFillFor(root.bodyText, Color.accent) : "transparent")

            Text {
              anchors.centerIn: parent
              text: "+"
              color: root.bodyText
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
            }

            MouseArea {
              id: addHeaderMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.beginCreate()
            }
          }

          Rectangle {
            visible: !root.editMode && root.currentNote !== ""
            width: Style.space(24)
            height: Style.space(24)
            radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(4)
              color: root.keyboardSection === "header" && root.headerIndex === 2
                ? Qt.rgba(root.bodyText.r, root.bodyText.g, root.bodyText.b, 0.32)
                : (deleteHeaderMouse.containsMouse ? Style.hoverFillFor(root.bodyText, Color.urgent) : "transparent")

            Text {
              anchors.centerIn: parent
              text: "×"
              color: Color.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
            }

            MouseArea {
              id: deleteHeaderMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.beginDelete()
            }
          }
        }
      }

      Rectangle {
        id: dropdownCard
        visible: height > 0
        width: parent.width
        height: root.dropdownOpen
          ? Math.min(Style.space(260), notesList.contentHeight + Style.space(42))
          : 0
        clip: true
        radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(4)
        color: Color.popups.background
        border.color: Color.popups.border
        border.width: 1

        Behavior on height {
          NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
        }

        Rectangle {
          id: noteSearchFrame
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: Style.space(32)
          color: "transparent"

          TextInput {
            id: noteSearchInput
            anchors.fill: parent
            anchors.margins: Style.space(5)
            text: root.noteSearch
            color: root.bodyText
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            selectByMouse: true
            clip: true
            onTextEdited: { root.noteSearch = text; root.dropdownIndex = 0; root.recomputeNotes() }
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Down) {
                root.moveDropdownSelection(1); event.accepted = true
              } else if (event.key === Qt.Key_Up) {
                root.moveDropdownSelection(-1); event.accepted = true
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                if (root.filteredNotes.length > 0) root.switchTo(root.filteredNotes[root.dropdownIndex].rel)
                event.accepted = true
              } else if (event.key === Qt.Key_Escape) {
                root.dropdownOpen = false; root.resetFocus("header"); event.accepted = true
              } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                root.keyboardSection = "search"
                root.keyCatcher.forceActiveFocus()
                event.accepted = true
              } else root.handleShortcut(event)
            }
          }
        }

        ListView {
          id: notesList
          anchors.fill: parent
          anchors.topMargin: Style.space(32)
          anchors.margins: Style.space(5)
          model: root.filteredNotes
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          section.property: "folder"
          section.delegate: Item {
            id: folderHeader
            required property string section
            width: notesList.width
            height: Style.space(22)

            Text {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(8)
              text: folderHeader.section === "" ? "VAULT" : folderHeader.section.toUpperCase()
              elide: Text.ElideRight
              color: root.dimText
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1
            }
          }

          delegate: Item {
            id: noteRow
            required property var modelData
            required property int index
            width: notesList.width
            height: Style.space(34)

            Rectangle {
              anchors.fill: parent
              radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(3)
              color: index === root.dropdownIndex
                ? Color.menu.selectedBackground
                : noteRow.modelData.rel === root.currentNote
                ? Color.menu.selectedBackground
                : (rowMouse.containsMouse ? Style.hoverFillFor(root.bodyText, Color.accent) : "transparent")
            }

            Row {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(18)
              anchors.rightMargin: Style.space(8)
              spacing: Style.space(6)

              Text {
                width: notesList.width * 0.5
                text: noteRow.modelData.name
                elide: Text.ElideMiddle
                color: index === root.dropdownIndex || noteRow.modelData.rel === root.currentNote ? Color.accent : root.bodyText
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Text {
                visible: noteRow.modelData.matchType === "content" || noteRow.modelData.matchType === "both"
                text: "📄"
                color: root.dimText
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                visible: noteRow.modelData.snippets && noteRow.modelData.snippets.length > 0
                width: notesList.width * 0.45
                text: noteRow.modelData.snippets[0].text
                elide: Text.ElideRight
                color: root.dimText
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            MouseArea {
              id: rowMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.switchTo(noteRow.modelData.rel)
            }
          }

          Text {
            visible: !root.vaultMissing && root.filteredNotes.length === 0
            anchors.centerIn: parent
            text: root.noteSearch === "" ? "No markdown notes found" : "No matching notes"
            color: root.dimText
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
        }
      }

      Rectangle {
        id: settingsCard
        visible: height > 0
        width: parent.width
        height: root.settingsOpen ? Math.min(Style.space(180), settingsBody.implicitHeight + Style.space(14)) : 0
        clip: true
        radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(4)
        color: Color.popups.background
        border.color: Color.popups.border
        border.width: 1

        Behavior on height {
          NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
        }

        Column {
          id: settingsBody
          anchors.fill: parent
          anchors.margins: Style.space(7)
          spacing: Style.space(7)

          Text {
            text: "VAULT FOLDER"
            color: root.dimText
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1
          }

          Rectangle {
            width: parent.width
            height: pathInput.implicitHeight + Style.space(10)
            radius: Style.space(4)
            color: "transparent"
            border.color: Color.popups.border
            border.width: 1

            TextInput {
              id: pathInput
              anchors.fill: parent
              anchors.margins: Style.space(5)
              text: root.draftVaultPath
              color: root.bodyText
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              selectByMouse: true
              clip: true
              onTextEdited: root.draftVaultPath = text
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                  root.keyboardSection = "settings"
                  root.keyCatcher.forceActiveFocus()
                  event.accepted = true
                } else if (event.key === Qt.Key_Escape) {
                  root.closeCards(); root.keyboardSection = "header"; root.keyCatcher.forceActiveFocus(); event.accepted = true
                }
              }
            }
          }

          Row {
            spacing: Style.space(6)

            Repeater {
              model: [
                { label: "SAVE", act: function() { if (root.draftVaultPath !== root.vaultPathRaw) root.applyVaultPath(root.draftVaultPath); else root.settingsOpen = false } },
                { label: "LOCATE", act: function() { vaultPickerProc.running = true } },
                { label: "REFRESH", act: function() { root.rescanNotes() } },
                { label: "DISCONNECT", act: function() { root.applyVaultPath("") } },
                { label: "HOT KEYS", act: function() { root.hotKeysOpen = true } }
              ]
              delegate: Rectangle {
                required property var modelData
                required property int index
                width: btnLbl.implicitWidth + Style.space(16)
                height: Style.space(24)
                radius: Style.space(4)
                color: btnMouse.containsMouse || btnMouse.pressed
                  ? Style.hoverFillFor(root.bodyText, Color.accent)
                  : (root.keyboardSection === "settings" && root.settingsIndex === index
                    ? Color.menu.selectedBackground
                    : Color.menu.selectedBackground)

                Text {
                  id: btnLbl
                  anchors.centerIn: parent
                  text: modelData.label
                  color: root.bodyText
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 1
                }

                MouseArea {
                  id: btnMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: { root.settingsIndex = index; modelData.act() }
                }
              }
            }
          }

          Text {
            width: parent.width
            text: root.vaultMissing
              ? "No vault connected. Paste a folder path above and SAVE."
              : "Changes apply immediately and are saved to shell.json."
            wrapMode: Text.WordWrap
            color: root.dimText
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      Rectangle {
        id: quickKeysCard
        visible: height > 0
        width: parent.width
        height: root.quickKeysOpen ? quickKeysBody.implicitHeight + Style.space(14) : 0
        clip: true
        radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(4)
        color: Color.popups.background
        border.color: Color.popups.border
        border.width: 1
        Behavior on height { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

        Column {
          id: quickKeysBody
          anchors.fill: parent
          anchors.margins: Style.space(8)
          spacing: Style.space(4)
          Text { text: "QUICK KEYS"; color: root.dimText; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true; font.letterSpacing: 1 }
          Text { text: "CTRL+K   Quick keys\nCTRL+N   New note\nCTRL+X   Delete note (read mode)\nCTRL+D   Delete task (read mode)\nCTRL+ENTER   Toggle edit / read-only\nCTRL+S   Search notes\nCTRL+M   Move note\nPAGE UP/DOWN   Scroll note\nJ/K   Move task cursor / scroll\nENTER/SPACE/L   Toggle task\nUP/DOWN   Move through rows and tasks\nRIGHT   Focus delete button (on completed task)\nLEFT   Return from delete button\nTAB   Cycle rows"; color: root.bodyText; font.family: root.fontFamily; font.pixelSize: Style.font.body; lineHeight: 1.25; lineHeightMode: Text.ProportionalHeight }
        }
      }

      Rectangle {
        id: createCard
        visible: height > 0
        width: parent.width
        height: root.createOpen ? createBody.implicitHeight + Style.space(14) : 0
        clip: true
        radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(4)
        color: Color.popups.background
        border.color: Color.popups.border
        border.width: 1
        Behavior on height { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

        Column {
          id: createBody
          anchors.fill: parent
          anchors.margins: Style.space(8)
          spacing: Style.space(6)
          Text { text: "NEW NOTE"; color: root.dimText; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true; font.letterSpacing: 1 }
          Rectangle {
            width: parent.width; height: Style.space(30); color: "transparent"; border.color: Color.popups.border; border.width: 1; radius: Style.space(4)
            TextInput {
              id: createTitleInput
              anchors.fill: parent
              anchors.margins: Style.space(5)
              text: root.createTitle
              color: root.bodyText
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              onTextEdited: root.createTitle = text
              Keys.onReturnPressed: root.submitCreate()
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Tab || event.key === Qt.Key_Down) {
                  createFolderGrid.forceActiveFocus(); event.accepted = true
                } else if (event.key === Qt.Key_Escape) {
                  root.closeCards(); root.keyboardSection = "header"; root.keyCatcher.forceActiveFocus(); event.accepted = true
                }
              }
            }
          }
          GridView {
            id: createFolderGrid
            width: parent.width
            height: Math.min(Style.space(140), contentHeight)
            cellWidth: Style.space(100)
            cellHeight: Style.space(28)
            model: root.folderModel
            focus: true
            keyNavigationEnabled: true
            currentIndex: root.folderIndex
            onCurrentIndexChanged: {
              if (currentIndex >= 0 && currentIndex < root.folderModel.length) {
                root.folderIndex = currentIndex
                var item = root.folderModel[currentIndex]
                if (item && !item.isPlus) {
                  root.folderDraft = item.path
                }
              }
            }

            delegate: Item {
              width: createFolderGrid.cellWidth
              height: createFolderGrid.cellHeight

              Loader {
                id: folderDelegateLoader
                anchors.fill: parent
                sourceComponent: modelData.isPlus ? plusButtonComponent : folderButtonComponent
              }

              Component {
                id: folderButtonComponent
                Rectangle {
                  anchors.fill: parent
                  anchors.margins: Style.space(2)
                  radius: Style.space(3)
                  color: modelData.path === root.folderDraft ? Color.menu.selectedBackground : "transparent"
                  border.color: createFolderGrid.currentIndex === index ? Color.accent : Color.popups.border
                  border.width: createFolderGrid.currentIndex === index ? 2 : 1

                  Text {
                    anchors.centerIn: parent
                    text: modelData.path === "" ? "VAULT ROOT" : modelData.path
                    color: root.bodyText
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    anchors.leftMargin: Style.space(6)
                    anchors.rightMargin: Style.space(6)
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      root.folderIndex = index
                      root.folderDraft = modelData.path
                    }
                  }
                }
              }

              Component {
                id: plusButtonComponent
                Item {
                  anchors.fill: parent
                  property bool editing: root.creatingNewFolder && createFolderGrid.currentIndex === index

                  Rectangle {
                    id: plusBtn
                    visible: !parent.editing
                    anchors.fill: parent
                    anchors.margins: Style.space(2)
                    radius: Style.space(3)
                    color: createFolderGrid.currentIndex === index ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.15) : "transparent"
                    border.color: createFolderGrid.currentIndex === index ? Color.accent : Color.popups.border
                    border.width: createFolderGrid.currentIndex === index ? 2 : 1

                    Row {
                      anchors.centerIn: parent
                      spacing: Style.space(4)
                      Text { text: "+"; color: Color.accent; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                      Text { text: "NEW FOLDER"; color: root.dimText; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.letterSpacing: 0.5 }
                    }

                    MouseArea {
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        root.folderIndex = index
                      }
                    }
                  }

                  Rectangle {
                    id: newFolderInputBg
                    visible: parent.editing
                    anchors.fill: parent
                    anchors.margins: Style.space(2)
                    radius: Style.space(3)
                    color: "transparent"
                    border.color: Color.accent
                    border.width: 2

                    TextInput {
                      id: newFolderInput
                      anchors.fill: parent
                      anchors.margins: Style.space(6)
                      color: root.bodyText
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      text: root.newFolderDraft
                      onTextEdited: root.newFolderDraft = text
                      focus: true
                      onVisibleChanged: if (visible) forceActiveFocus()
                      Keys.onReturnPressed: {
                        var valid = root.folderValue(root.newFolderDraft)
                        if (valid && !root.folders.includes(valid)) {
                          root.folders.push(valid)
                          root.folders.sort()
                          root.rebuildFolderModel()
                          root.folderDraft = valid
                          root.folderIndex = root.folders.indexOf(valid)
                          root.creatingNewFolder = false
                          root.newFolderDraft = ""
                        }
                      }
                      Keys.onEscapePressed: {
                        root.creatingNewFolder = false
                        root.newFolderDraft = ""
                      }
                    }
                  }
                }
              }
            }

            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                if (createFolderGrid.currentIndex >= 0 && createFolderGrid.currentIndex < root.folderModel.length) {
                  var item = root.folderModel[createFolderGrid.currentIndex]
                  if (item && item.isPlus) {
                    root.creatingNewFolder = true
                    root.newFolderDraft = ""
                    event.accepted = true
                    return
                  }
                  root.folderDraft = item.path
                  event.accepted = true
                }
              } else if (event.key === Qt.Key_Escape) {
                createTitleInput.forceActiveFocus()
                event.accepted = true
              } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                root.cycleKeyboardFocus(event.key === Qt.Key_Backtab ? -1 : 1)
                event.accepted = true
              }
            }
          }
          Row {
            spacing: Style.space(6)
            Rectangle {
              width: createLabel.implicitWidth + Style.space(16)
              height: Style.space(25)
              radius: Style.space(4)
              color: Color.menu.selectedBackground

              Text {
                id: createLabel
                anchors.centerIn: parent
                text: "CREATE"
                color: root.bodyText
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              MouseArea {
                anchors.fill: parent
                onClicked: root.submitCreate()
              }
            }
            Rectangle {
              width: cancelCreateLabel.implicitWidth + Style.space(16)
              height: Style.space(25)
              radius: Style.space(4)
              color: "transparent"

              Text {
                id: cancelCreateLabel
                anchors.centerIn: parent
                text: "CANCEL"
                color: root.dimText
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                anchors.fill: parent
                onClicked: root.createOpen = false
              }
            }
          }
          Text { visible: root.actionError !== ""; text: root.actionError; color: Color.urgent; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
        }
      }

      Rectangle {
        id: moveCard
        visible: height > 0
        width: parent.width
        height: root.moveOpen ? moveBody.implicitHeight + Style.space(14) : 0
        clip: true
        radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(4)
        color: Color.popups.background
        border.color: Color.popups.border
        border.width: 1
        Behavior on height { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

        Column {
          id: moveBody
          anchors.fill: parent
          anchors.margins: Style.space(8)
          spacing: Style.space(6)
          Text { text: "MOVE NOTE"; color: root.dimText; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true; font.letterSpacing: 1 }
          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            elide: Text.ElideMiddle
            text: "Moving: " + root.noteName
            color: root.bodyText
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
          GridView {
            id: moveFolderGrid
            width: parent.width
            height: Math.min(Style.space(140), contentHeight)
            cellWidth: Style.space(100)
            cellHeight: Style.space(28)
            model: root.folderModel
            focus: true
            keyNavigationEnabled: true
            currentIndex: root.folderIndex
            onCurrentIndexChanged: {
              if (currentIndex >= 0 && currentIndex < root.folderModel.length) {
                root.folderIndex = currentIndex
                var item = root.folderModel[currentIndex]
                if (item && !item.isPlus) {
                  root.folderDraft = item.path
                }
              }
            }

            delegate: Item {
              width: moveFolderGrid.cellWidth
              height: moveFolderGrid.cellHeight

              Loader {
                id: moveFolderDelegateLoader
                anchors.fill: parent
                sourceComponent: modelData.isPlus ? movePlusButtonComponent : moveFolderButtonComponent
              }

              Component {
                id: moveFolderButtonComponent
                Rectangle {
                  anchors.fill: parent
                  anchors.margins: Style.space(2)
                  radius: Style.space(3)
                  color: modelData.path === root.folderDraft ? Color.menu.selectedBackground : "transparent"
                  border.color: moveFolderGrid.currentIndex === index ? Color.accent : Color.popups.border
                  border.width: moveFolderGrid.currentIndex === index ? 2 : 1

                  Text {
                    anchors.centerIn: parent
                    text: modelData.path === "" ? "VAULT ROOT" : modelData.path
                    color: root.bodyText
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    anchors.leftMargin: Style.space(6)
                    anchors.rightMargin: Style.space(6)
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      root.folderIndex = index
                      root.folderDraft = modelData.path
                    }
                  }
                }
              }

              Component {
                id: movePlusButtonComponent
                Item {
                  anchors.fill: parent
                  property bool editing: root.creatingNewFolder && moveFolderGrid.currentIndex === index

                  Rectangle {
                    id: movePlusBtn
                    visible: !parent.editing
                    anchors.fill: parent
                    anchors.margins: Style.space(2)
                    radius: Style.space(3)
                    color: moveFolderGrid.currentIndex === index ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.15) : "transparent"
                    border.color: moveFolderGrid.currentIndex === index ? Color.accent : Color.popups.border
                    border.width: moveFolderGrid.currentIndex === index ? 2 : 1

                    Row {
                      anchors.centerIn: parent
                      spacing: Style.space(4)
                      Text { text: "+"; color: Color.accent; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
                      Text { text: "NEW FOLDER"; color: root.dimText; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.letterSpacing: 0.5 }
                    }

                    MouseArea {
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        root.folderIndex = index
                      }
                    }
                  }

                  Rectangle {
                    id: moveNewFolderInputBg
                    visible: parent.editing
                    anchors.fill: parent
                    anchors.margins: Style.space(2)
                    radius: Style.space(3)
                    color: "transparent"
                    border.color: Color.accent
                    border.width: 2

                    TextInput {
                      id: moveNewFolderInput
                      anchors.fill: parent
                      anchors.margins: Style.space(6)
                      color: root.bodyText
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      text: root.newFolderDraft
                      onTextEdited: root.newFolderDraft = text
                      focus: true
                      onVisibleChanged: if (visible) forceActiveFocus()
                      Keys.onReturnPressed: {
                        var valid = root.folderValue(root.newFolderDraft)
                        if (valid && !root.folders.includes(valid)) {
                          root.folders.push(valid)
                          root.folders.sort()
                          root.rebuildFolderModel()
                          root.folderDraft = valid
                          root.folderIndex = root.folders.indexOf(valid)
                          root.creatingNewFolder = false
                          root.newFolderDraft = ""
                        }
                      }
                      Keys.onEscapePressed: {
                        root.creatingNewFolder = false
                        root.newFolderDraft = ""
                      }
                    }
                  }
                }
              }
            }

            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                if (moveFolderGrid.currentIndex >= 0 && moveFolderGrid.currentIndex < root.folderModel.length) {
                  var item = root.folderModel[moveFolderGrid.currentIndex]
                  if (item && item.isPlus) {
                    root.creatingNewFolder = true
                    root.newFolderDraft = ""
                    event.accepted = true
                    return
                  }
                  root.folderDraft = item.path
                  event.accepted = true
                }
              } else if (event.key === Qt.Key_Escape) {
                root.closeCards(); root.keyboardSection = "header"; root.keyCatcher.forceActiveFocus(); event.accepted = true
              } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                root.cycleKeyboardFocus(event.key === Qt.Key_Backtab ? -1 : 1)
                event.accepted = true
              }
            }
          }
          Row {
            spacing: Style.space(6)

            Rectangle {
              width: moveLabel.implicitWidth + Style.space(16)
              height: Style.space(25)
              radius: Style.space(4)
              color: Color.menu.selectedBackground

              Text {
                id: moveLabel
                anchors.centerIn: parent
                text: "MOVE"
                color: root.bodyText
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              MouseArea {
                anchors.fill: parent
                onClicked: root.submitMove()
              }
            }

            Rectangle {
              width: cancelMoveLabel.implicitWidth + Style.space(16)
              height: Style.space(25)
              radius: Style.space(4)
              color: "transparent"

              Text {
                id: cancelMoveLabel
                anchors.centerIn: parent
                text: "CANCEL"
                color: root.dimText
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                anchors.fill: parent
                onClicked: root.moveOpen = false
              }
            }
          }
          Text { visible: root.actionError !== ""; text: root.actionError; color: Color.urgent; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
        }
      }

      Rectangle {
        id: editorFrame
        width: parent.width
        height: Style.space(370)
        color: "transparent"
        radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(4)
        border.color: root.editMode || root.keyboardSection === "read" ? Color.accent : Color.popups.border
        border.width: 1

        ScrollView {
          id: scrollArea
          anchors.fill: parent
          anchors.margins: Style.space(2)
          clip: true
          ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
          contentWidth: scrollArea.availableWidth
          contentHeight: root.editMode ? editor.implicitHeight : noteView.implicitHeight

          NoteView {
            id: noteView
            visible: !root.editMode
            width: scrollArea.availableWidth
            bodyText: root.bodyText
            dimText: root.dimText
            accent: Color.accent
            panelBackground: Color.popups.background
            fontFamily: root.fontFamily
            noteTitle: root.noteName
            noteOpen: root.currentNote !== ""
            taskCursorActive: root.keyboardSection === "read" && root.currentNote !== ""
            bodyFontSize: Style.font.body
            horizontalPadding: Style.space(10)
            verticalPadding: Style.space(8)
            onTaskClicked: (lineNo, checked) => root.toggleTask(lineNo, checked)
            onTaskAdded: (text) => root.addTask(text)
            onTaskInputTraverse: (delta) => {
              if (delta > 0) root.enterFooter()
              else root.enterReadAtLastTask()
            }
            onTaskInputTab: (direction) => {
              if (direction > 0) root.enterFooter()
              else root.enterReadAtLastTask()
            }
            onTaskInputEsc: {
              root.enterReadAtLastTask()
            }
            onTaskDeleted: (lineNo) => root.deleteTask(lineNo)
            onExitDeleteButtonFocus: {
              var cursorIdx = noteView.taskCursorIndex
              var taskCount = noteView.taskCount
              if (taskCount > 0) {
                var nextIdx = Math.min(cursorIdx, taskCount - 1)
                noteView.moveTaskCursor(nextIdx - cursorIdx)
                root.revealTaskCursor()
              } else {
                root.enterTaskInput()
              }
            }
            onLinkActivated: function(link) {
              // Note bodies are untrusted (a vault can be synced or shared), so
              // a link may not pick its own handler: an unfiltered file: link
              // would hand an arbitrary local path to whatever the desktop has
              // registered for it. PathGuard restricts this to http/https/mailto
              // and refuses targets xdg-open would read as an option.
              var allowed = PathGuard.linkAllowed(link)
              if (allowed === "") return
              linkLaunchProc.command = ["xdg-open", allowed]
              linkLaunchProc.running = true
            }
          }

          // Raw-text editor. Formats never flip at runtime, so there are no
          // deferred reparse signals racing the change guard.
          TextEdit {
            id: editor
            visible: root.editMode
            width: scrollArea.availableWidth
            readOnly: false
            textFormat: TextEdit.PlainText
            wrapMode: TextEdit.Wrap
            color: root.bodyText
            selectionColor: Color.menu.selectedBackground
            selectedTextColor: root.bodyText
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            selectByMouse: true
            cursorVisible: activeFocus
            topPadding: Style.space(8)
            bottomPadding: Style.space(8)
            leftPadding: Style.space(10)
            rightPadding: Style.space(10)

            onTextChanged: {
              if (root.applyingText || root.loadingNote || !root.editMode) return
              root.rawText = editor.text
              root.dirty = true
              saveTimer.restart()
            }

            Keys.onEscapePressed: function(event) {
              event.accepted = true
              if (root.dropdownOpen) root.dropdownOpen = false
              else root.close()
            }

            Keys.onPressed: function(event) {
              if (event.modifiers & Qt.ControlModifier) {
                root.handleShortcut(event)
                return
              }
              if (event.key === Qt.Key_PageDown) {
                root.pageScroll(scrollArea.height * 0.9)
                event.accepted = true
                return
              }
              if (event.key === Qt.Key_PageUp) {
                root.pageScroll(-scrollArea.height * 0.9)
                event.accepted = true
                return
              }
              if (event.text.length !== 1 || (event.modifiers & ~(Qt.ShiftModifier | Qt.KeypadModifier))) return
              var pairs = { "[": "]", "{": "}", "(": ")" }
              var closers = { "]": true, "}": true, ")": true }
              var typed = event.text
              var position = editor.cursorPosition
              if (pairs[typed] !== undefined) {
                event.accepted = true
                if (editor.selectedText.length > 0) {
                  var selected = editor.selectedText
                  var start = editor.selectionStart
                  editor.remove(start, editor.selectionEnd)
                  editor.insert(start, typed + selected + pairs[typed])
                  editor.cursorPosition = start + selected.length + 2
                } else {
                  editor.insert(position, typed + pairs[typed])
                  editor.cursorPosition = position + 1
                }
              } else if (closers[typed] && editor.getText(position, position + 1) === typed) {
                event.accepted = true
                editor.cursorPosition = position + 1
              }
            }
          }
        }

        Column {
          visible: root.vaultMissing || root.currentNote === ""
          anchors.centerIn: parent
          spacing: Style.space(8)

          Text {
            width: Math.min(editorFrame.width - Style.space(30), implicitWidth)
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.vaultMissing
              ? "No vault connected"
              : "Select a note from the list above"
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            color: root.dimText
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Rectangle {
            visible: root.vaultMissing
            anchors.horizontalCenter: parent.horizontalCenter
            width: connectLbl.implicitWidth + Style.space(20)
            height: Style.space(28)
            radius: Style.space(5)
            color: connectMouse.containsMouse || connectMouse.pressed
              ? Style.hoverFillFor(root.bodyText, Color.accent)
              : Color.menu.selectedBackground

            Text {
              id: connectLbl
              anchors.centerIn: parent
              text: "CONNECT VAULT\u2026"
              color: root.bodyText
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1
            }

            MouseArea {
              id: connectMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                vaultPickerProc.command = ["bash", "-c",
                  'if command -v zenity >/dev/null 2>&1; then zenity --file-selection --directory --title="Select Obsidian Vault"; ' +
                  'elif command -v kdialog >/dev/null 2>&1; then kdialog --getexistingdirectory --title "Select Obsidian Vault"; fi']
                vaultPickerProc.running = true
              }
            }
          }
        }
      }

      Item {
        id: footerRow
        width: parent.width
        implicitHeight: Math.max(modeLabel.implicitHeight, editSwitch.height)

        Row {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(8)

          Rectangle {
            visible: !root.editMode && root.currentNote !== ""
            width: editSwitch.implicitWidth
            height: editSwitch.implicitHeight
            radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(4)
            color: moveFooterMouse.containsMouse ? Style.hoverFillFor(root.bodyText, Color.accent) : Color.menu.selectedBackground
            border.width: root.keyboardSection === "footer" && root.footerIndex === 0 ? 1 : 0
            border.color: Color.accent

            Text {
              anchors.centerIn: parent
              text: "MOVE"
              color: root.bodyText
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            MouseArea {
              id: moveFooterMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.beginMove()
            }
          }

        }

        Text {
          id: modeLabel
          anchors.right: editSwitch.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: root.editMode ? "EDITING" : "READ-ONLY"
          color: root.editMode ? Color.accent : root.dimText
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1
        }

        ToggleSwitch {
          id: editSwitch
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          checked: root.editMode
          foreground: root.bodyText
          accent: Color.accent
          onToggled: root.setEditMode(!checked)
        }

        Rectangle {
          id: toggleFocusRing
          visible: root.keyboardSection === "footer" && root.footerIndex === 1
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          width: editSwitch.implicitWidth + Style.space(8)
          height: editSwitch.implicitHeight + Style.space(8)
          radius: Style.space(4)
          color: "transparent"
          border.color: Color.accent
          border.width: 1
        }
      }
    }

      ConfirmDialog {
        id: deleteDialog
        anchors.fill: parent
      opened: root.deleteConfirmOpen
      message: "Delete '" + root.noteName + "'? This cannot be undone."
      cancelText: "CANCEL"
      confirmText: "DELETE"
      background: Color.popups.background
      foreground: root.bodyText
      selectedText: Color.accent
      fontFamily: root.fontFamily
      onCanceled: root.deleteConfirmOpen = false
      onConfirmed: root.completeDelete()
    }
  }

  Loader {
    id: hotKeysPopupLoader
    source: "HotKeysPopup.qml"
    active: root.hotKeysOpen
    onStatusChanged: {
      if (status === Loader.Ready && item) {
        item.anchorItem = root
        item.bar = root
        item.open = root.hotKeysOpen
      }
    }
    onActiveChanged: {
      if (!active && item) item.open = false
    }
  }
}
