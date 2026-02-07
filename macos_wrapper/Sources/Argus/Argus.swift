import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct Argus: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)

        Settings {
            SettingsView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsLink()
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct ContentView: View {
    @AppStorage("clinePath") private var clinePath: String = ""
    @AppStorage("clineConfigPath") private var clineConfigPath: String = ""
    @State private var prompt: String = ""
    @State private var images: [URL] = []
    @State private var output: String = ""
    @State private var isRunning: Bool = false
    @State private var errorText: String? = nil
    @State private var statusText: String = ""
    @State private var isTargeted: Bool = false
    @State private var process: Process? = nil
    @State private var timeoutWorkItem: DispatchWorkItem? = nil
    @State private var logText: String = ""
    @State private var showLogs: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Cline Image Assistant")
                .font(.title2)

            VStack(alignment: .leading, spacing: 8) {
                Text("Images")
                    .font(.headline)

                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isTargeted ? Color.accentColor : Color.gray.opacity(0.4), lineWidth: 2)
                        .background(Color.gray.opacity(0.05))
                        .frame(height: 140)

                    VStack(spacing: 8) {
                        Text(images.isEmpty ? "Drag & drop images here" : "Drop more images to add")
                            .foregroundColor(.secondary)

                        HStack(spacing: 12) {
                            Button("+") { selectImages() }
                                .buttonStyle(.bordered)
                            Button("Clear") { images.removeAll() }
                                .buttonStyle(.bordered)
                                .disabled(images.isEmpty)
                        }
                    }
                }
                .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted, perform: handleDrop(providers:))

                if !images.isEmpty {
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(spacing: 12) {
                            ForEach(images, id: \.self) { url in
                                HStack(spacing: 6) {
                                    Image(systemName: "photo")
                                    Text(url.lastPathComponent)
                                        .lineLimit(1)
                                }
                                .padding(6)
                                .background(Color.gray.opacity(0.15))
                                .cornerRadius(8)
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("What do you want to do?")
                    .font(.headline)
                TextField("e.g. log a TODO item", text: $prompt)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 12) {
                Button(isRunning ? "Running…" : "Run") {
                    runCline()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning || images.isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Cancel") {
                    process?.terminate()
                }
                .buttonStyle(.bordered)
                .disabled(!isRunning)

                Button("Copy Output") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output, forType: .string)
                }
                .buttonStyle(.bordered)
                .disabled(output.isEmpty)

                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.bordered)

                Button("Logs") {
                    showLogs = true
                }
                .buttonStyle(.bordered)
                .disabled(logText.isEmpty)
            }

            if let errorText {
                Text(errorText)
                    .foregroundColor(.red)
            }
            if !statusText.isEmpty {
                Text(statusText)
                    .foregroundColor(.secondary)
                    .font(.footnote)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Output")
                    .font(.headline)

                TextEditor(text: $output)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 200)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
            }

            Spacer()
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 600)
        .sheet(isPresented: $showLogs) {
            LogView(logText: logText)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data else { return }
                let url = URL(dataRepresentation: data, relativeTo: nil)
                guard let url else { return }
                if isImage(url: url) {
                    DispatchQueue.main.async {
                        if !images.contains(url) {
                            images.append(url)
                        }
                    }
                }
            }
        }
        return true
    }

    private func selectImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.begin { response in
            if response == .OK {
                let urls = panel.urls
                for url in urls where isImage(url: url) {
                    if !images.contains(url) {
                        images.append(url)
                    }
                }
            }
        }
    }

    private func runCline() {
        errorText = nil
        output = ""
        statusText = "Starting…"
        logText = ""

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPrompt.isEmpty {
            errorText = "Please enter a prompt."
            return
        }

        if images.isEmpty {
            errorText = "Please add at least one image."
            return
        }

        let workspace: URL
        let imageNames: [String]
        do {
            let prepared = try prepareClineWorkspace(for: images)
            workspace = prepared.workspace
            imageNames = prepared.imageNames
        } catch {
            errorText = "Failed to stage images for Cline: \(error.localizedDescription)"
            return
        }

        let fullPrompt = buildPrompt(prompt: trimmedPrompt, imageNames: imageNames)

        guard let clineURL = resolveClineExecutable() else {
            errorText = "Could not find the 'cline' executable. Set CLINE_BIN or install cline on PATH."
            return
        }

        let process = Process()
        process.executableURL = clineURL
        process.currentDirectoryURL = workspace
        var args = ["--json", "--act", "--timeout", "180"]
        args += ["--cwd", workspace.path]
        if !clineConfigPath.isEmpty {
            args += ["--config", clineConfigPath]
        }
        args.append(fullPrompt)
        process.arguments = args

        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["HOME"] = home
        env["USER"] = NSUserName()
        env["LOGNAME"] = NSUserName()
        if env["CLINE_PATCH_UPTIME"] == nil {
            env["CLINE_PATCH_UPTIME"] = "1"
        }
        // Ensure Node is discoverable for the cline shebang (/usr/bin/env node)
        let clineDir = clineURL.deletingLastPathComponent().path
        let existingPath = env["PATH"] ?? ""
        if !existingPath.split(separator: ":").contains(Substring(clineDir)) {
            env["PATH"] = clineDir + ":" + existingPath
        }
        applyNodePatch(to: &env)
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let parser = ClineJSONStreamParser(
            onText: { text in
                DispatchQueue.main.async {
                    output = text
                    statusText = "Completed"
                }
            },
            onStatus: { status in
                DispatchQueue.main.async {
                    statusText = status
                }
            },
            onError: { message in
                DispatchQueue.main.async {
                    errorText = message
                    statusText = "Error"
                }
            },
            onLog: { line in
                DispatchQueue.main.async {
                    logText += line
                }
            }
        )

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                parser.consume(data)
            }
        }

        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let msg = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    errorText = msg.trimmingCharacters(in: .whitespacesAndNewlines)
                    logText += msg
                }
            }
        }

        process.terminationHandler = { _ in
            DispatchQueue.main.async {
                isRunning = false
                self.process = nil
                timeoutWorkItem?.cancel()
                timeoutWorkItem = nil
                if output.isEmpty, errorText == nil {
                    errorText = "No output received from Cline."
                }
            }
            try? FileManager.default.removeItem(at: workspace)
        }

        do {
            try process.run()
            self.process = process
            isRunning = true
            let workItem = DispatchWorkItem {
                if isRunning {
                    process.terminate()
                    errorText = "Timed out waiting for Cline."
                    isRunning = false
                }
            }
            timeoutWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 180, execute: workItem)
        } catch {
            errorText = "Failed to start Cline: \(error.localizedDescription)"
        }
    }

    private func buildPrompt(prompt: String, imageNames: [String]) -> String {
        var lines: [String] = [prompt]
        for name in imageNames {
            let marker = "@\(name)"
            if !prompt.contains(marker) {
                lines.append(marker)
            }
        }
        return lines.joined(separator: "\n")
    }

    private func prepareClineWorkspace(for images: [URL]) throws -> (workspace: URL, imageNames: [String]) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("argus-cline", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)

        var names: [String] = []
        for (index, url) in images.enumerated() {
            let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
            let name = "image-\(index + 1).\(ext)"
            let dest = workspace.appendingPathComponent(name)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: url, to: dest)
            names.append(name)
        }
        return (workspace, names)
    }

    private func isImage(url: URL) -> Bool {
        if let type = UTType(filenameExtension: url.pathExtension.lowercased()) {
            return type.conforms(to: .image)
        }
        return false
    }

    private func resolveClineExecutable() -> URL? {
        let fm = FileManager.default
        if !clinePath.isEmpty, fm.isExecutableFile(atPath: clinePath) {
            return URL(fileURLWithPath: clinePath)
        }

        if let envPath = ProcessInfo.processInfo.environment["CLINE_BIN"], fm.isExecutableFile(atPath: envPath) {
            return URL(fileURLWithPath: envPath)
        }

        let candidates = [
            "/usr/local/bin/cline",
            "/opt/homebrew/bin/cline",
            "/usr/bin/cline",
        ]

        for path in candidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        // Check nvm-managed installs
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let nvmDir = home + "/.nvm/versions/node"
        if let entries = try? fm.contentsOfDirectory(atPath: nvmDir) {
            let sorted = entries.sorted()
            for entry in sorted.reversed() {
                let candidate = nvmDir + "/" + entry + "/bin/cline"
                if fm.isExecutableFile(atPath: candidate) {
                    return URL(fileURLWithPath: candidate)
                }
            }
        }

        return nil
    }

}

