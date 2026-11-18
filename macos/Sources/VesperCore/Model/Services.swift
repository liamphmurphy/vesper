import Foundation

// Port of desktop/src/services.ts: "Send to Vesper" and "Send Text to Vesper" as Automator Quick
// Actions in ~/Library/Services. Both hand files to Vesper with `open -a`, which arrives as an
// open-files event, the same path as a Dock drop. Selected text is first written to a temporary
// .txt file. Nothing is put into a URL. Nothing here touches ~/Library/Services unless `install`
// is called with that directory; tests pass a scratch directory.

public enum QuickActions {
    public static let filesName = "Send to Vesper"
    public static let textName = "Send Text to Vesper"

    public struct Spec: Sendable, Equatable {
        public var name: String
        public var script: String
        /// 0: stdin (text), 1: as arguments (files).
        public var inputMethod: Int
        public var inputType: String
        public var sendFileTypes: [String]
        public var sendTypes: [String]
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Single-quotes for a POSIX shell.
    public static func shQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    public static func filesScript(appPath: String) -> String { "open -a \(shQuote(appPath)) \"$@\"\n" }

    public static func textScript(appPath: String) -> String {
        // mktemp gives a private 0600 file; the .txt name makes it a text attachment.
        [
            "dir=\"$(mktemp -d -t vesper-text)\" || exit 1",
            "f=\"$dir/Selected text.txt\"",
            "cat > \"$f\"",
            "[ -s \"$f\" ] || exit 0",
            "open -a \(shQuote(appPath)) \"$f\"",
            "",
        ].joined(separator: "\n")
    }

    public static func specs(appPath: String) -> [Spec] {
        [
            Spec(name: filesName, script: filesScript(appPath: appPath), inputMethod: 1,
                 inputType: "com.apple.Automator.fileSystemObject", sendFileTypes: ["public.item"], sendTypes: []),
            Spec(name: textName, script: textScript(appPath: appPath), inputMethod: 0,
                 inputType: "com.apple.Automator.text", sendFileTypes: [],
                 sendTypes: ["NSStringPboardType", "public.utf8-plain-text"]),
        ]
    }

    public static func infoPlist(_ spec: Spec) -> String {
        func array(_ key: String, _ values: [String]) -> String {
            guard !values.isEmpty else { return "" }
            let items = values.map { "\t\t\t\t<string>\(xmlEscape($0))</string>" }.joined(separator: "\n")
            return "\t\t\t<key>\(key)</key>\n\t\t\t<array>\n\(items)\n\t\t\t</array>\n"
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>NSServices</key>
        \t<array>
        \t\t<dict>
        \t\t\t<key>NSMenuItem</key>
        \t\t\t<dict>
        \t\t\t\t<key>default</key>
        \t\t\t\t<string>\(xmlEscape(spec.name))</string>
        \t\t\t</dict>
        \t\t\t<key>NSMessage</key>
        \t\t\t<string>runWorkflowAsService</string>
        \(array("NSSendFileTypes", spec.sendFileTypes))\(array("NSSendTypes", spec.sendTypes))\t\t</dict>
        \t</array>
        </dict>
        </plist>

        """
    }

    public static func documentWflow(_ spec: Spec) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
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
        \t\t\t\t\t<string>\(xmlEscape(spec.script))</string>
        \t\t\t\t\t<key>CheckedForUserDefaultShell</key>
        \t\t\t\t\t<true/>
        \t\t\t\t\t<key>inputMethod</key>
        \t\t\t\t\t<integer>\(spec.inputMethod)</integer>
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
        \t\t<string>\(spec.inputType)</string>
        \t\t<key>outputTypeIdentifier</key>
        \t\t<string>com.apple.Automator.nothing</string>
        \t\t<key>presentationMode</key>
        \t\t<integer>15</integer>
        \t\t<key>processesInput</key>
        \t\t<false/>
        \t\t<key>serviceInputTypeIdentifier</key>
        \t\t<string>\(spec.inputType)</string>
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

        """
    }

    /// ~/Library/Services
    public static func servicesDirectory(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Services", isDirectory: true)
    }

    /// Writes both Quick Actions into `directory`, replacing earlier copies. Returns the bundle paths.
    @discardableResult
    public static func install(appPath: String, into directory: URL) throws -> [URL] {
        let fm = FileManager.default
        var written: [URL] = []
        for spec in specs(appPath: appPath) {
            let bundle = directory.appendingPathComponent("\(spec.name).workflow", isDirectory: true)
            let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
            try? fm.removeItem(at: bundle)
            try fm.createDirectory(at: contents, withIntermediateDirectories: true)
            try infoPlist(spec).write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
            try documentWflow(spec).write(to: contents.appendingPathComponent("document.wflow"), atomically: true, encoding: .utf8)
            written.append(bundle)
        }
        return written
    }

    public static func uninstall(from directory: URL) {
        for name in [filesName, textName] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(name).workflow"))
        }
    }

    public static func isInstalled(in directory: URL) -> Bool {
        [filesName, textName].allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("\($0).workflow/Contents/document.wflow").path)
        }
    }

    /// The .app bundle containing an executable (/Applications/Vesper.app/Contents/MacOS/Vesper →
    /// /Applications/Vesper.app), or nil when it isn't inside one (a dev build).
    public static func appBundlePath(executablePath: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"^(.*?\.app)/Contents/MacOS/[^/]+\z"#),
              let m = re.firstMatch(in: executablePath, range: NSRange(executablePath.startIndex..., in: executablePath)),
              let r = Range(m.range(at: 1), in: executablePath)
        else { return nil }
        return String(executablePath[r])
    }
}
