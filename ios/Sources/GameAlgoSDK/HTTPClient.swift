import Foundation

public enum GameAlgoHTTPMethod: String, Sendable, Equatable {
    case get = "GET"
    case post = "POST"
}

public struct GameAlgoHTTPRequest: Sendable, Equatable {
    public var url: URL
    public var method: GameAlgoHTTPMethod
    public var headers: [String: String]
    public var body: Data?

    public init(
        url: URL,
        method: GameAlgoHTTPMethod,
        headers: [String: String] = [:],
        body: Data? = nil
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

public struct GameAlgoHTTPResponse: Sendable, Equatable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(
        statusCode: Int,
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        let lowercasedName = name.lowercased()
        for (key, value) in headers where key.lowercased() == lowercasedName {
            return value
        }
        return nil
    }
}

public protocol GameAlgoHTTPClient: Sendable {
    func send(_ request: GameAlgoHTTPRequest) async throws -> GameAlgoHTTPResponse
}

public final class URLSessionGameAlgoHTTPClient: GameAlgoHTTPClient, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: GameAlgoHTTPRequest) async throws -> GameAlgoHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.httpBody = request.body

        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw GameAlgoError.invalidResponse
            }

            var headers: [String: String] = [:]
            for (key, value) in httpResponse.allHeaderFields {
                guard let key = key as? String else { continue }
                headers[key.lowercased()] = String(describing: value)
            }

            return GameAlgoHTTPResponse(
                statusCode: httpResponse.statusCode,
                headers: headers,
                body: data
            )
        } catch let error as GameAlgoError {
            throw error
        } catch {
            throw GameAlgoError.networkFailed(error.localizedDescription)
        }
    }
}
