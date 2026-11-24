import Foundation
import Security

/// Validates corporate CA certificate files (PEM or binary DER) chosen in Settings
/// before handing their paths to the runner via `RUNNER_EXTRA_CA_FILE`.
public enum ExtraCACertificate {
    /// Matches Go's `maxExtraCAFileBytes` (1 MiB per file).
    public static let maxFileBytes = 1 << 20

    /// Returns true when `data` holds one or more valid X.509 certificates in either
    /// PEM format (with no non-certificate PEM blocks such as private keys) or
    /// binary DER format (single or concatenated).
    public static func isValidCertificateData(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= maxFileBytes else { return false }
        if let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN ") {
            return isValidPEMCertificates(text)
        }
        return isValidDERCertificates(data)
    }

    /// Validates a chosen certificate file on disk. Returns `nil` when valid, or an
    /// actionable error message otherwise.
    public static func validateFile(at url: URL) -> String? {
        let name = url.lastPathComponent
        if url.path.contains(":") {
            return "\(name) is in a path containing ':', which can't be passed to the runner."
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return "Couldn't read \(name)."
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxFileBytes + 1), !data.isEmpty else {
            return "\(name) is empty or unreadable."
        }
        if data.count > maxFileBytes {
            return "\(name) is larger than 1 MB."
        }
        if !isValidCertificateData(data) {
            return "\(name) isn't a valid PEM or DER certificate (files containing private keys are refused)."
        }
        return nil
    }

    private static func isValidPEMCertificates(_ text: String) -> Bool {
        var inCert = false
        var body = ""
        var count = 0
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("-----BEGIN ") && line.hasSuffix("-----") {
                if inCert { return false }
                let label = line.dropFirst("-----BEGIN ".count).dropLast("-----".count)
                guard label == "CERTIFICATE" else { return false }
                inCert = true
                body = ""
            } else if line.hasPrefix("-----END ") && line.hasSuffix("-----") {
                let label = line.dropFirst("-----END ".count).dropLast("-----".count)
                guard inCert, label == "CERTIFICATE" else { return false }
                guard let der = Data(base64Encoded: body, options: .ignoreUnknownCharacters),
                      !der.isEmpty,
                      SecCertificateCreateWithData(nil, der as CFData) != nil
                else { return false }
                inCert = false
                body = ""
                count += 1
            } else if inCert {
                body.append(line)
            }
        }
        return !inCert && count > 0
    }

    private static func isValidDERCertificates(_ data: Data) -> Bool {
        let bytes = Array(data)
        var offset = 0
        var count = 0
        while offset < bytes.count {
            guard offset + 1 < bytes.count, bytes[offset] == 0x30 else { return false }
            let lengthByte = bytes[offset + 1]
            let headerLen: Int
            let contentLen: Int
            if lengthByte < 0x80 {
                headerLen = 2
                contentLen = Int(lengthByte)
            } else {
                let numLenBytes = Int(lengthByte & 0x7f)
                guard numLenBytes > 0, numLenBytes <= 4, offset + 2 + numLenBytes <= bytes.count else { return false }
                var len = 0
                for j in 0..<numLenBytes {
                    len = (len << 8) | Int(bytes[offset + 2 + j])
                }
                headerLen = 2 + numLenBytes
                contentLen = len
            }
            let total = headerLen + contentLen
            guard total > headerLen, offset + total <= bytes.count else { return false }
            let slice = Data(bytes[offset..<(offset + total)])
            guard SecCertificateCreateWithData(nil, slice as CFData) != nil else { return false }
            offset += total
            count += 1
        }
        return count > 0
    }
}
