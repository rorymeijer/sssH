import Foundation

/// What changed in the block record.
///
/// The segmenter reports changes rather than owning an array of blocks, so the
/// bytes of a running command's output are held once — by whatever the UI
/// observes — instead of twice.
public enum CommandBlockEvent: Sendable {
    /// A new block started, `.prompting` or `.running` depending on how much
    /// the shell told us.
    case opened(CommandBlock)
    case commandChanged(id: UUID, command: String)
    case stateChanged(id: UUID, state: CommandBlock.State, at: Date)
    case outputAppended(id: UUID, bytes: [UInt8])
    /// Output was dropped: the block outgrew its cap, or a full-screen program
    /// ran inside it.
    case outputTruncated(id: UUID)
}

/// Splits a terminal stream into ``CommandBlock``s.
///
/// Two modes, and which one is in use is shown to the user rather than guessed
/// at silently:
///
/// - **Shell integration.** The shell emits `OSC 133` — and possibly VS Code's
///   `OSC 633` superset — so the boundaries and the exit status are exact.
/// - **Fallback.** Nothing emits markers, so a block is cut when the user
///   presses Return, and the command is the line the remote echoed rather than
///   a reconstruction from keystrokes. The echo is what the user actually saw,
///   so it survives history recall, tab completion and editing, none of which
///   replaying keystrokes would. There is no exit status in this mode, and a
///   block ends where the next command starts, not where its output stopped.
///
/// Neither mode captures anything while the alternate screen buffer is active.
/// A full-screen program is not a command with output, and a byte log of one
/// is unreadable: reconstructing what `vim` displayed needs a screen model, not
/// a transcript.
public struct CommandBlockSegmenter: Sendable {
    public struct Limits: Sendable {
        /// Per block. `cat`ting a large file must cost a bounded amount of
        /// memory, and the beginning is the part worth keeping: the command
        /// and the first error are at the top.
        public var outputBytesPerBlock: Int
        /// How long a single line may get before it stops being a plausible
        /// command echo and is treated as ordinary output.
        public var lineBytes: Int

        public init(outputBytesPerBlock: Int = 256 << 10, lineBytes: Int = 8192) {
            self.outputBytesPerBlock = outputBytesPerBlock
            self.lineBytes = lineBytes
        }
    }

    /// How boundaries are being found. Starts undetermined and settles on the
    /// first marker or the first submitted line.
    public enum Mode: String, Sendable, Hashable {
        case undetermined
        case shellIntegration
        case fallback
    }

    private enum Phase: Sendable {
        /// Between `A` and `B`: the shell is drawing its prompt.
        case prompting
        /// Between `B` and `C`: the user is typing and output is the echo.
        case typing
        /// After `C`, or after a Return in fallback mode.
        case running
        /// After `D`, before the next prompt. Also the state before the user
        /// has run anything at all, which is why a login banner is not
        /// attributed to a command.
        case idle
    }

    private var scanner = ShellIntegrationScanner()
    private let limits: Limits

    public private(set) var mode: Mode = .undetermined
    private var phase: Phase = .idle
    private var alternateScreenActive = false

    private var currentID: UUID?
    private var currentOutputBytes = 0
    private var currentTruncated = false

    /// Echoed bytes between `B` and `C`, from which the command text is
    /// recovered when nothing reported it directly.
    private var echo: [UInt8] = []
    /// The command line `OSC 633 ; E` reported, which beats the echo.
    private var reportedCommand: String?

    // Fallback-mode line buffering. The line being drawn is held back rather
    // than appended immediately, because it may turn out to be the echo of the
    // next command rather than output of the current one — and deciding that
    // after the fact would mean retroactively editing a block the UI has
    // already shown.
    private var pendingLine: [UInt8] = []
    private var pendingLineOverflowed = false
    private var lastWasCarriageReturn = false
    /// Set when a Return cut a block on a `\r`, so the `\n` that follows is
    /// dropped rather than starting the new block with a blank line.
    private var suppressLineFeedAfterCut = false
    /// Whether a Return the user sent is still waiting for the echoed newline
    /// that accounts for it.
    ///
    /// At most one, deliberately. A paste of ten lines arrives as ten Returns
    /// at once, and counting them would make the next ten echoed lines — most
    /// of them *output* — each cut a block. One armed Return means a paste
    /// becomes a single block containing the whole run, which is imprecise but
    /// never invents a command that was never typed.
    private var hasPendingSubmit = false
    /// How much of the line being drawn was already there when the user first
    /// typed into it — which is exactly the prompt.
    ///
    /// This is why the prompt can be separated from the command without
    /// guessing at its shape. Prompt detection by pattern is a losing game:
    /// people's prompts contain git branches, hostnames, emoji, timestamps and
    /// colours, and any regexp that survives contact with them also matches
    /// half the output of `grep`.
    private var promptPrefixLength: Int?

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    public var hasShellIntegration: Bool { mode == .shellIntegration }

