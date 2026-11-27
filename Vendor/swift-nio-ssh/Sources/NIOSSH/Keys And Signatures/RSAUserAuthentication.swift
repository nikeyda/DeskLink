//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Crypto
import CryptoExtras
import NIOCore
import NIOFoundationCompat

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// RSA signature algorithms for SSH user authentication (RFC 8332).
public enum NIOSSHRSAUserAuthentication: String, Sendable, CaseIterable {
    case sha512 = "rsa-sha2-512"
    case sha256 = "rsa-sha2-256"

    internal init?<Bytes: Collection>(identifier: Bytes) where Bytes.Element == UInt8 {
        guard let algorithm = Self.allCases.first(where: { identifier.elementsEqual($0.rawValue.utf8) }) else {
            return nil
        }
        self = algorithm
    }

    internal func sign(_ bytes: ByteBufferView, with key: _RSA.Signing.PrivateKey) throws -> Data {
        let signature: _RSA.Signing.RSASignature
        switch self {
        case .sha512:
            signature = try key.signature(for: SHA512.hash(data: bytes), padding: .insecurePKCS1v1_5)
        case .sha256:
            signature = try key.signature(for: SHA256.hash(data: bytes), padding: .insecurePKCS1v1_5)
        }
        return signature.rawRepresentation
    }

    internal func verify(_ bytes: ByteBufferView, signature: Data, with key: _RSA.Signing.PublicKey) -> Bool {
        let width = (key.keySizeInBits + 7) / 8
        guard !signature.isEmpty, signature.count <= width else { return false }
        // RFC 8332 allows leading zero octets to be omitted on the wire.
        let padded = Data(repeating: 0, count: width - signature.count) + signature
        let signature = _RSA.Signing.RSASignature(rawRepresentation: padded)
        switch self {
        case .sha512:
            return key.isValidSignature(signature, for: SHA512.hash(data: bytes), padding: .insecurePKCS1v1_5)
        case .sha256:
            return key.isValidSignature(signature, for: SHA256.hash(data: bytes), padding: .insecurePKCS1v1_5)
        }
    }
}

internal struct RSAPublicKey: Hashable, Sendable {
    let key: _RSA.Signing.PublicKey
    let modulus: Data
    let exponent: Data

    init(_ key: _RSA.Signing.PublicKey) throws {
        let numbers = try key.getKeyPrimitives()
        self.key = key
        self.modulus = numbers.modulus
        self.exponent = numbers.publicExponent
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.modulus == rhs.modulus && lhs.exponent == rhs.exponent
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(modulus)
        hasher.combine(exponent)
    }
}

extension ByteBuffer {
    mutating func writeRSAKey(_ key: RSAPublicKey) -> Int {
        self.writePositiveMPInt(key.exponent) + self.writePositiveMPInt(key.modulus)
    }

    mutating func readRSAKey() throws -> NIOSSHPublicKey? {
        guard let exponentField = self.readSSHString(), let modulusField = self.readSSHString() else {
            return nil
        }
        let exponent = try Self.readRSAMagnitude(exponentField, maximumBytes: 8)
        let modulus = try Self.readRSAMagnitude(modulusField, maximumBytes: 2048)
        let key = try _RSA.Signing.PublicKey(n: modulus, e: exponent)
        return try NIOSSHPublicKey(backingKey: .rsa(RSAPublicKey(key)))
    }

    private static func readRSAMagnitude(_ field: ByteBuffer, maximumBytes: Int) throws -> Data {
        let bytes = field.readableBytesView
        let magnitude = bytes.first == 0 ? bytes.dropFirst() : bytes[...]
        guard let leading = bytes.first, leading < 128,
            let first = magnitude.first, first != 0,
            (leading != 0 || first >= 128), magnitude.count <= maximumBytes
        else {
            throw NIOSSHError.invalidSSHMessage(reason: "invalid RSA key integer")
        }
        return Data(magnitude)
    }
}
