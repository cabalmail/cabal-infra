import Foundation

/// Builds an RFC 5322 wire representation of an `OutgoingMessage`.
///
/// - Plain-text-only messages emit a single `text/plain` body.
/// - HTML-only messages emit a single `text/html` body.
/// - Mixed text + HTML emit a `multipart/alternative`.
/// - Any message with attachments is wrapped in a `multipart/mixed`.
///
/// Attachment content is base64-encoded with 76-column line wrapping per
/// RFC 2045. Header field values that contain non-ASCII bytes are emitted
/// as RFC 2047 encoded-words using Q-encoding (a subset that covers what
/// subjects typically contain; for genuinely binary subjects the caller
/// can pre-encode).
enum MessageBuilder {
    static func build(_ message: OutgoingMessage, messageID: String, date: Date = Date()) -> Data {
        var headers: [(String, String)] = []
        headers.append(("Date", formatDate(date)))
        headers.append(("From", formatAddressList([message.from])))
        if !message.to.isEmpty {
            headers.append(("To", formatAddressList(message.to)))
        }
        if !message.cc.isEmpty {
            headers.append(("Cc", formatAddressList(message.cc)))
        }
        // Bcc deliberately not included in the DATA payload — that's the
        // whole point of a blind copy. `SmtpClient` still sends RCPT TO for
        // each Bcc address so the server delivers the message.
        headers.append(("Subject", encodeIfNeeded(message.subject)))
        headers.append(("Message-ID", "<\(messageID)>"))
        if let inReplyTo = message.inReplyTo {
            headers.append(("In-Reply-To", "<\(inReplyTo)>"))
        }
        if !message.references.isEmpty {
            headers.append(("References", message.references.map { "<\($0)>" }.joined(separator: " ")))
        }
        headers.append(("MIME-Version", "1.0"))
        for (key, value) in message.extraHeaders {
            headers.append((key, value))
        }

        let bodyPart = renderBody(message, containerHeaders: &headers)
        var out = Data()
        for (key, value) in headers {
            out.append(Data("\(key): \(value)\r\n".utf8))
        }
        out.append(Data("\r\n".utf8))
        out.append(bodyPart)
        return out
    }

    private static func renderBody(_ message: OutgoingMessage, containerHeaders: inout [(String, String)]) -> Data {
        if !message.attachments.isEmpty {
            let mixedBoundary = boundary(prefix: "mixed")
            containerHeaders.append(("Content-Type", "multipart/mixed; boundary=\"\(mixedBoundary)\""))
            var parts: [Data] = []
            parts.append(bodyAsBestAlternative(message))
            for attachment in message.attachments {
                parts.append(renderAttachment(attachment))
            }
            return renderMultipart(parts: parts, boundary: mixedBoundary)
        }

        if message.textBody != nil && message.htmlBody != nil {
            let altBoundary = boundary(prefix: "alt")
            containerHeaders.append(("Content-Type", "multipart/alternative; boundary=\"\(altBoundary)\""))
            let textPart = renderTextPart(message.textBody ?? "", mimeType: "text/plain")
            let htmlPart = renderTextPart(message.htmlBody ?? "", mimeType: "text/html")
            return renderMultipart(parts: [textPart, htmlPart], boundary: altBoundary)
        }

        if let text = message.textBody {
            containerHeaders.append(("Content-Type", "text/plain; charset=utf-8"))
            containerHeaders.append(("Content-Transfer-Encoding", "8bit"))
            return normalizeCRLF(text)
        }
        if let html = message.htmlBody {
            containerHeaders.append(("Content-Type", "text/html; charset=utf-8"))
            containerHeaders.append(("Content-Transfer-Encoding", "8bit"))
            return normalizeCRLF(html)
        }

        containerHeaders.append(("Content-Type", "text/plain; charset=utf-8"))
        return Data()
    }

