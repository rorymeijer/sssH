//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Licensed under Apache License v2.0
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// Which authentication method's method-specific message IDs are currently
/// meaningful.
///
/// SSH reuses message IDs 60–79 per authentication method (RFC 4252 §6), so
/// those bytes cannot be parsed without knowing what was asked for. The case
/// that forces this to exist is ID 60: it is `SSH_MSG_USERAUTH_PK_OK` during a
/// public-key exchange and `SSH_MSG_USERAUTH_INFO_REQUEST` during a
/// keyboard-interactive one, and the two payloads are nothing alike.
///
/// The user-authentication state machine owns this value and the packet parser
/// reads it. It is the only state the parser has, and this is why.
enum SSHUserAuthMethodInFlight: Hashable {
    /// No method-specific IDs are expected. Anything in 60–79 is parsed as the
    /// public-key case, which is what NIOSSH did before keyboard-interactive
    /// existed and what keeps behaviour unchanged for everyone else.
    case none
    case publicKey
    case keyboardInteractive
}