private func applyNodePatch(to env: inout [String: String]) {
    if env["CLINE_PATCH_UPTIME"] == "0" {
        return
    }
    guard let patchURL = Bundle.main.url(forResource: "patch_uptime", withExtension: "js") else {
        return
    }
    let requireFlag = "--require \(patchURL.path)"
    let existing = env["NODE_OPTIONS"] ?? ""
    if !existing.contains(requireFlag) {
        env["NODE_OPTIONS"] = (existing + " " + requireFlag).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private func extractClineText(from output: String) -> String? {
    var lastText: String? = nil
    let excludeSay = Set(["task", "api_req_started", "api_req_finished"])
    for line in output.split(separator: "\n") {
        guard let data = String(line).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { continue }

        guard let type = obj["type"] as? String, type == "say" else { continue }
        if let partial = obj["partial"] as? Bool, partial { continue }
        if let say = obj["say"] as? String, excludeSay.contains(say) { continue }
        if let text = obj["text"] as? String, !text.contains("<task>") {
            lastText = text
        }
    }
    return lastText
}

final class ClineJSONStreamParser {
    private var buffer = Data()
    private let onText: (String) -> Void
    private let onStatus: (String) -> Void
    private let onError: (String) -> Void
    private let onLog: (String) -> Void

    init(
        onText: @escaping (String) -> Void,
        onStatus: @escaping (String) -> Void,
        onError: @escaping (String) -> Void,
        onLog: @escaping (String) -> Void
    ) {
        self.onText = onText
        self.onStatus = onStatus
        self.onError = onError
        self.onLog = onLog
    }

    func consume(_ data: Data) {
        buffer.append(data)
        while let range = buffer.range(of: Data([0x0A])) {
            let line = buffer.subdata(in: 0..<range.lowerBound)
            buffer.removeSubrange(0..<range.upperBound)
            parse(line)
        }
    }

    private func parse(_ line: Data) {
        guard let str = String(data: line, encoding: .utf8) else { return }
        onLog(str + "\n")
        guard let obj = try? JSONSerialization.jsonObject(with: Data(str.utf8)) as? [String: Any] else { return }
        guard let type = obj["type"] as? String else { return }
        if type == "error" {
            if let message = obj["message"] as? String, !message.isEmpty {
                onError(message)
                return
            }
            if let message = obj["error"] as? String, !message.isEmpty {
                onError(message)
                return
            }
            onError("Cline reported an error.")
            return
        }
        guard type == "say" else { return }
        if let partial = obj["partial"] as? Bool, partial { return }
        if let say = obj["say"] as? String {
            if say == "task" {
                onStatus("Cline accepted task…")
                return
            }
            if say == "api_req_started" {
                onStatus("Cline requesting model…")
                return
            }
            if say == "api_req_finished" {
                onStatus("Cline processing response…")
                return
            }
        }
        guard let text = obj["text"] as? String else { return }
        if text.contains("<task>") { return }
        onText(text)
    }
}

struct SettingsView: View {
    @AppStorage("clinePath") private var clinePath: String = ""
    @AppStorage("clineConfigPath") private var clineConfigPath: String = ""
    @State private var testStatus: String = ""
    @State private var isTesting: Bool = false
    @AppStorage("helloPrompt") private var helloPrompt: String = "hello"
    @State private var helloTimeoutWorkItem: DispatchWorkItem? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings")
                .font(.title2)

            VStack(alignment: .leading, spacing: 8) {
                Text("Cline Executable")
                    .font(.headline)
                TextField("/path/to/cline", text: $clinePath)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 12) {
                    Button("Choose…") {
                        pickClinePath()
                    }
                    .buttonStyle(.bordered)

                    Button("Clear") {
                        clinePath = ""
                    }
                    .buttonStyle(.bordered)
                    .disabled(clinePath.isEmpty)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Cline Config Dir (optional)")
                        .font(.headline)
                    TextField("/path/to/config", text: $clineConfigPath)
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: 12) {
                        Button("Choose…") {
                            pickConfigDir()
                        }
                        .buttonStyle(.bordered)
                        Button("Clear") {
                            clineConfigPath = ""
                        }
                        .buttonStyle(.bordered)
                        .disabled(clineConfigPath.isEmpty)
                    }
                }

                HStack(spacing: 12) {
                    Button(isTesting ? "Testing…" : "Test Cline") {
                        testCline()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isTesting)

                    if !testStatus.isEmpty {
                        Text(testStatus)
                            .foregroundColor(testStatus.hasPrefix("OK") ? .green : .red)
                            .font(.footnote)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Hello Prompt")
                        .font(.headline)
                    TextField("hello", text: $helloPrompt)
                        .textFieldStyle(.roundedBorder)
                    Button("Run Hello Prompt") {
                        runHelloPrompt()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isTesting)
                }

                Text("Tip: if you use nvm, the path usually looks like ~/.nvm/versions/node/<version>/bin/cline")
                    .foregroundColor(.secondary)
                    .font(.footnote)

                Button("Open Cline Logs Folder") {
                    openLogsFolder()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func pickClinePath() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                clinePath = url.path
            }
        }
    }

    private func testCline() {
        testStatus = ""
        isTesting = true

        let path = clinePath.isEmpty ? "cline" : clinePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var args = ["--version"]
        if !clineConfigPath.isEmpty {
            args = ["--config", clineConfigPath] + args
        }
        process.arguments = args

        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["HOME"] = home
        env["USER"] = NSUserName()
        env["LOGNAME"] = NSUserName()
        if !clinePath.isEmpty {
            let clineDir = URL(fileURLWithPath: clinePath).deletingLastPathComponent().path
            let existingPath = env["PATH"] ?? ""
            if !existingPath.split(separator: ":").contains(Substring(clineDir)) {
                env["PATH"] = clineDir + ":" + existingPath
            }
        }
        applyNodePatch(to: &env)
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        process.terminationHandler = { _ in
            DispatchQueue.main.async {
                isTesting = false
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: outData, encoding: .utf8) ?? ""
                let err = String(data: errData, encoding: .utf8) ?? ""

                if !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    testStatus = "OK: " + out.trimmingCharacters(in: .whitespacesAndNewlines)
                } else if !err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    testStatus = "ERR: " + err.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    testStatus = "ERR: No output"
                }
            }
        }

        do {
            try process.run()
        } catch {
            isTesting = false
            testStatus = "ERR: " + error.localizedDescription
        }
    }

    private func runHelloPrompt() {
        testStatus = "Running…"
        isTesting = true
        helloTimeoutWorkItem?.cancel()
        helloTimeoutWorkItem = nil

        let path = clinePath.isEmpty ? "cline" : clinePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var args = ["--json", "--act", "--timeout", "60", helloPrompt]
        if !clineConfigPath.isEmpty {
            args = ["--config", clineConfigPath] + args
        }
        process.arguments = args

        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["HOME"] = home
        env["USER"] = NSUserName()
        env["LOGNAME"] = NSUserName()
        if !clinePath.isEmpty {
            let clineDir = URL(fileURLWithPath: clinePath).deletingLastPathComponent().path
            let existingPath = env["PATH"] ?? ""
            if !existingPath.split(separator: ":").contains(Substring(clineDir)) {
                env["PATH"] = clineDir + ":" + existingPath
            }
        }
        applyNodePatch(to: &env)
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        process.terminationHandler = { _ in
            DispatchQueue.main.async {
                isTesting = false
                helloTimeoutWorkItem?.cancel()
                helloTimeoutWorkItem = nil
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: outData, encoding: .utf8) ?? ""
                let err = String(data: errData, encoding: .utf8) ?? ""

                if let extracted = extractClineText(from: out), !extracted.isEmpty {
                    testStatus = "OK: " + extracted
                } else if !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    testStatus = "OK: " + out.trimmingCharacters(in: .whitespacesAndNewlines)
                } else if !err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    testStatus = "ERR: " + err.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    testStatus = "ERR: No output"
                }
            }
        }

        do {
            try process.run()
            let workItem = DispatchWorkItem {
                process.terminate()
                DispatchQueue.main.async {
                    isTesting = false
                    testStatus = "ERR: Timed out waiting for Cline."
                }
            }
            helloTimeoutWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: workItem)
        } catch {
            isTesting = false
            testStatus = "ERR: " + error.localizedDescription
        }
    }

    private func pickConfigDir() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                clineConfigPath = url.path
            }
        }
    }

    private func openLogsFolder() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let base = clineConfigPath.isEmpty ? home + "/.cline" : clineConfigPath
        let logs = base + "/data/logs"
        NSWorkspace.shared.open(URL(fileURLWithPath: logs))
    }
}

struct LogView: View {
    let logText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Logs")
                .font(.title2)
            TextEditor(text: .constant(logText))
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 400)
            HStack {
                Button("Copy Logs") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(logText, forType: .string)
                }
                .buttonStyle(.bordered)
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 720, height: 520)
    }
}
