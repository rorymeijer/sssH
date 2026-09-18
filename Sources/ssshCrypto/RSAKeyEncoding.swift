import BigInt
import Foundation

extension OpenSSHPrivateKey.RSAComponents {
    public enum Failure: Error, Equatable {
        /// A prime was zero or one, so the CRT exponents cannot be computed.
        /// Only reachable from a corrupt or hostile key file.
        case invalidPrimes
    }

    /// PKCS#1 `RSAPrivateKey`, the DER that swift-crypto's `_RSA.Signing.PrivateKey`
    /// reads.
    ///
    /// OpenSSH stores `n, e, d, iqmp, p, q` and *not* the CRT exponents
    /// `dP = d mod (p-1)` and `dQ = d mod (q-1)`, so those are derived here.
    /// That is the only reason this module needs big-integer arithmetic.
    ///
    /// OpenSSH's `iqmp` is `q⁻¹ mod p`, which is exactly PKCS#1's
    /// `coefficient`; no conversion is needed, only the right field order.
    public func pkcs1DERRepresentation() throws -> [UInt8] {
        let p = BigUInt(Data(prime1))
        let q = BigUInt(Data(prime2))
        let d = BigUInt(Data(privateExponent))

        guard p > 1, q > 1 else { throw Failure.invalidPrimes }

        let dP = d % (p - 1)
        let dQ = d % (q - 1)

        return DER.sequence([
            DER.integer(0),                       // version: two-prime
            DER.integer(modulus),
            DER.integer(publicExponent),
            DER.integer(privateExponent),
            DER.integer(prime1),
            DER.integer(prime2),
            DER.integer(Array(dP.serialize())),
            DER.integer(Array(dQ.serialize())),
            DER.integer(coefficient),
        ])
    }

    /// SubjectPublicKeyInfo, which is what swift-crypto's
    /// `_RSA.Signing.PublicKey(derRepresentation:)` expects — it reads
    /// `RSA_PUBKEY`, not a bare PKCS#1 `RSAPublicKey`.
    public func subjectPublicKeyInfoDERRepresentation() -> [UInt8] {
        Self.subjectPublicKeyInfo(modulus: modulus, publicExponent: publicExponent)
    }

    /// The same, for a public key that arrived on its own — a host key off the
    /// wire, or a line out of `authorized_keys`.
    public static func subjectPublicKeyInfo(modulus: [UInt8], publicExponent: [UInt8]) -> [UInt8] {
        let pkcs1 = DER.sequence([
            DER.integer(modulus),
            DER.integer(publicExponent),
        ])

        return DER.sequence([
            DER.sequence([DER.rsaEncryptionOID, DER.null]),
            DER.bitString(pkcs1),
        ])
    }
}
