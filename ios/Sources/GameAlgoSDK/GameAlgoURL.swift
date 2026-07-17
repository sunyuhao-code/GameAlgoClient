import Foundation

func gameAlgoEndpoint(baseURL: URL, path: String) -> URL? {
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else {
        return nil
    }
    let basePath = components.percentEncodedPath.replacingOccurrences(
        of: "/+$",
        with: "",
        options: .regularExpression
    )
    let endpointPath = path.replacingOccurrences(
        of: "^/+",
        with: "",
        options: .regularExpression
    )
    components.percentEncodedPath = "\(basePath)/\(endpointPath)"
    components.query = nil
    components.fragment = nil
    return components.url
}
