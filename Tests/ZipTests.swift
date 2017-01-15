//
//  ZipTests.swift
//  SWCompression
//
//  Created by Timofey Solomko on 14.01.17.
//  Copyright © 2017 Timofey Solomko. All rights reserved.
//

import XCTest
import SWCompression

class ZipTests: XCTestCase {

    static let testType: String = "zip"

    func test() {
        guard let testData = try? Data(contentsOf: Constants.url(forTest: "SWCompressionSourceCode", withType: ZipTests.testType),
                                       options: .mappedIfSafe) else {
                                        XCTFail("Failed to load test archive")
                                        return
        }

        guard let zipDict = try? ZipContainer.open(containerData: testData) else {
            XCTFail("Unable to open ZIP archive.")
            return
        }

        guard zipDict.count == 211 else {
            XCTFail("Incorrect number of entries.")
            return
        }
    }

    func test64() {
        guard let testData = try? Data(contentsOf: Constants.url(forTest: "Zip64Test", withType: ZipTests.testType),
                                       options: .mappedIfSafe) else {
                                        XCTFail("Failed to load test archive")
                                        return
        }

        guard let zipDict = try? ZipContainer.open(containerData: testData) else {
            XCTFail("Unable to open ZIP archive.")
            return
        }

        guard zipDict.count == 1 else {
            XCTFail("Incorrect number of entries.")
            return
        }
    }

}