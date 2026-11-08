import Foundation

struct Video: Identifiable, Hashable {
    let id: String
    let title: String
    let channel: String
    let duration: String
    let thumbnail: URL?

    var watchURL: URL { URL(string: "https://www.youtube.com/watch?v=\(id)")! }
}
