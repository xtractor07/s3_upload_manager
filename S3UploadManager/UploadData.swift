//
//  UploadData.swift
//  S3UploadManager
//
//  Created by Kumar Aman on 13/12/23.
//

import Foundation

struct CreateMultipartUploadResponse: Codable {
    let uploadId: String
    let fileKey: String

    enum CodingKeys: String, CodingKey {
        case uploadId = "UploadId"
        case fileKey = "fileKey"
    }
}

struct PreSignedURLResponse: Codable {
    struct Part: Codable {
        let signedUrl: String
        let partNumber: Int

        enum CodingKeys: String, CodingKey {
            case signedUrl = "signedUrl"
            case partNumber = "PartNumber"
        }
    }

    let parts: [Part]
}

enum UploadTaskType {
    case createMultipartUpload
    case getMultipartPreSignedUrls
    case uploadMedia
    case completeMultipartUpload
    // Add more task types as needed
}

struct CompleteUploadRequest: Encodable {
    let fileKey: String
    let UploadId: String
    let parts: [Part]
}

struct Part: Encodable {
    let PartNumber: Int
    let ETag: String
}

struct UploadData {
    var fileKey: String?
    var uploadId: String?
    var mediaUrl: URL?
    var mimeType: String?
    var eTag: String?
}
