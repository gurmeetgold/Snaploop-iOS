from pathlib import Path

path = Path('Sources/Features/MyPhotos/MyPhotosView.swift')
text = path.read_text()
old = '.safeAreaPadding(.top, 8)'
new = '.safeAreaPadding(.top, 16)'
count = text.count(old)
if count != 1:
    raise SystemExit(f'expected one top safe-area padding target, found {count}')
path.write_text(text.replace(old, new, 1))

test = Path('Tests/SnapLoopTests/PhotoDetailSafeAreaRegressionTests.swift')
test.write_text('''import XCTest\n\nfinal class PhotoDetailSafeAreaRegressionTests: XCTestCase {\n    func testPhotoDetailChromeUsesExtraTopSafeAreaClearance() throws {\n        let candidates = [\n            "Sources/Features/MyPhotos/MyPhotosView.swift",\n            "../../Sources/Features/MyPhotos/MyPhotosView.swift"\n        ]\n        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {\n            XCTFail("MyPhotosView.swift not found")\n            return\n        }\n        let source = try String(contentsOfFile: path)\n        XCTAssertTrue(source.contains(".safeAreaPadding(.top, 16)"))\n        XCTAssertFalse(source.contains(".safeAreaPadding(.top, 8)"))\n    }\n}\n''')
