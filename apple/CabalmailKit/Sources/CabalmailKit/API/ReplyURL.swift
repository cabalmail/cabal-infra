import Foundation

extension URL {
    /// A URL from an API reply that the client may follow: absolute, `http`
    /// or `https`, with a host. Anything else reads as no URL at all.
    ///
    /// The Lambdas' `sign_url` answers the literal string `"Error"` inside a
    /// 200 when it can't sign, and `URL(string: "Error")` parses as a relative
    /// URL. Taken at face value, the client followed it as a second,
    /// unauthenticated GET to nowhere, and the reader said "Couldn't reach the
    /// server. unsupported URL." for a server-side signing failure (#1804).
    init?(followableReplyString raw: String) {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host(), !host.isEmpty
        else { return nil }
        self = url
    }
}
