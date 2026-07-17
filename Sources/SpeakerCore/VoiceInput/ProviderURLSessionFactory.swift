import Foundation

package enum ProviderURLSessionFactory {
    package static func ephemeralConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        return configuration
    }

    package static func makeSession() -> URLSession {
        URLSession(configuration: ephemeralConfiguration())
    }
}
