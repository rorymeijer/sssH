import Foundation
import Logging
import NIOCore
import NIOSSH
import ssshCore

/// One SSH session channel, either PTY-backed (`shell`) or not (`exec`).
final class NIOSSHShellSession: SSHShellSession, @unchecked Sendable {
    enum Mode {
        /// `pty-req` then `shell` — the interactive case.
        case interactiveShell(SSHShellConfiguration)
        /// `exec` with no PTY, so stdout and stderr stay separate.
        case command(String, environment: [String: String])
    }

    let events: SSHShellEventStream

    private let channel: Channel
    private let sink: SSHShellEventSink
    private let logger: Logger
    private let lock = NSLock()
    private var _terminalSize: TerminalSize?

    var terminalSize: TerminalSize? {
        lock.lock()
        defer { lock.unlock() }
        return _terminalSize
    }

    private init(
        channel: Channel,
        sink: SSHShellEventSink,
        events: SSHShellEventStream,
        initialSize: TerminalSize?,
        logger: Logger
    ) {
        self.channel = channel
        self.sink = sink
        self.events = events
        self._terminalSize = initialSize
        self.logger = logger
    }

    // MARK: - Opening

    /// Opens a channel and brings it all the way up to a running shell.
    ///
    /// Everything up to and including the `shell` request happens in one
    /// `flatSubmit` block on the connection's event loop. That is not just
    /// tidiness: `NIOSSHHandler.createChannel` is documented as not
    /// thread-safe, and the reply-correlation FIFO in ``ShellChannelHandler``
    /// only works if each `expectReply` is registered before its request is
    /// written.
    static func open(
        on sshHandler: NIOSSHHandler,
        eventLoop: EventLoop,
        mode: Mode,
        channelOpenTimeout: Duration,
        sinkConfiguration: SSHShellEventSink.Configuration,
        logger: Logger
    ) async throws -> NIOSSHShellSession {
        let sink = SSHShellEventSink(configuration: sinkConfiguration)
        let stream = sink.makeStream()
        let handler = ShellChannelHandler(sink: sink, logger: logger)

        let channel: Channel = try await eventLoop.flatSubmit {
            let created = eventLoop.makePromise(of: Channel.self)

            sshHandler.createChannel(created, channelType: .session) { channel, _ in
                channel.pipeline.addHandler(handler)
            }

            // The server may accept the TCP connection and then never answer
            // `channel-open`. Without this the open would hang until the
            // socket eventually died.
            let timeout = eventLoop.scheduleTask(in: .nanoseconds(channelOpenTimeout.nanosecondsClamped)) {
                created.fail(SSHTransportError.timedOut(operation: "channel-open", after: channelOpenTimeout))
            }
            created.futureResult.whenComplete { _ in timeout.cancel() }

            return created.futureResult
        }.get()

        do {
            try await configure(channel: channel, handler: handler, mode: mode, logger: logger)
        } catch {
            try? await channel.close().get()
            throw error
        }

        let session = NIOSSHShellSession(
            channel: channel,
            sink: sink,
            events: stream,
            initialSize: mode.initialTerminalSize,
            logger: logger
        )

        // Reads are demand-driven, so the consumer's progress has to be able to
        // wake the channel back up. This closure runs on whatever thread
        // drained the stream, hence the hop.
        sink.onDemandForMoreData { [weak channel] in
            guard let channel else { return }
            channel.eventLoop.execute { channel.read() }
        }

        // Prime the pump: with autoRead off nothing arrives until we ask.
        channel.eventLoop.execute { channel.read() }

        if case .interactiveShell(let configuration) = mode, let startup = configuration.startupCommand, !startup.isEmpty {
            // Written as terminal input, exactly as if the user had typed it,
            // so shell aliases and functions apply.
            try await session.write(Array("\(startup)\n".utf8)[...])
        }

        return session
    }

