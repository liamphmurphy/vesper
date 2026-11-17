import fs from "node:fs";
import os from "node:os";
import path from "node:path";

/**
 * "Send to Vesper" in Finder's Quick Actions and the Services menu
 * (LAZYAGENTS-247).
 *
 * Electron can't register an NSServices provider (that needs an
 * NSApplication servicesProvider in native code), so Vesper installs two
 * Automator Quick Actions into ~/Library/Services instead. Both hand the
 * files to Vesper with `open -a`, which arrives as app `open-file`, the same
 * path as a Dock drop. Selected text is first written to a temporary .txt file.
 * Nothing is put into a URL.
 */

export const SERVICE_FILES_NAME = "Send to Vesper";
export const SERVICE_TEXT_NAME = "Send Text to Vesper";

function xmlEscape(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

/** Shell-quotes for a POSIX shell (single quotes). */
export function shQuote(s: string): string {
  return `'${s.replace(/'/g, `'\\''`)}'`;
}

export function filesScript(appPath: string): string {
  return `open -a ${shQuote(appPath)} "$@"\n`;
}

export function textScript(appPath: string): string {
  // mktemp gives a private 0600 file; the .txt name makes it a text attachment.
  return [
    'dir="$(mktemp -d -t vesper-text)" || exit 1',
    'f="$dir/Selected text.txt"',
    'cat > "$f"',
    '[ -s "$f" ] || exit 0',
    `open -a ${shQuote(appPath)} "$f"`,
    "",
  ].join("\n");
}

interface WorkflowSpec {
  name: string;
  script: string;
  /** 0: stdin (text), 1: as arguments (files). */
  inputMethod: 0 | 1;
  /** Automator service input type. */
  inputType: "com.apple.Automator.fileSystemObject" | "com.apple.Automator.text";
  sendTypes: { files?: string[]; pasteboard?: string[] };
}

export function infoPlist(spec: WorkflowSpec): string {
  const sendFileTypes = spec.sendTypes.files
    ? `\t\t\t<key>NSSendFileTypes</key>\n\t\t\t<array>\n${spec.sendTypes.files.map((t) => `\t\t\t\t<string>${xmlEscape(t)}</string>`).join("\n")}\n\t\t\t</array>\n`
    : "";
  const sendTypes = spec.sendTypes.pasteboard
    ? `\t\t\t<key>NSSendTypes</key>\n\t\t\t<array>\n${spec.sendTypes.pasteboard.map((t) => `\t\t\t\t<string>${xmlEscape(t)}</string>`).join("\n")}\n\t\t\t</array>\n`
    : "";
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>NSServices</key>
\t<array>
\t\t<dict>
\t\t\t<key>NSMenuItem</key>
\t\t\t<dict>
\t\t\t\t<key>default</key>
\t\t\t\t<string>${xmlEscape(spec.name)}</string>
\t\t\t</dict>
\t\t\t<key>NSMessage</key>
\t\t\t<string>runWorkflowAsService</string>
${sendFileTypes}${sendTypes}\t\t</dict>
\t</array>
</dict>
</plist>
`;
}

export function documentWflow(spec: WorkflowSpec): string {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>AMApplicationBuild</key>
\t<string>523</string>
\t<key>AMApplicationVersion</key>
\t<string>2.10</string>
\t<key>AMDocumentVersion</key>
\t<string>2</string>
\t<key>actions</key>
\t<array>
\t\t<dict>
\t\t\t<key>action</key>
\t\t\t<dict>
\t\t\t\t<key>AMAccepts</key>
\t\t\t\t<dict>
\t\t\t\t\t<key>Container</key>
\t\t\t\t\t<string>List</string>
\t\t\t\t\t<key>Optional</key>
\t\t\t\t\t<true/>
\t\t\t\t\t<key>Types</key>
\t\t\t\t\t<array>
\t\t\t\t\t\t<string>com.apple.cocoa.string</string>
\t\t\t\t\t</array>
\t\t\t\t</dict>
\t\t\t\t<key>AMActionVersion</key>
\t\t\t\t<string>2.0.3</string>
\t\t\t\t<key>AMApplication</key>
\t\t\t\t<array>
\t\t\t\t\t<string>Automator</string>
\t\t\t\t</array>
\t\t\t\t<key>AMParameterProperties</key>
\t\t\t\t<dict>
\t\t\t\t\t<key>COMMAND_STRING</key>
\t\t\t\t\t<dict/>
\t\t\t\t\t<key>CheckedForUserDefaultShell</key>
\t\t\t\t\t<dict/>
\t\t\t\t\t<key>inputMethod</key>
\t\t\t\t\t<dict/>
\t\t\t\t\t<key>shell</key>
\t\t\t\t\t<dict/>
\t\t\t\t\t<key>source</key>
\t\t\t\t\t<dict/>
\t\t\t\t</dict>
\t\t\t\t<key>AMProvides</key>
\t\t\t\t<dict>
\t\t\t\t\t<key>Container</key>
\t\t\t\t\t<string>List</string>
\t\t\t\t\t<key>Types</key>
\t\t\t\t\t<array>
\t\t\t\t\t\t<string>com.apple.cocoa.string</string>
\t\t\t\t\t</array>
\t\t\t\t</dict>
\t\t\t\t<key>ActionBundlePath</key>
\t\t\t\t<string>/System/Library/Automator/Run Shell Script.action</string>
\t\t\t\t<key>ActionName</key>
\t\t\t\t<string>Run Shell Script</string>
\t\t\t\t<key>ActionParameters</key>
\t\t\t\t<dict>
\t\t\t\t\t<key>COMMAND_STRING</key>
\t\t\t\t\t<string>${xmlEscape(spec.script)}</string>
\t\t\t\t\t<key>CheckedForUserDefaultShell</key>
\t\t\t\t\t<true/>
\t\t\t\t\t<key>inputMethod</key>
\t\t\t\t\t<integer>${spec.inputMethod}</integer>
\t\t\t\t\t<key>shell</key>
\t\t\t\t\t<string>/bin/zsh</string>
\t\t\t\t\t<key>source</key>
\t\t\t\t\t<string></string>
\t\t\t\t</dict>
\t\t\t\t<key>BundleIdentifier</key>
\t\t\t\t<string>com.apple.RunShellScript</string>
\t\t\t\t<key>CFBundleVersion</key>
\t\t\t\t<string>2.0.3</string>
\t\t\t\t<key>CanShowSelectedItemsWhenRun</key>
\t\t\t\t<false/>
\t\t\t\t<key>CanShowWhenRun</key>
\t\t\t\t<true/>
\t\t\t\t<key>Category</key>
\t\t\t\t<array>
\t\t\t\t\t<string>AMCategoryUtilities</string>
\t\t\t\t</array>
\t\t\t\t<key>Class Name</key>
\t\t\t\t<string>RunShellScriptAction</string>
\t\t\t\t<key>InputUUID</key>
\t\t\t\t<string>7C2E7C5A-1D3F-4C3B-9D5E-1A2B3C4D5E6F</string>
\t\t\t\t<key>Keywords</key>
\t\t\t\t<array>
\t\t\t\t\t<string>Shell</string>
\t\t\t\t\t<string>Script</string>
\t\t\t\t</array>
\t\t\t\t<key>OutputUUID</key>
\t\t\t\t<string>8D3F8D6B-2E4A-4D4C-AE6F-2B3C4D5E6F70</string>
\t\t\t\t<key>UUID</key>
\t\t\t\t<string>9E4A9E7C-3F5B-4E5D-BF70-3C4D5E6F7081</string>
\t\t\t\t<key>UnlocalizedApplications</key>
\t\t\t\t<array>
\t\t\t\t\t<string>Automator</string>
\t\t\t\t</array>
\t\t\t\t<key>arguments</key>
\t\t\t\t<dict/>
\t\t\t\t<key>isViewVisible</key>
\t\t\t\t<integer>1</integer>
\t\t\t</dict>
\t\t\t<key>isViewVisible</key>
\t\t\t<integer>1</integer>
\t\t</dict>
\t</array>
\t<key>connectors</key>
\t<dict/>
\t<key>workflowMetaData</key>
\t<dict>
\t\t<key>applicationBundleIDsByPath</key>
\t\t<dict/>
\t\t<key>applicationPaths</key>
\t\t<array/>
\t\t<key>inputTypeIdentifier</key>
\t\t<string>${spec.inputType}</string>
\t\t<key>outputTypeIdentifier</key>
\t\t<string>com.apple.Automator.nothing</string>
\t\t<key>presentationMode</key>
\t\t<integer>15</integer>
\t\t<key>processesInput</key>
\t\t<false/>
\t\t<key>serviceInputTypeIdentifier</key>
\t\t<string>${spec.inputType}</string>
\t\t<key>serviceOutputTypeIdentifier</key>
\t\t<string>com.apple.Automator.nothing</string>
\t\t<key>serviceProcessesInput</key>
\t\t<false/>
\t\t<key>systemImageName</key>
\t\t<string>NSActionTemplate</string>
\t\t<key>useAutomaticInputType</key>
\t\t<false/>
\t\t<key>workflowTypeIdentifier</key>
\t\t<string>com.apple.Automator.servicesMenu</string>
\t</dict>
</dict>
</plist>
`;
}

export function serviceSpecs(appPath: string): WorkflowSpec[] {
  return [
    {
      name: SERVICE_FILES_NAME,
      script: filesScript(appPath),
      inputMethod: 1,
      inputType: "com.apple.Automator.fileSystemObject",
      sendTypes: { files: ["public.item"] },
    },
    {
      name: SERVICE_TEXT_NAME,
      script: textScript(appPath),
      inputMethod: 0,
      inputType: "com.apple.Automator.text",
      sendTypes: { pasteboard: ["NSStringPboardType", "public.utf8-plain-text"] },
    },
  ];
}

export function servicesDir(home = os.homedir()): string {
  return path.join(home, "Library", "Services");
}

/** Writes both Quick Actions; returns the bundle paths. Replaces earlier copies. */
export function installServices(appPath: string, dir = servicesDir()): string[] {
  const written: string[] = [];
  for (const spec of serviceSpecs(appPath)) {
    const bundle = path.join(dir, `${spec.name}.workflow`);
    const contents = path.join(bundle, "Contents");
    fs.rmSync(bundle, { recursive: true, force: true });
    fs.mkdirSync(contents, { recursive: true });
    fs.writeFileSync(path.join(contents, "Info.plist"), infoPlist(spec), "utf8");
    fs.writeFileSync(path.join(contents, "document.wflow"), documentWflow(spec), "utf8");
    written.push(bundle);
  }
  return written;
}

export function uninstallServices(dir = servicesDir()): void {
  for (const name of [SERVICE_FILES_NAME, SERVICE_TEXT_NAME]) {
    fs.rmSync(path.join(dir, `${name}.workflow`), { recursive: true, force: true });
  }
}

export function servicesInstalled(dir = servicesDir()): boolean {
  return [SERVICE_FILES_NAME, SERVICE_TEXT_NAME].every((name) =>
    fs.existsSync(path.join(dir, `${name}.workflow`, "Contents", "document.wflow")),
  );
}

/**
 * The .app bundle path containing this executable
 * (/Applications/Vesper.app/Contents/MacOS/Vesper → /Applications/Vesper.app), or null in dev.
 */
export function appBundlePath(execPath: string): string | null {
  const m = /^(.*?\.app)\/Contents\/MacOS\/[^/]+$/.exec(execPath);
  return m ? m[1] : null;
}
