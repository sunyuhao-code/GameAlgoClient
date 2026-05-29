import Foundation

public typealias GameAlgoLogHandler = @Sendable (String) -> Void

public enum GameAlgoLoggers {
    public static let console: GameAlgoLogHandler = { message in
        print(message)
    }
}
