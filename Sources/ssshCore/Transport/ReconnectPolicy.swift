import Foundation

/// Exponential backoff with jitter for automatic reconnection.
///
/// Jitter matters here: an app with twenty saved hosts that all dropped
/// because the Wi-Fi went away must not reconnect in lockstep.
public struct ReconnectPolicy: Hashable, Sendable {
    public var initialDelay: Duration
    public var maximumDelay: Duration
    public var multiplier: Double
    /// Fraction of the computed delay that is randomised, 0...1.
    public var jitter: Double
    /// `nil` means keep trying for as long as the session is open.
    public var maximumAttempts: Int?

    public init(
        initialDelay: Duration = .seconds(1),
        maximumDelay: Duration = .seconds(60),
        multiplier: Double = 2,
        jitter: Double = 0.2,
        maximumAttempts: Int? = nil
    ) {
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        self.multiplier = multiplier
        self.jitter = jitter.clamped(to: 0...1)
        self.maximumAttempts = maximumAttempts
    }

    public static let `default` = ReconnectPolicy()
    public static let never = ReconnectPolicy(maximumAttempts: 0)

    public func shouldRetry(attempt: Int) -> Bool {
        guard let maximumAttempts else { return true }
        return attempt <= maximumAttempts
    }

    /// Delay before `attempt` (1-based).
    ///
    /// - Parameter randomValue: injected so the sequence is testable.
    public func delay(forAttempt attempt: Int, randomValue: Double = Double.random(in: 0...1)) -> Duration {
        precondition(attempt >= 1, "attempts are 1-based")

        let exponent = Double(attempt - 1)
        let base = initialDelay.seconds * pow(multiplier, exponent)
        let capped = min(base, maximumDelay.seconds)

        // Jitter is subtractive ("full jitter" applied downwards) so a delay
        // never exceeds `maximumDelay`.
        let spread = capped * jitter
        let jittered = capped - spread * randomValue

        return .seconds(max(0, jittered))
    }
}

extension Duration {
    /// Seconds as a `Double`. `components` is (seconds, attoseconds).
    public var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}

extension Comparable {
    fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