    private static func configure(
        channel: Channel,
        handler: ShellChannelHandler,
        mode: Mode,
        logger: Logger
    ) async throws {
        switch mode {
        case .interactiveShell(let configuration):
            try await sendEnvironment(configuration.environment, on: channel)

            try await sendRequest(
                SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true,
                    term: configuration.terminalType.name,
                    terminalCharacterWidth: configuration.initialSize.columns,
                    terminalRowHeight: configuration.initialSize.rows,
                    terminalPixelWidth: configuration.initialSize.pixelWidth,
                    terminalPixelHeight: configuration.initialSize.pixelHeight,
                    // An empty mode set means "server defaults", which is what
                    // a fresh OpenSSH PTY effectively gets.
                    terminalModes: SSHTerminalModes([:])
                ),
                on: channel,
                handler: handler,
                failureMessage: "the server refused to allocate a pseudo-terminal (pty-req)"
            )

            try await sendRequest(
                SSHChannelRequestEvent.ShellRequest(wantReply: true),
                on: channel,
                handler: handler,
                failureMessage: "the server refused to start a shell"
            )

            logger.debug("interactive shell running", metadata: [
                "term": .string(configuration.terminalType.name),
                "size": .string("\(configuration.initialSize.columns)x\(configuration.initialSize.rows)"),
            ])

        case .command(let command, let environment):
            try await sendEnvironment(environment, on: channel)

            try await sendRequest(
                SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true),
                on: channel,
                handler: handler,
                failureMessage: "the server refused to run the command"
            )
        }
    }

    /// `env` requests go out without `want_reply`: servers refuse anything
    /// outside their `AcceptEnv` list, a refusal is not worth failing a
    /// connection over, and a round trip each would be.
    private static func sendEnvironment(_ environment: [String: String], on channel: Channel) async throws {
        for (name, value) in environment.sorted(by: { $0.key < $1.key }) {
            try await channel.triggerUserOutboundEvent(
                SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: name, value: value)
            )
        }
    }

    /// Registers the reply expectation and writes the request in a single hop
    /// onto the event loop, so the handler's reply FIFO cannot be reordered by
    /// a concurrent request.
    private static func sendRequest(
        _ event: Any,
        on channel: Channel,
        handler: ShellChannelHandler,
        failureMessage: String
    ) async throws {
        let reply: EventLoopFuture<Void> = try await channel.eventLoop.submit {
            handler.sendRequestExpectingReply(event, on: channel)
        }.get()

        do {
            try await reply.get()
        } catch {
            // The handler cannot know which request a bare
            // SSH_MSG_CHANNEL_FAILURE answers, so it reports a generic
            // refusal; here we do know, and replace it with the specific
            // message. Anything else (a lost connection, a write failure)
            // passes through unchanged.
            if let transportError = error as? SSHTransportError {
                if case .channelRequestFailed = transportError {
                    throw SSHTransportError.channelRequestFailed(failureMessage)
                }
                throw transportError
            }
            throw SSHTransportError.channelRequestFailed(failureMessage)
        }
    }

    // MARK: - SSHShellSession

    func write(_ bytes: ArraySlice<UInt8>) async throws {
        guard !bytes.isEmpty else { return }
        guard channel.isActive else { throw SSHTransportError.connectionLost(.remoteClosed) }

        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        try await channel.writeAndFlush(buffer).get()
    }

    func resize(to size: TerminalSize) async throws {
        lock.lock()
        let unchanged = _terminalSize == size
        if !unchanged { _terminalSize = size }
        lock.unlock()

        // A `window-change` for the size the PTY already has is pure noise, and
        // SwiftUI will hand us the same size repeatedly during a live drag.
        guard !unchanged else { return }
        guard channel.isActive else { throw SSHTransportError.connectionLost(.remoteClosed) }

        try await channel.triggerUserOutboundEvent(
            SSHChannelRequestEvent.WindowChangeRequest(
                terminalCharacterWidth: size.columns,
                terminalRowHeight: size.rows,
                terminalPixelWidth: size.pixelWidth,
                terminalPixelHeight: size.pixelHeight
            )
        )
    }

    func send(signal: SSHSignal) async throws {
        guard channel.isActive else { throw SSHTransportError.connectionLost(.remoteClosed) }
        try await channel.triggerUserOutboundEvent(
            SSHChannelRequestEvent.SignalRequest(signal: signal.rawValue)
        )
    }

    func sendEOF() async throws {
        guard channel.isActive else { return }
        try await channel.close(mode: .output).get()
    }

    func close() async {
        guard channel.isActive else { return }
        try? await channel.close().get()
    }
}

extension NIOSSHShellSession.Mode {
    var initialTerminalSize: TerminalSize? {
        switch self {
        case .interactiveShell(let configuration): return configuration.initialSize
        case .command: return nil
        }
    }
}

extension Duration {
    /// Nanoseconds as an `Int64`, saturating instead of trapping on a duration
    /// large enough to overflow.
    var nanosecondsClamped: Int64 {
        let (seconds, attoseconds) = components
        let maxSeconds = Int64.max / 1_000_000_000
        guard seconds < maxSeconds else { return .max }
        guard seconds > -maxSeconds else { return .min }
        return seconds * 1_000_000_000 + attoseconds / 1_000_000_000
    }
}