    // MARK: - Output

    public mutating func consumeOutput(_ bytes: ArraySlice<UInt8>, now: Date = Date()) -> [CommandBlockEvent] {
        var events: [CommandBlockEvent] = []
        for token in scanner.scan(bytes) {
            switch token {
            case .bytes(let span):
                route(span[...], now: now, into: &events)
            case .marker(let marker):
                apply(marker, now: now, into: &events)
            }
        }
        return events
    }

    /// Bytes that are not part of a marker sequence, routed by what the shell
    /// last said it was doing.
    private mutating func route(_ span: ArraySlice<UInt8>, now: Date, into events: inout [CommandBlockEvent]) {
        guard !alternateScreenActive else {
            noteTruncated(into: &events)
            return
        }
        if mode == .shellIntegration {
            switch phase {
            case .typing:
                let room = limits.lineBytes - echo.count
                if room > 0 { echo.append(contentsOf: span.prefix(room)) }
            case .running:
                append(span, into: &events)
            case .prompting, .idle:
                break
            }
        } else {
            routeFallback(span, now: now, into: &events)
        }
    }

    /// Walks the span a byte at a time, holding back the line currently being
    /// drawn until a newline says what it was.
    private mutating func routeFallback(_ span: ArraySlice<UInt8>, now: Date, into events: inout [CommandBlockEvent]) {
        for byte in span {
            switch byte {
            case 0x0D:
                let outcome = endFallbackLine(now: now, into: &events)
                if outcome == .output {
                    appendRaw(byte, into: &events)
                } else {
                    // The `\r\n` the shell echoed for the user's Return marks
                    // the boundary; it is not output on either side of it.
                    suppressLineFeedAfterCut = true
                }
                lastWasCarriageReturn = true

            case 0x0A:
                // A `\r\n` pair ends one line, not two, but both bytes still
                // belong in the output: dropping the `\n` would leave a bare
                // `\r`, which rewrites a line rather than ending it.
                var outcome = LineOutcome.output
                if !lastWasCarriageReturn {
                    outcome = endFallbackLine(now: now, into: &events)
                }
                if outcome == .output, !suppressLineFeedAfterCut {
                    appendRaw(byte, into: &events)
                }
                suppressLineFeedAfterCut = false
                lastWasCarriageReturn = false

            default:
                lastWasCarriageReturn = false
                suppressLineFeedAfterCut = false
                if pendingLine.count < limits.lineBytes {
                    pendingLine.append(byte)
                } else {
                    // Too long to be a command echo. Let it through as output
                    // and stop pretending this line might be a command.
                    if !pendingLineOverflowed {
                        pendingLineOverflowed = true
                        flushPendingLine(into: &events)
                    }
                    appendRaw(byte, into: &events)
                }
            }
        }
    }

    private enum LineOutcome: Equatable {
        /// An ordinary output line: its bytes and its terminator belong to the
        /// running block.
        case output
        /// The echo of a submitted command: a new block starts here, and the
        /// echoed line and its terminator belong to neither block.
        case cut
        /// A Return with nothing typed at it. The shell redraws its prompt and
        /// nothing ran, so there is no block to open and nothing to record.
        case discarded
    }

