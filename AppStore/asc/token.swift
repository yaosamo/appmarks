// Prints an App Store Connect API token (ES256 JWT, valid 20 minutes) for the key in
// ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8.
//
//   swift AppStore/asc/token.swift <KEY_ID> <ISSUER_ID> > token   (then: curl -H @header …)
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: token.swift KEY_ID ISSUER_ID\n".data(using: .utf8)!)
    exit(1)
}
let (keyID, issuer) = (args[1], args[2])
let path = NSString(string: "~/.appstoreconnect/private_keys/AuthKey_\(keyID).p8").expandingTildeInPath
let key = try P256.Signing.PrivateKey(pemRepresentation: String(contentsOfFile: path, encoding: .utf8))

func b64(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }

let now = Int(Date().timeIntervalSince1970)
let header = b64(json(["alg": "ES256", "kid": keyID, "typ": "JWT"]))
let claims = b64(json(["iss": issuer, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"]))
let input = "\(header).\(claims)"
let signature = try key.signature(for: Data(input.utf8)).rawRepresentation
print("\(input).\(b64(signature))")
