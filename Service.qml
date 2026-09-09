import QtQuick
import Quickshell
import Quickshell.Io

// Oma Quick Plugin TUI service: keeps an app-launcher entry installed while the plugin
// is enabled and removes it when the plugin is disabled or removed. The TUI
// itself is bin/oma-quick-plugin-tui; nothing else runs inside omarchy-shell.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string pluginId: manifest && manifest.id
    ? String(manifest.id) : "felipe.oma-quick-plugin-tui"
  readonly property string homeDir: Quickshell.env("HOME")
  readonly property string dataHome: Quickshell.env("XDG_DATA_HOME") || homeDir + "/.local/share"
  readonly property string desktopPath: dataHome + "/applications/" + pluginId + ".desktop"
  readonly property string shellConfigPath: homeDir + "/.config/omarchy/shell.json"
  readonly property string marker: "X-Oma-Quick-Plugin-TUI-Managed=true"

  // Omarchy 4.0.3 strips __sourceDir from the manifest handed to third-party
  // plugins, so derive the plugin directory from this file's own URL. Works
  // for git installs, file:// installs and a symlinked dev checkout alike.
  readonly property string sourceDir: {
    var dir = localPath(Qt.resolvedUrl("."))
    return dir.charAt(dir.length - 1) === "/" ? dir.slice(0, -1) : dir
  }
  readonly property string desktopSourcePath: sourceDir + "/assets/oma-quick-plugin-tui.desktop"

  // bash <script> <source> <target> <plugin-dir> <marker>: substitute
  // @PLUGIN_DIR@ and replace the launcher atomically. Refuses to touch a file
  // we did not write. Everything variable arrives as argv, never spliced into
  // the script text.
  readonly property string installScript: [
    "set -euo pipefail",
    "source_file=$1; target=$2; plugin_dir=$3; marker=$4",
    "if [[ -L \"$target\" || (-e \"$target\" && ! -f \"$target\") ]]; then",
    "  printf 'Oma Quick Plugin TUI: refusing to replace non-regular launcher: %s\\n' \"$target\" >&2; exit 1",
    "fi",
    "if [[ -f \"$target\" ]] && ! grep -Fqx -- \"$marker\" \"$target\"; then",
    "  printf 'Oma Quick Plugin TUI: refusing to replace an unowned launcher: %s\\n' \"$target\" >&2; exit 1",
    "fi",
    // The template wraps @PLUGIN_DIR@ in double quotes on the Exec= line, so
    // escape the directory for a quoted desktop-entry argument. Two layers
    // apply: the entry's string escaping (\\ -> \) runs before the Exec
    // quoting rule, so a literal backslash, double quote, backtick or dollar
    // needs "\\" in front of it in the file (the spec's own "\\\\" example),
    // and a lone % introduces a field code, so it becomes %%.
    "esc=${plugin_dir//\\\\/\\\\\\\\\\\\\\\\}",
    "esc=${esc//\\\"/\\\\\\\\\\\"}",
    "esc=${esc//\\`/\\\\\\\\\\`}",
    "esc=${esc//\\$/\\\\\\\\\\$}",
    "esc=${esc//%/%%}",
    "mkdir -p -- \"$(dirname -- \"$target\")\"",
    "tmp=$(mktemp -- \"${target}.tmp.XXXXXX\")",
    "trap 'rm -f -- \"$tmp\"' EXIT",
    "while IFS= read -r line || [[ -n $line ]]; do",
    "  printf '%s\\n' \"${line//@PLUGIN_DIR@/\"$esc\"}\"",
    "done <\"$source_file\" >\"$tmp\"",
    "chmod 0644 -- \"$tmp\"",
    "mv -f -- \"$tmp\" \"$target\"",
    "trap - EXIT"
  ].join("\n")

  // bash <script> <target> <shell.json> <plugin-id> <marker>: remove the
  // launcher unless the plugin is still enabled (a third-party plugin is
  // enabled iff its id is listed in shell.json plugins[]), so a plugin reload
  // keeps it and disable/remove drops it.
  readonly property string cleanupScript: [
    "set -euo pipefail",
    "target=$1; config=$2; plugin_id=$3; marker=$4",
    "sleep 0.1",
    "[[ -f \"$target\" && ! -L \"$target\" ]] || exit 0",
    "grep -Fqx -- \"$marker\" \"$target\" || exit 0",
    "if [[ -e \"$config\" ]]; then",
    "  command -v jq >/dev/null 2>&1 || exit 0",
    "  jq -e . \"$config\" >/dev/null 2>&1 || exit 0",
    "  jq -e --arg id \"$plugin_id\" 'any((.plugins // [])[]; (.id // \"\") == $id)' \"$config\" >/dev/null 2>&1 && exit 0",
    "fi",
    "rm -f -- \"$target\""
  ].join("\n")

  function localPath(url) {
    var value = String(url || "")
    if (value.indexOf("file://") === 0) value = value.slice(7)
    try {
      return decodeURIComponent(value)
    } catch (error) {
      return value
    }
  }

  function installLauncher() {
    if (!sourceDir || launcherInstaller.running) return
    launcherInstaller.command = [
      "bash", "-c", installScript, "oma-quick-plugin-tui-launcher-install",
      desktopSourcePath, desktopPath, sourceDir, marker
    ]
    launcherInstaller.running = true
  }

  Process {
    id: launcherInstaller

    stderr: StdioCollector {
      id: launcherStderr
      waitForEnd: true
    }

    onExited: function(exitCode) {
      if (exitCode !== 0)
        console.warn("Oma Quick Plugin TUI: could not install app launcher:",
          launcherStderr.text.trim())
    }
  }

  Component.onCompleted: installLauncher()

  Component.onDestruction: {
    Quickshell.execDetached([
      "bash", "-c", cleanupScript, "oma-quick-plugin-tui-launcher-cleanup",
      desktopPath, shellConfigPath, pluginId, marker
    ])
  }
}
