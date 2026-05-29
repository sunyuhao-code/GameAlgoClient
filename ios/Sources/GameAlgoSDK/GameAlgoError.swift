import Foundation

public enum GameAlgoError: Error, Equatable, LocalizedError {
    case invalidURL(String)
    case invalidConfigFileName(String)
    case invalidEvents(String)
    case invalidResponse
    case apiError(statusCode: Int, code: String?, message: String)
    case encodingFailed(String)
    case decodingFailed(String)
    case networkFailed(String)
    case scriptExecutionFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidURL(value):
            return "Invalid URL: \(value)"
        case let .invalidConfigFileName(name):
            return "Invalid config file name: \(name)"
        case let .invalidEvents(message):
            return message
        case .invalidResponse:
            return "Invalid HTTP response"
        case let .apiError(statusCode, code, message):
            if let code {
                return "GameAlgo API returned \(statusCode) (\(code)): \(message)"
            }
            return "GameAlgo API returned \(statusCode): \(message)"
        case let .encodingFailed(message):
            return "Encoding failed: \(message)"
        case let .decodingFailed(message):
            return "Decoding failed: \(message)"
        case let .networkFailed(message):
            return "Network request failed: \(message)"
        case let .scriptExecutionFailed(message):
            return "Script execution failed: \(message)"
        }
    }
}
