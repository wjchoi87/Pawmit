import XCTest
@testable import PawmitCore

final class GitHubReleaseTests: XCTestCase {
    func testLatestAPIFromRepoAddresses() {
        let api = "https://api.github.com/repos/wjchoi87/Pawmit/releases/latest"
        for raw in ["https://github.com/wjchoi87/Pawmit", "github.com/wjchoi87/Pawmit", " https://github.com/wjchoi87/Pawmit/ ",
                    "https://github.com/wjchoi87/Pawmit/releases", "https://github.com/wjchoi87/Pawmit.git",
                    "https://api.github.com/repos/wjchoi87/Pawmit", "https://api.github.com/repos/wjchoi87/Pawmit/releases/latest"] {
            XCTAssertEqual(GitHubRelease.latestAPI(for: raw)?.absoluteString, api, raw)
        }
        // update.json 주소·저장소 아닌 주소는 GitHub 경로를 타지 않는다
        XCTAssertNil(GitHubRelease.latestAPI(for: "https://example.com/pawmit/update.json"))
        XCTAssertNil(GitHubRelease.latestAPI(for: "https://github.com/wjchoi87"))
        XCTAssertNil(GitHubRelease.latestAPI(for: "http://github.com/wjchoi87/Pawmit"))
        XCTAssertNil(GitHubRelease.latestAPI(for: "https://github.com/a%2F..%2Fx/Pawmit"))
    }

    func testParseLatest() {
        let json = #"""
        {"tag_name":"v0.2.1","body":"백업 추가","assets":[
          {"name":"checksums.txt","browser_download_url":"https://x/checksums.txt"},
          {"name":"other.zip","browser_download_url":"https://x/other.zip"},
          {"name":"Pawmit-0.2.1.zip","browser_download_url":"https://x/Pawmit-0.2.1.zip"}]}
        """#
        XCTAssertEqual(GitHubRelease.parseLatest(Data(json.utf8)),
                       .init(version: "0.2.1", zipURL: "https://x/Pawmit-0.2.1.zip", notes: "백업 추가"))
        // Pawmit 이름이 없으면 첫 zip, zip이 없으면 nil
        let other = #"{"tag_name":"0.3.0","body":"","assets":[{"name":"app.zip","browser_download_url":"https://x/app.zip"}]}"#
        XCTAssertEqual(GitHubRelease.parseLatest(Data(other.utf8)), .init(version: "0.3.0", zipURL: "https://x/app.zip", notes: nil))
        // 디버그 심볼 zip은 건너뛴다 (실제 릴리스에서 첫 zip이 dSYM인 경우가 있었다)
        let dsym = #"{"tag_name":"v0.77.0","assets":[{"name":"App-0.77.0.dSYM.zip","browser_download_url":"https://x/a.dSYM.zip"},{"name":"App-0.77.0.zip","browser_download_url":"https://x/a.zip"}]}"#
        XCTAssertEqual(GitHubRelease.parseLatest(Data(dsym.utf8))?.zipURL, "https://x/a.zip")
        let noZip = #"{"tag_name":"v1.0.0","assets":[]}"#
        XCTAssertNil(GitHubRelease.parseLatest(Data(noZip.utf8))?.zipURL)
        XCTAssertNil(GitHubRelease.parseLatest(Data(#"{"message":"Not Found"}"#.utf8)))
        XCTAssertNil(GitHubRelease.parseLatest(Data("not json".utf8)))
    }
}

final class UpdateURLConfigTests: XCTestCase {
    func testDefaultIsPublicRepoAndEmptyMeansOff() throws {
        XCTAssertEqual(PawmitConfig().updateURL, "https://github.com/wjchoi87/Pawmit")
        // 키가 없거나 null → 기본 주소
        XCTAssertEqual(try JSONDecoder().decode(PawmitConfig.self, from: Data("{}".utf8)).updateURL, PawmitConfig.defaultUpdateURL)
        XCTAssertEqual(try JSONDecoder().decode(PawmitConfig.self, from: Data(#"{"updateURL":null}"#.utf8)).updateURL, PawmitConfig.defaultUpdateURL)
        // 빈 문자열 = 사용자가 끔 → 저장했다 다시 읽어도 꺼진 채로
        var off = PawmitConfig()
        off.updateURL = ""
        let reread = try JSONDecoder().decode(PawmitConfig.self, from: JSONEncoder().encode(off))
        XCTAssertEqual(reread.updateURL, "")
        // 직접 넣은 주소는 그대로
        XCTAssertEqual(try JSONDecoder().decode(PawmitConfig.self, from: Data(#"{"updateURL":"https://example.com/u.json"}"#.utf8)).updateURL,
                       "https://example.com/u.json")
    }
}
