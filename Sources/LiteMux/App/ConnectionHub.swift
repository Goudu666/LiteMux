import Foundation
import Observation
import LiteMuxCore

/// Owns the background channels to each host: one SFTP session per host,
/// all riding on the shared ControlMaster tunnel that the terminal opened.
@MainActor @Observable
final class ConnectionHub {
    let invocation = SSHInvocation()
    @ObservationIgnored private let local = LocalFileSystem()
    @ObservationIgnored private var remotes: [String: SFTPFileSystem] = [:]
    @ObservationIgnored private var inFlight: [String: Task<SFTPFileSystem, Error>] = [:]
    @ObservationIgnored private var masterWatchers: [String: Task<Void, Never>] = [:]

    /// Hosts with a live multiplexed tunnel (or a live local shell).
    private(set) var onlineHosts: Set<String> = [HostEntry.localID]

    /// Called when a host's tunnel comes up, so the file tree and status bar can retry.
    @ObservationIgnored var onHostOnline: ((String) -> Void)?

    init() {
        try? invocation.ensureControlDirectory()
    }

    func environment(for host: HostEntry) -> [String: String] {
        var extra: [String: String] = [:]
        if host.hasSavedPassword { extra = Askpass.environment(account: host.id) }
        return ProcessRunner.baseEnvironment(extra: extra)
    }

    /// The file system for a host, opening an SFTP channel if needed.
    func fileSystem(for host: HostEntry) async throws -> FileSystemProvider {
        guard let endpoint = host.endpoint else { return local }
        if let fs = remotes[host.id], fs.client.isOpen { return fs }
        remotes[host.id] = nil
        if let task = inFlight[host.id] { return try await task.value }

        let args = invocation.sftpArguments(endpoint: endpoint, usesAskpass: host.hasSavedPassword)
        let env = environment(for: host)
        let hostID = host.id
        let task = Task<SFTPFileSystem, Error> {
            let client = SFTPClient(executable: SSHInvocation.sshPath, arguments: args, environment: env)
            try await client.start()
            return SFTPFileSystem(client: client)
        }
        inFlight[hostID] = task
        defer { inFlight[hostID] = nil }
        let fs = try await task.value
        fs.client.onClose = { [weak self] _ in
            Task { @MainActor in self?.evict(hostID) }
        }
        remotes[hostID] = fs
        markOnline(hostID)
        return fs
    }

    func evict(_ hostID: String) {
        remotes[hostID]?.client.close()
        remotes[hostID] = nil
    }

    func markOnline(_ hostID: String) {
        if !onlineHosts.contains(hostID) {
            onlineHosts.insert(hostID)
            onHostOnline?(hostID)
        }
    }

    func markOffline(_ hostID: String) {
        guard hostID != HostEntry.localID else { return }
        onlineHosts.remove(hostID)
    }

    /// Whether a ControlMaster for the endpoint is alive.
    func masterIsAlive(_ endpoint: SSHEndpoint) async -> Bool {
        let out = await ProcessRunner.run(SSHInvocation.sshPath,
                                          invocation.controlArguments(endpoint: endpoint, command: "check"),
                                          environment: ProcessRunner.baseEnvironment(), timeout: 3)
        return out.status == 0
    }

    /// After a terminal starts connecting, watch for its master to appear so
    /// panels that were waiting for authentication can come online.
    func watchForMaster(_ host: HostEntry) {
        guard let endpoint = host.endpoint, masterWatchers[host.id] == nil else { return }
        let hostID = host.id
        masterWatchers[hostID] = Task { [weak self] in
            for attempt in 0..<90 {
                try? await Task.sleep(nanoseconds: attempt < 10 ? 700_000_000 : 2_000_000_000)
                if Task.isCancelled { break }
                guard let self else { return }
                if await self.masterIsAlive(endpoint) {
                    self.markOnline(hostID)
                    break
                }
            }
            self?.masterWatchers[hostID] = nil
        }
    }

    /// Closes SFTP channels and asks every multiplexing master we created to exit.
    /// Remote tmux sessions are untouched, so long jobs keep running.
    func shutdown() {
        for (_, fs) in remotes { fs.client.close() }
        remotes.removeAll()
        for (_, t) in masterWatchers { t.cancel() }
        let sockets = invocation.existingControlSockets()
        let group = DispatchGroup()
        for socket in sockets {
            group.enter()
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: SSHInvocation.sshPath)
                p.arguments = SSHInvocation.exitArguments(socketPath: socket)
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try? p.run()
                p.waitUntilExit()
                try? FileManager.default.removeItem(atPath: socket)
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + 1.5)
    }
}
