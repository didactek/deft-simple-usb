//
//  PlatformEndpointAddress.swift
//  deft-simple-usb
//
//  Created by Kit Transue on 2021-04-28.
//  Copyright © 2021 Kit Transue
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation

public struct PlatformEndpointAddress<RawValue: FixedWidthInteger> {
    enum EndpointDirection: RawValue {
        // Table 9-13. Standard Endpoint Descriptor
        case input = 0b1000_0000
        case output = 0
    }

    public let rawValue: RawValue

    public init(rawValue: RawValue) {
        self.rawValue = rawValue
    }

    // USB 2.0: 9.6.6 Endpoint:
    // Bit 7 is direction IN/OUT
    let directionMask = RawValue(EndpointDirection.input.rawValue | EndpointDirection.output.rawValue)

    public var isWritable: Bool {
        get {
            return rawValue & directionMask == EndpointDirection.output.rawValue
        }
    }
}
