import Foundation
import NIOCore
import ssshCore

/// The live numbers behind one tunnel.
///
/// Updated from several event loops — one per forwarded connection — and read
/// from the main actor by the UI, so it is lock-protected rather than
/// event-loop-confined. The lock is held for a few integer operations at a
/// time; the alternative, hopping to one loop per chunk of forwarded data,
/// would cost far more than it saves.
final class PortForwardCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var total = 0
    private var sent: UInt64 = 0
    private var received: UInt64 = 0

    var snapshot: PortForwardStatistics {
        lock.lock()
        defer { lock.unlock() }
        return PortForwardStatistics(
            activeConnections: active,
            totalConnections: total,
            bytesSent: sent,
            bytesReceived: received
        )
    }

    func connectionOpened() {
        lock.lock()
        active += 1
        total += 1
        lock.unlock()
    }

    func connectionClosed() {
        lock.lock()
        // A connection can be reported closed twice — once from each end of
        // the glue — and a negative count in a status line looks like a bug in
        // the tunnel rather than in the counter.
        active = max(0, active - 1)
        lock.unlock()
    }

    func add(sent bytes: Int) {
        guard bytes > 0 else { return }
        lock.lock()
        sent &+= UInt64(bytes)
        lock.unlock()
    }

    func add(received bytes: Int) {
        guard bytes > 0 else { return }
        lock.lock()
        received &+= UInt64(bytes)
        lock.unlock()
    }
}

/// Counts bytes passing through one end of a tunnel.
///
/// Always placed on the *local* end of a forwarded connection, whichever
/// direction the tunnel runs. That is what makes "sent" and "received" mean
/// what a person expects: out of this device and into it. On the local end,
/// inbound data is on its way out over SSH, for `-L` and `-R` alike.
final class ByteCountingHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let counters: PortForwardCounters
    private var hasReportedClose = false

    init(counters: PortForwardCounters) {
        self.counters = counters
    }

    func handlerAdded(context: ChannelHandlerContext) {
        counters.connectionOpened()
    }

    func channelInactive(context: ChannelHandlerContext) {
        reportClosed()
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        // A channel can be torn down without ever going inactive — the whole
        // SSH connection dropping does exactly that — so the count is closed
        // out here as well, once.
        reportClosed()
    }

    private func reportClosed() {
        guard !hasReportedClose else { return }
        hasReportedClose = true
        counters.connectionClosed()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        counters.add(sent: unwrapInboundIn(data).readableBytes)
        context.fireChannelRead(data)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        counters.add(received: unwrapOutboundIn(data).readableBytes)
        context.write(data, promise: promise)
    }
}
