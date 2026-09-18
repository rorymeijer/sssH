import Foundation
import NIOCore
import NIOSSH
import ssshCore

/// Completes a promise when user authentication succeeds, or fails it with the
/// most useful error available.
///
/// NIOSSH signals success with a `UserAuthSuccessEvent` user event and reports
/// failure by erroring the channel. The raw channel error for a refused login
/// is not something worth showing a user, so the authentication delegate's own
/// account of what it offered and what the server said it would accept takes
/// precedence.
final class HandshakeHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = Any

    /// Safe to read at any point in the channel's life, unlike the promise it
    /// belongs to.
    let authenticated: EventLoopFuture<Void>

    private let promise: EventLoopPromise<Void>
    private let authenticationDelegate: CredentialAuthenticationDelegate
    private var hasCompleted = false

    init(eventLoop: EventLoop, authenticationDelegate: CredentialAuthenticationDelegate) {
        let promise = eventLoop.makePromise(of: Void.self)
        self.promise = promise
        self.authenticated = promise.futureResult
        self.authenticationDelegate = authenticationDelegate
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            complete(with: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // An error raised by our own delegate — a wrong passphrase, an
        // unsupported method — already says exactly what went wrong.
        complete(with: error is SSHTransportError ? error : authenticationDelegate.authenticationFailure())
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        // A server dropping the connection mid-handshake is the usual shape of
        // "too many authentication failures".
        complete(with: authenticationDelegate.authenticationFailure())
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        // Never leave the promise dangling: an uncompleted `EventLoopPromise`
        // traps on deinit in debug builds.
        complete(with: ChannelError.eof)
    }

    private func complete(with error: Error?) {
        // All of these callbacks run on the channel's event loop, so a plain
        // flag is enough to make this once-only.
        guard !hasCompleted else { return }
        hasCompleted = true

        if let error {
            promise.fail(error)
        } else {
            promise.succeed(())
        }
    }
}