    /// Ends the line being drawn and says what it turned out to be.
    private mutating func endFallbackLine(now: Date, into events: inout [CommandBlockEvent]) -> LineOutcome {
        defer {
            pendingLine.removeAll(keepingCapacity: true)
            pendingLineOverflowed = false
            promptPrefixLength = nil
        }

        guard hasPendingSubmit else {
            flushPendingLine(into: &events)
            return .output
        }
        hasPendingSubmit = false

        // An overflowed line is not a command echo — but the Return that armed
        // this submit was still a Return, so consume it rather than let it
        // mis-attribute the next line.
        guard !pendingLineOverflowed else {
            flushPendingLine(into: &events)
            return .discarded
        }

        let split = min(promptPrefixLength ?? 0, pendingLine.count)
        let prompt = PlainText.extract(from: pendingLine[..<split])
        let command = PlainText.extract(from: pendingLine[split...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return .discarded }

        mode = .fallback
        finishCurrent(exitStatus: nil, now: now, into: &events)
        open(command: command, prompt: prompt, state: .running, heuristic: true, now: now, into: &events)
        phase = .running
        return .cut
    }

    private mutating func appendRaw(_ byte: UInt8, into events: inout [CommandBlockEvent]) {
        append([byte][...], into: &events)
    }

    private mutating func flushPendingLine(into events: inout [CommandBlockEvent]) {
        guard !pendingLine.isEmpty else { return }
        append(pendingLine[...], into: &events)
        pendingLine.removeAll(keepingCapacity: true)
    }

    private mutating func append(_ span: ArraySlice<UInt8>, into events: inout [CommandBlockEvent]) {
        guard phase == .running, let id = currentID, !span.isEmpty else { return }
        let room = limits.outputBytesPerBlock - currentOutputBytes
        guard room > 0 else {
            noteTruncated(into: &events)
            return
        }
        let kept = span.prefix(room)
        currentOutputBytes += kept.count
        events.append(.outputAppended(id: id, bytes: Array(kept)))
        if kept.count < span.count { noteTruncated(into: &events) }
    }

    private mutating func noteTruncated(into events: inout [CommandBlockEvent]) {
        guard let id = currentID, !currentTruncated else { return }
        currentTruncated = true
        events.append(.outputTruncated(id: id))
    }

    private mutating func apply(_ marker: ShellIntegrationMarker, now: Date, into events: inout [CommandBlockEvent]) {
        if case .alternateScreen(let active) = marker {
            alternateScreenActive = active
            return
        }

        // Any 133/633 marker means the far side has shell integration. Once
        // that is settled, Return no longer cuts blocks — the markers do, and
        // running both rules would cut every block twice.
        if mode != .shellIntegration {
            flushPendingLine(into: &events)
            hasPendingSubmit = false
            promptPrefixLength = nil
            mode = .shellIntegration
        }

        switch marker {
        case .promptStart:
            finishCurrent(exitStatus: nil, now: now, into: &events)
            open(command: "", state: .prompting, heuristic: false, now: now, into: &events)
            phase = .prompting
            echo.removeAll(keepingCapacity: true)
            reportedCommand = nil

        case .commandStart:
            if currentID == nil {
                open(command: "", state: .prompting, heuristic: false, now: now, into: &events)
            }
            phase = .typing
            echo.removeAll(keepingCapacity: true)

        case .commandExecuted:
            if currentID == nil {
                open(command: "", state: .prompting, heuristic: false, now: now, into: &events)
            }
            let recovered = reportedCommand
                ?? PlainText.extract(from: echo[...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let id = currentID, !recovered.isEmpty {
                events.append(.commandChanged(id: id, command: recovered))
            }
            echo.removeAll(keepingCapacity: true)
            phase = .running
            if let id = currentID {
                events.append(.stateChanged(id: id, state: .running, at: now))
            }

        case .commandFinished(let exitStatus):
            finishCurrent(exitStatus: exitStatus, now: now, into: &events)
            phase = .idle

        case .commandLine(let text):
            reportedCommand = text
            if let id = currentID {
                events.append(.commandChanged(id: id, command: text))
            }

        case .alternateScreen:
            break // handled above
        }
    }

    // MARK: - Input

    /// Bytes the user sent.
    ///
    /// Only the Returns matter, and only in fallback mode. What was typed is
    /// never used as the command text: the echo is both more accurate and what
    /// the user saw. Nor does a Return cut a block immediately — it arms one,
    /// and the echoed newline that comes back is what actually cuts it. That
    /// keeps a paste and a slow link from cutting blocks ahead of the output
    /// they belong to.
    public mutating func consumeInput(_ bytes: ArraySlice<UInt8>) -> [CommandBlockEvent] {
        guard mode != .shellIntegration, !alternateScreenActive, !bytes.isEmpty else { return [] }
        // Whatever the shell had already drawn when the user first touched
        // this line is the prompt.
        if promptPrefixLength == nil { promptPrefixLength = pendingLine.count }
        if bytes.contains(where: { $0 == 0x0D || $0 == 0x0A }) {
            hasPendingSubmit = true
        }
        return []
    }

    // MARK: - Block lifecycle

    private mutating func open(command: String, prompt: String = "", state: CommandBlock.State, heuristic: Bool, now: Date, into events: inout [CommandBlockEvent]) {
        let block = CommandBlock(command: command, prompt: prompt, state: state, startedAt: now, isHeuristic: heuristic)
        currentID = block.id
        currentOutputBytes = 0
        currentTruncated = false
        events.append(.opened(block))
    }

    private mutating func finishCurrent(exitStatus: Int32?, now: Date, into events: inout [CommandBlockEvent]) {
        guard let id = currentID else { return }
        events.append(.stateChanged(id: id, state: .finished(exitStatus: exitStatus), at: now))
        currentID = nil
        currentOutputBytes = 0
        currentTruncated = false
    }

    /// The shell exited, or the connection dropped: close whatever is open so
    /// that no block is left running for ever.
    ///
    /// The line being drawn is discarded rather than flushed. An unterminated
    /// line at the end of a session is the prompt that was waiting for input,
    /// and appending a prompt to the previous command's output is exactly the
    /// kind of small wrongness that makes a block view untrustworthy.
    public mutating func finish(now: Date = Date()) -> [CommandBlockEvent] {
        var events: [CommandBlockEvent] = []
        pendingLine.removeAll(keepingCapacity: true)
        promptPrefixLength = nil
        finishCurrent(exitStatus: nil, now: now, into: &events)
        phase = .idle
        return events
    }
}
