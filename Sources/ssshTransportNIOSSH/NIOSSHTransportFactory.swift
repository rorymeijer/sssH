import Logging
import NIOCore
import NIOPosix
import ssshCore

/// The one place in the app that names a concrete SSH backend.
///
/// Everything else takes an `any SSHTransportFactory`, so replacing the
/// backend is a change to this file and the dependency graph, not to the app.
public struct NIOSSHTransportFactory: SSHTransportFactory {
    private let group: EventLoopGroup
    private let logger: Logger
    private let sinkConfiguration: SSHShellEventSink.Configuration

    /// - Parameter group: shared across transports so twenty open sessions do
    ///   not mean twenty event-loop threads. Defaults to one thread per core,
    ///   with connections spread across them.
    public init(
        group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        logger: Logger = Logger(label: "nl.rorymeijer.sssh.transport"),
        sinkConfiguration: SSHShellEventSink.Configuration = .default
    ) {
        self.group = group
        self.logger = logger
        self.sinkConfiguration = sinkConfiguration
    }

    public func makeTransport() -> any SSHTransport {
        NIOSSHTransport(group: group, logger: logger, sinkConfiguration: sinkConfiguration)
    }
}
