import CryptoKit
import Foundation

/// Canonical JSON for the Cloud import manifest.
///
/// The server recomputes `aggregateSha256` over its own accepted aggregate and
/// refuses the import when the digest differs, so the client must emit exactly
/// the same bytes: the same keys, in the same order, with the same escaping and
/// integer formatting. This writer therefore does not use `JSONSerialization`
/// (which sorts or reorders keys and escapes control characters differently).
enum CloudCanonicalJSON {
    /// One JSON value in canonical form. Objects keep insertion order.
    indirect enum Value: Equatable {
        case string(String)
        case integer(Int)
        case bool(Bool)
        case null
        case array([Value])
        case object([(String, Value)])

        static func == (lhs: Value, rhs: Value) -> Bool { lhs.encoded == rhs.encoded }

        var encoded: String {
            switch self {
            case .string(let value): return CloudCanonicalJSON.quoted(value)
            case .integer(let value): return String(value)
            case .bool(let value): return value ? "true" : "false"
            case .null: return "null"
            case .array(let values): return "[" + values.map(\.encoded).joined(separator: ",") + "]"
            case .object(let members):
                return "{" + members.map { "\(CloudCanonicalJSON.quoted($0.0)):\($0.1.encoded)" }.joined(separator: ",") + "}"
            }
        }
    }

    /// JSON string escaping that matches `JSON.stringify`: only `"`, `\` and
    /// control characters are escaped, with the short forms where they exist.
    /// Non-ASCII text is emitted literally as UTF-8.
    static func quoted(_ value: String) -> String {
        var output = "\""
        for character in value.unicodeScalars {
            switch character {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            default:
                if character.value < 0x20 {
                    output += String(format: "\\u%04x", character.value)
                } else {
                    output.unicodeScalars.append(character)
                }
            }
        }
        return output + "\""
    }

    static func sha256Hex(of value: Value) -> String {
        SHA256.hash(data: Data(value.encoded.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension CloudImportManifest {
    /// ISO-8601 with milliseconds and a `Z` suffix, matching the server's
    /// `Date#toISOString` shape that the accepted aggregate is built from.
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private var canonicalLoans: [CloudCanonicalJSON.Value] {
        loans.map { loan in
            .object([
                ("id", .string(loan.id.uuidString.lowercased())),
                ("principalCents", .integer(loan.principalCents)),
                ("outstandingCents", .integer(loan.outstandingCents)),
                ("purpose", loan.purpose.map { CloudCanonicalJSON.Value.string($0) } ?? .null),
                ("dueDate", loan.dueDate.map { CloudCanonicalJSON.Value.string($0) } ?? .null),
                ("status", .string(loan.status)),
                ("createdAt", .string(Self.timestamp(loan.createdAt))),
                ("paidAt", loan.paidAt.map { CloudCanonicalJSON.Value.string(Self.timestamp($0)) } ?? .null),
            ] + (loan.schedule.map { schedule in
                [(
                    "schedule",
                    CloudCanonicalJSON.Value.object([
                        ("cadence", .string(schedule.cadence)),
                        ("amountCents", .integer(schedule.amountCents)),
                        ("firstDueDate", .string(schedule.firstDueDate)),
                    ])
                )]
            } ?? []))
        }
    }

    private var canonicalLoanOccurrences: [CloudCanonicalJSON.Value] {
        loanOccurrences.map { occurrence in
            .object([
                ("loanId", .string(occurrence.loanID.uuidString.lowercased())),
                ("dueOn", .string(occurrence.dueOn)),
                ("status", .string(occurrence.status)),
                (
                    "entryOperationId",
                    occurrence.entryOperationID.map { CloudCanonicalJSON.Value.string($0.uuidString.lowercased()) } ?? .null
                ),
            ])
        }
    }

    private var canonicalEntries: [CloudCanonicalJSON.Value] {
        entries.map { entry in
            .object([
                ("operationId", .string(entry.operationID.uuidString.lowercased())),
                ("type", .string(entry.type)),
                ("direction", .string(entry.direction)),
                ("amountCents", .integer(entry.amountCents)),
                ("balanceBeforeCents", .integer(entry.balanceBeforeCents)),
                ("balanceAfterCents", .integer(entry.balanceAfterCents)),
                ("reason", entry.reason.map { CloudCanonicalJSON.Value.string($0) } ?? .null),
                ("loanId", entry.loanID.map { CloudCanonicalJSON.Value.string($0.uuidString.lowercased()) } ?? .null),
                ("recordedAt", .string(Self.timestamp(entry.recordedAt))),
            ])
        }
    }

    /// The exact structure the server hashes: lineage, names, then the loan and
    /// entry arrays. `avatarUrl` is always present because the server
    /// normalizes a missing value to `null` before hashing.
    ///
    /// `loanOccurrences` is appended only when this household actually has a
    /// scheduled loan. `allowanceRule` is appended only when it has a weekly
    /// allowance. The server adds each key to its own expected digest only
    /// when a client sent it, so a household with neither hashes
    /// byte-for-byte what it hashed before those plans existed.
    var canonicalAggregate: CloudCanonicalJSON.Value {
        .object([
            ("lineageId", .string(lineageID.uuidString.lowercased())),
            ("familyName", .string(familyName)),
            ("nickname", .string(nickname)),
            ("avatarUrl", avatarURL.map { CloudCanonicalJSON.Value.string($0) } ?? .null),
            ("loans", .array(canonicalLoans)),
            ("entries", .array(canonicalEntries)),
        ] + (loanOccurrences.isEmpty ? [] : [("loanOccurrences", .array(canonicalLoanOccurrences))])
          + (allowanceRule.map { [("allowanceRule", canonicalAllowanceRule($0))] } ?? []))
    }

    private func canonicalAllowanceRule(_ rule: AllowanceRule) -> CloudCanonicalJSON.Value {
        .object([
            ("id", rule.id.map { CloudCanonicalJSON.Value.string($0) } ?? .null),
            ("amountCents", .integer(rule.amountCents)),
            ("cadence", .string(rule.cadence)),
            ("weekday", .integer(rule.weekday)),
            ("startDate", .string(rule.startDate)),
            ("endDate", rule.endDate.map { CloudCanonicalJSON.Value.string($0) } ?? .null),
            ("active", .bool(rule.active)),
            (
                "nextOccurrenceId",
                rule.nextOccurrenceID.map { CloudCanonicalJSON.Value.string($0) } ?? .null
            ),
            (
                "nextDueDate",
                rule.nextDueDate.map { CloudCanonicalJSON.Value.string($0) } ?? .null
            ),
        ])
    }

    public var aggregateSHA256: String { CloudCanonicalJSON.sha256Hex(of: canonicalAggregate) }

    /// The request body. It sends the same keys in the same order as the hashed
    /// aggregate, plus the import operation id and digest.
    public var requestBody: Data {
        let aggregate: [(String, CloudCanonicalJSON.Value)] = {
            guard case .object(let members) = canonicalAggregate else { return [] }
            return members
        }()
        let body = CloudCanonicalJSON.Value.object(
            [("operationId", .string(operationID.uuidString.lowercased())), ("aggregateSha256", .string(aggregateSHA256))] + aggregate
        )
        return Data(body.encoded.utf8)
    }
}
