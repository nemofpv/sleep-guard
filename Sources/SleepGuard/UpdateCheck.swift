// The only place SleepGuard uses the network: asking GitHub which release is the latest.
//
// The request says nothing about this Mac or its user, and the answer is used for one thing:
// the version number in the menu's "Update available" row (see newerVersion in Policy.swift).
// Nothing is downloaded and nothing is installed; the row opens the release page in the browser.

import Foundation

let latestReleaseAPI = URL(string: "https://api.github.com/repos/nemofpv/sleep-guard/releases/latest")!
/// Where the "Update available" row leads. Fixed here: an address from the answer is never opened.
let releasesPage = URL(string: "https://github.com/nemofpv/sleep-guard/releases/latest")!

private let updateSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral   // no cookies, nothing cached on disk
    config.timeoutIntervalForRequest = 15
    config.timeoutIntervalForResource = 30
    return URLSession(configuration: config)
}()

/// Calls back on the main queue with the tag of the latest release, or nil when there was no
/// usable answer: offline, an error status, or a body that is not a release.
func fetchLatestReleaseTag(_ completion: @escaping (String?) -> Void) {
    var request = URLRequest(url: latestReleaseAPI)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    // GitHub refuses requests without a User-Agent. The default one would add the app's and the
    // system's version numbers; the bare name is enough.
    request.setValue("SleepGuard", forHTTPHeaderField: "User-Agent")
    updateSession.dataTask(with: request) { data, response, _ in
        let ok = (response as? HTTPURLResponse)?.statusCode == 200
        let tag = ok ? data.flatMap(latestReleaseTag(inJSON:)) : nil
        DispatchQueue.main.async { completion(tag) }
    }.resume()
}
