// Path and link validation for Nether.
//
// Deliberately NOT marked `.pragma library`: that pragma is QML-specific
// syntax that node cannot parse, and keeping it out lets tests/test_pathguard.mjs
// import this exact file rather than a copy of it. Import from QML with
//   import "PathGuard.js" as PathGuard
//
// Every value here is untrusted: note paths arrive from note content, from
// the vault layout on disk, and from shell IPC, which any process running as
// the user can call.

var SAFE_SCHEMES = ["http", "https", "mailto"]

// Returns the relative path, or "" when the input could name anything other
// than a direct child of the vault.
//
// Rejects: non-strings, NUL bytes, absolute paths, and any empty, "." or ".."
// segment. Segments are checked individually so that both "a/../../b" and a
// bare ".." are refused; a substring test for ".." would also reject the
// legitimate folder "notes..archive". Absolute input is refused outright
// rather than normalised, so "/etc/passwd" cannot be quietly reinterpreted as
// a vault-relative path.
function safeRel(rel) {
  if (typeof rel !== "string" || rel === "") return ""
  for (var n = 0; n < rel.length; n++) {
    if (rel.charCodeAt(n) === 0) return ""
  }
  if (rel.charAt(0) === "/") return ""

  var parts = rel.split("/")
  for (var i = 0; i < parts.length; i++) {
    var part = parts[i]
    if (part === "" || part === "." || part === "..") return ""
  }
  return parts.join("/")
}

// Joins a validated relative path onto the vault root. Returns "" if either
// side is unusable. This is the only sanctioned way to build a path that will
// be handed to FileView or a Process.
function inVault(vault, rel) {
  if (typeof vault !== "string" || vault === "") return ""
  var root = vault.replace(/\/+$/, "")
  if (root === "") return ""
  var safe = safeRel(rel)
  if (safe === "") return ""
  return root + "/" + safe
}

// True only for a path the vault scan actually produced. This is the stronger
// check than safeRel: it cannot be satisfied by a well-formed but unlisted
// path, so IPC callers can only ever name a note that exists in the vault.
function isKnownNote(notes, rel) {
  if (!Array.isArray(notes) || typeof rel !== "string" || rel === "") return false
  for (var i = 0; i < notes.length; i++) {
    var note = notes[i]
    if (note && note.rel === rel) return true
  }
  return false
}

// Returns the link if its scheme is one we are willing to hand to xdg-open,
// otherwise "". Note bodies are untrusted — a vault can be synced or shared —
// so a link may not choose its own handler: an unfiltered "file:" link opens
// an arbitrary local path with whatever the desktop has registered for it.
//
// Relative targets are refused because there is no base to resolve them
// against, and a target beginning with "-" is refused because xdg-open would
// parse it as an option rather than a file.
function linkAllowed(url) {
  if (typeof url !== "string") return ""
  var trimmed = url.trim()
  if (trimmed === "" || trimmed.charAt(0) === "-") return ""

  var match = /^([a-zA-Z][a-zA-Z0-9+.\-]*):/.exec(trimmed)
  if (!match) return ""

  var scheme = match[1].toLowerCase()
  for (var i = 0; i < SAFE_SCHEMES.length; i++) {
    if (SAFE_SCHEMES[i] === scheme) return trimmed
  }
  return ""
}

// Trims an accumulated {rel: [snippets]} map to a bounded number of files so
// a broad query over a large vault cannot grow without limit. The first
// maxFiles keys are kept, matching the order rg emitted them, so the result
// set is a deterministic prefix rather than an arbitrary tail. Returns the
// number of files dropped so the caller can say the result set was clipped.
function capResults(matches, maxFiles) {
  if (!matches || typeof matches !== "object") return 0
  if (!isFinite(maxFiles) || maxFiles < 0) return 0
  var keys = Object.keys(matches)
  if (keys.length <= maxFiles) return 0
  var dropped = keys.length - maxFiles
  for (var i = keys.length - 1; i >= maxFiles; i--) delete matches[keys[i]]
  return dropped
}
