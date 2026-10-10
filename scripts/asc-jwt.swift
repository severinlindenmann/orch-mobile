#!/usr/bin/env swift
// Prints a short-lived App Store Connect API JWT (ES256) to stdout.
// usage: asc-jwt.swift <key.p8> <keyID> <issuerID>
// Reads the key file; never prints it. Callers must not log stdout.
import Foundation
import CryptoKit

func b64url(_ d: Data) -> String {
    d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
let a = CommandLine.arguments
guard a.count == 4, let pem = try? String(contentsOfFile: a[1], encoding: .utf8) else {
    FileHandle.standardError.write(Data("usage: asc-jwt.swift key.p8 keyID issuerID\n".utf8)); exit(2)
}
do {
    let key = try P256.Signing.PrivateKey(pemRepresentation: pem)
    let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": a[2], "typ": "JWT"], options: [.sortedKeys])
    let now = Int(Date().timeIntervalSince1970)
    let claims = try JSONSerialization.data(withJSONObject: ["iss": a[3], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"], options: [.sortedKeys])
    let input = b64url(header) + "." + b64url(claims)
    let sig = try key.signature(for: Data(input.utf8))
    print(input + "." + b64url(sig.rawRepresentation))
} catch {
    FileHandle.standardError.write(Data("jwt: failed to sign\n".utf8)); exit(1)
}
