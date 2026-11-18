import Foundation

// Port of desktop/src/drop.ts: files dropped on the Dock icon or opened with Vesper. Mirrors the
// server's POST /api/v1/chat-attachments rules so the person hears about a file the server would
// refuse before anything uploads (the server still checks every upload).

public struct DroppedFile: Sendable, Equatable {
    public var path: String
    public var size: Int
    public var isFile: Bool
    public init(path: String, size: Int, isFile: Bool = true) {
        self.path = path
        self.size = size
        self.isFile = isFile
    }
}

public struct AcceptedFile: Sendable, Equatable {
    public var path: String
    public var name: String
    public var size: Int
    public var mime: String
}

public struct RejectedFile: Sendable, Equatable {
    public var name: String
    public var reason: String
}

public struct SendFilesInput: Sendable {
    /// "new" for a new chat (with personaId, or the default persona), or an existing chat id.
    public var target: String
    public var personaId: String?
    public var message: String?
    public var attachmentIds: [String]
    public init(target: String, personaId: String? = nil, message: String? = nil, attachmentIds: [String]) {
        self.target = target
        self.personaId = personaId
        self.message = message
        self.attachmentIds = attachmentIds
    }
}

public enum Drop {
    public static let maxAttachmentBytes = 25 * 1024 * 1024
    /// POST /chats/{id}/messages takes at most 5 attachment ids.
    public static let maxAttachmentsPerMessage = 5

    /// Extensions the server accepts, with the MIME type sent in the multipart part.
    public static let attachmentTypes: [String: String] = [
        ".pdf": "application/pdf", ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
        ".gif": "image/gif", ".webp": "image/webp", ".txt": "text/plain", ".md": "text/markdown",
        ".markdown": "text/markdown", ".csv": "text/csv", ".json": "application/json", ".zip": "application/zip",
    ]

    public static func classifyDroppedFiles(_ files: [DroppedFile]) -> (accepted: [AcceptedFile], rejected: [RejectedFile]) {
        var accepted: [AcceptedFile] = []
        var rejected: [RejectedFile] = []
        var seen = Set<String>()
        for f in files {
            let name = (f.path as NSString).lastPathComponent
            if !seen.insert(f.path).inserted { continue }
            if !f.isFile {
                rejected.append(RejectedFile(name: name, reason: "Folders can't be attached; zip it first."))
                continue
            }
            let ext = (name as NSString).pathExtension.lowercased()
            guard !ext.isEmpty, let mime = attachmentTypes[".\(ext)"] else {
                rejected.append(RejectedFile(name: name, reason: "Unsupported type (PDF, images, text, Markdown, CSV, JSON or zip)."))
                continue
            }
            if f.size <= 0 {
                rejected.append(RejectedFile(name: name, reason: "The file is empty."))
                continue
            }
            if f.size > maxAttachmentBytes {
                rejected.append(RejectedFile(name: name, reason: "Over the 25 MB limit."))
                continue
            }
            if accepted.count >= maxAttachmentsPerMessage {
                rejected.append(RejectedFile(name: name, reason: "A message takes at most \(maxAttachmentsPerMessage) files."))
                continue
            }
            accepted.append(AcceptedFile(path: f.path, name: name, size: f.size, mime: mime))
        }
        return (accepted, rejected)
    }

    /// A filename safe inside a multipart Content-Disposition header.
    public static func safeMultipartFilename(_ name: String) -> String {
        var cleaned = ""
        for u in name.unicodeScalars {
            if u.value <= 0x1f || u.value == 0x7f || u == "\"" || u == "\\" { cleaned.unicodeScalars.append("_") } else { cleaned.unicodeScalars.append(u) }
        }
        cleaned = String(cleaned.prefix(200))
        return cleaned.isEmpty ? "file" : cleaned
    }

    /// One file as multipart/form-data with a single `file` field.
    public static func buildMultipartBody(
        fileName: String, mime: String, data: Data, boundary: String = "----vesper\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    ) -> (body: Data, contentType: String) {
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeMultipartFilename(fileName))\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return (body, "multipart/form-data; boundary=\(boundary)")
    }

    /// The API call that posts the uploaded files to a chat. Ids are validated; the person's text goes only in the JSON body.
    public static func buildSendFilesRequest(_ input: SendFilesInput) -> Result<APICall, CaptureError> {
        let ids = input.attachmentIds.filter { $0.range(of: uuidPattern, options: .regularExpression) != nil }
        if ids.isEmpty || ids.count != input.attachmentIds.count { return .failure(CaptureError("No files were uploaded.")) }
        if ids.count > maxAttachmentsPerMessage { return .failure(CaptureError("Too many files for one message.")) }
        let names = ids.count == 1 ? "this file" : "these files"
        let typed = (input.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let text = typed.isEmpty ? "Here's \(names)." : typed
        let message: APIBody = ["body": .string(text), "attachment_ids": .array(ids.map { .string($0) })]
        if input.target == "new" {
            let persona = (input.personaId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !persona.isEmpty && persona.range(of: uuidPattern, options: .regularExpression) == nil {
                return .failure(CaptureError("Pick a persona from the list."))
            }
            var body: APIBody = ["message": .object(message)]
            if !persona.isEmpty { body["persona_id"] = .string(persona) }
            return .success(APICall(path: "/api/v1/chats", body: body))
        }
        if input.target.range(of: uuidPattern, options: .regularExpression) == nil { return .failure(CaptureError("Pick a chat from the list.")) }
        return .success(APICall(path: "/api/v1/chats/\(input.target)/messages", body: message))
    }
}
