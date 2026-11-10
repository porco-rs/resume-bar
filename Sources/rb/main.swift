import Darwin
import Foundation
import RBContract

signal(SIGPIPE, SIG_IGN)

func copy(_ key: String) -> String { RBCopy.active[key] ?? key }
let help = copy("rb.help")
func fail(_ text: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data((text + "\n").utf8)); exit(code)
}
let args = Array(CommandLine.arguments.dropFirst())
if args == ["--help"] || args == ["-h"] { print(help); exit(0) }
guard let command = args.first, ["ls", "add", "start", "done", "bis", "due", "export"].contains(command) else { fail(help, 2) }
var index = 1, all = false, cc = false, project: String?, deadline: String?, positional: [String] = []
while index < args.count {
    let arg = args[index]; index += 1
    switch arg {
    case "-a" where command == "ls" && !all: all = true
    case "--cc" where command == "start" && !cc: cc = true
    case "-p" where command != "export" && project == nil && index < args.count: project = args[index]; index += 1
    case let option where ["--bis", "--by"].contains(option) && command == "add" && deadline == nil && index < args.count: deadline = args[index]; index += 1
    default:
        guard !arg.hasPrefix("-") || (["bis", "due"].contains(command) && arg == "-") else { fail(help, 2) }
        positional.append(arg)
    }
}
let request: RBRequest
switch command {
case "ls" where positional.isEmpty: request = .list(allProjects: all, project: project)
case "add" where positional.count == 1: request = .add(text: positional[0], deadline: deadline, project: project)
case "start" where positional.count == 1: request = .start(query: positional[0], tool: cc ? .claude : nil, project: project)
case "done" where positional.count <= 1: request = .done(query: positional.first, project: project)
case let name where ["bis", "due"].contains(name) && positional.count == 2: request = .setDeadline(query: positional[0], deadline: positional[1] == "-" ? nil : positional[1], project: project)
case "export" where positional.isEmpty: request = .export
default: fail(help, 2)
}
let path = ProcessInfo.processInfo.environment["RB_SOCKET"] ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ResumeBar/rb.sock").path
var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX); addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
let pathBytes = Array(path.utf8)
guard !pathBytes.contains(0), pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { fail(copy("rb.invalidSocket"), 2) }
withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: pathBytes + [0]) }
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
if fd < 0 {
    if errno == EPERM || errno == EACCES { fail(copy("rb.sandbox"), 4) }
    fail(copy("rb.socketFailed"), 3)
}
let connected = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
if connected != 0 {
    switch errno {
    case EPERM, EACCES: fail(copy("rb.sandbox"), 4)
    case ENOENT, ECONNREFUSED: fail(copy("rb.notRunning"), 3)
    default: fail(copy("rb.connectionFailed"), 3)
    }
}
var noSigPipe: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout.size(ofValue: noSigPipe)))
var data = try JSONEncoder().encode(request); data.append(10)
let sent = data.withUnsafeBytes { bytes -> Bool in
    var offset = 0
    while offset < bytes.count { let n = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0); if n <= 0 { return false }; offset += n }
    return true
}
guard sent else { fail(copy("rb.connectionFailed"), 3) }
var response = Data(), buffer = [UInt8](repeating: 0, count: 8192)
var complete = false
while response.count <= RBSocket.maxResponseBytes {
    let count = recv(fd, &buffer, min(buffer.count, RBSocket.maxResponseBytes + 1 - response.count), 0)
    guard count > 0 else { fail(copy("rb.invalidResponse"), 3) }
    if let newline = buffer[..<count].firstIndex(of: 10) {
        response.append(contentsOf: buffer[..<newline]); complete = true; break
    }
    response.append(contentsOf: buffer[..<count])
}
guard complete, response.count <= RBSocket.maxResponseBytes else { fail(copy("rb.invalidResponse"), 3) }
close(fd)
guard let result = try? JSONDecoder().decode(RBResponse.self, from: response) else { fail(copy("rb.invalidResponse"), 3) }
func describe(_ line: RBEntryLine) -> String {
    let glyph = line.sessionCount == 0 ? "◇" : (line.status == .wartet ? "◐" : "●")
    var parts = [glyph + " " + line.title]
    if let project = line.projectName { parts.append(project) }
    if let deadline = line.deadline {
        let input = DateFormatter(); input.locale = Locale(identifier: "en_US_POSIX"); input.timeZone = TimeZone(secondsFromGMT: 0); input.dateFormat = "yyyy-MM-dd"
        if let date = input.date(from: deadline) {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let weekday = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"].map { copy("rb.weekday." + $0) }[calendar.component(.weekday, from: date) - 1]
            let output = DateFormatter(); output.locale = Locale(identifier: "en_US_POSIX"); output.timeZone = TimeZone(secondsFromGMT: 0); output.dateFormat = AppLanguage.current == .de ? "dd.MM." : "MMM d"
            parts.append(copy("rb.datePrefix") + " " + weekday + " " + output.string(from: date))
        } else { parts.append(copy("rb.datePrefix") + " " + deadline) }
    }
    if line.awaitsConfirmation { parts.append(copy("rb.confirmation")) }
    return parts.joined(separator: " · ")
}
switch result {
case .entry(let entry):
    switch command {
    case "done", "start":
        let prefix = command == "done" ? copy("rb.done") : copy("rb.started")
        var parts = [prefix + entry.title]
        if let project = entry.projectName { parts.append(project) }
        if command == "done" && entry.awaitsConfirmation { parts.append(copy("rb.confirmation")) }
        print(parts.joined(separator: " · "))
    case "bis", "due":
        var line = entry; line.sessionCount = 0; line.projectName = nil; line.awaitsConfirmation = false
        print(describe(line))
    default: print(describe(entry).replacingOccurrences(of: "◇ ", with: copy("rb.remembered"), options: .anchored))
    }
case .entries(let entries):
    if entries.isEmpty { print(copy("rb.empty")) }
    for entry in entries { print(describe(entry)) }
case .failed(let code, let matches):
    let message: String
    switch code {
    case .notFound: message = copy("rb.notFound")
    case .foreignProject: message = copy("rb.foreignProject")
    case .invalidDeadline: message = copy("rb.invalidDeadline")
    case .ambiguous: message = copy("rb.ambiguous")
    case .notAllowed: message = copy("rb.notAllowed")
    case .badRequest: message = copy("rb.badRequest")
    case .accessOff: message = copy("rb.accessOff")
    case .callerUnknown: message = copy("rb.callerUnknown")
    case .storeFailed: message = copy("rb.storeFailed")
    case .startFailed: message = copy("rb.startFailed")
    }
    fail(([message] + matches.map(describe)).joined(separator: "\n"), code == .ambiguous ? 2 : 1)
case .exported(let json): print(json)
}
