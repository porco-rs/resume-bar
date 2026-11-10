import RBContract

enum ContextProject {
    static func resolve(_ raw: Context?, in snapshot: Snapshot) -> Context? {
        guard var context = raw else { return nil }
        if let tty = context.tty {
            let matches = snapshot.sessions.filter { $0.live.running && $0.live.tty == tty }
            if let project = matches.first?.projectId, matches.allSatisfy({ $0.projectId == project }) {
                context.projectId = project
                return context
            }
        }
        context.projectId = context.cwd.flatMap { cwd in
            snapshot.projects
                .filter { cwd == $0.rootPath || cwd.hasPrefix($0.rootPath.hasSuffix("/") ? $0.rootPath : $0.rootPath + "/") }
                .max { $0.rootPath.count < $1.rootPath.count }?.id
        }
        return context
    }
}