    private static func bodyAsBestAlternative(_ message: OutgoingMessage) -> Data {
        if message.textBody != nil && message.htmlBody != nil {
            let altBoundary = boundary(prefix: "alt")
            let textPart = renderTextPart(message.textBody ?? "", mimeType: "text/plain")
            let htmlPart = renderTextPart(message.htmlBody ?? "", mimeType: "text/html")
            var out = Data()
            out.append(Data("Content-Type: multipart/alternative; boundary=\"\(altBoundary)\"\r\n\r\n".utf8))
            out.append(renderMultipart(parts: [textPart, htmlPart], boundary: altBoundary))
            return out
        }
        if let html = message.htmlBody {
            return renderTextPart(html, mimeType: "text/html")
        }
        return renderTextPart(message.textBody ?? "", mimeType: "text/plain")
    }

    private static func renderTextPart(_ text: String, mimeType: String) -> Data {
        var out = Data()
        out.append(Data("Content-Type: \(mimeType); charset=utf-8\r\n".utf8))
        out.append(Data("Content-Transfer-Encoding: 8bit\r\n".utf8))
        out.append(Data("\r\n".utf8))
        out.append(normalizeCRLF(text))
        return out
    }

    private static func renderAttachment(_ attachment: Attachment) -> Data {
        var out = Data()
        out.append(Data("Content-Type: \(attachment.mimeType); name=\"\(attachment.filename)\"\r\n".utf8))
        out.append(Data("Content-Transfer-Encoding: base64\r\n".utf8))
        out.append(Data("Content-Disposition: attachment; filename=\"\(attachment.filename)\"\r\n".utf8))
        if let contentID = attachment.contentID {
            out.append(Data("Content-ID: <\(contentID)>\r\n".utf8))
        }
        out.append(Data("\r\n".utf8))
        let base64 = attachment.data.base64EncodedString()
        // Wrap at 76 characters per RFC 2045.
        var cursor = base64.startIndex
        while cursor < base64.endIndex {
            let end = base64.index(cursor, offsetBy: 76, limitedBy: base64.endIndex) ?? base64.endIndex
            out.append(Data(base64[cursor..<end].utf8))
            out.append(Data("\r\n".utf8))
            cursor = end
        }
        return out
    }

    private static func renderMultipart(parts: [Data], boundary: String) -> Data {
        var out = Data()
        for part in parts {
            out.append(Data("--\(boundary)\r\n".utf8))
            out.append(part)
            if let last = part.last, last != UInt8(ascii: "\n") {
                out.append(Data("\r\n".utf8))
            }
        }
        out.append(Data("--\(boundary)--\r\n".utf8))
        return out
    }

    private static func boundary(prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    }

    private static func normalizeCRLF(_ string: String) -> Data {
        let lfOnly = string.replacingOccurrences(of: "\r\n", with: "\n")
        let noBareCR = lfOnly.replacingOccurrences(of: "\r", with: "\n")
        let normalized = noBareCR.replacingOccurrences(of: "\n", with: "\r\n")
        return Data(normalized.utf8)
    }

    // MARK: - Header formatting

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }

    private static func formatAddressList(_ addresses: [EmailAddress]) -> String {
        addresses.map(formatAddress).joined(separator: ", ")
    }

    private static func formatAddress(_ address: EmailAddress) -> String {
        let addr = "\(address.mailbox)@\(address.host)"
        if let name = address.name, !name.isEmpty {
            return "\(encodeIfNeeded(name)) <\(addr)>"
        }
        return addr
    }

    private static func encodeIfNeeded(_ value: String) -> String {
        if value.allSatisfy({ $0.isASCII }) && !value.contains(where: \.isNewline) {
            return value
        }
        // RFC 2047 Q-encoded word. Good enough for subjects / display names;
        // the encoded word must not exceed 75 bytes, so break long values.
        let base64 = Data(value.utf8).base64EncodedString()
        return "=?utf-8?B?\(base64)?="
    }
}
