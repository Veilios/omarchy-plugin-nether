.pragma library

function leadingLevel(line) {
  var prefix = /^(\s*)/.exec(line)[1]
  var level = 0
  var spaces = 0
  for (var i = 0; i < prefix.length; i++) {
    if (prefix[i] === "\t") {
      level++
      spaces = 0
    } else {
      spaces++
      if (spaces === 2) {
        level++
        spaces = 0
      }
    }
  }
  return level
}

function withoutIndent(line) {
  return line.replace(/^\s+/, "")
}

function parseBlocks(source) {
  var lines = String(source || "").split("\n")
  var blocks = []
  var blankLines = 0

  for (var i = 0; i < lines.length; i++) {
    var raw = lines[i]
    if (raw.trim() === "") {
      blankLines++
      continue
    }

    var line = withoutIndent(raw)
    var level = leadingLevel(raw)
    var block = {
      type: "paragraph",
      text: line,
      level: level,
      checked: false,
      marker: "",
      gapBefore: Math.min(blankLines, 2),
      lineNo: i
    }

    var heading = /^(#{1,6})\s+(.+?)\s*$/.exec(line)
    var pseudoHeading = /^(\*{2,3})(.+?)\1\s*$/.exec(line)
    var task = /^([-*+])\s+\[([ xX])\]\s*(.*?)(?:\s*<!--\s*completed:\s*([^>]+)\s*-->)?$/.exec(line)
    var bullet = /^([-*+])\s+(.*)$/.exec(line)
    var ordered = /^(\d+[.)])\s+(.*)$/.exec(line)

    if (heading) {
      block.type = "heading"
      block.text = heading[2]
      block.level = heading[1].length
    } else if (pseudoHeading) {
      block.type = "pseudoHeading"
      block.text = pseudoHeading[2]
    } else if (/^([-*_])(?:\s*\1){2,}\s*$/.test(line)) {
      block.type = "divider"
      block.text = ""
    } else if (task) {
      block.type = "task"
      block.text = task[3]
      block.checked = task[2].toLowerCase() === "x"
      block.completedAt = task[4] ? new Date(task[4]).getTime() : null
    } else if (bullet) {
      block.type = "bullet"
      block.text = bullet[2]
    } else if (ordered) {
      block.type = "ordered"
      block.text = ordered[2]
      block.marker = ordered[1]
    }

    blocks.push(block)
    blankLines = 0
  }

  return blocks
}
